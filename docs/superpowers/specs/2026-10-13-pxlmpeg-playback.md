# Interactive playback, first native backend

Status: implementation scope selected from the request to work on interactive playback.

Provide an optional first-party `PXLPlayback` Swift library and `pxl-player` AppKit demo. A main-actor `PlaybackSession` owns one local media item, an observable snapshot, play/pause, bounded asynchronous opening/seeking, volume/mute and explicit close. `PlaybackView` presents an AVPlayerLayer directly, without SwiftUI VideoPlayer. Replacement, cancellation and close invalidate old asynchronous work; older seek completions cannot change a newer session. UI callbacks must allow safe reentrant controls.

Reuse existing strict H.264/HEVC MOV/MP4 metadata admission, including Main10, orientation and tagged colour. Accept an explicit missing-colour interpretation for ALi clips. Playback does not rewrite the file or discard tracks. The host keeps security-scoped access alive, owns window/UI/cache state, and calls close when the attachment goes away.

Backend is explicitly AVPlayer. Apple owns decoded queues, audio synchronization, colour presentation and codec choice. This module does not claim the transcode worker's required-hardware enforcement, owned-memory budget or Metal kernels. No custom PCM clock, bounded frame leases, DeckLink output, speed controls, frame stepping or HDR reference-display approval in this milestone. Zero third-party dependencies; macOS 15 declared floor, validated on the current Mac only.

## Acceptance

Native generated media exercises ready/play/time advancement/pause, forward/backward seek, end/replay, close/reopen, concurrent replacement, task cancellation, invalid media and seek range validation. Verify decoded video delivery using AVPlayerItemVideoOutput in developer tests, independently of session labels. Cover HEVC/Main10/rotation and the supplied iPhone original read-only. Build the demo and verify its surface layout; physical display colour and audio listening remain distinct unperformed checks.

## AI analysis boundary

A future optional analyzer receives timestamped display-oriented frames and emits versioned observations. User priority is semantic search for people, objects and actions. Timestamped descriptions and embeddings require a host-selected visual/temporal model; OCR is an optional separate analyzer, not scene/action understanding. Model observations remain uncertain evidence, not verified facts. Sample frames under explicit budgets, retain actual sample timestamps, normalized boxes and confidence, deduplicate observations into spans while recording sampling gaps. Write a new sidecar, never modify an original. Record source identity, analyzer version/configuration and provenance; exact source-hash policy and observation schema will be selected with the first analyzer implementation.

PXLmpeg owns media access and observations. Pixel Deck owns catalog storage, search UI and user decisions. Semantic models remain optional adapters; no model runtime, download or database is mandatory for the core. Measure OCR latency, recall, cancellation, memory and competition with playback on real footage before promising throughput. HDR/10-bit preprocessing and orientation need explicit validation.

User requirement: prioritize Apple Neural Engine inference. Select an ANE-compatible Core ML model, initially evaluate CPU + Neural Engine configuration to avoid competing with playback on the GPU, and profile cold/warm latency and operation placement. This permits CPU execution; neither Core ML compute-unit selection nor a compute plan proves exclusive ANE execution. A compute plan reports supported/preferred devices, while runtime Instruments/Xcode traces establish measured utilization. Model architecture, conversion, weights license, temporal context and quality need evaluation before selection. No mandatory third-party runtime in the media core.
