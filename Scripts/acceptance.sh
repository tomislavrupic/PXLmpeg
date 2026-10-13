#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build.sh" -c release
cd "$root"
bindir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$root/Artifacts"
artifacts="$(mktemp -d "$root/Artifacts/native.XXXXXX")"
"$bindir/pxl-validation" "$artifacts" | tee "$artifacts/validation.log"
mkdir "$artifacts/relocated"
cp "$bindir/pxlmpeg" "$artifacts/relocated/pxlmpeg"
cp -R "$bindir/PXLmpeg_PXLMetal.bundle" "$artifacts/relocated/"
cd /tmp
"$artifacts/relocated/pxlmpeg" capabilities --json > "$artifacts/capabilities.jsonl"
"$artifacts/relocated/pxlmpeg" plan "$artifacts/cli-job.json" --json > "$artifacts/plan.jsonl"
"$artifacts/relocated/pxlmpeg" run "$artifacts/cli-job.json" --json > "$artifacts/run.jsonl"
"$artifacts/relocated/pxlmpeg" inspect "$artifacts/cli-output.mov" --json > "$artifacts/inspect.jsonl"
if [ -x /usr/bin/sandbox-exec ]; then
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$artifacts/relocated/pxlmpeg" capabilities --json > "$artifacts/no-network.jsonl"
fi
printf '%s\n' "$artifacts" > "$root/.work/latest-acceptance-path"
printf 'Acceptance artifacts: %s\n' "$artifacts"
