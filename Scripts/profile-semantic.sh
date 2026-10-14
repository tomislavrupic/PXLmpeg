#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [ "$#" -lt 1 ]; then
  echo 'Usage: Scripts/profile-semantic.sh SOURCE [MODELS] [s0|s2] [cpuOnly|cpuAndNeuralEngine|all]' >&2
  exit 2
fi
source_path="$1"
model_path="${2:-$root/.work/semantic/models}"
variant="${3:-s2}"
compute="${4:-cpuAndNeuralEngine}"
mkdir -p Artifacts
output="$(mktemp -d "$root/Artifacts/semantic-profile.XXXXXX")"
binary="$(swift build --build-system native -c release --show-bin-path)/pxl-search"
"$binary" profile --models "$model_path" --variant "$variant" --compute "$compute" \
  --repetitions 100 --attach-delay 15 "$source_path" > "$output/profile.json" 2> "$output/target.log" &
profile_pid=$!
trap 'kill "$profile_pid" 2>/dev/null || true' EXIT
ready=false
for ((attempt=0; attempt<120; attempt++)); do
  if grep -q '"profileReady":true' "$output/target.log"; then ready=true; break; fi
  if ! kill -0 "$profile_pid" 2>/dev/null; then break; fi
  sleep 0.25
done
if [ "$ready" != true ]; then
  cat "$output/target.log" >&2
  echo 'Profile target did not become ready' >&2
  exit 3
fi
xcrun xctrace record --template 'Core AI' --instrument 'Neural Engine' --instrument 'Points of Interest' \
  --time-limit 25s --output "$output/runtime.trace" --attach "$profile_pid"
wait "$profile_pid"
trap - EXIT
xcrun xctrace export --input "$output/runtime.trace" --toc > "$output/toc.xml"
xcrun xctrace export --input "$output/runtime.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="ane-hw-intervals"]' > "$output/ane.xml"
xcrun xctrace export --input "$output/runtime.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' > "$output/phases.xml"
python3 "$root/Scripts/summarize-semantic-trace.py" "$output"
printf 'Profile artifacts: %s\n' "$output"
