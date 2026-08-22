#!/usr/bin/env bash
# Copy the site-derived RAN config out of a working tree into site/.
#
#   ./scripts/23-extract-site-config.sh [aerial-tree] [oai-tree]
#
# Why: on this class of box the only record of the local derivation is a set of
# modified files inside somebody's home directory -- often one named like an
# archive. NVIDIA ships no DGX Spark cuphycontroller or l2_adapter YAML, so
# those edits ARE the deployment. Copy them somewhere deliberate before anyone
# tidies up.
#
# site/ is untracked: this material contains fronthaul MACs, VLANs and cell
# identity, and the repo is public.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
SELF_STACK="$ROOT/stack"
DEST="$ROOT/site/config"
mkdir -p "$DEST"

# Reuse the same discovery rule as 12-ran-recipe.sh: modified tree wins, our own
# pristine stack/ clone never counts, and prefer the pinned release.
pick() { # pick <remote-substring> <preferred-describe>
  local m="$1" want="$2" g r best="" match=""
  while read -r g; do
    r="$(dirname "$g")"
    case "$r" in "$SELF_STACK"/*|"$SELF_STACK") continue ;; esac
    git -C "$r" remote -v 2>/dev/null | grep -qi "$m" || continue
    [ -n "$(git -C "$r" status -s 2>/dev/null)" ] || continue
    [ -z "$best" ] && best="$r"
    [ "$(git -C "$r" describe --tags --always 2>/dev/null)" = "$want" ] && match="$r"
  done < <(find "$HOME" -maxdepth 6 -name .git -type d 2>/dev/null)
  echo "${match:-$best}"
}

AERIAL="${1:-$(pick 'aerial-cuda-accelerated-ran' "$AERIAL_SRC_REF")}"
OAI="${2:-$(pick 'openairinterface5g' '')}"
echo ">> aerial tree: ${AERIAL:-NOT FOUND} ($(git -C "${AERIAL:-/}" describe --tags --always 2>/dev/null))"
echo ">> oai tree   : ${OAI:-NOT FOUND}"

copied=0
take() { # take <src> <label>
  [ -f "$1" ] || { echo "   miss: $1"; return; }
  cp "$1" "$DEST/" && { echo "   took: $(basename "$1")  ($2)"; copied=$((copied+1)); }
}

if [ -n "${AERIAL:-}" ]; then
  CFG="$AERIAL/cuPHY-CP/cuphycontroller/config"
  # Only the modified files: the stock ones are already in stack/.
  while read -r f; do
    [ -n "$f" ] || continue
    take "$AERIAL/$f" "modified in aerial tree"
  done < <(git -C "$AERIAL" status -s --porcelain -- "$CFG" 2>/dev/null \
             | awk '$1=="M"{print $NF}')
  take "$AERIAL/run_l1.sh" "L1 launcher"
  # Record exactly what the derivation changed, so it can be re-applied to a
  # future Aerial release instead of re-derived from scratch.
  git -C "$AERIAL" diff > "$DEST/aerial-site.patch" 2>/dev/null \
    && echo "   took: aerial-site.patch ($(grep -c '^@@' "$DEST/aerial-site.patch") hunks)"
fi

if [ -n "${OAI:-}" ]; then
  D="$OAI/ci-scripts/yaml_files/sa_gnb_aerial"
  take "$OAI/targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb-vnf.sa.band78.273prb.aerial.conf" "gNB L2/L3 config"
  take "$D/docker-compose.yaml" "reference launch topology"
  git -C "$OAI" diff > "$DEST/oai-site.patch" 2>/dev/null \
    && echo "   took: oai-site.patch ($(grep -c '^@@' "$DEST/oai-site.patch") hunks)"
fi

echo
echo ">> $copied file(s) in $DEST"
echo ">> site/ is gitignored — this material is site-identifying and the repo is public."
ls -1 "$DEST" 2>/dev/null | sed 's/^/   /'
