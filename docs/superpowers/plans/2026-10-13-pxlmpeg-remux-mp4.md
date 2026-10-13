# Native MP4 and Remux Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one independent final review. Work remains local and unversioned under the parent ownership rules.

**Goal:** Add native MOV/MP4 output and compressed-video/AAC stream copying for supported media, useful for Sirius inline preview preparation and Pixel Deck compatible copies.

**Architecture:** `OutputContainer` extends the existing transcode request with a backward-compatible MOV default. Separate `RemuxRequest`/`PreparedRemux` types expose no resize/bitrate options. Both operations share the actor's lifecycle, cancellation, source checks and atomic output transaction; a dedicated remux worker feeds compressed samples directly to AVAssetWriter. No decoder, GPU or encoder is created for remux. Container selection controls file type, private file extension and MP4 fast-start layout.

**Tech Stack:** Swift6, AVFoundation/CoreMedia, existing first-party budget/transaction helpers. No third-party runtime, package, source or subprocess media execution.

**Spec:** Existing architecture sections 2–7,9–12 and M2 output milestone; user authorized continued FFmpeg-replacement development and clarified Sirius inline previews as a target. This is media preparation, not a host-player crash fix or full playback API.

## Global constraints

- Apple Silicon/macOS15 declared floor, tested machine M3 Ultra/macOS27 only.
- Preserve source footage; explicit new destination; no overwriting or Git initialization.
- Existing transcode JSON remains schema1/MOV default; unknown fields and schema fail.
- Remux uses the currently admitted tagged H.264/HEVC Main/Main10 4:2:0 family, MOV/MP4 input, optional supported AAC. No invented colour tags or expanded codec promises.
- Timed metadata requires explicit discard; no resizing, bitrate changes or orientation baking in remux. Original coded dimensions, transform, compressed payloads, sample timing and HDR signalling are retained.
- Owned media remains bounded; per-job receipt distinguishes compressed copy from hardware transcode. MP4 optimizes for network use (moov before mdat).
- Sirius/Pixel Deck source, running apps and production player state remain untouched. Authenticated endpoint/reconnect and app UI are host responsibilities.

## Review focus

1. B-frame PTS/durations and decode order/spacing survive stream copy; permitted constant decode-clock rebasing is measured and reported.
2. AAC access-unit payloads/timing/priming survive buffer regrouping.
3. HDR/RPU and display transforms are preserved without decoding or stale metadata regeneration.
4. MP4 atomic collision/cancellation/source-change handling matches MOV; extension/type mismatches fail.
5. Remux bypasses hardware initialization and false hardware claims, including relocated CLI without Metal resources.

## Tasks

### 1. MP4 transcode output

Files: PXLMedia/JobRequest.swift + OutputContainer.swift; PXLmpeg/OutputTransaction.swift,MediaPlanner.swift,JobRunner.swift; PXLAppleMedia/ContainerWriter.swift; tests/ContainerOutputTests.swift.

- [x] RED: native H.264 and Main10 HLG requests with outputContainer=mp4 produce valid MP4, unchanged timing/audio/colour, moov before mdat; legacy defaults MOV; container/extension mismatch rejects.
- [x] Extend request Codable with `OutputContainer` (.mov/.mp4), default MOV. OutputTransaction accepts explicit container, uses matching private filename for no-replace commit/cleanup. Writer selects native AVFileType and network optimization. Existing callers default MOV.
- [x] GREEN: focused native output/transaction/schema tests.

### 2. Compressed stream-copy API and worker

Files: PXLMedia/RemuxRequest.swift; PXLmpeg/PreparedRemux.swift,ExecutionJob.swift,RemuxRunner.swift,MediaEngine.swift; inspector stores original transform; receipt operation/container fields.

- [x] RED: generated B-frame H.264/HEVC Main10 rotated files remux MOV→MP4→MOV; every encoded video payload/PTS/duration and decode order/spacing (a visible constant muxer DTS offset is permitted), audio access unit/timing/trim/format, coded dimensions/transform/HDR metadata and decoded pictures match. Explicit audio drop works.
- [x] Public `prepare(RemuxRequest) -> PreparedRemux` and `execute(PreparedRemux) -> JobReceipt`; keep existing API. Shared internal execution description reuses actor state/verification. Packet-only plan budget; worker confined to dedicated serial queue, one buffered packet per input, services mux readiness across tracks.
- [x] Test source changes, destination races, cancellation and wrong engine identity without publishing partial files. No codec/GPU hardware flags or bitrate claims for remux.
- [x] GREEN: focused remux and full suite.

### 3. CLI, real footage and consumer contract

Files: CLI parser/entrypoint; test helpers; Tools/PXLValidation/Remux.swift; Scripts/acceptance-remux.sh; README and validation report.

- [x] RED: `plan-remux REQUEST.json` and `remux REQUEST.json` parse, bound request size, reject transcode-only fields, emit one terminal receipt and preserve cancellation semantics.
- [x] Add CLI using same actor/public API and progress path. Plan output describes actual operation/container; fix stale help version.
- [x] Release corpus: generated codecs/rotations/VFR/offsets/audio durations; genuine IMG_6703.MOV read-only with explicit timed-metadata discard; native MP4 transcode; sample/hash/timing/HDR/source SHA verification. Relocated offline remux works with CLI alone, no Metal bundle; transcode still needs bundled kernels.
- [x] Run full tests, dependency audit, independent review, fix important findings and save proportional evidence.
- [x] Document Sirius boundary: local source → inspect → optional compatible MP4 transcode/remux → progress/cancel/receipt → host AVKit player. Remux preserves codec and cannot make unsupported media playable; thumbnails, PCM/seek playback API and authenticated endpoint are later work.

## Execution status

Completed locally:64 tests,22 release copy jobs, relocated offline CLI without Metal bundle, dependency audit and independent review. User explicitly authorized Git initialization and public commit/push to tomislavrupic/PXLmpeg; no other product was edited. See `docs/validation/remux-mp4.md` for the constant-DTS-rebasing ruling, scratch cleanup fix, review and limits.
