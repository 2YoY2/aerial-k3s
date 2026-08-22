#!/usr/bin/env bash
# Phase 5: prove the network works end-to-end, layer by layer.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
NS=oai

echo "== 1. Control plane: gNB associated + UE registered (AMF's view) =="
kubectl logs -n "$NS" deploy/oai-amf --tail=200 | grep -E "gNB|5GMM" | tail -12 || true

echo; echo "== 2. UE got a user-plane tunnel? (needs oaitun_ue1 with 12.1.1.x) =="
kubectl exec -n "$NS" deploy/oai-nr-ue -- ip -4 addr show oaitun_ue1

echo; echo "== 3. Traffic through gNB -> UPF: ping the UPF tunnel endpoint =="
kubectl exec -n "$NS" deploy/oai-nr-ue -- ping -I oaitun_ue1 -c 3 12.1.1.1

echo; echo "== 4. Beyond the UPF (N6): ping the traffic server =="
TRF_IP=$(kubectl get svc -n "$NS" oai-traffic-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$TRF_IP" ]; then
  kubectl exec -n "$NS" deploy/oai-nr-ue -- ping -I oaitun_ue1 -c 3 "$TRF_IP" || true
  echo; echo "== 5. Throughput (iperf3, 10 s downlink through the whole stack) =="
  kubectl exec -n "$NS" deploy/oai-nr-ue -- iperf3 -c "$TRF_IP" -B 12.1.1.2 -t 10 -R || \
    echo "(iperf3 optional — UE bind IP may differ: check step 2 output)"
fi

echo; echo ">> If steps 1-3 passed you have a working 5G network. Next: 05-scale-out-cell2.sh"
