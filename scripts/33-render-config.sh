#!/usr/bin/env bash
# Render the DU's runtime configs from site/site.yaml + the PRISTINE upstream
# templates in stack/. Output goes to site/rendered/.
#
#   ./scripts/33-render-config.sh
#
# This is what makes the repo portable. Nothing is copied from a previous
# deployment: the templates come from the version-pinned upstream clones, and
# every site-specific value comes from site/site.yaml. Given the same site.yaml,
# a bare server produces byte-identical configs to this one.
#
# It prints a diff of every change it makes against the untouched template, so
# the derivation is reviewable rather than magic.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
. "$ROOT/scripts/lib-tools.sh"
need_tool yq || { echo "yq is required" >&2; exit 1; }
export PATH="$HOME/.local/bin:$PATH"

STACK="${STACK_DIR:-$ROOT/stack}"
SITE="$ROOT/site/site.yaml"
OUT="$ROOT/site/rendered"
PROFILE="${PROFILE:-P5G_WNC_DGX}"   # which upstream template to start from

[ -f "$SITE" ] || { echo "missing $SITE — copy site.example.yaml and fill it in" >&2; exit 1; }
mkdir -p "$OUT"

s() { yq -r "$1 // \"\"" "$SITE"; }   # scalar from site.yaml
a() { yq -o=json -I=0 "$1"  "$SITE"; } # array from site.yaml, as JSON/flow

# ---------------------------------------------------------------- L1 config
TPL="$STACK/aerial-cuda-accelerated-ran/cuPHY-CP/cuphycontroller/config/cuphycontroller_${PROFILE}.yaml"
[ -f "$TPL" ] || {
  echo "template not found: $TPL" >&2
  echo "available profiles:" >&2
  ls -1 "$(dirname "$TPL")" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
}
L1="$OUT/cuphycontroller_site.yaml"
cp "$TPL" "$L1"
echo ">> L1 template: $TPL"

