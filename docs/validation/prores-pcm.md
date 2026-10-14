# ProRes MOV + PCM native ingest — first research slice

Date: 2026-10-14. Research branch only; not a production Pixel Deck integration or ProRes export claim.

## Public boundary

`PXLProfessionalMedia` is a separate Swift library. It does not broaden `MediaEngine.inspect`, transcode/remux, search admission or the NV12/P010 Metal transform recipe. It uses only Apple system frameworks and the existing internal media/error/budget types.

- Local MOV with one progressive ProRes Proxy/LT/422/HQ video track, even 16–4096 dimensions, square pixels, full clean aperture and proper quarter-turn orientation. Tagged BT.709 or BT.2020 HLG/PQ is required; no colour assumption is made.
- Native VideoToolbox decode delivers retained `x422` CVPixelBuffers: ten-bit, video range, two full-height 16-bit planes, 4:2:2. Plane 0 is W × H; interleaved UV plane is W/2 × H. The source is not routed through 4:2:0 or converted to a display RGB image. Rotation remains metadata for the consumer.
- Optional one mono/stereo 48 kHz PCM track: signed integer 16/24/32 or float32 input, standard mono/stereo layout when explicitly tagged. Delivered audio is interleaved little-endian float32, with at most 8192 frames per chunk and no sample-rate conversion or channel remix. Unknown/custom multichannel layouts and other audio codecs reject.
- Source presentation timestamps and durations remain rational. Source edit gaps may be represented as correctly timed PCM silence by the native reader. Audio/video offsets are independent. Container timecode tracks may accompany read-only sources; SMPTE values are not extracted.
- Hardware decode is required by default. Explicit `.allowSoftware` permits native fallback, with actual `decoderHardware` reported. Merely opening ProRes never establishes acceleration.

```swift
import PXLMedia
import PXLProfessionalMedia

let session = try await ProfessionalMediaSession.open(sourceURL)
let info = session.descriptor
if let frame = try await session.nextVideoFrame() {
  // Retain frame through GPU/renderer completion, and treat its pixels as read-only.
  // Use frame.pixelBuffer, presentationTime, duration and generation.
}
if let audio = try await session.nextAudioChunk(maximumFrames: 1024) {
  // Retain audio while using its interleaved Float32 samples.
}
let generation = try await session.seek(to: MediaTime(value: 10001, timescale: 48000))
// Flush the host's queued picture/sound and discard older generations.
// Check session.isCurrent(generation:) before presenting a retained result.
await session.close()
```

The host owns the playback clock, monitoring/LUT transform, rendering, audio devices, external output and access permissions. `seek` chooses the first video sample whose PTS is at/after the request, and the first audio sample at/after the request; it does not promise a frame exists at every arbitrary time. This is a pull ingest API, not an AVPlayer wrapper or complete playback scheduler.

## Ownership, transport and limits

One serial worker owns mutable readers/decoder state. Generation assignment and operation enqueueing are atomic; at most eight native operations may be pending. A successful seek restarts both readers. Already-retained old leases stay valid as memory, but their generation is stale. A failed admission caused by resource pressure does not advance the working generation. Source identity, size and modification time are checked at open and reads; this is not a full content hash on every frame.

Default owned budget: 128 MiB and two retained video frames. Open rejects a configured budget smaller than one source-sized frame, the packet reservation and (if present) one pending/delivered PCM chunk; impossible configurations fail before decoder setup. Frame storage, a conservative compressed-packet reservation and pending/delivered PCM are accounted across seek and close. Reservation failure occurs before consuming another sample. The packet limit is 32 MiB; a pending converted PCM buffer is capped at 1 MiB. No prefetch occurs. Returned leases retain reservations until deallocation, including after closing the session. Retaining only a raw CVPixelBuffer or copying Data while dropping its wrapper transfers memory accounting responsibility to the consumer; the engine cannot bound consumer copies or opaque Apple allocations.

`cancel()` fences further delivery immediately. Cancelling a Swift read task cancels the entire session; create a new session to resume. Close drains queue-owned resources and is idempotent. Native cancellation is cooperative at call boundaries and cannot preempt an OS/driver stall. The earlier whole-Mac search incident remains unresolved; this small codec probe is not a general system-stability certificate.

## Real source evidence

The user supplied a short real ALi production render: 1920 × 1088, 24 fps, ProRes 422 HQ (`apch`), Rec.709, 24-bit stereo PCM at 48 kHz. Private paths, media and logs remain outside Git. The original was read only; SHA-256 before/after matched.

