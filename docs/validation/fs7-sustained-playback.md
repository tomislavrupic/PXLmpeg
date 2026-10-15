# FS7 sustained GUI playback with camera color

On 15 October 2026, one full real **17:16.4 Sony FS7 XAVC Intra MXF** played to
EOF in Pixel Deck PXL Research, after the user confirmed their background render
had finished. The source was 3840×2160, 25 fps, 10-bit 4:2:2. Automatic
S-Log3/S-Gamut3.Cine interpretation and the captured Sony LC-709 Type A look
remained enabled throughout. The actual preview texture was **2360×890** with
fit/letterboxing; this is not 4K output validation.

PXLmpeg supplied capture metadata. Decode used Pixel Deck's compatibility
VideoToolbox hardware path, followed by the corrected Metal color pipeline and
the real RME Fireface UCX audio clock. Native PXLmpeg MXF decoding is not enabled.
The optimized arm64 build ran on M3 Ultra, 28 logical CPUs and 96 GiB RAM, with
ordinary desktop activity still present. Audio was muted while its device clock
ran. No model inference ran in this test.

| Measurement | Result |
| --- | ---: |
| Media duration / measured wall time | 1036.400 / 1036.804 s |
| Reported dropped / late frames | 0 / 0 |
| Reported audio underruns / video queue starvation | 0 / 0 |
| Absolute selection-clock error, p95 / maximum | 18.667 / 18.667 ms |
| GPU duration, p50 / p95 / maximum | 0.131 / 0.154 / 0.661 ms |
| Decode rolling p95, median / maximum after first minute | 22.074 / 23.596 ms |
| Frame budget | 40 ms |
| Whole-process average CPU | 109.87% of one core, about 1.10 cores |
| RSS at first minute / end / sampled peak | 249.97 / 270.31 / 289.77 MiB |
| Thermal state | Nominal in all 500 samples |
| Actual audio clock active | 499/500 samples; final EOF sample inactive |
| Main-thread stall events ≥25 ms / sampled rolling peak | 7 / 34.738 ms |
| GPU completions / frame selections | 25,817 / 25,909 |

The completion count is **92 lower (0.355%)** than the selected-frame count.
Completions are not unique PTS acknowledgements: redraws/coalescing and final
in-flight work can affect the relationship. The cause of this gap was not
instrumented, so zero reported scheduling drops does **not** establish
frame-perfect display. A next presentation check should attach PTS to each GPU
presentation and distinguish coalescing, duplicate draws and output latency.

After EOF, seeks to **518.20 s** and **1005.32 s** settled in **38.95 ms** and
**46.14 ms** respectively. Each resumed segment advanced on the real audio clock
with no audio/decoder error, completed 26 GPU renders, and then held position
while paused. Source identity, size and mtime checks passed; this is not a
whole-file checksum of the 32.5 GB original.

Sync is frame-selection PTS versus the audio master clock, not physical
scanout/audio latency or audible lip-sync approval. GPU times are command-buffer
durations. Decode/stall values sample the app's rolling 180-value windows,
not full-run decode/stall quantiles. Memory grew about 20 MiB from the first
minute to the end, below startup peak; an hour/overnight test is still needed to
resolve long-term growth. No energy, calibrated-display, multichannel-routing,
native-MXF speedup or general stability claim follows from this one run.

The earlier run stopped for concurrent rendering remains partial under-load
evidence and is not an idle A/B baseline. All 500 raw samples and runtime logs
stay local; the [sanitized receipt](2026-10-15-fs7-sustained-playback.json) keeps
summary metrics, regular milestones and a digest of the private full report.
Reproduction uses Pixel Deck's research-only `--pxl-soak-report` command, documented
in `Documentation/PXL_NATIVE_PLAYBACK.md`. It checks full EOF, continuous GPU
progress, real audio clock and post-soak transport, and preserves periodic
checkpoints on interruption.
