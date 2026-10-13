# PXLmpeg Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task, or superpowers:subagent-driven-development if the user selects delegation. Steps use checkbox (`- [ ]`) syntax for tracking. This document authorizes no implementation or changes to other products by itself.

**Goal:** Prove a native Swift/Metal media pipeline with bounded ownership, hardware codec verification, correct sample timing, and a reusable library/CLI, without third-party core dependencies.

**Architecture:** Implement the M1 native pipeline proof in the linked specification. AVFoundation reads/writes compressed samples, VideoToolbox owns hardware codec sessions, our Metal kernels scale shared-surface frames, and a Swift executor coordinates a bounded single job. A structured request and receipt connect the library and CLI.

**Tech Stack:** Swift 6, SwiftPM, Metal Shading Language, Foundation, CoreMedia, AVFoundation, VideoToolbox, CoreVideo, IOSurface, CryptoKit, OSLog, Dispatch, Darwin, XCTest, Xcode Metal tools.

**Spec:** [PXLmpeg architecture](../specs/2026-10-13-pxlmpeg-architecture.md). Read both documents before execution.

## Global Constraints

- Deployment floor: macOS 15.0; runtime architecture: arm64 Apple Silicon.
- Minimum toolchain: Swift 6.0 with full Xcode and its Metal tools; Swift 6 language mode.
- The first implementation is offline file processing. Live preview and real-time audio require separate execution policies later.
- A library and CLI ship before a graphical application or background service.
- No external package dependencies, third-party source, binary targets, network services, model downloads, or external media subprocesses in the core.
- M1 supports only the architecture's section 8 matrix; it is not an application-ready release.
- Owned media budget: 256 MiB per job, configurable from 64–2048 MiB.
- At most four admitted video frames, including frames awaiting codec or GPU completion.
- At most 32 compressed packets and 32 MiB of owned packet payload across queues; reject an individual packet over 8 MiB.
- One running job per engine instance; a second request returns `engineBusy`.
- Never overwrite source media, an existing destination, another job's partial file, or another product's files.
- No Git initialization, repository relocation, publication, installation into applications, or shared-branch changes are included. If a repository is separately authorized, commit each independently verified task there; otherwise leave changes as local files.

## Review Focus

1. Empty, truncated, or midstream-changing media: fail with the source stage identified and no destination (Tasks 3, 5, 9).
2. Slow writer, missing callback, or late callback after cancellation: remain bounded, diagnose no progress, and retain in-use storage (Tasks 4, 5, 9).
3. Nonzero starts, VFR, unequal A/V durations, or AAC priming: preserve supported timing and reject unsupported transformations explicitly (Tasks 3, 7, 9).
4. Destination/source aliases, a destination created during execution, or disk failure: preserve existing files and remove only this job's partial output (Tasks 8, 9).
5. Missing Metal resources, unsupported hardware settings, or a changed source after preparation: typed failure, no hidden fallback, no false success (Tasks 2, 5, 9, 10).

## Delivery sequence

Tasks 1–10 implement M1. Execute sequentially: ownership and timing interfaces are shared across tasks and should settle before hardware integration. The roadmap at the end defines subsequent milestones; it is not permission to add them to M1.

Before code: verify the current directory and instructions again. These documents were created in an empty unversioned folder. Do not assume the state will remain unchanged.

## Planned file map

