#!/usr/bin/env bash
# Install k3s, configured for a real-time RAN host.
#
#   ./scripts/32-install-k3s.sh
#
# Three decisions worth knowing about:
#
# 1. --docker. The DU images are built locally (oai-gnb-aerial:latest) and the
#    Aerial image is 26 GB. Using the existing Docker daemon means k3s sees
#    those images directly; with the default containerd you would have to
#    export and re-import 26 GB every rebuild.
#
# 2. k3s is pinned to the housekeeping cores. The kernel isolates 4-19 for the
#    RAN; a control plane scheduling itself onto an Aerial worker core causes
#    late slots. systemd CPUAffinity keeps k3s on the same cores as the rest
#    of the OS.
#
# 3. traefik and servicelb are disabled. A DU uses host networking; an ingress
#    controller is dead weight and one more thing binding ports.
#
# This does NOT touch driver, kernel, hugepages, PTP or NIC configuration.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOUSEKEEPING="${HOUSEKEEPING_CPUS:-0-3}"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

if command -v k3s >/dev/null 2>&1; then
  echo ">> k3s already installed: $(k3s --version | head -1)"
else
  echo ">> installing k3s (docker runtime, no traefik/servicelb, kubeconfig readable)"
  curl -sfL https://get.k3s.io | sh -s - \
    --docker \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    || { echo "k3s install failed" >&2; exit 1; }
fi

echo ">> pinning the k3s service to housekeeping cores ($HOUSEKEEPING)"
sudo mkdir -p /etc/systemd/system/k3s.service.d
sudo tee /etc/systemd/system/k3s.service.d/cpu-affinity.conf >/dev/null <<EOF
# The RAN owns the isolated cores. Keep the control plane off them.
[Service]
CPUAffinity=$HOUSEKEEPING
EOF
sudo systemctl daemon-reload
sudo systemctl restart k3s
sleep 5

echo ">> kubeconfig"
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config" 2>/dev/null
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null
chmod 600 "$HOME/.kube/config" 2>/dev/null
grep -q 'KUBECONFIG' "$HOME/.bashrc" 2>/dev/null || \
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
export KUBECONFIG="$HOME/.kube/config"

echo ">> waiting for the node"
for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done
kubectl get nodes -o wide 2>&1 | head -3

# ---------------------------------------------------------------- GPU access
echo
echo ">> GPU scheduling"
# With --docker, a pod gets the GPU only if Docker's DEFAULT runtime is nvidia.
# We do NOT change /etc/docker/daemon.json here: this host runs other people's
# containers, and switching the default runtime under them is not ours to do.
if docker info 2>/dev/null | grep -qi 'Default Runtime: nvidia'; then
  echo "   OK: docker default runtime is nvidia — containers get the GPU directly"
  # The device plugin is OPT-IN, and off by default on purpose.
  #
  # It cannot run on a unified-memory GPU such as GB10: it builds its device
  # map by querying per-device memory and NVML answers "Not Supported", so the
  # DaemonSet crash-loops and the node never advertises nvidia.com/gpu at all.
  # (nvidia-smi shows the same thing as "Memory-Usage: Not Supported".)
  #
  # It is also not needed on a dedicated RAN node: a device plugin rations GPUs
  # between competing pods, and with nvidia as the default runtime the GPU is
  # injected into every container regardless.
  if [ "${INSTALL_DEVICE_PLUGIN:-0}" = 1 ]; then
    kubectl get ds -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1 \
      || kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
  else
    echo "   device plugin not installed (INSTALL_DEVICE_PLUGIN=1 to force)."
    echo "   Pods reach the GPU through the runtime; the chart does not request"
    echo "   nvidia.com/gpu unless you set l1.requestGpu=true."
    if kubectl get ds -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1; then
      echo "   NOTE: a device-plugin DaemonSet is already present. On GB10 it will"
      echo "   crash-loop. Remove it with:"
      echo "     kubectl delete ds -n kube-system nvidia-device-plugin-daemonset"
    fi
  fi
else
  cat <<'MSG'
   Docker's default runtime is NOT nvidia, so pods cannot get the GPU and
   the device plugin has nothing to enumerate. Run these YOURSELF -- the
   restart interrupts every container on the host:

       sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null
       sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
       sudo systemctl restart docker

   Use nvidia-ctk rather than writing daemon.json by hand: it merges the
   runtime in and preserves any other settings the file already holds.

   Then re-run this script to install the device plugin.
MSG
fi

echo
echo ">> node resources visible to the scheduler:"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range $k,$v := .status.allocatable}{"   "}{$k}{"="}{$v}{"\n"}{end}{end}' 2>/dev/null \
  | grep -E 'cpu|memory|hugepages|nvidia' || echo "   (node not ready yet)"
echo
echo ">> next: ./scripts/33-deploy-du.sh"
