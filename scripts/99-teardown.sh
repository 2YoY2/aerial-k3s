#!/usr/bin/env bash
# Remove everything: RAN, core, and the whole cluster.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

helm uninstall oai-nr-ue oai-gnb -n oai 2>/dev/null || true
helm uninstall oai-5g-basic -n oai 2>/dev/null || true
kubectl delete namespace oai oai-cell2 --ignore-not-found 2>/dev/null || true
minikube delete
echo ">> all gone."