```text
Package.swift                         # five production targets; no dependencies
.gitignore                            # build products and generated metallib
Kernels/Scale.metal                   # original NV12 plane resampling kernels
Sources/
  PXLMedia/
    MediaTime.swift                   # validated rational time
    JobRequest.swift                  # strict schema v1 and configuration
    MediaDescriptions.swift           # assets, formats, capabilities
    JobEvidence.swift                 # progress, receipts, stable errors
  PXLAppleMedia/
    AssetInspector.swift              # metadata and supported-format checks
    SampleReader.swift                # bounded original-format sample access
    MediaLease.swift                  # reference-counted backend ownership
    MediaBudget.swift                 # shared owned bytes and frame/packet credits
    PixelBufferPool.swift             # threshold-limited IOSurface buffers
    VideoDecoder.swift                # hardware VT decoding and callbacks
    VideoEncoder.swift                # hardware VT encoding and callbacks
    ContainerWriter.swift             # compressed video/AAC muxing
  PXLMetal/
    MetalContext.swift                # device, queues, bundled library
    TextureLease.swift                # CVMetalTexture lifetime
    PlaneScaler.swift                 # dispatch and GPU completion
    Resources/PXLKernels.metallib      # generated; never handwritten/committed
  PXLmpeg/
    MediaEngine.swift                 # public actor and lifecycle
    PreparedJob.swift                 # opaque validated recipe
    MediaPlanner.swift                # recipe lowering and feasibility
    OutputTransaction.swift           # exclusive partial and publication
    JobRunner.swift                   # per-job backend execution
  pxlmpeg/
    main.swift                        # entrypoint and signal bridge
    CommandLine.swift                 # fixed command grammar
    JSONEventWriter.swift             # bounded machine-readable events
Tests/
  PXLMediaTests/                      # model and schema
  PXLAppleMediaTests/                 # adapter and codec tests
  PXLMetalTests/                      # CPU reference vs real kernels
  PXLmpegTests/                       # planner, budget, transaction, executor
  PXLmpegCLITests/                    # CLI contract and relocation
  Support/                           # first-party fakes and fixture generator
Scripts/
  build.sh                           # compile metallib then swift build
  test.sh                            # prepare resources then swift test
  verify-dependencies.sh             # manifest and artifact audit
  acceptance.sh                      # native corpus and CLI verification
docs/validation/                     # measured reports written during execution
```

Tests/Support may be a test-support target, never a shipped library dependency. Add files when their task begins; do not create empty placeholders for later milestones.

Backend interfaces used by another target use Swift `package` visibility. Reservation types belong to `PXLAppleMedia`, not `PXLmpeg`; this keeps the target graph acyclic. Public exposure is limited to the model and engine facade. Names below described as internal refer to the package boundary; use file/type `internal` only when no other target consumes them.

### Task 1: Request, time, and evidence contracts

**Files:** create `Package.swift`, `.gitignore`, the four `Sources/PXLMedia/*.swift` files, `Tests/PXLMediaTests/MediaTimeTests.swift`, `Tests/PXLMediaTests/JobRequestTests.swift`.

**Interfaces:**

- `MediaTime.init(value: Int64, timescale: Int32) throws`; immutable integer properties, Codable/Sendable/Equatable/Comparable. Use validated CoreMedia conversion in the adapter, not in the serialized model.
- `JobRequest`: schemaVersion `Int` (=1), id `UUID`, source/destination `URL`, resizeWidth `Int?`, videoBitrate `Int`, audioPolicy `AudioPolicy` (`copy`, `drop`), memoryBudgetBytes `Int`.
- `JobRequest.decodeStrict(_ data: Data) throws -> JobRequest`; reject unknown fields and non-file URLs. `normalizedData() throws -> Data` produces deterministic sorted-key JSON with defaults made explicit.
- `EngineConfiguration.init(defaultMemoryBudgetBytes: Int = 268_435_456) throws`.
- Define value types `AssetDescriptor`, `CapabilityReport`, `JobProgress`, `JobReceipt`, and `MediaError` from spec sections 5, 9, 10. Stable error codes include invalidRequest, unsupportedMedia, unsupportedHardware, hardwareUnavailable, resourceLimit, engineBusy, sourceChanged, destinationExists, cancelled, ioFailure, codecFailure, gpuFailure, timingViolation, noProgress.
- Errors contain `code`, `stage`, `message`, optional underlying domain/code. Do not put raw unbounded OS payloads into the JSON API.

- [ ] Add failing tests: 1/24 equals 1000/24000; invalid timescale zero/negative throws; extreme cross-timescale comparisons do not overflow; schema 2/unknown key/odd width/nonpositive bitrate/remote URL fails; omitted budget normalizes to 268435456.
- [ ] Run `swift test --filter PXLMediaTests`; confirm failures identify missing implementation, then implement contracts and strict validation.
- [ ] Test width limits 16/4096 accepted, 14/4098 rejected; budget 67108864/2147483648 accepted and values outside rejected. Verify Codable round trips preserve integer time and normalized requests are byte-identical regardless of input key order.
- [ ] Run `swift test --filter PXLMediaTests`; require all pass in Swift 6 language mode. Record task evidence; commit only if a repository has been authorized.

Start with only targets whose files exist. Subsequent tasks add their own target declarations and tests; the final production target graph must match the specification.

### Task 2: Reproducible Metal build and device discovery

