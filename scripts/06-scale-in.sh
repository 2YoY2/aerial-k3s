#!/usr/bin/env bash
# Scale back in: remove cell2 entirely. The core keeps running; the AMF just
# sees the gNB leave. This asymmetry (cells come and go, core stays) is the
# whole reason to run the RAN on Kubernetes.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
NS2=oai-cell2

helm uninstall oai-nr-ue-cell2 -n "$NS2" 2>/dev/null || true
helm uninstall oai-gnb-cell2   -n "$NS2" 2>/dev/null || true
kubectl delete namespace "$NS2" --ignore-not-found
echo ">> cell2 gone. Check the AMF noticed: kubectl logs -n oai deploy/oai-amf --tail=20"
