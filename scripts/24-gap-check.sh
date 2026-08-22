#!/usr/bin/env bash
# What is still missing between "host is ready" and "the DU can start"?
# READ-ONLY. Answers, concretely: is there a compiled L1, is the L2 image built,
# is the core reachable, is the fronthaul live, is there a cluster.
#
#   ./scripts/24-gap-check.sh
#
# Site values are read from site/config (put there by 23-extract-site-config.sh)
# so nothing about your deployment is hardcoded in this public repo.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
SITE="$ROOT/site/config"
SELF_STACK="$ROOT/stack"

ok()   { printf '  \033[32mOK  \033[0m  %s\n' "$*"; }
gap()  { printf '  \033[31mGAP \033[0m  %s\n' "$*"; }
info() { printf '  ....  %s\n' "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }

sec "1. Compiled Aerial L1 binary"
# run_l1.sh looks for build.$(uname -m)/... then build/... under cuBB_SDK.
ARCH="$(uname -m)"
FOUND_BIN=""
while read -r b; do
  [ -n "$b" ] || continue
  FOUND_BIN="$b"
  info "found: $b"
done < <(find "$HOME" -maxdepth 8 -type f -name cuphycontroller_scf -perm -u+x 2>/dev/null | head -5)
if [ -z "$FOUND_BIN" ]; then
  gap "no compiled cuphycontroller_scf anywhere — the L1 must be built (cuBB build inside the container)"
else
  # Would run_l1.sh actually find it? It only tries two directory names.
  root="${FOUND_BIN%%/cuPHY-CP/*}"; bdir="$(basename "$root")"
  if [ "$bdir" = "build.$ARCH" ] || [ "$bdir" = "build" ]; then
    ok "binary is in '$bdir' — run_l1.sh will find it"
  else
    gap "binary is in '$bdir', but run_l1.sh only checks 'build.$ARCH' and 'build'"
    info "fix: symlink it, e.g.  ln -s $bdir \$(dirname $root)/build.$ARCH"
  fi
fi

sec "2. cuBB tree at the path the launch config mounts"
MOUNT_SRC=""
[ -f "$SITE/docker-compose.yaml" ] && MOUNT_SRC="$(grep -oE '^[[:space:]]*-[[:space:]]*[^:]*:/opt/nvidia/cuBB' "$SITE/docker-compose.yaml" | head -1 | sed 's/.*- *//; s/:.*//')"
[ -n "$MOUNT_SRC" ] && info "compose mounts: $MOUNT_SRC -> /opt/nvidia/cuBB"
for p in "${MOUNT_SRC/#\~/$HOME}" /opt/aerial/cuBB /opt/nvidia/cuBB; do
  [ -n "$p" ] || continue
  if [ -d "$p" ]; then ok "exists: $p"; else gap "absent: $p"; fi
done

sec "3. OAI L2 image"
for img in oai-gnb-aerial ran-base ran-build; do
  if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^$img:"; then
    ok "$img present"
  else
    [ "$img" = "oai-gnb-aerial" ] && gap "$img MISSING — the L2 container image must be built" \
                                  || info "$img not present"
  fi
done
# OAI needs nvIPC headers/libs extracted from the Aerial image to build with
# `nfapi = AERIAL`; the tarball is the usual way that gets staged.
NVIPC="$(find "$HOME" -maxdepth 7 -name 'nvipc_src*.tar.gz' 2>/dev/null | head -3)"
[ -n "$NVIPC" ] && { ok "nvIPC source tarball present:"; printf '        %s\n' $NVIPC; } \
                || info "no nvipc_src tarball found (extracted from the Aerial container at build time)"

sec "4. 5G core reachability (the gNB config points at an AMF)"
CONF="$(ls "$SITE"/*aerial.conf 2>/dev/null | head -1)"
if [ -f "$CONF" ]; then
  AMF="$(grep -oE 'ipv4[[:space:]]*=[[:space:]]*"[0-9.]+"' "$CONF" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  LOCAL="$(grep -oE 'GNB_IPV4_ADDRESS_FOR_NG_AMF[^"]*"[0-9./]+"' "$CONF" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  info "AMF in config: ${AMF:-none}   gNB N2 address: ${LOCAL:-none}"
  if [ -n "$LOCAL" ]; then
    ip -4 addr show 2>/dev/null | grep -q "$LOCAL" && ok "$LOCAL is configured on this host" \
      || gap "$LOCAL is NOT on any interface here — the gNB cannot bind N2/N3"
  fi
  if [ -n "$AMF" ]; then
    if ping -c1 -W2 "$AMF" >/dev/null 2>&1; then
      ok "AMF $AMF responds to ping"
      if command -v ncat >/dev/null 2>&1; then
        ncat -z --sctp -w3 "$AMF" 38412 >/dev/null 2>&1 \
          && ok "AMF SCTP 38412 open — an existing core is live" \
          || gap "AMF SCTP 38412 closed — core not listening (deploy one, or fix the address)"
      else
        info "install ncat to test SCTP 38412"
      fi
    else
      gap "AMF $AMF unreachable — you will need to deploy a core, or repoint the gNB"
    fi
  fi
else
  gap "no gNB config in site/config — run ./scripts/23-extract-site-config.sh"
fi

sec "5. Fronthaul / RU"
RU_MAC="$(grep -ohiE 'dst_mac_addr:[[:space:]]*([0-9a-f]{2}:){5}[0-9a-f]{2}' "$SITE"/cuphycontroller_*.yaml 2>/dev/null | head -1 | awk '{print tolower($2)}')"
[ -n "$RU_MAC" ] && info "RU MAC from config: $RU_MAC" || info "no RU MAC in site/config"
for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
  [ "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" = "up" ] || continue
  [ "$(cat "/sys/class/net/$i/mtu" 2>/dev/null)" -ge 8192 ] 2>/dev/null || continue
  ok "fronthaul port up with jumbo MTU: $i"
done
if [ -n "$RU_MAC" ] && ip neigh 2>/dev/null | grep -qi "$RU_MAC"; then
  ok "RU MAC seen in the neighbour table"
else
  info "RU MAC not in the neighbour table (normal: eCPRI is L2, it need not ARP)"
fi

sec "6. Cluster"
for b in k3s kubectl helm; do
  command -v "$b" >/dev/null 2>&1 && ok "$b: $(command -v $b)" || gap "$b not installed"
done
kubectl get nodes >/dev/null 2>&1 && ok "a cluster is reachable" || info "no cluster reachable yet"

sec "7. MPS"
pgrep -af nvidia-cuda-mps-control >/dev/null 2>&1 \
  && ok "MPS control running" \
  || info "MPS not running — run_l1.sh starts it itself at L1 launch"

printf '\n>> GAP lines above are what stands between this host and a running DU.\n'
