# Native interactive playback checkpoint — 13 October 2026

Backend: optional first-party `PXLPlayback`, AVPlayer and direct AppKit AVPlayerLayer. It is independent of processing jobs and does not pull a model runtime into the core.

## Behavior

`@MainActor PlaybackSession` supplies local open, play/pause, zero-tolerance native seek, volume/mute, replacement and close. Snapshots carry state, source descriptor, native position/duration, requested playback intent and backend identity. Notifications suppress unchanged values and defer nested changes to avoid recursive host callbacks.

Native metadata admission uses the existing tagged H.264/HEVC MOV/MP4 subset, Main10/HDR and display rotation. Known untagged ALi SDR clips require explicit `assumeBT709Limited`. Playback reads the original and does not discard camera timed metadata. Host security-scoped access must cover the session lifetime.

Open/seek have 15-second logical deadlines. Task cancellation, newer operations and close invalidate older completions. Native metadata cancellation remains advisory; this is not a hard deadline for an underlying OS call. Native seek accuracy is limited by sample timing. End-of-file replay uses an explicit seek to zero. `pxl-player` demonstrates open, timeline, play/pause/replay, volume and mute.

## Checks on the current Mac

Apple M3 Ultra, macOS 27.0.1, Swift 6.4 / Xcode 27. Declared deployment floor remains macOS 15, not independently tested on that OS.

The full suite passed **73 tests, zero failures**, including nine native playback tests. Release build, local app bundle/Info.plist/ad hoc signature verification and the CLI/player system-only dependency audit passed. See the [test log](2026-10-13-playback-tests.log) and [dependency audit](2026-10-13-playback-dependencies.log).

Playback tests cover:

- H.264/AAC with B-frames, actual native time advancement, pause stability, forward/backward seek and independently obtained decoded frames via AVPlayerItemVideoOutput.
- HEVC Main10 HLG, rotation metadata admission, end/replay, direct surface layout.
- Audio longer than video using the native item duration; explicit colour interpretation for untagged SDR.
- Open replacement/close, pre-cancelled tasks and cancellation from state observers.
- Latest-seek wins while playing; pause during seek stays paused.
- Observer close during seek completion, and repeated pause/close callbacks without recursive notifications.
- Supplied iPhone original: open, seek, actual decoded frame delivery, pause, back-seek and close. Original SHA-256 remained `869d328924d5a3df27163822c0f69c104e900c9c2ae102face9906a8ca11ccc6`.

The camera test is optional in public checkouts: set `PXL_PLAYBACK_SOURCE` to a supported local file. Without it, that one test is explicitly skipped. Local working logs remain excluded from publication.

## Limits of this evidence

Native decoded frames and session tests establish functional media delivery, not subjective playback quality. The Mac demo builds but has not been manually auditioned for audio or approved on an HDR reference display. No Sirius or Pixel Deck source was changed and their reported player crash was not reproduced or fixed here.

AVPlayer owns codec selection, decoded queues, audio synchronization, colour presentation and opaque system memory. Playback does not expose the transcode pipeline's required-hardware flags, owned-allocation budget, custom Metal rendering, PCM buffers, frame leases, DeckLink support or frame stepping. The native view avoids SwiftUI VideoPlayer but does not establish that an unrelated host application's crash is resolved.

Semantic people/object/action indexing with Neural Engine acceleration is [research design](../architecture/semantic-analysis.md), not implemented functionality. No model has been downloaded or bundled.
