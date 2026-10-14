# Semantic search prototype — 14 October 2026

PXLmpeg **0.7.0-semantic-prototype** implements local sampled visual search in the optional `PXLAnalysis` Swift library and `pxl-search` CLI. The selected default is **original MobileCLIP-S2**, with S0 retained for comparison. Core media processing still has zero external package or binary dependencies, and no model is bundled in Git.

On this M3 Ultra, S2 warm native predictions measured **2.266 ms/image and 1.259 ms/text** with `cpuAndNeuralEngine`. Both S0 and S2 retrieved the expected source for **7/7 known test queries** across 70 sampled frames. Actual ANE intervals were recorded inside both image and text prediction batches. These results establish a working first prototype, not general accuracy, temporal understanding or an ANE-only pipeline.

The [sanitized structured report](2026-10-14-semantic-search.json) contains source hashes/aliases, sample times, ranked results, all prediction timing samples, device plans and runtime interval summaries. Originals, images, model weights, embeddings and raw system traces remain local and unmodified.

## Test conditions and retrieval

Hardware: Apple M3 Ultra, 96 GiB, macOS 27.0.1, Xcode 27 / Swift 6.4. Release build. Background applications were not controlled. The declared macOS 15 minimum was not tested on that OS.

The dataset contains a genuine iPhone camera original (HEVC Main10, BT.2020 HLG, 3840 × 2160, 180° display rotation) and six SDR ALi clips. The camera file was moved during the work; the final run used the relocated original directly, not a transcode or remux. Source SHA-256 values before and after indexing matched for all seven files.

Sampling interval: **0.5 seconds**, at most 256 requests per source, 70 unique actual source frames; no source was truncated. The iPhone source uses native `forceSDR` sampling. The six ALi clips use explicitly assumed BT.709 limited metadata with the core hardware decoder. Each source's actual sample timestamps and backend are in the report.

These prompts were written after visual inspection of sampled frames. The test asks which source ranks first, not whether the highest-scoring instant is an independently annotated temporal event.

| Query | Expected source alias | S2 top timestamp | S0/S2 top source correct |
| --- | --- | ---: | --- |
| a room with a guitar and a tall plant by the window | iphone-original | 3.0 s | yes / yes |
| a giant insect creature in a spaceship cockpit | ali-01 | 0.5 s | yes / yes |
| a corridor covered in blue slime | ali-02 | 3.0 s | yes / yes |
| soldiers walking through a ruined alien landscape | ali-03 | 0.5 s | yes / yes |
| a frightened woman in a white spacesuit | ali-04 | 3.0 s | yes / yes |
| a man in a helmet holding a finger to his lips | ali-05 | 2.5 s | yes / yes |
| a tentacled alien creature served on a plate with candles | ali-06 | 4.5 s | yes / yes |

S0 indexing took **3.402 s** and S2 **5.578 s** for all seven clips. This includes raw-asset verification/compilation/loading, full source hashing before/after, sampling, preprocessing and embeddings; it excludes JSON serialization/publication. These short runs are dominated by startup and do not establish sustained indexing throughput. A persistent `SemanticAnalyzer` reuses loaded models.

## Model selection and prediction latency