**Files:** create `Scripts/build.sh`, `Scripts/test.sh`, `Sources/PXLMetal/MetalContext.swift`, initial `Kernels/Scale.metal`, `Tests/PXLMetalTests/MetalContextTests.swift`; modify manifest and ignore rules.

**Interfaces:** internal `MetalContext.init() throws`; `device: MTLDevice`, `commandQueue: MTLCommandQueue`, `library: MTLLibrary`; shader library lookup uses `Bundle.module` and the resource path fixed by the package manifest.

- [ ] Add failing native tests `bundledShaderRunsFromForeignWorkingDirectory` and `missingShaderLibraryIsTypedFailure`. The first dispatches an original minimal copy kernel and checks a known byte pattern; the second uses an injected resource resolver, without damaging real build products.
- [ ] Make `build.sh` compile kernels with `xcrun -sdk macosx metal` and link with `xcrun -sdk macosx metallib` for the 15.0 deployment floor before invoking SwiftPM. Place output in `Sources/PXLMetal/Resources/PXLKernels.metallib`, explicitly bundled by the manifest. Scripts must quote paths and run correctly from a workspace path containing spaces.
- [ ] Implement device/library discovery and structured capability errors. No source compilation at runtime and no silent default-library lookup from the host app.
- [ ] Run `./Scripts/test.sh --filter MetalContextTests` and `./Scripts/build.sh --configuration release`; execute the test from a temporary unrelated working directory. Verify actual GPU dispatch, not only shader compilation. Preserve logs in `docs/validation/metal-build.md`.

A failure here stops hardware-path development until packaging is corrected. A compute shader test is not evidence of video-codec support.

### Task 3: Inspect and read original samples

**Files:** create `AssetInspector.swift`, `SampleReader.swift`, `Tests/Support/FixtureFactory.swift`, `Tests/PXLAppleMediaTests/AssetInspectorTests.swift`, `Tests/PXLAppleMediaTests/SampleReaderTests.swift`; extend media descriptions and manifest.

**Interfaces:**

- `AssetInspector.inspect(_ url: URL) async throws -> AssetDescriptor`.
- Internal `SampleReader.init(source: URL, audioPolicy: AudioPolicy) throws`; `nextVideo() throws -> EncodedSample?`, `nextAudio() throws -> EncodedSample?`, `cancel()`; methods used only on the owning backend queue.
- `EncodedSample` owns a CMSampleBuffer, track identity, PTS/DTS/duration, sequence, and charged payload size. It is not publicly Sendable. Reading nil at EOF is distinct from reader failure.
- Test-only `FixtureFactory.make(_ recipe: FixtureRecipe, at url: URL) async throws -> FixtureManifest` creates native tagged fixtures using Apple frameworks. Manifest records expected timing and audio payload hashes using CryptoKit.

- [ ] Add failing tests for one supported 1920×1080 tagged H.264 clip, absent audio, explicitly dropped audio, rotated/HDR/missing-colour input, extra tracks, empty/truncated file, and changing video format. Supported inspection returns exact dimensions/colour/timing; others fail with the specified stage and reason.
- [ ] Implement AVAssetReader outputs with nil output settings to vend original-format video/audio samples. Preserve sample attachments and avoid eager loading of the file.
- [ ] Generate fixtures in test temporary directories: a short 24 fps no-B-frame H.264 clip, AAC at 48 kHz with a known event and relative offset, VFR sample durations, invalid geometry, and a deliberately truncated copy. Fixtures are first-party outputs; generation failure fails the native test rather than substituting a mock silently.
- [ ] Add sample tests for nonnegative strictly increasing PTS, positive durations, one video sample per buffer, DTS equal to PTS or invalid, max packet size 8 MiB, and audio format-policy validation. Detect reordered/B-frame input as timingViolation; do not claim AVAssetReader metadata alone proves its absence.
- [ ] Run `./Scripts/test.sh --filter 'AssetInspectorTests|SampleReaderTests'`; compare observed packets/timestamps/attachments with fixture manifests. Store no production assets in the repository.

### Task 4: Bounded reservations and buffer lifetime

**Files:** create `Sources/PXLAppleMedia/MediaBudget.swift`, `Sources/PXLAppleMedia/MediaLease.swift`, `Sources/PXLAppleMedia/PixelBufferPool.swift`, `Tests/PXLAppleMediaTests/MediaBudgetTests.swift`, `Tests/PXLAppleMediaTests/MediaLeaseTests.swift`, `Tests/Support/ControlledCompletion.swift`.