# The per-cell array has been named differently across releases; find it rather
# than assume, so a rename upstream fails loudly here instead of silently
# writing nothing.
CELLS=""
for k in cell_configs cells cellConfigs; do
  [ "$(yq ".cuphydriver_config.$k[0].dst_mac_addr // \"\"" "$L1")" != "" ] && { CELLS="$k"; break; }
done
[ -n "$CELLS" ] || { echo "could not locate the cell array in $TPL" >&2; exit 1; }
echo "   cell array: cuphydriver_config.$CELLS  (cells: $(yq ".cuphydriver_config.$CELLS | length" "$L1"))"

# Cell 0 is the only one this DU serves. The remaining blocks are upstream
# placeholders; cell_group_num keeps them inert, and we do not touch them.
RU_MAC="$(s .ru.mac)"; VLAN="$(s .ru.vlan)"; PCP="$(s .ru.pcp)"; NIC="$(s .fronthaul.nic_pcie)"
yq -i "
  .cuphydriver_config.$CELLS[0].dst_mac_addr = \"$RU_MAC\" |
  .cuphydriver_config.$CELLS[0].src_mac_addr = \"00:00:00:00:00:00\" |
  .cuphydriver_config.$CELLS[0].vlan = $VLAN |
  .cuphydriver_config.$CELLS[0].pcp  = $PCP  |
  .cuphydriver_config.$CELLS[0].nic  = \"$NIC\"
" "$L1"

for k in eAxC_id_ssb_pbch:ssb_pbch eAxC_id_pdcch:pdcch eAxC_id_pdsch:pdsch eAxC_id_csirs:csirs \
         eAxC_id_pusch:pusch eAxC_id_pucch:pucch eAxC_id_prach:prach eAxC_id_srs:srs; do
  yq -i ".cuphydriver_config.$CELLS[0].${k%%:*} = $(a ".ru.eaxc.${k##*:}")" "$L1"
done

# O-RAN timing windows and PCP go on EVERY cell, not just cell 0.
#
# The other cell entries are upstream placeholders pointing at RUs that do not
# exist here, but the L1 still validates them at CONFIG.request time, and a
# block carrying the vendor's reference timing alongside ours is inconsistent.
# The known-good config on this site sets them identically across all cells.
NCELLS="$(yq ".cuphydriver_config.$CELLS | length" "$L1")"
for t in T1a_max_cp_ul_ns T1a_min_cp_ul_ns T1a_max_cp_dl_ns T1a_min_cp_dl_ns \
         T1a_max_up_ns Ta4_min_ns Ta4_max_ns Tcp_adv_dl_ns ul_u_plane_tx_offset_ns; do
  v="$(s ".ru.timing.$t")"
  [ -n "$v" ] && [ "$v" != "0" ] && yq -i ".cuphydriver_config.$CELLS[].$t = $v" "$L1"
done
yq -i ".cuphydriver_config.$CELLS[].pcp = $PCP" "$L1"
echo "   timing + pcp applied to all $NCELLS cells"

# Global cuPHY tuning. NOT cosmetic: prach_aggr_per_ctx in particular decides
# how many PRACH occasions a context aggregates, and too low a value makes
# cuphyValidatePrachParams reject the cell with "pOccaPrms is null" -- which
# reads like a PRACH *configuration* error in the gNB conf, not a cuPHY
# capacity one.
for k in mps_sm_ul_order pusch_aggr_per_ctx prach_aggr_per_ctx pucch_aggr_per_ctx srs_aggr_per_ctx; do
  v="$(s ".aerial.$k")"
  if [ -n "$v" ] && [ "$v" != "null" ] && [ "$v" != "0" ]; then
    yq -i ".cuphydriver_config.$k = $v" "$L1"
    echo "   aerial.$k = $v"
  fi
done

# CPU pinning: absolute core ids, which must sit inside the kernel's isolcpus.
yq -i "
  .cuphydriver_config.workers_ul = $(a .cpu.aerial_workers_ul) |
  .cuphydriver_config.workers_dl = $(a .cpu.aerial_workers_dl) |
  .low_priority_core = $(s .cpu.aerial_low_priority)
" "$L1"

# dApp support: without both of these the E3 agent never starts and a dApp
# waits forever with no error.
if [ "$(s .dapp.enabled)" = "true" ]; then
  yq -i "
    .cuphydriver_config.data_config.data_core = $(s .cpu.data_core) |
    .cuphydriver_config.data_config.e3_agent_enable = 1
  " "$L1"
  echo "   dApp: E3 agent enabled on core $(s .cpu.data_core)"
fi

# ---------------------------------------------------------------- L2 config
# Pick the template matching this cell's bandwidth. OAI ships 106prb and
# 273prb variants and the first alphabetically is 106 -- but the templates
# differ in more than dl_carrierBandwidth: initialDLBWPlocationAndBandwidth
# encodes RBstart and length for that PRB count and is NOT templated here, so
# starting from the wrong one yields a subtly wrong initial bandwidth part.
CONFD="$STACK/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF"
PRB="$(s .cell.prb)"; BAND="$(s .cell.band)"
# Require a name ending exactly in ".aerial.conf". OAI also ships variants like
# .aerial.20.conf, .aerial.21.conf and .aerial.ul-heavy.conf, and "2" sorts
# before "c" so an alphabetical pick lands on .20 -- a different cell's config
# whose other parameters we do not template.
GT="$(ls "$CONFD"/*band${BAND}.${PRB}prb*.aerial.conf 2>/dev/null | head -1)"
if [ -z "$GT" ]; then
  echo ">> No canonical band${BAND}/${PRB}prb aerial template. Candidates:"
  ls -1 "$CONFD"/*aerial*.conf 2>/dev/null | sed 's|.*/|     |'
  echo ">> Refusing to guess: variants differ in parameters this script does not"
  echo "   template (initialDLBWPlocationAndBandwidth, MACRLC tuning)."
  exit 1
fi
L2="$OUT/gnb.conf"
if [ -n "$GT" ]; then
  cp "$GT" "$L2"
  echo ">> L2 template: $GT"
  # libconfig, not YAML: targeted key = value; rewrites that keep indentation.
  setc() { sed -i -E "s|^([[:space:]]*$1[[:space:]]*=[[:space:]]*)[^;,]*|\1$2|" "$L2"; }
  inl()  { sed -i -E "s|($1[[:space:]]*=[[:space:]]*)[0-9]+|\1$2|g" "$L2"; }

  setc gNB_ID "$(s .gnb.id)"
  setc gNB_name "\"$(s .gnb.name)\""
  setc tracking_area_code "$(s .plmn.tac)"
  inl  mcc "$(s .plmn.mcc)"; inl mnc "$(s .plmn.mnc)"
  setc physCellId "$(s .cell.phys_cell_id)"
  setc nr_cellid "$(s .cell.nr_cellid)L"
  setc absoluteFrequencySSB "$(s .cell.absolute_frequency_ssb)"
  setc dl_absoluteFrequencyPointA "$(s .cell.absolute_frequency_point_a)"
  setc dl_carrierBandwidth "$(s .cell.prb)"; setc ul_carrierBandwidth "$(s .cell.prb)"
  setc prach_ConfigurationIndex "$(s .cell.prach_configuration_index)"
  setc pdsch_AntennaPorts_XP "$(s .cell.pdsch_antenna_ports_xp)"
  setc pdsch_AntennaPorts_N1 "$(s .cell.pdsch_antenna_ports_n1)"
  setc pusch_AntennaPorts "$(s .cell.pusch_antenna_ports)"
  setc nrofDownlinkSlots "$(s .cell.tdd.dl_slots)"
  setc nrofDownlinkSymbols "$(s .cell.tdd.dl_symbols)"
  setc nrofUplinkSlots "$(s .cell.tdd.ul_slots)"
  setc nrofUplinkSymbols "$(s .cell.tdd.ul_symbols)"
  setc tr_s_poll_core "$(s .cpu.oai_poll_core)"
  # AMF address and the gNB's own N2/N3 bind address.
  sed -i -E "s|(ipv4[[:space:]]*=[[:space:]]*\")[0-9.]+|\1$(s .core.amf_ip)|" "$L2"
  sed -i -E "s|(GNB_IPV4_ADDRESS_FOR_NG_AMF[^\"]*\")[0-9./]+|\1$(s .core.gnb_n2_ip)|" "$L2"
  sed -i -E "s|(GNB_IPV4_ADDRESS_FOR_NGU[^\"]*\")[0-9./]+|\1$(s .core.gnb_n2_ip)|" "$L2"
else
  echo ">> WARNING: no gNB template found under stack/openairinterface5g — skipping L2"
fi

# ---------------------------------------------------------------- verify
# Both sed and yq no-op silently when a key is absent from the template. A
# template variant missing one key would otherwise deploy with the upstream
# value and look, in the diff, exactly like "nothing needed changing".
vfail=0
ck() { # ck <label> <want> <got>
  if [ "$2" = "$3" ]; then printf '  ok    %-30s %s\n' "$1" "$3"
  else printf '  FAIL  %-30s want=%s got=%s\n' "$1" "$2" "${3:-<absent>}"; vfail=1; fi
}
echo
echo "===== verification: did every value land? ====="
ck "L1 cell0 dst_mac" "$RU_MAC" "$(yq ".cuphydriver_config.$CELLS[0].dst_mac_addr" "$L1")"
ck "L1 cell0 vlan"    "$VLAN"   "$(yq ".cuphydriver_config.$CELLS[0].vlan" "$L1")"
ck "L1 cell0 pcp"     "$PCP"    "$(yq ".cuphydriver_config.$CELLS[0].pcp" "$L1")"
ck "L1 cell0 nic"     "$NIC"    "$(yq ".cuphydriver_config.$CELLS[0].nic" "$L1")"
for t in T1a_min_cp_dl_ns Ta4_max_ns; do
  want="$(s ".ru.timing.$t")"
  [ -n "$want" ] && [ "$want" != "0" ] && ck "L1 $t" "$want" "$(yq ".cuphydriver_config.$CELLS[0].$t" "$L1")"
done
if [ "$(s .dapp.enabled)" = "true" ]; then
  ck "L1 data_core" "$(s .cpu.data_core)" "$(yq '.cuphydriver_config.data_config.data_core' "$L1")"
  ck "L1 e3_agent_enable" "1" "$(yq '.cuphydriver_config.data_config.e3_agent_enable' "$L1")"
fi
# Global tuning, and the LAST cell -- proving the loop reached every entry and
# not just cell 0, which is the mistake this check exists to catch.
for k in mps_sm_ul_order pusch_aggr_per_ctx prach_aggr_per_ctx; do
  want="$(s ".aerial.$k")"
  [ -n "$want" ] && [ "$want" != "0" ] && [ "$want" != "null" ] \
    && ck "L1 $k" "$want" "$(yq ".cuphydriver_config.$k" "$L1")"
done
LAST=$(( $(yq ".cuphydriver_config.$CELLS | length" "$L1") - 1 ))
ck "L1 cell$LAST pcp"  "$PCP" "$(yq ".cuphydriver_config.$CELLS[$LAST].pcp" "$L1")"
ck "L1 cell$LAST T1a_min_cp_dl_ns" "$(s .ru.timing.T1a_min_cp_dl_ns)" \
   "$(yq ".cuphydriver_config.$CELLS[$LAST].T1a_min_cp_dl_ns" "$L1")"
if [ -f "${L2:-}" ]; then
  gv() { grep -m1 -E "^[[:space:]]*$1[[:space:]]*=" "$L2" \
         | sed -E 's/^[^=]*=[[:space:]]*//; s/[;,].*//; s/[[:space:]]*#.*//' | tr -d '"L '; }
  ck "L2 physCellId"   "$(s .cell.phys_cell_id)" "$(gv physCellId)"
  ck "L2 nr_cellid"    "$(s .cell.nr_cellid)"    "$(gv nr_cellid)"
  ck "L2 prach index"  "$(s .cell.prach_configuration_index)" "$(gv prach_ConfigurationIndex)"
  ck "L2 dl_carrierBW" "$PRB" "$(gv dl_carrierBandwidth)"
  ck "L2 SSB arfcn"    "$(s .cell.absolute_frequency_ssb)" "$(gv absoluteFrequencySSB)"
  ck "L2 dl_slots"     "$(s .cell.tdd.dl_slots)"   "$(gv nrofDownlinkSlots)"
  ck "L2 ul_symbols"   "$(s .cell.tdd.ul_symbols)" "$(gv nrofUplinkSymbols)"
  ck "L2 pusch ports"  "$(s .cell.pusch_antenna_ports)" "$(gv pusch_AntennaPorts)"
  ck "L2 tr_s_poll_core" "$(s .cpu.oai_poll_core)" "$(gv tr_s_poll_core)"
  ck "L2 amf_ip" "$(s .core.amf_ip)" \
     "$(grep -m1 -oE 'ipv4[^"]*"[0-9.]+' "$L2" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
  ck "L2 gnb_n2_ip" "$(s .core.gnb_n2_ip)" \
     "$(grep -m1 -oE 'GNB_IPV4_ADDRESS_FOR_NG_AMF[^"]*"[0-9./]+' "$L2" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
fi
if [ "$vfail" != 0 ]; then
  echo
  echo ">> Some values did not reach the rendered config. NOT safe to deploy."
  echo "   A FAIL usually means the chosen template lacks that key."
  exit 1
fi

# ---------------------------------------------------------------- review
echo
echo "===== L1 changes vs pristine template ====="
diff -u "$TPL" "$L1" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | sed 's/^/  /' || echo "  (none)"
if [ -f "$L2" ] && [ -n "$GT" ]; then
  echo
  echo "===== L2 changes vs pristine template ====="
  diff -u "$GT" "$L2" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | sed 's/^/  /' || echo "  (none)"
fi
echo
echo ">> rendered: $L1"
[ -f "$L2" ] && echo ">> rendered: $L2"
echo ">> review the diffs above, then: ./scripts/34-deploy-du.sh"
