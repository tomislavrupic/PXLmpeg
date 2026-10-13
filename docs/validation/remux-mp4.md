# Native remux and MP4 validation — 2026-10-13

PXLmpeg **0.5.0-remux-mp4** adds native MP4 transcoding output and compressed H.264/HEVC/AAC copying between MOV and MP4. This is a useful native subset for compatible preview files, not complete FFmpeg parity or a playback view/session.

## Verified boundaries

- **64 tests passed** on M3 Ultra/macOS27.0.1/Xcode27/Swift6.4. New native tests cover H.264/Main10 HLG MP4 output and fast-start box order, extension/container validation and legacy MOV defaults, B-frame/VFR/nonzero-start MOV→MP4→MOV copying, encoded payload/PTS/duration/sync identity, decode-clock spacing, AAC samples/trim/format, decoded plane hashes, exact transforms, HDR metadata, audio drop, source changes, engine identity and active cancellation.
- **11 release source cases, 22 remux jobs passed**: ten generated combinations of H.264, HEVC Main8, Main10 SDR/HLG/PQ and 0/90° transforms, variable frame durations, nonzero starts and shorter/longer AAC; plus a genuine 4K iPhone HLG/Dolby8.4 original with 91 frames and a 180° transform. All source SHA256 checks matched.
- Every compressed video access-unit hash, PTS, duration and sync flag matched. DTS order and spacing matched after an explicitly allowed constant clock shift. Every decoded plane and frame timing matched independent AVFoundation decoding. Raw display matrices and supplied HDR/static/ambient metadata matched.
- AAC access units were normalized across container sample-buffer regrouping. Payload hashes, raw per-sample timing, trim/priming fields, rendered span and codec configuration/channel layout matched. Container-only labels were ignored using CoreMedia's documented comparison API; codec/sample-description atoms were retained in the comparison.
- Relocated release CLI ran offline from `/tmp` with **no Metal resource bundle**. `plan-remux`, `remux` and `inspect` succeeded. The remux worker creates no VT sessions or GPU objects; receipts correctly show hardware flags false, empty metalDevice and no bitrate claim.
- Genuine iPhone round-trip preserved 3840×2160 Main10 HLG, its 180° transform, ambient metadata, Dolby configuration/RPU signalling and 91 encoded pictures. Five camera timed-metadata tracks were explicitly discarded. Each copy used a measured owned compressed-buffer peak of 645,950 bytes. Opaque mux/driver allocations are excluded; these functional runs are not a repeated benchmark.
- Dependency audit: zero external Swift packages/binary targets; runtime closure is Apple system frameworks and Swift libraries.

[Release results](2026-10-13-remux.json), [tests](2026-10-13-remux-tests.log), [dependency audit](2026-10-13-remux-dependencies.log). Generated media and raw local evidence stay in ignored `Artifacts/remux.*` / `.work/remux/`; regenerate with `Scripts/acceptance-remux.sh /absolute/path/to/iphone-original.MOV`. Public evidence paths are redacted; original source footage is never included.

## Contract and implementation

`OutputContainer` selects MOV or MP4, with a backward-compatible MOV default for `JobRequest`. File extension must match the selected container. `AVAssetWriter` emits the selected native file type; MP4 network optimization places `moov` before `mdat`.

Separate `RemuxRequest`/`PreparedRemux` types omit codec, bitrate and pixel-processing options. They accept the currently admitted tagged H.264/HEVC Main/Main10 4:2:0 family and optional supported AAC. Remux copies compressed samples in decode order, retains exact source transform/timebase/colour/HDR metadata, and initializes no decoder, GPU or encoder. It cannot make an unsupported codec/profile playable, reduce file size through compression, bake rotation, or invent missing colour tags. Explicit `audioPolicy=drop` is supported.

The existing actor's cancellation, one-job admission, fingerprint checks, watchdog and atomic publication are shared by both operations through an immutable internal execution description. Remux holds one pending compressed buffer per input, with existing 8MiB packet/32MiB queue admission limits and a 64MiB default owned budget. Its plan reserves a 16MiB maximum two-packet working set, rather than decoded frames.

The private output filename follows the selected container; descriptor-relative no-replace commit and cleanup work for both types. A new active-cancel test exposed AVAssetWriter's safe-save scratch (`media.mp4.sb-*`) surviving cancellation briefly. Workers now explicitly cancel the writer before aborting the output transaction. Cleanup removes only regular writer-owned scratch names inside the reserved directory and leaves unknown entries/symlinks untouched. Native cancellation and preservation tests pass.

## Decode clock ruling

For a tested H.264 empty-edit/nonzero-start pattern, source output DTS starts at 0.125s while remux output DTS starts at 0s. Encoded bytes, presentation times, durations, relative decode spacing and all decoded pictures remain identical. Materializing mapped PTS/DTS into new sample timing does not prevent Apple's muxer rebasing the decode clock.

This is permitted constant rebasing, **not exact DTS identity**. The receipt's `firstVideoDecodeTimeOffset` reports the measured first-packet offset. Release validation checks the same offset at every video packet. Production verification remains lightweight (metadata and first packet), not a complete second pass over compressed samples. Arbitrary edit lists, discontinuities and trim/preroll behavior are not established by these fixtures.

## Review and consumer scope

Independent read-only review identified the initial cancellation-test gap and exact-transform verification gap. Both were corrected; active cancellation exposed and drove the scratch cleanup fix. Follow-up review cleared lifecycle order, descriptor confinement, pointer lifetime and format comparison. The minor diagnostic wording was corrected.

[Sirius integration contract](../integrations/sirius-preview.md): supported local source → inspect → remux or transcode to a new compatible MP4 → completed receipt → host AVKit player. The host owns chat attachments, views, security scope, cache, authenticated transport and reconnect. No Sirius or Pixel Deck source was modified, and no host crash fix or playback stability is claimed.

Next capabilities remain thumbnails/frame extraction, a bounded seek/flush/PCM playback API, precise trim/concatenation, broader formats and explicit HDR tone mapping. Minimum macOS15 runtime, other hardware, calibrated HDR output and per-frame RPU/Dolby certification remain unverified.