**Interfaces:**

- Internal `MediaBudget.reserve(bytes: Int, kind: ReservationKind) throws -> Reservation`; `Reservation.release()` is idempotent. Limits and counters live on one owner; implementation exposes current and peak charged bytes for tests/receipts.
- `MediaLease` retains a CVPixelBuffer plus timing/format description and reservation. Backend-only transition methods identify codec/GPU users; final release waits for every user.
- `PixelBufferPool.acquire() throws -> MediaLease`; initialized with exact NV12 geometry, IOSurface/Metal compatibility attributes, and a threshold derived from the negotiated budget. The pool never expands without a reservation.

- [ ] Add tests: fifth admitted frame waits or is refused without allocation; 33rd packet/33rd MiB is not admitted; padded bytes are charged; releasing twice does not underflow; a minimum working set above budget fails; four-frame budget reduces to fewer slots when needed.
- [ ] Implement reservations and actual pool thresholds. Keep credit acquisition outside codec/GPU callbacks. Specify a cancellable wait mechanism owned by the runner; do not block a codec callback on a semaphore.
- [ ] Add controlled-completion tests: cancellation during GPU reading retains the input; encoder delay retains output; late callbacks cannot double-release or mutate a terminal job; submitted work may drain after cancellation.
- [ ] Run `./Scripts/test.sh --filter 'MediaBudgetTests|MediaLeaseTests'`; stress 1000 randomized completion orders with a fixed recorded seed and verify zero live reservations after drain.

### Task 5: Verified hardware decode and encode adapters

**Files:** create `VideoDecoder.swift`, `VideoEncoder.swift`, `Tests/PXLAppleMediaTests/VideoCodecTests.swift`, `Tests/Support/CodecBackendFake.swift`.

**Interfaces:** queue-confined adapters:

- `VideoDecoder.init(format: CMVideoFormatDescription, configuration: DecoderConfiguration, completion: @escaping DecoderCompletion) throws`; `submit(_ sample: EncodedSample, reservation: Reservation) throws`, `finish() throws`, `cancel()`.
- `VideoEncoder.init(configuration: EncoderConfiguration, completion: @escaping EncoderCompletion) throws`; `submit(_ frame: MediaLease) throws`, `finish() throws`, `cancel()`.
- Completion records contain sequence, timing, retained sample/frame payload or typed error. Configuration includes negotiated geometry, NV12 format, hardware-required policy and encoder bitrate. No backend callback directly calls an actor or writes a file.

- [ ] Add native tests: decode a fixture into NV12; encode known frames; query actual hardware use as true; reject unavailable hardware or required settings; propagate OSStatus failure. Fakes exercise failures that cannot be induced reliably on the host.
- [ ] Create VT sessions with hardware-required specifications. For encoding disable frame reordering and require an accepted bounded-delay configuration compatible with the frame admission limit. Validate returned formats and all required VTSetSessionProperty results.
- [ ] Implement callback ownership with exactly-once completion accounting. Reorder asynchronous decoder completions by admitted sample sequence for M1's no-reordering input; never assume callback arrival order. Drain delayed/asynchronous work at EOF before invalidation.
- [ ] Test delayed callbacks, reverse completion order, dropped-frame flags, codec failure, and cancellation during both decode and encode. Any unexpected dropped frame is an error for offline processing.
- [ ] Run `./Scripts/test.sh --filter VideoCodecTests`; require a real hardware decode/encode round trip and record accepted settings/actual hardware flags. Verify forward progress with four admission credits; unsupported bounded-delay settings fail explicitly instead of increasing queues indefinitely.

### Task 6: Original NV12 scaling kernels

**Files:** implement `Kernels/Scale.metal`; create `TextureLease.swift`, `PlaneScaler.swift`, `Tests/PXLMetalTests/PlaneScalerTests.swift`, `Tests/PXLMetalTests/ScalarScaleReference.swift`.

**Interfaces:** `PlaneScaler.init(context: MetalContext) throws`; queue-confined `submit(_ frame: MediaLease, output: MediaLease, completion: @escaping ScaleCompletion) throws`. Completion fires after GPU work completes or fails; output timing and colour metadata equal the input's.

