#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build.sh" -c release
cd "$root"
bindir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$root/Artifacts" "$root/.work"
artifacts="$(mktemp -d "$root/Artifacts/remux.XXXXXX")"
"$bindir/pxl-validation" remux "$artifacts" "$@" | tee "$artifacts/validation.log"
mkdir "$artifacts/relocated"
cp "$bindir/pxlmpeg" "$artifacts/relocated/pxlmpeg"
# Deliberately omit the Metal resource bundle: remux must not initialize the GPU.
cd /tmp
"$artifacts/relocated/pxlmpeg" plan-remux "$artifacts/cli-remux.json" > "$artifacts/plan.jsonl"
if [ -x /usr/bin/sandbox-exec ]; then
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$artifacts/relocated/pxlmpeg" remux "$artifacts/cli-remux.json" > "$artifacts/run.jsonl"
else
  "$artifacts/relocated/pxlmpeg" remux "$artifacts/cli-remux.json" > "$artifacts/run.jsonl"
fi
"$artifacts/relocated/pxlmpeg" inspect "$artifacts/cli-output.mp4" > "$artifacts/inspect.jsonl"
printf '%s\n' "$artifacts" > "$root/.work/latest-remux-acceptance-path"
printf 'Remux acceptance artifacts: %s\n' "$artifacts"