On M3 Ultra / macOS 27.0.1, the first bounded release probe read all **49 video frames** and **98,000 PCM sample frames** to EOF. Their last presentation ends both equal **49/24 seconds**. VideoToolbox's actual hardware property was **true**, and output was **x422**.

Initial measurements: open about **130 ms**, first frame after open **2.8 ms**, 49-frame pull about **29.9 ms**, three seek + video/audio reads **4.0–5.0 ms**. These are single short-clip measurements, including API/queue overhead; not sustained real-time playback, display latency or a cross-device benchmark. The conservative owned reservation peak was **41,975,808 bytes**; sampled process footprint peaked near **126 MB**, including native internals. Sampling can miss transient peaks.

## Reproduce the bounded probe

```sh
./Scripts/build.sh -c release
./.build/release/pxl-prores probe /absolute/path/clip.mov
# An explicit cap for video; independent audio validation is capped at 30 seconds:
./.build/release/pxl-prores probe /absolute/path/clip.mov --max-frames 120
# Explicitly permit a software backend, without hiding the measured hardware flag:
./.build/release/pxl-prores probe /absolute/path/clip.mov --allow-software
```

The JSON receipt includes source hash, unchanged status, native descriptor, video/audio EOF and counts, source/end timestamps, actual pixel format/hardware, open/first-frame/read/seek timings, owned-memory metrics and sampled process footprint. It produces no media or rendered preview. `maximumFrames` caps probe work, not the library's source duration.

## Verification result

Final project command `./Scripts/test.sh`: **127 executed, 112 passed, 15 skipped, 0 failures**, including **15 professional ingest/admission tests**. Model-dependent cases remain skipped and no inference was performed. Release build, Swift format checks, CLI invalid-cap rejection and five-product runtime/package dependency audit passed. Independent static review found no remaining Critical/Important findings; its two Minor admission mismatches were reproduced and corrected with failing/passing tests.

Generated ProRes Proxy, LT, 422 and HQ fixtures all delivered hardware-decoded x422 frames on the test Mac. Additional checks cover full-height chroma, retained lower ten-bit luma precision, PCM values/channel order and chunk continuity, native timeline silence/delayed content, video edit offsets, concurrent seeks, EOF/restart, resource retry without sample loss, invalid seek/cancel/close, source changes, rejected unsigned PCM/custom layouts and impossible-budget rejection before decoder setup. Native PCM fixtures and real footage use signed **24-bit stereo**; mono and other admitted PCM precisions have not yet had direct fixture/runtime validation. HDR metadata admission is not reference-display approval.

The final rebuilt probe repeated the real-source result: 49 video frames, 98,000 audio frames, x422, actual hardware true, matching end times and unchanged hash. Its open was about 144 ms, first frame 2.9 ms and video pull 30.4 ms; sampled process footprint was about 128 MB. Both receipts and the verification boundary are preserved in [sanitized evidence](2026-10-14-prores-pcm.json). No private media/path is included.

## Pixel Deck adoption boundary

This supplies the buffer/audio shape its current compatibility engine consumes. Pixel Deck still needs an explicit adapter that retains video leases through Metal/DeckLink completion, preserves channel identity, coordinates both pull streams against its clock, flushes output on generation changes and routes unsupported sources to its existing compatibility backend. No Pixel Deck source or installed app was changed by this slice.

PXLmpeg's macOS 15 deployment floor and Pixel Deck's macOS 14 declaration must be resolved before adoption. Native ProRes encoding/export, 4444/XQ alpha, RAW, MXF/XAVC, multitrack/multichannel sound, resampling, production timecode, wider geometry and sustained long-clip transport are outside this slice. HDR metadata admission does not establish calibrated HDR monitoring approval.

## References

- [First implementation boundary and professional roadmap](../architecture/pixel-deck-engine-roadmap.md).
- Apple: [Decode ProRes with AVFoundation and VideoToolbox](https://developer.apple.com/videos/play/wwdc2020/10090/).
- Apple: [AVAssetReaderTrackOutput](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput).

## Subsequent consumer acceptance

The original measurements above remain ingest-only. A later separate Pixel Deck research build exercised the real Metal renderer and Core Audio clock; see [consumer integration and verification](../integrations/pixel-deck-playback.md). Decoder creation now classifies only missing/not-currently-available decoder statuses as hardware unavailable, enabling explicit consumer fallback while retaining corrupt-data errors.