- [ ] Add reference tests for identity copy, 1920×1080→1280×720, enlargement, independent stride padding, constant Y/Cb/Cr fields, ramps, impulses, checkerboards, and chroma edges. Assert height calculation uses nearest even with ties upward; reject a computed height outside 16–4096.
- [ ] Write an independent scalar Swift reference in tests: normalized area-overlap weights for reduction; centre-aligned bilinear interpolation for enlargement; edge clamp; declared left-sited chroma coordinate mapping. Establish exact source/destination pixel-centre equations in test comments before translating to Metal.
- [ ] Implement separate plane kernels with R8Unorm luma/RG8Unorm chroma mapping and bounded work proportional to the footprint. Use separable passes and charge any intermediate surfaces. Dispatch using actual plane dimensions; never assume tightly packed CPU rows or convert through RGBA unnecessarily.
- [ ] Enforce the spec's 1-code-value constant/copy and 2-code-value filtered tolerances. Compare every output pixel on small generated patterns; inspect representative enlarged images as an additional check, not a replacement for numerical tests.
- [ ] Run `./Scripts/test.sh --filter PlaneScalerTests` under Metal validation. Prove texture and surface leases survive GPU completion and return to the pool afterward. No performance claim until Task 10 measures the full pipeline.

### Task 7: Container writer and compressed audio preservation

**Files:** create `ContainerWriter.swift`, `Tests/PXLAppleMediaTests/ContainerWriterTests.swift`; extend fixture manifests.

**Interfaces:** queue-confined `ContainerWriter.init(temporaryURL: URL, videoFormat: CMVideoFormatDescription, audioFormat: CMAudioFormatDescription?) throws`; readiness properties per track, `appendVideo(_ sample: EncodedSample) throws`, `appendAudio(_ sample: EncodedSample) throws`, `finish() async throws`, `cancel()`.

- [ ] Add round-trip tests for encoded H.264 MOV output with no audio, AAC copy, and explicit drop. Verify source format hints are supplied to pass-through writer inputs and samples match those hints.
- [ ] Implement AVAssetWriter with nil output settings for already encoded samples; use writer readiness to stop admission. Preserve sample timing/attachments, relative track offsets, and supported source timeline. Do not retime audio independently or synthesize an FPS grid.
- [ ] Test first/last video samples, VFR durations, nonzero starts, shorter/longer audio, AAC packet payload hashes, and priming/trim attachments. Compare exported playback boundaries and audible alignment with the source; if the constrained path cannot preserve a fixture, explicitly reject that input shape and record it as M2 work rather than silently changing timing.
- [ ] Run `./Scripts/test.sh --filter ContainerWriterTests`; require successful finalization and read-back through a fresh reader. Test full-disk/write failure through a controlled writer adapter and confirm no false completion.

### Task 8: Prepared plans and source-preserving publication

**Files:** create `PreparedJob.swift`, `MediaPlanner.swift`, `OutputTransaction.swift`, `Tests/PXLmpegTests/MediaPlannerTests.swift`, `Tests/PXLmpegTests/OutputTransactionTests.swift`.

**Interfaces:**

- Internal `MediaPlanner.prepare(_ request: JobRequest, asset: AssetDescriptor, capabilities: CapabilityReport) throws -> PreparedJob`; selected operations and memory estimates are immutable.
- Public `PreparedJob` exposes only read-only description/id; construction stays internal to the engine.
- `OutputTransaction.init(destination: URL, source: URL, jobID: UUID) throws`; `temporaryURL: URL`; `commit() throws`, `abort()`; abort is idempotent and touches only the owned partial.

- [ ] Add planner tests for supported path, geometry calculation, insufficient budget, unsupported capability, source/destination identity collision, and digest reproducibility. Invalid plans create no output or temporary file.
- [ ] Implement input identity/metadata fingerprinting and native path validation. Exclusively create a unique private job directory (mode 0700) within the destination directory. Pass its absent `media.mov` path to the writer. Final no-replace publication moves that file to the destination on the same filesystem; cleanup removes only the owned directory.
- [ ] Add transaction tests: existing destination preserved byte-for-byte; hardlink/symlink source aliases rejected; destination appearing immediately before commit preserved; cancellation removes only this job's temporary data; foreign partial file untouched; final rename failure leaves source/destination intact.
- [ ] Implement no-replace atomic publication with the macOS primitive and explicit errno mapping. Do not use an ordinary overwriting rename after an existence check.
- [ ] Run `./Scripts/test.sh --filter 'MediaPlannerTests|OutputTransactionTests'`; include paths containing spaces and non-ASCII characters.

### Task 9: End-to-end engine and cancellation

