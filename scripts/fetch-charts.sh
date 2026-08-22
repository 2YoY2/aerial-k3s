#!/usr/bin/env bash
# Fetch the official OAI Helm charts into ./orchestration.
#
# They are NOT vendored into this repo: upstream is a separate project with its
# own license and release cadence, and pinning a copy here would rot. The
# deploy scripts call this automatically if the charts are missing.
#
# Pin a different ref with:  OAI_CHARTS_REF=v2.2.0 ./scripts/fetch-charts.sh
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$BASE/orchestration"
REF="${OAI_CHARTS_REF:-main}"
URL="${OAI_CHARTS_URL:-https://github.com/openairinterface/orchestration.git}"

if [ -d "$DEST/.git" ]; then
  echo ">> charts already present: $DEST ($(git -C "$DEST" rev-parse --short HEAD))"
  exit 0
fi

echo ">> cloning OAI charts ($REF) into $DEST"
git clone --depth 1 --branch "$REF" "$URL" "$DEST"
echo ">> done: $(git -C "$DEST" rev-parse --short HEAD)"
