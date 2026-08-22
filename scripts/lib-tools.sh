# Fetch the small CLI tools the scripts need, into ~/.local/bin. Source, don't run.
#
# The repo must work on a bare server: assuming a tool is already installed
# because it happened to be on one particular box is how a pipeline becomes
# unreproducible. Everything here is a single static binary.
need_tool() {  # need_tool <name>
  local name="$1" arch url dest="$HOME/.local/bin"
  command -v "$name" >/dev/null 2>&1 && return 0
  mkdir -p "$dest"; export PATH="$dest:$PATH"
  command -v "$name" >/dev/null 2>&1 && return 0
  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) echo "unsupported arch $(uname -m) for $name" >&2; return 1 ;;
  esac
  case "$name" in
    yq)      url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" ;;
    kubectl) url="https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl" ;;
    *) echo "don't know how to install $name" >&2; return 1 ;;
  esac
  echo ">> installing $name for linux/$arch"
  curl -sfL "$url" -o "$dest/$name" && chmod +x "$dest/$name" || {
    echo "failed to install $name" >&2; return 1; }
  command -v "$name" >/dev/null 2>&1
}