**Files:** create `MediaEngine.swift`, `JobRunner.swift`, `Tests/PXLmpegTests/MediaEngineTests.swift`, `Tests/PXLmpegTests/NativePipelineTests.swift`, `Tests/Support/PipelineBackendFake.swift`.

**Interfaces:** implement all `MediaEngine` signatures from spec section 9. Progress is a latest-value snapshot, not an unbounded event queue. `execute` returns a success receipt or throws a `MediaError` carrying a terminal failure/cancellation receipt. The engine retains the latest terminal receipt until the next job; it keeps no unbounded job history.

- [ ] Add failing controlled-pipeline tests for the lifecycle, engineBusy, stalled writer, late codec/GPU callbacks, source changed after prepare, malformed sample midstream, and cancellation in each active stage. Assert exactly one terminal result, bounded counters, and no published output on failure/cancel.
- [ ] Connect the real reader→decoder→scaler→encoder→writer path with the separate audio-copy branch. Use one backend coordination queue and bounded completion mailboxes; actor methods issue commands rather than doing blocking I/O. Process each track fairly so writer readiness on one track cannot starve the other.
- [ ] Recheck prepared fingerprints before execution and after finalization; revalidate hardware sessions at execution time. A previously successful prepare does not guarantee hardware remains available.
- [ ] Implement a configurable execution watchdog with a default 60-second no-progress interval, measured from backend completion or writer progress. It stops admission and reports noProgress; it must not forcibly free buffers still used by the OS. Cancel requests acknowledge promptly; final teardown waits for in-flight native work. Test watchdog logic with an injected clock rather than waiting a minute.
- [ ] Drain codecs and GPU work, finish the writer, inspect output, then commit atomically. Handle cancellation arriving during commit using a single serialized terminal decision: either publication wins and returns completed, or cancellation wins and no destination is published.
- [ ] Run `./Scripts/test.sh --filter 'MediaEngineTests|NativePipelineTests'`. A 10-second native fixture must retain exact supported presentation timing/frame count, pass audio-copy checks, respect owned-memory limits, and return verified hardware flags. Repeat cancellation 100 times with deterministic injected delay schedules; record residual leases and partial files (both zero after drain).

### Task 10: CLI, dependency audit, and measured acceptance

**Files:** create three `Sources/pxlmpeg/*.swift` files, `Tests/PXLmpegCLITests/CommandLineTests.swift`, `Tests/PXLmpegCLITests/CLIAcceptanceTests.swift`, `Scripts/verify-dependencies.sh`, `Scripts/acceptance.sh`, `docs/validation/m1-native-pipeline.md`; update README with actual commands and limitations.

**Interfaces:** `CommandLine.parse(_ arguments: [String]) throws -> Command`; fixed grammar from spec section 9. `JSONEventWriter.emit(_ event: JobEvent) throws` writes one JSON object per line; `JobEvent` holds schemaVersion, jobID, type, payload. Version/capability output identifies the exact build.

- [ ] Add parser tests for all four commands, missing/unknown arguments, invalid JSON, Unicode/spaced paths, stdin/stdout expectations, and documented exit codes. No implicit shell interpolation or support for arbitrary commands.
- [ ] Implement a small parser with Foundation/Swift. Poll the latest progress snapshot at most 4 Hz. Bound the stdout transport; coalesce progress under a slow consumer, and treat a broken pipe as cancellation while preserving cleanup. Reserve the terminal event and emit it once when output remains writable. SIGINT requests cancellation through a safe signal bridge.
- [ ] Make dependency audit assert zero external package dependencies/binary targets and inspect the runtime closure. Review first-party source provenance as well as linked libraries. Validate the installed-layout CLI with its resource bundle from an unrelated directory and without network access.
- [ ] Run `./Scripts/test.sh`, `./Scripts/build.sh --configuration release`, `./Scripts/verify-dependencies.sh`, and `./Scripts/acceptance.sh`. In acceptance, missing GPU/VT support is a failed readiness gate, not a passing skip.
- [ ] Benchmark deterministic 1080p and 4K fixtures with unchanged size and 4K→1080p reduction. Warm up once, measure five runs, record median/range, quality/timing checks, settings, hardware flags, owned-buffer peak, process footprint, and thermal/power context. Compare a 10-second and 120-second fixture to detect accumulation with duration; investigate sustained footprint growth beyond codec/cache warm-up.
- [ ] Write the evidence report distinguishing fake/unit/GPU/codec/full-pipeline coverage. Optional FFmpeg comparison is developer-only and must disclose encoder/filter differences. Do not add it as a build dependency.
- [ ] Update README to say M1 proof complete only when evidence supports it. Keep macOS 15 validation and M2 application readiness explicitly unverified until exercised on their required boundaries.

