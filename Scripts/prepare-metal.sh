#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.build/metal" "$root/Sources/PXLMetal/Resources"
xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$root/Kernels/Scale.metal" -o "$root/.build/metal/Scale.air"
xcrun -sdk macosx metallib "$root/.build/metal/Scale.air" -o "$root/Sources/PXLMetal/Resources/PXLKernels.metallib"
