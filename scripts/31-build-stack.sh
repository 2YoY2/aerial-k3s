#!/usr/bin/env bash
# Build the RAN from the pristine sources in stack/. Nothing from a previous
# deployment is reused -- not its build tree, not its images, not its configs.
#
#   ./scripts/31-build-stack.sh          # build both
#   ./scripts/31-build-stack.sh l1       # Aerial cuBB only
#   ./scripts/31-build-stack.sh l2       # OAI gNB image only
#
# L1: cuBB is compiled INSIDE the Aerial container against the mounted source
#     tree, producing build.$(uname -m)/ -- the layout run_l1.sh expects.
# L2: OAI is built with nvIPC support so it speaks FAPI to Aerial. The nvIPC
#     sources ship inside the Aerial container and must be staged into the OAI
#     tree first; that is what makes `nfapi = "AERIAL"` compile.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/versions.env"
[ -f "$ROOT/site/versions.env" ] && . "$ROOT/site/versions.env"
STACK="${STACK_DIR:-$ROOT/stack}"
AERIAL_SRC="$STACK/aerial-cuda-accelerated-ran"
OAI_SRC="$STACK/openairinterface5g"
ARCH="$(uname -m)"
WHAT="${1:-all}"

step() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$AERIAL_SRC" ] || die "missing $AERIAL_SRC — run ./scripts/21-fetch-stack.sh"
docker image inspect "$AERIAL_IMAGE:$AERIAL_TAG" >/dev/null 2>&1 \
  || die "Aerial image $AERIAL_IMAGE:$AERIAL_TAG not present — run ./scripts/21-fetch-stack.sh"

# Provenance of the one artefact we do not build ourselves. A registry digest
# means the image came from NGC and matches what NGC published; a local build or
# a `docker commit` has no digest. If this prints none, re-pull before trusting
# it -- `docker pull` is a no-op when the local copy already matches.
DIGEST="$(docker image inspect -f '{{range .RepoDigests}}{{.}}{{end}}' "$AERIAL_IMAGE:$AERIAL_TAG" 2>/dev/null)"
if [ -n "$DIGEST" ]; then
  echo ">> Aerial image provenance: $DIGEST"
else
  echo ">> WARNING: Aerial image has NO registry digest — it was not pulled from"
  echo "   NGC, so its contents are unverified. Re-pull it:"
  echo "     docker login nvcr.io && docker pull $AERIAL_IMAGE:$AERIAL_TAG"
fi

