#!/usr/bin/env bash
# Phase 3: deploy the OAI 5G core (oai-5g-basic umbrella chart) into namespace "oai".
# Components: mysql, NRF, UDR, UDM, AUSF, AMF, SMF, UPF, LMF, traffic-server, ims.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)/orchestration"
NS=oai

# the upstream charts aren't vendored in this repo — grab them on first run
[ -d "$REPO" ] || "$(dirname "$0")/fetch-charts.sh"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

cd "$REPO/oai-5g-core/oai-5g-basic"
# the umbrella chart references its sub-charts as file:// deps — vendor them in
helm dependency update .

helm upgrade --install oai-5g-basic . -n "$NS"

echo ">> waiting for all core pods to be Ready (first run pulls ~3 GB of images)..."
kubectl wait --for=condition=Ready pods --all -n "$NS" --timeout=15m

echo; kubectl get pods -n "$NS"
echo; echo ">> AMF is the door the gNB knocks on. Its last log lines:"
kubectl logs -n "$NS" deploy/oai-amf --tail=15
echo ">> done. Next: 03-deploy-ran.sh"
