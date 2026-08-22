#!/usr/bin/env bash
# Phase 6: SCALE OUT — add a second cell (gNB + UE) in its own namespace,
# served by the SAME core. This is how one core serves many cell sites.
#
# A gNB is stateful — it has an identity (gNB_ID, nr_cellid). The chart's yq
# startup patch does NOT rewrite gNB_ID, so two gNBs from the same chart would
# collide. We copy the chart once and bump the identity for cell2.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
BASE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$BASE/orchestration"
NS2=oai-cell2

# the upstream charts aren't vendored in this repo — grab them on first run
[ -d "$REPO" ] || "$(dirname "$0")/fetch-charts.sh"

# 1. one-time: make a cell2 copy of the gNB chart with a unique identity
if [ ! -d "$REPO/oai-5g-ran/oai-gnb-cell2" ]; then
  cp -r "$REPO/oai-5g-ran/oai-gnb" "$REPO/oai-5g-ran/oai-gnb-cell2"
  sed -i -e 's/gNB_ID: 0xe00/gNB_ID: 0xe01/' \
         -e 's/nr_cellid: 12345678/nr_cellid: 12345679/' \
         "$REPO/oai-5g-ran/oai-gnb-cell2/config.yaml"
  sed -i 's/^name: oai-gnb$/name: oai-gnb-cell2/' "$REPO/oai-5g-ran/oai-gnb-cell2/Chart.yaml"
  echo ">> created chart copy oai-gnb-cell2 (gNB_ID 0xe01)"
fi

kubectl get ns "$NS2" >/dev/null 2>&1 || kubectl create namespace "$NS2"

# 2. gNB for cell2 — reaches the AMF across namespaces via full service DNS
helm upgrade --install oai-gnb-cell2 "$REPO/oai-5g-ran/oai-gnb-cell2" -n "$NS2" \
  -f "$BASE/values/gnb-cell2-values.yaml"
kubectl wait --for=condition=Ready pods --all -n "$NS2" --timeout=10m

echo ">> AMF should now list TWO gNBs:"
kubectl logs -n oai deploy/oai-amf --tail=60 | grep -iE "gnb" | tail -8 || true

# 3. second UE (second SIM from the subscriber DB) attaches to cell2's gNB
helm upgrade --install oai-nr-ue-cell2 "$REPO/oai-5g-ran/oai-nr-ue" -n "$NS2" \
  --set config.fullImsi="001010000000101"
kubectl wait --for=condition=Ready pods --all -n "$NS2" --timeout=10m

echo; echo ">> verify cell2's UE got its own tunnel:"
sleep 20
kubectl exec -n "$NS2" deploy/oai-nr-ue -- ip -4 addr show oaitun_ue1 || \
  echo "(not up yet — retry the line above in ~30 s)"
echo ">> scale back down anytime with 06-scale-in.sh"
