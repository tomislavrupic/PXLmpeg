# Sirius inline-video integration boundary

PXLmpeg can now prepare supported media for an inline AVKit player through its public Swift API or CLI. No Sirius source changes, installation, running-app restart or player-crash fix were performed in this repository.

## Available contract

1. Host resolves a local source URL, security-scoped access and an owned new cache destination.
2. `MediaEngine.inspect(source)` returns actual codec, dimensions, orientation, bit depth, colour/HDR signalling and extra-track count. Unsupported sources fail explicitly.
3. If the host player supports the original codec/profile and only needs a compatible container, submit `RemuxRequest` for MP4. This copies compressed samples, preserves the display transform and does not initialize codecs or GPU. Remux does not lower resolution, reduce bitrate or repair unsupported media.
4. For a smaller derivative, submit `JobRequest` with explicit output container, codec, resize width, bitrate and colour/timed-metadata policies. The native hardware/Metal pipeline creates a new MOV/MP4. Main10 requires HEVC; HDR-to-SDR tone mapping does not exist.
5. Keep one `MediaEngine` per independently scheduled job slot, consume coalesced `progress(for:)`, and call `cancel(id)` when a preview is superseded. Cancellation stops admission and waits for safe teardown. A completed receipt means the new file was finalized, checked and published without replacing an existing destination.
6. Only after completion does the host attach the new URL to chat and hand it to its native AVKit view. The host owns view lifetime, main-thread behavior, playback controls, access lifetimes, cache eviction and chat attachment state.

```swift
import PXLMedia
import PXLmpeg

let engine = MediaEngine(configuration: try EngineConfiguration())
let request = try RemuxRequest(
    source: sourceURL, destination: newPreviewURL,
    outputContainer: .mp4, audioPolicy: .copy,
    timedMetadataPolicy: .discard)
let plan = try await engine.prepare(request)
let receipt = try await engine.execute(plan)
// Publish the newPreviewURL to the host attachment/player only after completion.
```

`timedMetadataPolicy=.discard` must be a deliberate host policy. It drops camera timed-metadata tracks, not video HDR colour/ambient metadata. Original files stay untouched. Requests with missing colour tags require an explicit supported transcode interpretation; remux currently admits the tagged native subset only.

## Optional native playback

The optional `PXLPlayback` library now provides `@MainActor PlaybackSession` and an AppKit `PlaybackView` backed directly by AVPlayerLayer. Hosts can open completed supported local files, play/pause, seek, set volume/mute and close. `onChange` supplies coalesced main-actor snapshots. New opens and seeks invalidate older logical operations; replacing or closing a session prevents stale completions from changing its state. Cancelled/superseded operations throw `CancellationError`. Open and seek have a 15-second logical deadline; underlying native cancellation is advisory, not a hard OS teardown guarantee.

Use one retained session per active attachment surface, retain security-scoped access for its lifetime, and call `close()` when the attachment is removed or reused. Construct `PlaybackView(session:)` on the main actor. After `.ended`, explicitly seek to zero before replay. `open(_:colourPolicy:)` accepts a deliberate missing-colour interpretation for known ALi SDR clips; the default remains strict. Playback neither copies nor discards timed metadata tracks.

This first backend uses **AVPlayer** for decoding, clock/audio synchronization, buffers and native colour presentation. It does not promise required hardware decoding, bounded decoded-frame memory, custom Metal playback, PCM/audio-clock access, frame stepping or pull-frame leases. A future custom playback worker will need generation-safe frame leases and explicit PCM/clock policy. HDR source recognition and decoded output are not reference-display approval. No authenticated Mac endpoint or thumbnail API is exposed.
Authenticated transport, reconnect, project storage, chat state and generation remain host responsibilities. No network listener, account credentials or model runtime belongs in the processing core.

The supplied Sirius screenshot reports a SwiftUI player-view bridge crash. It is context for the intended workflow, not a verified crash diagnosis in this repository. Producing a valid media file does not establish that a host view, HDR display path or playback session is stable; integration requires an actual open/play/seek/close/cancel test in the owning app.
