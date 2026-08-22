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

# O-RAN timing windows — the most RU-specific values in the stack.
for t in T1a_max_cp_ul_ns T1a_min_cp_ul_ns T1a_max_cp_dl_ns T1a_min_cp_dl_ns \
         T1a_max_up_ns Ta4_min_ns Ta4_max_ns Tcp_adv_dl_ns ul_u_plane_tx_offset_ns; do
  v="$(s ".ru.timing.$t")"
  [ -n "$v" ] && [ "$v" != "0" ] && yq -i ".cuphydriver_config.$CELLS[0].$t = $v" "$L1"
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
PRB="$(s .cell.prb)"
GT="$(ls "$CONFD"/*band$(s .cell.band).${PRB}prb*aerial*.conf 2>/dev/null | grep -v ul-heavy | head -1)"
if [ -z "$GT" ]; then
  GT="$(ls "$CONFD"/*band*aerial*.conf 2>/dev/null | grep -v ul-heavy | head -1)"
  [ -n "$GT" ] && echo ">> WARNING: no ${PRB}prb template; falling back to $(basename "$GT")." \
               && echo "   Check initialDLBWPlocationAndBandwidth by hand — it is PRB-specific."
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
