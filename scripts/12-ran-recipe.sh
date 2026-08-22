#!/usr/bin/env bash
# Print the exact launch recipe for the Aerial L1 + OAI L2 stack, redacted.
#
#   ./scripts/12-ran-recipe.sh
#
# The inventory (script 10) tells you what the box HAS. This tells you how the
# RAN was actually STARTED: the L1 run script, the L2 compose file, the nvIPC
# adapter config, the fronthaul cell block, and — most valuable — the local
# diffs against upstream, which are the site-specific customisations you must
# carry into Kubernetes.
#
# Read-only. Paste the output into the working chat; secrets are redacted.
set -uo pipefail

. "$(dirname "$0")/lib-redact.sh"

# Locate the trees by their git remote, so this works on any box.
find_repo() {  # find_repo <remote-substring>
  local m="$1" g r
  while read -r g; do
    r="$(dirname "$g")"
    git -C "$r" remote -v 2>/dev/null | grep -qi "$m" && { echo "$r"; return 0; }
  done < <(find "$HOME" -maxdepth 6 -name .git -type d 2>/dev/null)
  return 1
}

AERIAL="${AERIAL_REPO:-$(find_repo 'aerial-cuda-accelerated-ran')}"
OAI="${OAI_REPO:-$(find_repo 'openairinterface5g')}"

sec() { printf '\n===== %s =====\n' "$*"; }
# cat_file <label> <path> [maxlines]
cat_file() {
  local n="${3:-120}" t
  sec "$1"
  if [ -f "$2" ]; then
    echo "# path: $2"
    head -n "$n" "$2" | redact
    t=$(wc -l < "$2"); [ "$t" -gt "$n" ] && echo "... [$((t - n)) more lines]"
  else
    echo "(not found: $2)"
  fi
}

echo "########## RAN LAUNCH RECIPE ##########"
echo "aerial repo: ${AERIAL:-NOT FOUND}"
echo "oai repo   : ${OAI:-NOT FOUND}"

sec "BOOT PARAMETERS (isolcpus / hugepages / iommu)"
cat /proc/cmdline

sec "CUDA MPS STATE"
# -f is required: pgrep matches only the first 15 chars of a process NAME,
# so "nvidia-cuda-mps-control" never matches without full-cmdline matching.
pgrep -af nvidia-cuda-mps-control || echo "mps-control: not running"
pgrep -af nvidia-cuda-mps-server  || echo "mps-server:  not running"
ls -ld /tmp/nvidia-mps 2>/dev/null || echo "/tmp/nvidia-mps: absent"
echo "CUDA_MPS_* in this shell:"; env | grep -E '^CUDA_MPS' || echo "(none)"

sec "IRQ / TUNING SERVICES"
systemctl list-unit-files --state=enabled --no-pager 2>/dev/null \
  | grep -iE 'ptp|phc|irq|tuned|cpu|nvidia|mps|aerial' || echo "(none matched)"

# ---------------------------------------------------------------- Aerial L1
if [ -n "${AERIAL:-}" ]; then
  sec "AERIAL: VERSION + LOCAL CHANGES"
  git -C "$AERIAL" describe --tags --always 2>&1
  git -C "$AERIAL" log -1 --oneline 2>&1
  git -C "$AERIAL" status -s 2>&1 | head -30

  sec "AERIAL: DIFF vs UPSTREAM (the site-specific customisation)"
  git -C "$AERIAL" diff 2>/dev/null | redact | head -300
  echo "... [diff truncated at 300 lines]"

  cat_file "AERIAL: run_l1.sh"            "$AERIAL/run_l1.sh"                 80
  cat_file "AERIAL: versions.sh"          "$AERIAL/cubb_scripts/install/versions.sh" 40
  # nvIPC transport between cuphycontroller and the OAI L2
  cat_file "AERIAL: l2_adapter_config_P5G_DGX.yaml" \
      "$AERIAL/cuPHY-CP/cuphycontroller/config/l2_adapter_config_P5G_DGX.yaml" 100
  # The fronthaul cell block — MAC/VLAN/eAxC per cell
  sec "AERIAL: FRONTHAUL CELL BLOCK"
  sed -n '/^cell_configs:/,$p' \
      "$AERIAL/cuPHY-CP/cuphycontroller/config/cuphycontroller_P5G_WNC_DGX.yaml" 2>/dev/null \
      | head -80 | redact || echo "(cell_configs section not found)"
fi

# ---------------------------------------------------------------- OAI L2/L3
if [ -n "${OAI:-}" ]; then
  D="$OAI/ci-scripts/yaml_files/sa_gnb_aerial"
  sec "OAI: VERSION + LOCAL CHANGES"
  git -C "$OAI" describe --tags --always 2>&1
  git -C "$OAI" status -s 2>&1 | head -30

  cat_file "OAI: docker-compose.yaml (CURRENT)"   "$D/docker-compose.yaml"            120
  cat_file "OAI: .env"                            "$D/.env"                            40
  # What the k3s attempt looked like before and after it broke
  cat_file "OAI: docker-compose.yaml.pre-k3s"     "$D/docker-compose.yaml.pre-k3s"    120
  cat_file "OAI: docker-compose.yaml.broken-aug21" "$D/docker-compose.yaml.broken-aug21" 120
  cat_file "OAI: docker-compose-ue.yaml"          "$D/docker-compose-ue.yaml"          60

  sec "OAI: DIFF vs UPSTREAM"
  git -C "$OAI" diff 2>/dev/null | redact | head -200
  echo "... [diff truncated at 200 lines]"
fi

sec "RAN-RELATED IMAGES"
docker images 2>/dev/null | grep -iE 'aerial|oai|ran-|rancher|nvcr' || echo "(none)"

printf '\n########## END RECIPE ##########\n'