# ------------------------------------------------------------------ L1
build_l1() {
  step "L1: compiling cuBB inside $AERIAL_TAG (target: build.$ARCH)"
  if [ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ]; then
    echo "   already built — delete build.$ARCH to force a rebuild"
    return 0
  fi
  # Use the release's OWN build entry point. Inventing a cmake line risks
  # building with different flags than the release expects, which surfaces much
  # later as subtle runtime failure rather than an honest compile error.
  # run_l1.sh names the first of these in its header comment.
  local cmd="" script=""
  for c in testBenches/phase4_test_scripts/build_aerial_sdk.sh \
           cubb_scripts/build.sh cubb_scripts/install/build.sh build.sh; do
    [ -f "$AERIAL_SRC/$c" ] && { script="$c"; break; }
  done
  if [ -n "$script" ]; then
    echo "   using in-tree build script: $script"
    cmd="chmod +x '$script' && ./'$script'"
  else
    echo "   No in-tree build script found. What this release ships:"
    ls -1 "$AERIAL_SRC"/*.sh 2>/dev/null | sed 's|.*/|     |'
    ls -1 "$AERIAL_SRC"/cubb_scripts/ 2>/dev/null | sed 's/^/     cubb_scripts\//'
    ls -1 "$AERIAL_SRC"/testBenches/phase4_test_scripts/ 2>/dev/null | head -10 | sed 's/^/     testBenches\/phase4_test_scripts\//'
    [ -f "$AERIAL_SRC/CMakeLists.txt" ] && echo "     (CMakeLists.txt is present)"
    die "cannot pick a build command safely — tell me which of the above to use"
  fi
  # isolcpus removes cores 4-19 from the default affinity mask, so an
  # unconstrained build container sees only the housekeeping cores -- on a
  # 20-core box that is a 4-core build. The RAN is not running during a build,
  # so hand it the whole machine. Override with BUILD_CPUS if the RAN is live.
  # (Expect PTP rms to wobble while this runs; it re-locks afterwards.)
  local ncpu; ncpu="$(nproc --all 2>/dev/null || nproc)"
  local cpus="${BUILD_CPUS:-0-$((ncpu - 1))}"
  echo "   building on cores $cpus (host has $ncpu; without this it would use $(nproc))"

  # SYS_NICE silences the chrt warning: the build script tries to set a
  # real-time policy for itself. Harmless when denied, but noisy.
  docker run --rm --gpus all \
    --cpuset-cpus="$cpus" \
    --cap-add=SYS_NICE \
    -v "$AERIAL_SRC":/opt/nvidia/cuBB \
    -v /usr/src:/usr/src -v /lib/modules:/lib/modules \
    -w /opt/nvidia/cuBB \
    -e cuBB_SDK=/opt/nvidia/cuBB \
    "$AERIAL_IMAGE:$AERIAL_TAG" \
    bash -lc "$cmd" || die "cuBB build failed (see output above)"

  # The container builds as root, so the output would be root-owned on the host
  # and need sudo to clean up or rebuild later.
  if [ -d "$AERIAL_SRC/build.$ARCH" ] && [ "$(stat -c %u "$AERIAL_SRC/build.$ARCH")" = 0 ] && [ "$(id -u)" != 0 ]; then
    echo "   returning ownership of build.$ARCH to $(id -un)"
    sudo chown -R "$(id -u):$(id -g)" "$AERIAL_SRC/build.$ARCH" 2>/dev/null || \
      echo "   (could not chown; you will need sudo to remove build.$ARCH)"
  fi

  [ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
    || die "build finished but cuphycontroller_scf is missing from build.$ARCH"
  echo "   built: build.$ARCH/.../cuphycontroller_scf"
}

# ------------------------------------------------------------------ L2
build_l2() {
  [ -d "$OAI_SRC" ] || die "missing $OAI_SRC — run ./scripts/21-fetch-stack.sh"

  step "L2: staging nvIPC sources out of the Aerial container"
  # Copy from the image, not from any previous deployment's tarball, so the
  # nvIPC version always matches the Aerial release being deployed.
  local cid
  cid="$(docker create "$AERIAL_IMAGE:$AERIAL_TAG")" || die "could not create helper container"
  local staged=0
  for p in /opt/nvidia/cuBB/cuPHY-CP/gt_common_libs /opt/cuBB/cuPHY-CP/gt_common_libs; do
    if docker cp "$cid:$p" "$OAI_SRC/.nvipc-stage" 2>/dev/null; then staged=1; break; fi
  done
  docker rm -f "$cid" >/dev/null 2>&1
  if [ "$staged" = 1 ]; then
    local tb
    tb="$(find "$OAI_SRC/.nvipc-stage" -name 'nvipc_src*.tar.gz' | sort | tail -1)"
    [ -n "$tb" ] && { cp "$tb" "$OAI_SRC/"; echo "   staged $(basename "$tb")"; } \
                 || echo "   no nvipc_src tarball inside the image (may be prebuilt in it)"
    rm -rf "$OAI_SRC/.nvipc-stage"
  else
    echo "   could not read gt_common_libs from the image; continuing"
  fi

  step "L2: building the OAI gNB image with the Aerial FAPI split"
  local df
  df="$(ls "$OAI_SRC"/docker/Dockerfile.*aerial* 2>/dev/null | head -1)"
  if [ -z "$df" ]; then
    echo "   No Aerial Dockerfile found. Available:"
    ls -1 "$OAI_SRC"/docker/ 2>/dev/null | sed 's/^/     /'
    die "cannot build L2 without an Aerial gNB Dockerfile"
  fi
  echo "   dockerfile: $(basename "$df")"

  # OAI builds in stages: base -> build -> target.
  #
  # These are rebuilt every time on purpose. An existing ran-base/ran-build on
  # a reused host was produced by whoever set the box up before, from sources
  # and flags nobody can now inspect -- and it would silently become a layer
  # underneath the image we ship. "Fresh" has to mean the whole chain, not just
  # the top of it. Set REUSE_BASE=1 to trade that guarantee for build time.
  for stage in base build; do
    local sdf img="ran-$stage:latest"
    sdf="$(ls "$OAI_SRC"/docker/Dockerfile.$stage.* 2>/dev/null | grep -v aerial | head -1)"
    [ -n "$sdf" ] || continue
    if [ "${REUSE_BASE:-0}" = 1 ] && docker image inspect "$img" >/dev/null 2>&1; then
      echo "   $img present and REUSE_BASE=1 — reusing an inherited image"
    else
      echo "   building $img from $(basename "$sdf")"
      docker build --pull -t "$img" -f "$sdf" "$OAI_SRC" || die "$img build failed"
    fi
  done

  docker build -t oai-gnb-aerial:latest -f "$df" "$OAI_SRC" \
    || die "oai-gnb-aerial build failed"
  echo "   built: oai-gnb-aerial:latest"
}

case "$WHAT" in
  l1)  build_l1 ;;
  l2)  build_l2 ;;
  all) build_l1; build_l2 ;;
  *)   die "usage: $0 [l1|l2|all]" ;;
esac

step "Result"
docker images --format '   {{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null \
  | grep -E 'oai-gnb-aerial|ran-base|ran-build' || echo "   (no OAI images)"
[ -x "$AERIAL_SRC/build.$ARCH/cuPHY-CP/cuphycontroller/examples/cuphycontroller_scf" ] \
  && echo "   L1 binary: $AERIAL_SRC/build.$ARCH/..." \
  || echo "   L1 binary: NOT BUILT"
