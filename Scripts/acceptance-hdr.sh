#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build.sh" -c release
cd "$root"
bindir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$root/Artifacts" "$root/.work"
artifacts="$(mktemp -d "$root/Artifacts/hdr.XXXXXX")"
"$bindir/pxl-validation" hdr "$artifacts" "$@" | tee "$artifacts/validation.log"
mkdir "$artifacts/relocated"
cp "$bindir/pxlmpeg" "$artifacts/relocated/pxlmpeg"
cp -R "$bindir/PXLmpeg_PXLMetal.bundle" "$artifacts/relocated/"
cd /tmp
"$artifacts/relocated/pxlmpeg" plan "$artifacts/cli-job.json" > "$artifacts/plan.jsonl"
if [ -x /usr/bin/sandbox-exec ]; then
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$artifacts/relocated/pxlmpeg" run "$artifacts/cli-job.json" > "$artifacts/run.jsonl"
else
  "$artifacts/relocated/pxlmpeg" run "$artifacts/cli-job.json" > "$artifacts/run.jsonl"
fi
"$artifacts/relocated/pxlmpeg" inspect "$artifacts/cli-output.mov" > "$artifacts/inspect.jsonl"
printf '%s\n' "$artifacts" > "$root/.work/latest-hdr-acceptance-path"
printf 'HDR acceptance artifacts: %s\n' "$artifacts"
