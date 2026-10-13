#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/prepare-metal.sh"
cd "$root"
exec swift test --build-system native "$@"