S2 has stronger published broad benchmark results than S0 in the [official original release](https://huggingface.co/apple/coreml-mobileclip), while remaining fast enough in this experiment. The official matched Core ML pair and tokenizer avoid a PyTorch/conversion runtime. Our seven-query set does **not** demonstrate a quality advantage: both scored 7/7. Selection remains provisional until a held-out dataset tests recall and false matches.

Each run uses one actual iPhone frame and the text “a person in a room.” First image/text predictions and five warmups are excluded, followed by 100 measurements per encoder. Values below are median **synchronous Core ML prediction wall time**, excluding model load, frame conversion, tokenization and output normalization.

| Model | Compute policy | Image median | Text median |
| --- | --- | ---: | ---: |
| S0 | cpuOnly | 8.351 ms | 2.081 ms |
| S0 | cpuAndNeuralEngine | 1.774 ms | 1.522 ms |
| S0 | all | 1.145 ms | 18.932 ms |
| **S2** | **cpuAndNeuralEngine** | **2.266 ms** | **1.259 ms** |
| S2 | cpuOnly | 19.185 ms | 4.597 ms |
| S2 | all | 2.143 ms | 37.914 ms |

The S2 CPU+ANE run loaded in 3.509 s, then recorded first predictions of 7.417 ms/image and 4.678 ms/text. These are first calls for that model instance, not a guaranteed cold OS/cache measurement. `.all` was especially slow for text in these runs; that is a measured result on this machine under its current workload, not a universal GPU conclusion. CPU+ANE is the default because it performs well for both encoders here and leaves GPU inference out of the policy.

A separate seven-source S2 index process completed in **5.26 s wall time**, including publication. `/usr/bin/time -l` reported **518,963,200 bytes maximum resident set size** (about 495 MiB) and **740,672,832 bytes peak memory footprint** (about 706 MiB). These process metrics are not a combined process/device/XPC peak or a strict total-memory guarantee. The sampler's 256 MiB owned decoded-media budget excludes Core ML, Core Image and OS allocations.

## What actually ran on the Neural Engine

The requested policy, compute plan and runtime trace provide different evidence:

| Encoder | Preferred plan operations | Estimated ANE cost weight | Runtime batch overlap |
| --- | --- | ---: | --- |
| S2 image | 390 ANE, 2 CPU, 1320 unassigned | 99.265% | 100 ANE intervals during 100 measured calls |
| S2 text | 254 ANE, 6 CPU, 458 unassigned | 87.424% | 100 ANE intervals during 100 measured calls |

Unassigned plan operations include constants/control bookkeeping. Estimated cost weights are **not measured runtime operation percentages**. CPU fallback is present in both plans. `.cpuAndNeuralEngine` does not force all computation onto ANE; preprocessing can also use the GPU.

Instruments attached to a prewarmed target using **Core AI + Neural Engine + Points of Interest**. PID-scoped `MeasuredImageBatch` and `MeasuredTextBatch` signposts delimit the 100-call loops. The image batch lasted **255.494 ms**, with **194.997 ms** of unioned overlapping ANE hardware intervals. The text batch lasted **225.010 ms**, with **159.482 ms** of unioned overlapping intervals. The complete recording contains 212 prediction intervals, including the first calls and warmups.

Attached ANE rows are generic “Neural Engine Prediction” hardware events and lack independent PID/model attribution. The overlap is evidence consistent with ANE participation in both encoders, but cannot prove that every interval belongs exclusively to PXLmpeg or determine an exact CPU/ANE operation or utilization percentage. An earlier image-only launch probe also recorded model-labelled `mobileclip_s2_image` ANE predictions. No equivalent model-labelled text attribution was obtained. A cold full-startup trace failed to complete a benchmark within its recording window; it is not used as performance evidence. The successful warmed trace excludes startup.

Raw traces can contain other processes and host details, so they are ignored local artifacts. Only the sanitized metrics are published. Apple explains the distinction between configuration and performance analysis in its [Core ML performance guide](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode) and [optimization session](https://developer.apple.com/videos/play/wwdc2022/10027/).

## Model provenance

`Scripts/fetch-semantic-model.py` uses only Python's standard library and explicitly downloads pinned assets. The runtime has no network code or Python dependency. It verifies SHA-256, preserves existing mismatched files and stores a provenance manifest, model card and the original release's linked weight terms alongside assets.

- Core ML models: `apple/coreml-mobileclip` revision `3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947`.
- Tokenizer: official native example revision `48faa0fea4b08d74188b3841771aca6ff2c92852`.
- The pinned original [model card](https://huggingface.co/apple/coreml-mobileclip/blob/3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947/README.md) declares `apple-ascl` and links the historical [LICENSE_weights_data](https://github.com/apple-aiml-research/ml-mobileclip/blob/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/LICENSE_weights_data). Those terms are separate from PXLmpeg's source license. The newer repository's model license belongs to a later release and is not silently substituted for this pinned original release. No weights or tokenizer data are redistributed here.

Model identity hashes the raw image/text assets, tokenizer and preprocessing revision. Arbitrary host compiled caches are ignored; loading uses compiler-returned temporary paths with raw asset hashes checked before/after. The native tokenizer matches conformance sequences from Apple's native example; it does not introduce a third-party tokenizer runtime.

## Verification and reproduction

**86 tests passed, zero failures and zero skips**, with both model assets and the relocated camera original supplied. Release build passed. Manifest audit found zero external package dependencies and zero binary targets. Runtime audit passed for `pxlmpeg`, `pxl-player` and `pxl-search`.

Coverage includes tokenizer conformance; malformed/oversized records and vectors; model mismatch; poisoned compiled cache isolation; actual PTS/rotation/HDR conversion; explicitly assumed versus tagged BT.709 pixel consistency; forward sampling across timestamp gaps; busy admission and cancellation; FIFO source/sidecar rejection; exclusive output publication; and existing video, remux, HDR and playback regressions. Independent code review's important findings were addressed and its follow-up found none remaining.

```sh
./Scripts/build.sh -c release
python3 Scripts/fetch-semantic-model.py --variant both
PXL_SEMANTIC_MODELS="$PWD/.work/semantic/models" \
PXL_PLAYBACK_SOURCE=/absolute/path/camera-original.MOV ./Scripts/test.sh
./Scripts/verify-dependencies.sh

./.build/release/pxl-search index --models .work/semantic/models \
  --variant s2 --interval 0.5 --assume-bt709 \
  --output /absolute/path/new-index.json /absolute/path/camera.MOV /absolute/path/ali.mp4
./.build/release/pxl-search query --models .work/semantic/models \
  --index /absolute/path/new-index.json "a guitar beside a plant"
./.build/release/pxl-search profile --models .work/semantic/models \
  --variant s2 --compute cpuAndNeuralEngine --repetitions 100 /absolute/path/tagged.MOV
./Scripts/profile-semantic.sh /absolute/path/tagged.MOV
```

The tracing script requires full Xcode/Instruments and an already-built release binary. Its default source admission is strict; use a tagged source such as the iPhone camera original. It prewarms, attaches to its own process, exports hardware/signpost tables and writes a conservative summary into ignored `Artifacts/`. Local `xctrace` permissions/tool availability can affect reproduction.

## Limits before application integration

This is sampled image/text retrieval, not captioning, OCR, tracking, person identification or a temporal action model. It cannot establish “walking,” “entering” or “leaving” from isolated frames. Center crops discard edges; sparse samples miss short events. Cosine similarity is not probability, and an absent query still ranks some candidate. The test set is small and known in advance, with no blind held-out evaluation or calibrated rejection threshold.

Cancellation is cooperative around native calls. Total native/model memory is not bounded by the decoded-media budget. Long-form indexing, simultaneous playback responsiveness, broad HDR conversion quality and macOS 15 remain unvalidated. Hosts must manage security-scoped access, catalog lifecycle and source-change validation. Pixel Deck/Sirius integration and a semantic search UI remain follow-up work. See [architecture and next gates](../architecture/semantic-analysis.md).
