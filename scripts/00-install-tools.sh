#!/usr/bin/env bash
# Phase 1: install kubectl, helm and minikube into ~/.local/bin (no sudo needed).
set -euo pipefail

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
WORKDIR=$(mktemp -d); cd "$WORKDIR"

# kubectl — the CLI you use for everything cluster-side
KVER=$(curl -sL https://dl.k8s.io/release/stable.txt)
echo ">> installing kubectl $KVER"
curl -sLo kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
install kubectl "$HOME/.local/bin/kubectl"

# minikube — disposable local Kubernetes cluster (docker driver)
echo ">> installing minikube"
curl -sLo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
install minikube "$HOME/.local/bin/minikube"

# helm — the package manager the OAI charts are deployed with
echo ">> installing helm"
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  | HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO=false bash

# make sure ~/.local/bin is on PATH in future shells
grep -q '\.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

echo; echo ">> versions:"
kubectl version --client | head -1
minikube version | head -1
helm version --short
echo ">> done. Open a new shell (or 'export PATH=$HOME/.local/bin:\$PATH') and run 01-create-cluster.sh"
