# Pixel Deck native/compatibility A/B research

Within each batch, both backends use the same optimized arm64 research executable
and the same short 1920×1088 ProRes HQ/24-bit
stereo PCM source, same 1920×1088 BGRA Metal output. Five fresh processes per
backend, with order alternated and file cache warm. Both delivered 49 actual
hardware-decoded frames and 98,000 PCM sample frames to complete EOF. Rendering
was serial and offscreen with each command buffer awaited; these are throughput
and headroom measurements, not actual playback FPS or power measurements.

| First batch median | PXLmpeg native | Compatibility | Interpretation |
| --- | ---: | ---: | --- |
| Open + first frame |120.72 ms |206.25 ms |42% less elapsed time |
| 49-frame decode + render |199.35 ms |267.09 ms |25% less elapsed time |
| Video pulls total |48.85 ms |98.11 ms |50% less elapsed time |
| Video-phase CPU time |55.41 ms |48.29 ms |15% more CPU time |
| Sampled peak process RSS |212.2 MiB |158.1 MiB |34% more resident memory |
| Pooled seek median |4.70 ms |1.86 ms |Native slower in this case |

A second five-trial-per-backend batch through the committed reproduction script
reported open/first-frame 125.03 ms versus 199.32 ms, serial decode/render 62.91 ms
versus 123.61 ms, video CPU 37.60 ms versus 43.68 ms, and sampled RSS 212.5 MiB versus 214.4 MiB.
Elapsed-time gains persisted (opening 37–42%; serial decode/render 25–49%), while
render timing and CPU/RSS costs shifted materially. These are batch medians,
not bounds on individual runs. We did not isolate system/GPU cache state or
background scheduling; neither batch establishes a general CPU, memory or
energy advantage. Native seeks were slower in both batches.

Both backends already use VideoToolbox hardware, so this does not compare
hardware decode against software decode. A single B&W LUT smoke run per backend
also changed rendered pixels; it is not a statistical LUT performance comparison.
All twenty trials, GPU timings and both sets of medians are retained in
[sanitized evidence](2026-10-15-camera-metadata-performance.json).

A separate FS7 XAVC/MXF case confirms automatic capture-color selection and 120
4K frames rendered using the compatibility hardware path. That clip has no
native PXLmpeg decoder yet and cannot establish native-vs-compatibility speedup.
Source size/mtime were unchanged; the benchmark does not claim a whole-file hash
check of the 32.5 GB camera original. The original ProRes ingest/playback acceptance
separately recorded an unchanged SHA-256.

Both configurations remain research boundaries. Next compare long clips, 4K
ProRes variants and sustained real-time A/V cadence with transform enabled,
measure memory growth and thermal behavior, and use a dedicated energy/power
instrument before making efficiency claims. Independent review corrected card
LUT preservation, source fencing and cap-accounting issues. See Pixel Deck's
`Scripts/benchmark_pxl_playback.sh` for reproduction.