## M1 completion checklist

- [ ] Supported recipe executes through actual hardware VT sessions and our Metal kernels.
- [ ] Model, numerical GPU, native media, lifetime, output-safety, and CLI tests pass.
- [ ] Owned-memory limits and slow-consumer behavior are evidenced; total RSS is separately reported.
- [ ] Audio payload and timeline checks pass on the accepted fixture subset.
- [ ] Unsupported input fails explicitly and leaves original media intact.
- [ ] No required external runtime/package/source dependency was introduced.
- [ ] CLI/resource relocation works; receipts report actual settings and hardware use.
- [ ] Limitations remain visible; no application workflow has been silently switched to this proof.

## Roadmap and next decisions

### M2 — application-ready media

Write a separate detailed plan after M1 measurements. The key prerequisite is bounded presentation-order handling for real H.264/HEVC B-frame streams, with a codec-supported reorder bound and failure behavior. Also cover orientation baking, broader SDR colour/range/chroma mappings, VFR and discontinuities, AAC priming/edit lists, supported trim/concatenation semantics, and MP4 muxing. Extend hardware capability probes per codec/profile/bit depth; names such as M1/M2/M3 are not a codec capability database.

Acceptance: an explicitly selected ALi source corpus, a synthetic adversarial corpus, and actual minimum/current macOS machines. Only then prepare an additive ALi adapter in its owning repository. Preserve the current production path until audiovisual review accepts representative outputs.

### M3 — compositing and offline audio

Design linear-light image composition with an explicit alpha/colour contract, and a separate PCM/DSP pipeline with sample-accurate timing and declared processor latency. Add text/layout only through a justified system-framework boundary. Tests cover compositing references, frequency/impulse response, resampling alias rejection, channel layout, clipping, and output alignment. Add Pixel Music integration after its required operations exist.

### M4 — high-fidelity formats

Add capability-gated ProRes, 10-bit surfaces, HDR metadata, and explicit tone mapping. Validate on actual supported hardware and an appropriate viewing path. SDR output correctness is not evidence of HDR correctness.

### M5 — optional AI stage

Choose one real host-requested operation before specifying a model-node API. Define image/PCM/tensor layout, lookahead/history, time mapping, memory reservation, cancellation, model identity, and output quality evaluation. Keep model/runtime dependency ownership outside the core. AI-generated plans undergo the same deterministic validation as hand-authored plans.

## Execution status — 2026-10-13

The first native pipeline, package, CLI, original kernels, hardware checks, owned-budget accounting, safe publication, cancellation, and benchmark driver are implemented. See [measured validation](../../validation/m1-native-pipeline.md) and `.work/progress.md` for evidence and deviations. The original detailed checkboxes above are retained as the full acceptance backlog, not a claim that every planned adversarial case ran.

Execution deliberately uses one synchronous frame in flight on a dedicated worker and a per-frame encoder drain. The requested MaxFrameDelayCount property is unsupported by this machine's encoder, so explicit draining provides the bound. Asynchronous reorder/fake-callback stress is deferred with asynchronous admission. The CLI target is `PXLmpegCLI` to avoid a case-insensitive module-path collision with `PXLmpeg`. Resource lookup checks installed bundle locations without invoking SwiftPM's fatal missing-bundle accessor.

Native pipeline delivery is working. Full M1 hardening remains open for the unexercised adversarial matrix: VFR/nonzero starts/priming, stage-specific fault injection, repeated cancellation/lease schedules, minimum-OS testing, and broader input rejection fixtures. M2 application readiness and integration are not claimed.


### Subsequent scoped increments — 2026-10-13

B-frame, HEVC/quarter-turn rotation and Main10/HDR work were explicitly requested and implemented in their separate plans. See `docs/validation/bframes.md`, `hevc-rotation.md`, and `hdr.md` for bounded evidence. This advances selected M2/M3 format capabilities; it does not close the entire M2 application/API matrix, general timing/priming work, HDR viewing approval or macOS15 hardware validation. Pixel Deck fit was assessed read-only; no consumer was integrated.
