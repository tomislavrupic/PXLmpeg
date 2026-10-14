# ProRes MOV + PCM implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline. Steps use checkbox syntax for tracking.

**Goal:** Deliver timestamped retained native ProRes 422-family video frames and 48 kHz PCM chunks for a Pixel Deck consumer.

**Architecture:** A separate `PXLProfessionalMedia` Swift library admits professional MOV sources without broadening transcode/remux or the 4:2:0 pixel contract. Immutable metadata loads asynchronously; one dedicated serial worker owns readers and a VideoToolbox decoder. Pull delivery has no prefetch and shared lifetime reservations bound returned media.

**Tech stack:** Swift 6, AVFoundation, VideoToolbox, CoreMedia/CoreVideo, AudioToolbox; no external dependencies.

**Spec:** `docs/architecture/pixel-deck-engine-roadmap.md`, first implementation acceptance boundary.

## Global constraints

- macOS 15; existing Pixel Deck macOS 14 deployment difference remains explicit.
- ProRes Proxy/LT/422/HQ MOV only; 16–4096 even dimensions, progressive, square pixels, full aperture, proper quarter-turn rotation, tagged BT.709 or BT.2020 HLG/PQ.
- Preserve ten-bit 4:2:2 in x422 surfaces; no monitoring transform or 4:2:0 conversion.
- Optional single mono/stereo 48 kHz linear PCM track. Return little-endian interleaved float32, at most 8192 frames per chunk; preserve source presentation offsets.
- Default hardware-required decode; optional explicit software allowance reports actual VT hardware flag. No acceleration inferred from codec name.
- Default 128 MiB owned budget, two retained video frames; reserve before consuming source data. Native/framework internals and consumer copies are outside that accounting.
- Seek returns a new generation, restarts both readers, chooses the first video frame with PTS >= target and trims audio to the first sample >= target. Retained results carry generation; consumers discard old generations.
- Cancellation is terminal for the session, cooperatively checked before/after native calls; no driver preemption guarantee. Close drains queue-owned resources.
- No model loads or inference, automatic installed-app update, or Pixel Deck source modification.

## Review focus

1. Holding frames through seek must not evade the shared budget; resource pressure must not consume the next sample.
2. PCM source offset and chunk splitting must not reset timestamps or swap channels.
3. Concurrent seek/cancel must not admit an older generation or race mutable codec state.
4. Unsupported ProRes 4444/PCM layouts/colour must reject before native decode and leave processing recipes unchanged.
5. Truncated files, EOF, invalid/nonfinite seek and repeated closes must terminate with explicit outcomes.

### Task 1: Professional source admission and native fixtures

**Files:** `Sources/PXLProfessionalMedia/ProfessionalSource.swift`, `ProfessionalTypes.swift`; `Tests/Support/FixtureFactory.swift`; `Tests/PXLProfessionalMediaTests/ProfessionalMediaTests.swift`; `Package.swift`.
**Interfaces:** `ProfessionalMediaSession.open(_:options:) async throws`, immutable `ProfessionalAssetDescriptor` and `ProfessionalMediaOptions`.

- [x] Write native 10-bit 4:2:2 ProRes HQ + integer PCM fixture and admission tests; observe missing feature failure.
- [x] Implement metadata admission separately from `AssetInput`; reject unsupported formats/layouts and preserve timing/colour/orientation.
- [x] Verify HQ and a second 422 variant, rejection of 4444 and existing strict processing rejection; commit.

### Task 2: Retained frame/PCM pull session and transport

**Files:** `ProfessionalMediaSession.swift`, `ProfessionalWorker.swift`, `ProResDecoder.swift`, `PCMReader.swift`, `ProfessionalTypes.swift`; same test target.
**Interfaces:** `nextVideoFrame()`, `nextAudioChunk(maximumFrames:)`, `seek(to:)`, `close()`, immediate `cancel()`, `isCurrent(generation:)`, metrics. All async reads return immutable leased results, timestamps and generation.

- [x] Test x422 geometry/chroma precision, PCM sample/channel content, rational PTS, split continuity, seek/EOF, retained-budget pressure/retry, invalid input, cancellation and close.
- [x] Implement queue-confined VT and independent reader outputs, lifetime accounting and generation fences; observe red then green.
- [x] Run controlled small fixtures serially, then the project suite without model variables; commit.

### Task 3: Real-footage harness, evidence and integration contract

**Files:** native professional-media validation executable/CLI, `docs/validation/prores-pcm.md`, README/dependency audit as needed.

- [x] Add a bounded validation harness using the public API; output actual hardware, pixel layout, timing, counts, memory and seek metrics without producing media.
- [x] Test generated HQ and second variant, and real supplied footage when available; hash originals before/after. Distinguish synthetic fixture evidence from real production footage.
- [x] Build release, run dependency audit, review concurrency/ownership/admission, document the Pixel Deck adapter boundary and remaining runtime limits; commit and push the research branch.

## Execution notes

Implemented inline on the existing research branch. The existing native fixture factory was extended rather than duplicated; default AAC fixtures remain covered by the full suite. The delayed PCM fixture is represented by AVAssetWriter as initial timeline silence, so tests verify that silence and independently expected sought sample content rather than claiming a nonzero source-track start. Review identified two admission mismatches (unsigned PCM and an impossible budget); both were reproduced then corrected. Final evidence: 127 tests, 112 passed, 15 skipped, zero failures; release build, five-product dependency audit and real-source probe pass. Pixel Deck adoption/output, mono/other PCM precision runtime coverage and longer transport validation remain outside the completed first slice.
