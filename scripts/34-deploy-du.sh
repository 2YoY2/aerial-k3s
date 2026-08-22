#!/usr/bin/env bash
# Deploy the DU (Aerial L1 + OAI L2) onto k3s from the artefacts built locally.
#
#   ./scripts/34-deploy-du.sh
#   NAMESPACE=ran ./scripts/34-deploy-du.sh
#
# Everything it needs was produced by earlier steps; it verifies each before
# touching the cluster, because a half-satisfied prerequisite here becomes a
# CrashLoopBackOff that takes far longer to read than an up-front check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
. "$ROOT/scripts/lib-tools.sh"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

STACK="${STACK_DIR:-$ROOT/stack}"
AERIAL_SRC="$STACK/aerial-cuda-accelerated-ran"
CFGDIR="$AERIAL_SRC/cuPHY-CP/cuphycontroller/config"
RENDERED="$ROOT/site/rendered"
NS="${NAMESPACE:-ran}"
REL="${RELEASE:-aerial-du}"
ARCH="$(uname -m)"

die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
step(){ printf '\n\033[1m>> %s\033[0m\n' "$*"; }

step "Preflight"
need_tool kubectl >/dev/null || die "kubectl unavailable"
command -v helm >/dev/null 2>&1 || die "helm not installed"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — run ./scripts/32-install-k3s.sh"
[ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
  || die "no L1 binary — run ./scripts/31-build-stack.sh l1"
docker image inspect oai-gnb-aerial:latest >/dev/null 2>&1 \
  || die "oai-gnb-aerial:latest missing — run ./scripts/31-build-stack.sh l2"
[ -f "$RENDERED/cuphycontroller_site.yaml" ] \
  || die "no rendered L1 config — run ./scripts/33-render-config.sh"
echo "   cluster : $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
echo "   L1      : build.$ARCH present"
echo "   L2      : oai-gnb-aerial:latest"

# run_l1.sh resolves its argument as cuphycontroller_<profile>.yaml inside the
# cuBB tree, so the rendered config has to live there under a name of our own.
# Using a distinct name keeps the upstream vendor templates untouched, so the
# tree still diffs clean against the pinned tag apart from this one file.
step "Installing the rendered L1 config into the cuBB tree"
cp -f "$RENDERED/cuphycontroller_site.yaml" "$CFGDIR/cuphycontroller_site.yaml" \
  || die "could not write $CFGDIR/cuphycontroller_site.yaml"
echo "   $CFGDIR/cuphycontroller_site.yaml"
# The L1 config names its adapter file; make sure that file actually exists.
L2A="$(grep -m1 '^l2adapter_filename:' "$CFGDIR/cuphycontroller_site.yaml" | awk '{print $2}')"
[ -f "$CFGDIR/$L2A" ] || die "L1 config references $L2A but it is not in $CFGDIR"
echo "   l2 adapter: $L2A (upstream default — CPU affinities not templated yet)"

step "Namespace and gNB config"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
if [ -f "$RENDERED/gnb.conf" ]; then
  kubectl create configmap gnb-conf -n "$NS" \
    --from-file=gnb.conf="$RENDERED/gnb.conf" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   configmap/gnb-conf from site/rendered/gnb.conf"
  GNB_ARG=(--set l2.configMap=gnb-conf)
else
  echo "   WARNING: no rendered gnb.conf — the L2 will use the image default"
  GNB_ARG=()
fi

step "Deploying $REL to namespace $NS"
helm upgrade --install "$REL" "$ROOT/charts/aerial-du" -n "$NS" \
  --set l1.cubbHostPath="$AERIAL_SRC" \
  --set l1.configProfile=site \
  --set l1.image.repository="$AERIAL_IMAGE" \
  --set l1.image.tag="$AERIAL_TAG" \
  "${GNB_ARG[@]}" \
  || die "helm install failed"

step "Status"
kubectl get pods -n "$NS" -o wide
cat <<EOF

>> The L1 becomes ready when it prints "L1 is ready!" — that means the
   fronthaul is up and the RU is responding. Watch it with:

     kubectl logs -n $NS -l app.kubernetes.io/name=aerial-du -c nv-cubb -f

   Then the L2, which registers with the AMF over N2:

     kubectl logs -n $NS -l app.kubernetes.io/name=aerial-du -c oai-gnb -f

   If the L1 never reports ready, the usual causes are fronthaul timing
   (the T1a/Ta4 windows in site.yaml) or the RU not being provisioned for
   the VLAN and eAxC ids this config uses.
EOF
