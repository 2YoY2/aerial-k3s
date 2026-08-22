#!/usr/bin/env bash
# Phase 2: create a single-node Kubernetes cluster with minikube (docker driver).
# Knobs: CPUS=8 MEMORY=12g ./01-create-cluster.sh
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

CPUS="${CPUS:-8}"
MEMORY="${MEMORY:-12g}"

echo ">> starting minikube ($CPUS cpus, $MEMORY ram)"
minikube start --driver=docker --cpus="$CPUS" --memory="$MEMORY" --container-runtime=docker

# metrics-server feeds 'kubectl top' and the HorizontalPodAutoscaler (Phase 6)
minikube addons enable metrics-server

echo; echo ">> cluster state:"
kubectl get nodes -o wide
kubectl get pods -A
echo ">> done. Next: 02-deploy-core.sh"
