#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${PXL_SEMANTIC_MODELS:-}" ] && pgrep -x pxl-search-app >/dev/null; then
  echo 'Close PXLSearch.app before running real-model tests; interactive use and compiler stress tests must not overlap.' >&2
  exit 2
fi
"$root/Scripts/prepare-metal.sh"
cd "$root"
exec swift test --build-system native "$@"
