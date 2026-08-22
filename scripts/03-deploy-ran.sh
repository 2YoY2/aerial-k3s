#!/usr/bin/env bash
# Phase 4: deploy the RAN — monolithic gNB (RF simulator mode) + one simulated UE.
# The gNB's k8s service is named "oai-ran"; the UE connects to it on port 4043.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)/orchestration"
NS=oai

# the upstream charts aren't vendored in this repo — grab them on first run
[ -d "$REPO" ] || "$(dirname "$0")/fetch-charts.sh"

echo ">> installing gNB (waits for AMF SCTP 38412 in an init step)"
helm upgrade --install oai-gnb "$REPO/oai-5g-ran/oai-gnb" -n "$NS"
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=oai-gnb -n "$NS" --timeout=10m

echo ">> gNB up. AMF should now show one connected gNB:"
kubectl logs -n "$NS" deploy/oai-amf --tail=40 | grep -iA2 "gnb" | tail -6 || true

echo ">> installing UE (IMSI 001010000000100 — pre-provisioned in mysql)"
helm upgrade --install oai-nr-ue "$REPO/oai-5g-ran/oai-nr-ue" -n "$NS"
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=oai-nr-ue -n "$NS" --timeout=10m

echo ">> done. Give the UE ~30 s to sync + register, then run 04-verify.sh"
