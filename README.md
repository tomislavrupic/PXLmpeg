# PXLmpeg

![PXLmpeg — Swift + Metal · Apple Silicon](assets/pxlmpeg-banner-v1.png)

A native Swift + Metal media engine for Apple Silicon, with **zero third-party dependencies in the core**.

**Early research phase.** PXLmpeg is experimental and actively evolving; it is not yet a complete FFmpeg replacement. [Visit the project site](https://tomislavrupic.github.io/PXLmpeg/).

**Current priority:** professional media support and the native frame/audio engine needed by Pixel Deck. The research branch now has a separate native ProRes 422-family MOV + PCM ingest prototype; Sony MXF/XAVC remains a roadmap target. A separate Pixel Deck research build now connects it to the actual Metal renderer and Core Audio clock; [playback evidence and limits](docs/integrations/pixel-deck-playback.md). Production adoption and ProRes export remain future work. See the [Pixel Deck engine roadmap](docs/architecture/pixel-deck-engine-roadmap.md). Semantic search remains optional.

The native pipeline reads H.264/HEVC MOV/MP4 with AVFoundation, decodes on required hardware with VideoToolbox, rotates/resizes NV12 or 10-bit P010 planes with our Metal kernels, encodes on required hardware, and writes a new MOV or MP4. AAC can be copied unchanged or explicitly dropped. Both codec sessions report actual hardware use.

The **0.7.0-semantic-prototype** milestone added optional local semantic footage search with Core ML MobileCLIP-S2, timestamped sidecar indexes and Neural Engine profiling. See [semantic validation](docs/validation/semantic-search.md). The optional native playback library and Mac demo support play/pause, seeking, audio and generation-safe replacement; see [playback validation](docs/validation/playback.md).

The **0.5 remux/MP4 milestone** added MP4 output and native compressed stream copying. MOV/MP4 round trips preserve encoded pictures, AAC samples, presentation timing, display transforms and HDR metadata; the copy path initializes no decoder, GPU or encoder. Main10 SDR and BT.2020 HLG/PQ remain supported. See [remux/MP4 validation](docs/validation/remux-mp4.md) and [Sirius preview integration contract](docs/integrations/sirius-preview.md). See [HDR/iPhone validation](docs/validation/hdr.md), [HEVC/rotation results](docs/validation/hevc-rotation.md), and [Pixel Deck fit](docs/validation/pixel-deck-fit.md). Earlier [B-frame results](docs/validation/bframes.md) and [initial benchmarks](docs/validation/m1-native-pipeline.md) remain historical evidence.

## Build and run

Requires Apple Silicon and full Xcode with Metal tools. Tested with Swift 6.4 / Xcode 27 on macOS 27.0.1. The declared macOS 15 deployment floor has not been tested on a macOS 15 machine.

```sh
git clone https://github.com/tomislavrupic/PXLmpeg.git
cd PXLmpeg
./Scripts/build.sh -c release
./.build/release/pxlmpeg capabilities
./.build/release/pxlmpeg inspect /absolute/path/input.mov
./.build/release/pxlmpeg plan job.json
./.build/release/pxlmpeg run job.json
```

Example `job.json` (replace the paths; the destination must not exist):

```json
{
  "schemaVersion": 1,
  "id": "11111111-1111-1111-1111-111111111111",
  "source": "file:///absolute/path/input.mov",
  "destination": "file:///absolute/path/output.mov",
  "resizeWidth": 1280,
  "videoBitrate": 4000000,
  "audioPolicy": "copy",
  "memoryBudgetBytes": 268435456
}
```

Set `"outputContainer": "mp4"` with a `.mp4` destination for MP4 output; the default remains MOV with a `.mov` destination. MP4 files use fast-start layout for progressive local/HTTP playback. Set `"outputCodec": "hevc"` for HEVC output; H.264 remains the legacy default. Ten-bit input requires HEVC and retains its bit depth and transfer function. For iPhone files with timed metadata tracks, explicitly select `"timedMetadataPolicy": "discard"` (default `reject`); the receipt records the discarded track count. Original source files remain untouched.

Omit `resizeWidth` to keep the display size. Resizing preserves aspect ratio with an even output height. `audioPolicy` is `copy` or `drop`. Commands emit versioned JSON lines; `--json` is an optional explicit alias for that behavior. Exit codes: 0 success, 2 invalid/unsupported request or resource limit, 3 processing/I/O failure, 130 cancellation. Ctrl-C requests cancellation and waits for safe native teardown.

When relocating the CLI for transcoding, copy **both** `.build/release/pxlmpeg` and `.build/release/PXLmpeg_PXLMetal.bundle` into the same directory. Working-directory-independent lookup is tested. A missing resource bundle returns a typed error for operations requiring Metal. `remux`, `plan-remux`, `inspect` and `help` work without that bundle.

## Supported recipe

- Local MOV/MP4 with one H.264/HEVC video track and at most one mono/stereo AAC track at 44.1/48 kHz. Timed metadata tracks require explicit discard; other extra tracks are rejected.
- B-frame input with an SPS-derived bounded presentation window; progressive 4:2:0, limited range, left chroma, 8-bit BT.709 or 10-bit BT.709 / BT.2020 HLG/PQ.
- Identity or 90/180/270-degree proper rotation, square pixels, full clean aperture, even coded dimensions from 16 through 4096. Transcoding bakes rotation into pixels and writes an identity transform; remux retains the original matrix.
- GPU copy or separable area/bilinear scaling; H.264/HEVC Main or HEVC Main10 MOV/MP4 output. HLG/PQ filtering stays in encoded YCbCr space; no implicit tone mapping or linear-light composition.
- Supplied mastering-display, content-light and ambient metadata retained and verified. Apple encoder HDR insertion is configured to Auto with old dynamic metadata preservation disabled. Receipts expose actual output static metadata and Dolby configuration RPU signalling; they do not certify per-frame RPU contents or HDR display appearance.
- One running job per engine; transcoding uses one rendered frame at a time with up to `SPS reorder bound + 1` retained decoded frames; bounded owned memory; atomic publication that refuses to overwrite an existing destination.

The narrow Dolby input subset is single-layer profile 8 with an HLG/PQ-compatible base layer and v1.0 configuration (8.4/8.1). ProRes in the transcode/remux recipe, 4:4:4, full-range, arbitrary transforms, broader containers, editing, PCM/audio DSP, general tone mapping and temporal video understanding remain future work. Native VFR, nonzero-start and simple container edit-offset cases pass; general trim/preroll/speed changes and AAC priming need broader validation. HDR reference-display approval and minimum-OS validation remain unperformed.

ALi files with missing colour tags require an explicit `"inputColourPolicy": "assumeBT709Limited"` in the job request. The default is `requireTagged`. This interpretation is recorded in receipts; conflicting tagged colour is rejected. `plan` applies the request policy, while `inspect` remains strict.

## Professional ProRes + PCM ingest (research)

The separate `PXLProfessionalMedia` library delivers retained ten-bit 4:2:2 `x422` CVPixelBuffers and timestamped mono/stereo 48 kHz float32 PCM chunks from ProRes Proxy/LT/422/HQ MOV. Pull delivery, owned-memory reservations, generation-fenced seeks, cancellation and actual VideoToolbox hardware reporting form the first engine boundary intended for Pixel Deck. Default decode requires hardware; unsupported formats reject explicitly. Existing transcode/remux recipes remain unchanged.

```sh
./Scripts/build.sh -c release
./.build/release/pxl-prores probe /absolute/path/prores-pcm.mov
```

A real HQ/24-bit PCM render reached EOF with 49 native video frames and 98,000 PCM frames, matching presentation ends and unchanged source SHA-256. That original probe validates ingest. The subsequent [Pixel Deck consumer check](docs/integrations/pixel-deck-playback.md) validates a first short-clip Metal/audio-clock playback path. See the [API, limits and measured evidence](docs/validation/prores-pcm.md). ProRes export, 4444/XQ/RAW, MXF, multichannel audio and sustained production transport remain future work.

## Interactive playback

The optional `PXLPlayback` library provides a main-actor `PlaybackSession` and a direct AppKit `PlaybackView`. Open, play/pause, zero-tolerance native seeking, volume/mute, clip replacement and close are available in the first research backend. A small Mac demo uses the same API:

```sh
./Scripts/build.sh -c release
./.build/release/pxl-player /absolute/path/input.mov
# Explicit interpretation for untagged SDR ALi clips:
./.build/release/pxl-player --assume-bt709 /absolute/path/input.mp4
```

To build a local development app bundle, run `./Scripts/build-player.sh`, then open `.build/PXLPlayer.app`. It is ad hoc signed for local use, not a notarized release.

The demo also has an Open dialog. Use the optional interpretation checkbox only for untagged SDR sources known to be Rec.709 limited. Playback reads the original; it does not discard or rewrite metadata tracks.

```swift
import PXLPlayback

// On the main actor; retain session and host security-scoped access.
let session = PlaybackSession()
let view = PlaybackView(session: session)
session.onChange = { snapshot in /* update host controls */ }
try await session.open(sourceURL)
session.play()
try await session.seek(to: 1.5)
session.pause()
session.close() // on attachment/window teardown
```

This backend uses **AVPlayer** for decoding, audio synchronization and presentation. It does not enforce the transcode worker's hardware selection or owned-memory budget, expose PCM/frame leases, or use our Metal kernels for playback. Native zero-tolerance seeking remains constrained by source sample timing. After `.ended`, seek to zero before replaying. The host owns UI, access lifetimes and cache state. See [playback validation](docs/validation/playback.md).

Read-only semantic search and playback accept editor timecode tracks alongside supported video/audio; export/remux still rejects those tracks. Result timestamps remain source presentation times, without SMPTE timecode mapping.

The draft native search app also has a [Pixel Records app identity](assets/app-icon/README.md), including a packaged macOS icon and matching dark interface. See [native search UI validation](docs/validation/native-search-ui.md) for the open stability investigation and current verification limits.

## Semantic footage search

The optional `PXLAnalysis` library and `pxl-search` CLI encode sampled frames and text into a shared 512-dimensional embedding space. Search returns ranked **actual source timestamps**, source hashes and cosine similarity scores. MobileCLIP-S2 is the default; S0 is available for comparison. This is an early visual retrieval prototype, not verified captions, identity recognition or temporal action understanding.

Fetch the pinned original Apple Core ML models and matching tokenizer explicitly. Python 3 standard library is used only by this developer download script; runtime inference is native Swift/Core ML and performs no network requests. Model assets stay outside Git and have their own [upstream release terms](docs/validation/semantic-search.md#model-provenance).

```sh
./Scripts/build.sh -c release
python3 Scripts/fetch-semantic-model.py --variant s2
./.build/release/pxl-search index --models .work/semantic/models \
  --output /absolute/path/new-index.json --interval 0.5 /absolute/path/input.mov
./.build/release/pxl-search query --models .work/semantic/models \
  --index /absolute/path/new-index.json --limit 5 "a person beside a car"
```

Use `--assume-bt709` for untagged SDR footage only when that interpretation is known to be correct. Rotation is applied before model preprocessing. SDR uses the core hardware decoder and explicit BT.709 conversion; HDR samples use Apple's system SDR conversion. Both are rendered to sRGB and center-cropped to 256 × 256 for the model. The original HDR source is untouched. Sparse sampling and center cropping can miss brief events or objects near the edges.

```swift
import PXLAnalysis

let analyzer = try SemanticAnalyzer(models: localModelDirectory)
let index = try await analyzer.index(
    sources: [sourceURL], options: try SamplingOptions(intervalSeconds: 0.5))
try index.write(to: newSidecarURL) // exclusive publication; never overwrites
let hits = try await analyzer.query("a guitar beside a plant", index: index, limit: 5)
// hits contain source, sourceSHA256, actualTime and score.
```

Retain the actor to reuse loaded models for warm searches. Each CLI invocation verifies raw model assets and asks Core ML to compile them; repeated analyzer loads in one process reuse a bounded compiler-owned pool. Startup takes seconds on the tested Mac. Warm prediction times are not CLI startup or indexing throughput. Indexes bind model, tokenizer, preprocessing and source SHA-256 identities. Hosts must revalidate source contents before reusing an index after file changes; querying does not reopen or rehash the footage.

Sampling defaults to one frame per second, capped at 256 requests per source; limits are 32 sources, 4096 aggregate embeddings and a 32 MiB serialized sidecar. Only one operation runs per analyzer. Cancellation is cooperative around native calls. The SDR decoder has a 256 MiB owned-media budget; Core ML, Core Image and OS allocations are outside that budget.

```sh
./.build/release/pxl-search plan --models .work/semantic/models
./.build/release/pxl-search profile --models .work/semantic/models \
  --compute cpuAndNeuralEngine --repetitions 100 /absolute/path/tagged.mov
# Full Xcode/Instruments required; raw trace stays in ignored Artifacts/:
./Scripts/profile-semantic.sh /absolute/path/tagged.mov
```

`.cpuAndNeuralEngine` permits CPU fallbacks and excludes GPU inference; image preprocessing can still use the GPU. `plan` reports preferred devices and estimated cost weights. `profile` reports native prediction latency; the Instruments script correlates actual ANE hardware intervals with PID-scoped benchmark batches. None of these metrics is an exact percentage of operations running on ANE. See the [measured results and attribution limits](docs/validation/semantic-search.md) and [architecture](docs/architecture/semantic-analysis.md).

## Native search app — research build

`PXLSearch.app` adds footage/model-folder pickers, indexing, text search, thumbnail results and native preview. Click a result to open its source and seek to the indexed source PTS. Playback starts muted. File → Open Index / Save Index As reuses sidecars; existing files are never overwritten.

**Stability investigation remains open:** a whole-Mac stall and forced restart were reported during the first interactive trial. The initial 11 UI tests passed, including actual Search/result button actions and advancing playback, but that does not establish system stability. Resource fixes subsequently passed lightweight tests; full hardware revalidation has been paused. See [incident and verification boundaries](docs/validation/native-search-ui.md). This is a development build, not a notarized release.

```sh
python3 Scripts/fetch-semantic-model.py --variant s2
./Scripts/build-search-app.sh
open .build/PXLSearch.app
# Explicit CPU compatibility for a controlled future test:
./.build/release/pxl-search-app --compute cpuOnly --models .work/semantic/models
# Reuse an existing index; --query only prefills, it does not start inference:
./.build/release/pxl-search-app --models .work/semantic/models \
  --index /absolute/path/index.json --query "a guitar beside a plant"
```

Add Footage can accumulate files from different folders. Select the explicit Rec.709 assumption only for known untagged SDR, then Index Footage. Sampling is one second with per-source caps; partial indexing is displayed. Search shows at most 12 candidates, at most three per source with one-second separation, plus actual timestamps and similarity scores. Source contents are checked before search and selected playback. Thumbnail previews use Apple's display-oriented SDR extraction and may differ from the analyzer's explicit BT.709 conversion.

The device selector exposes Neural Engine + CPU and CPU compatibility; CPU compatibility excludes ANE/GPU **inference**, while decoding, thumbnails, preprocessing and playback still use native system hardware. There is no silent fallback. Models remain external; the development bundle records a local cache folder only. Choose Models if the folder moves. The app is unsandboxed for local development; sandbox/bookmark support remains future work.

Thumbnail/HDR image waits have an eight-second logical deadline and native cancellation forwarding. At most two unfinished native image requests may remain; timed-out requests retain admission permits until native callbacks finish, preventing unbounded replacements. This cannot force a hung driver or native call to stop. Compiler artifacts are reused within one process for at most two identities, validated before cache admission, and cleaned on final lease release/normal exit when no compilation lock is busy. A forced kill or stalled compilation at exit can leave temporary artifacts for OS cleanup. No arbitrary host compiled cache is loaded.

The packaging script signs/verifies a fresh staged bundle before replacing it, preserving the previous bundle and any running executable inode. It does not restart a running app. Real-model tests refuse to start while the search app is running.

## Copy without re-encoding

For supported tagged H.264/HEVC sources, use the separate remux request. It keeps coded dimensions, the original display transform, compressed video and optional AAC; it has no bitrate, resize or codec-selection fields. It preserves source codec/profile and does not make an unsupported codec playable.

```sh
./.build/release/pxlmpeg plan-remux examples/remux-mp4.json
./.build/release/pxlmpeg remux examples/remux-mp4.json
```

Edit the example's file URLs first; the destination must not exist. Compressed copying uses bounded packets rather than decoded surfaces. Container muxing can rebase the decode clock: receipts expose the measured first-video DTS offset, while acceptance checks every packet for a constant shift with identical PTS/duration/payload. AAC validation accounts for packet regrouping and retains trim/priming fields. General trims, discontinuities and arbitrary edit lists remain separate work.

MOV/MP4 structural labels can change during remux; this does not mean pixel or codec data changed. Strict input colour/profile admission still applies. Timed metadata requires explicit discard; arbitrary container metadata, chapters and extra tracks are not copied.

## Library

```swift
import PXLMedia
import PXLmpeg

let engine = MediaEngine(configuration: try EngineConfiguration())
let request = try JobRequest(
    source: sourceURL, destination: newDestinationURL,
    resizeWidth: 1280, videoBitrate: 4_000_000, audioPolicy: .copy)
let prepared = try await engine.prepare(request)
let receipt = try await engine.execute(prepared)
```

The public API also offers `inspect`, `capabilities`, `progress(for:)`, `cancel`, and `lastReceipt`. Backend handles stay inside the package. A watchdog reports `stalled-native-teardown-pending` independently of blocked processing; it retains native storage and throws `noProgress` when control safely returns. This is not a hard teardown deadline for a hung OS call.

The request's budget measures engine-owned media allocations, not total process memory. Receipts report a separately sampled process footprint. Codec/driver allocations and sampling gaps mean that value is not a strict system-wide peak.

## Verification

```sh
./Scripts/test.sh
# Optional real-model and camera tests (after fetching model assets):
PXL_SEMANTIC_MODELS="$PWD/.work/semantic/models" \
PXL_PLAYBACK_SOURCE=/absolute/path/to/iphone-original.MOV ./Scripts/test.sh
./Scripts/build.sh -c release
./Scripts/verify-dependencies.sh
./Scripts/acceptance.sh
./Scripts/acceptance-bframes.sh /absolute/path/to/ali-output.mp4
./Scripts/acceptance-wide.sh /absolute/path/to/hevc.mp4
./Scripts/acceptance-remux.sh /absolute/path/to/iphone-original.MOV
bash Scripts/acceptance-hdr.sh /absolute/path/to/iphone-original.MOV
```

Acceptance generates first-party media, performs one warm-up and five measured runs for each 1080p/4K case, checks frame count/timestamps and hardware flags, and exercises the relocated CLI. Reports and representative outputs go to `Artifacts/native.*`; `.work/latest-acceptance-path` identifies the latest completed run. `pxl-validation` and `PXLTestSupport` are development tools, not dependencies of the production libraries or CLIs.

Build scripts currently select SwiftPM's native build system for predictable resource packaging; Xcode 27 warns that this option is deprecated. No FFmpeg, Homebrew, Python, external Swift package, downloaded binary, model weights, or network service is required to build or run the engine.

## Design and scope

- [Native search UI and stability investigation](docs/validation/native-search-ui.md)
- [Interactive playback results](docs/validation/playback.md)
- [Semantic search results and ANE evidence](docs/validation/semantic-search.md)
- [Semantic analysis architecture](docs/architecture/semantic-analysis.md)
- [Remux and MP4 results](docs/validation/remux-mp4.md)
- [Sirius preview integration contract](docs/integrations/sirius-preview.md)
- [Architecture](docs/superpowers/specs/2026-10-13-pxlmpeg-architecture.md)
- [Plan and execution status](docs/superpowers/plans/2026-10-13-pxlmpeg-foundation.md)
- [Native validation](docs/validation/m1-native-pipeline.md)
- [HEVC and rotation validation](docs/validation/hevc-rotation.md)
- [Main10/HDR and iPhone validation](docs/validation/hdr.md)
- [Pixel Deck consumer assessment](docs/validation/pixel-deck-fit.md)
- [B-frame plan](docs/superpowers/plans/2026-10-13-pxlmpeg-bframes.md)
- [B-frame results and real ALi tests](docs/validation/bframes.md)

PXLmpeg owns processing within one media job. Applications own their projects and creative decisions; Sirius retains orchestration across jobs and models. No existing application workflow has been switched over. Source is published at [tomislavrupic/PXLmpeg](https://github.com/tomislavrupic/PXLmpeg). Generated media, local build output and working ledgers remain excluded. This is an early native subset rather than complete FFmpeg format/feature parity.


## Project site

The static landing page lives in `site/`, independent of the native engine. `Scripts/build-site.sh` prepares `.build/site` using the selected PL icon and current signal-flow infographic; no npm packages or web framework are required. GitHub Pages publishes it through `.github/workflows/pages.yml`. To preview locally, run the build script and serve `.build/site` with a static HTTP server.
