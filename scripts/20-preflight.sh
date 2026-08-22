#!/usr/bin/env bash
# Check that this host is ready to run Aerial L1. READ-ONLY: it changes nothing.
#
#   ./scripts/20-preflight.sh
#
# Host preparation (driver, kernel, DOCA/OFED, hugepages, CPU isolation, NIC
# firmware, PTP) is deliberately OUT of scope for this repo -- it is done once
# per box, usually by whoever racked it, following NVIDIA's DGX Spark install
# guide. This script only tells you whether that work is present and correct,
# so a later failure in the RAN can be blamed on the RAN and not the host.
#
# Exit: 0 all good, 1 something FAILED.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/site/versions.env" ] && . "$ROOT/site/versions.env"

pass=0; warnc=0; failc=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warnc=$((warnc+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failc=$((failc+1)); }
sec()  { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# cmp_ver <label> <found> <expected>  — exact match expected, near-match warns
cmp_ver() {
  if [ -z "$2" ];        then bad  "$1: not detected (expected $3)"
  elif [ "$2" = "$3" ];  then ok   "$1: $2"
  else                        warn "$1: $2 (validated: $3)"
  fi
}

sec "Platform"
ARCH="$(uname -m)"; cmp_ver "arch" "$ARCH" "$REQ_ARCH"
cmp_ver "kernel" "$(uname -r)" "$REQ_KERNEL"

sec "GPU"
if have nvidia-smi; then
  cmp_ver "driver" "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" "$REQ_DRIVER"
  GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  [ -n "$GPU" ] && ok "gpu: $GPU" || bad "no GPU reported"
  CU="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: *[0-9.]+' | grep -oE '[0-9.]+' | head -1)"
  cmp_ver "cuda" "$CU" "$REQ_CUDA"
else
  bad "nvidia-smi not found"
fi

sec "CUDA MPS (required: cuPHY partitions SMs across PUSCH/PDSCH/... via MPS)"
# GB10 has no MIG, so MPS is the only way to share the GPU with a dApp.
if pgrep -af nvidia-cuda-mps-control >/dev/null 2>&1; then
  ok "mps-control running"
else
  warn "MPS not running — start it before launching L1 (nvidia-cuda-mps-control -d)"
fi

sec "Memory / hugepages"
HP_SZ="$(grep -i '^Hugepagesize' /proc/meminfo | awk '{print $2}')"
HP_N="$(grep -i '^HugePages_Total' /proc/meminfo | awk '{print $2}')"
if [ "${HP_SZ:-0}" = "1048576" ]; then ok "hugepage size: 1G"
else warn "hugepage size: ${HP_SZ:-none} kB (expected 1048576 = 1G)"; fi
if [ "${HP_N:-0}" -ge "$REQ_HUGEPAGES_1G" ] 2>/dev/null; then ok "hugepages: $HP_N x 1G"
else bad "hugepages: ${HP_N:-0} (expected >= $REQ_HUGEPAGES_1G)"; fi

sec "CPU isolation"
CMD="$(cat /proc/cmdline)"
for k in isolcpus nohz_full rcu_nocbs; do
  v="$(printf '%s\n' "$CMD" | grep -oE "${k}=[^ ]+" || true)"
  if [ -n "$v" ]; then ok "$v"; else bad "$k missing from kernel cmdline (expected $k=...$REQ_ISOLCPUS)"; fi
done
# nproc honours the caller's CPU affinity, and isolcpus removes the isolated
# cores from the default scheduler domain -- so on a correctly isolated host a
# plain `nproc` reports only the housekeeping cores. Report both, or "cores: 4"
# on a 20-core box reads like a fault when it is proof the isolation works.
NPROC_ALL="$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
NPROC_AVAIL="$(nproc)"
if [ "${NPROC_AVAIL:-0}" -lt "${NPROC_ALL:-0}" ] 2>/dev/null; then
  ok "cores: $NPROC_ALL total, $NPROC_AVAIL unisolated (isolation is active)"
else
  ok "cores: $NPROC_ALL total (no CPU isolation in effect)"
fi

sec "Fronthaul NIC"
FH=""
for i in $(ls /sys/class/net 2>/dev/null | grep -v lo); do
  drv="$(ethtool -i "$i" 2>/dev/null | awk '/^driver:/{print $2}')"
  [ "$drv" = "mlx5_core" ] || continue
  mtu="$(cat "/sys/class/net/$i/mtu" 2>/dev/null)"
  link="$(cat "/sys/class/net/$i/operstate" 2>/dev/null)"
  fw="$(ethtool -i "$i" 2>/dev/null | awk '/^version:/{print $2}')"
  if [ "$link" = "up" ] && [ "${mtu:-0}" -ge "$REQ_FH_MTU" ] 2>/dev/null; then
    ok "$i: link up, mtu $mtu, ofed $fw  <- fronthaul candidate"
    FH="$i"
  else
    printf '  ....  %s: link %s, mtu %s\n' "$i" "${link:-?}" "${mtu:-?}"
  fi
  [ -n "$fw" ] && [ "$fw" != "$REQ_OFED" ] && warn "$i ofed $fw (validated: $REQ_OFED)"
done
[ -n "$FH" ] || bad "no mlx5 port that is up with MTU >= $REQ_FH_MTU (fronthaul needs jumbo frames)"

sec "PTP (fronthaul is time-synchronous; without lock the RU will not accept U-plane)"
if pgrep -af '[p]tp4l' >/dev/null 2>&1; then
  ok "ptp4l running"
  RMS="$(journalctl -u ptp4l --no-pager -n 20 2>/dev/null | grep -oE 'rms +[0-9]+' | tail -1 | awk '{print $2}')"
  if [ -n "$RMS" ]; then
    if [ "$RMS" -lt 100 ] 2>/dev/null; then ok "ptp4l rms ${RMS} ns (locked)"
    else warn "ptp4l rms ${RMS} ns — high; expect fronthaul errors above ~100 ns"; fi
  fi
else
  bad "ptp4l not running"
fi
pgrep -af '[p]hc2sys' >/dev/null 2>&1 && ok "phc2sys running" || warn "phc2sys not running"

sec "Container runtime"
if have docker && docker info >/dev/null 2>&1; then
  ok "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if docker info 2>/dev/null | grep -qi 'nvidia'; then ok "nvidia container runtime present"
  else warn "nvidia runtime not visible in docker info (needed to give L1 the GPU)"; fi
else
  bad "docker not usable by this user"
fi
# NGC access: the Aerial image is not public.
if grep -q 'nvcr.io' "$HOME/.docker/config.json" 2>/dev/null; then
  ok "nvcr.io credentials present"
else
  warn "not logged in to nvcr.io — run: docker login nvcr.io   (username: \$oauthtoken)"
fi

sec "Disk"
FREE_GB="$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -z "$FREE_GB" ] && FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "${FREE_GB:-0}" -ge "$REQ_FREE_GB" ] 2>/dev/null; then ok "free: ${FREE_GB}G"
else bad "free: ${FREE_GB:-?}G — need >= ${REQ_FREE_GB}G (the Aerial image alone is ~26 GB)"; fi

printf '\n== Summary ==\n  %d passed, %d warnings, %d failures\n' "$pass" "$warnc" "$failc"
if [ "$failc" -gt 0 ]; then
  echo "  Host is NOT ready. Fix the FAIL items (see NVIDIA's DGX Spark install guide)."
  exit 1
fi
echo "  Host looks ready for the Aerial stack."
