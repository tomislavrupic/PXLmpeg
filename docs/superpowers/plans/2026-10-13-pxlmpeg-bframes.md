# H.264 B-frame Input Implementation Plan

> Execute inline using superpowers:executing-plans, with one final independent review. The user explicitly requested implementation of the existing M2 B-frame boundary.

**Goal:** Hardware-decode reordered H.264 input, restore exact presentation order with bounded owned storage, and prepare read-only testing of ALi footage.

**Architecture:** Keep synchronous VideoToolbox decoding in decode order. Parse SPS/VUI reorder limits, retain at most reorderDepth + 1 decoded frames, emit the lowest PTS when safe, and drain at EOF. Preserve PTS/duration through the existing Metal/encoder/mux path. Add explicit input colour assumptions only if local ALi testing demonstrates missing metadata; never silently infer BT.709 from resolution.

**Spec:** Existing architecture sections 6–9 and M2 roadmap, refined below. **Tech:** first-party Swift/Metal and Apple frameworks only.

## Scope and invariants

- Existing macOS 15 floor, arm64, hardware-required codecs, new destination only, strict budget, and isolated unversioned workspace remain.
- Progressive H.264 Baseline/Main/High 8-bit 4:2:0 only. SPS declares max_num_reorder_frames when VUI restrictions exist; otherwise conservatively use the level-derived decoded-picture-buffer bound, capped at 16 (Baseline / High constraint_set3 can prove zero).
- Validate SPS bounded syntax, progressive flag, 8-bit 4:2:0, references, reorder <= buffer <= 16, and dimensions. Use the largest bound across same-geometry SPS; reject changing dimensions.
- Decode order requires strictly increasing numeric DTS (negative initial DTS allowed), and nonnegative numeric PTS; no DTS <= PTS assumption (see observed native-fixture ruling). DTS-absent streams retain the old increasing-PTS requirement. Duplicate/late presentation timestamps fail before publication.
- Frame-credit limit becomes stream-specific (1…17), covering decode plus retained display queue. Planner accounts every possible decoded surface plus one output, scratch and packets before execution. Runtime enforces byte and frame limits.
- Queue emits at most one frame per render iteration; EOF drains all retained frames. No temporal/asynchronous VT flags; callback remains synchronous and checked.
- No application source edits or automatic switching of ALi processing paths.

## Review Focus

1. Underreported reorder depth, duplicate/late PTS, DTS discontinuity: typed failure and no published output.
2. Cancellation while decoded frames are queued: all leases released after native return, no partial output.
3. Budget cannot fit declared window, including absent VUI fallback: fail preparation before creating output.
4. First/last B-frames and nonzero starts/edit-list boundaries: exact retained display timeline, no missing final frames.
5. Untagged ALi media: require an explicit recorded interpretation; never silently relabel unknown colour.

## Tasks

### 1. Stream-derived bounds

Files: H264Format.swift, AssetInspector.swift, MediaDescriptions.swift, MediaPlanner.swift, MediaBudget.swift; new H264StreamTests.swift.
- [x] RED: parse explicit reorder 2/buffer 3, absent restriction fallback, malformed/truncated/interlaced/unsupported depth or excessive bounds.
- [x] Implement original bounded SPS/VUI parser and propagate optional descriptor reorder depth. Keep existing public model decoding compatible with older receipts.
- [x] RED→GREEN: planner rejects insufficient multi-frame budget; admission credits enforce negotiated limit.
- [x] Verify targeted tests and record evidence.

### 2. Ordered native frames

Files: SampleReader.swift, VideoDecoder.swift, PresentationBuffer.swift, OrderedVideoReader.swift, JobRunner.swift; new PresentationBufferTests.swift, BFramePipelineTests.swift; FixtureFactory.swift.
- [x] Generate native H.264 with frame reordering enabled and assert compressed packet PTS really goes backward; a merely enabled encoder flag is insufficient evidence.
- [x] RED: existing engine rejects that input; queue tests cover arbitrary bounded permutations, EOF, duplicates/late frames and cleanup.
- [x] Implement decode-order timing checks, bounded presentation queue, stream-specific frame reservations and EOF drain.
- [x] Compare decoded frames in presentation order against independent AVAssetReader decoded NV12 reference, not only sorted timestamp labels. Verify AAC payload/timing, final frame, cancellation and whole pipeline.

### 3. Real-footage boundary and release

Files: developer validation tool, strict request model if explicit missing-colour policy is needed, README and docs/validation/bframes.md.
- [x] Probe a small local ALi corpus read-only and report metadata restrictions separately from B-frame correctness.
- [x] Exercise supported ALi clips through release CLI into this project's generated artifact directory; verify source hashes and independent presentation timeline/frame pixels.
- [x] Full tests, release build, dependency audit, relocated CLI, independent review and one focused fix pass.
- [x] Save receipts, commands, coverage and remaining M2 limits.

## Execution decisions

User intent is explicit: continue implementation according to the approved roadmap. The elaborated mechanics do not require another permission loop. No Git init/commit/worktree helpers; retain local ledger. Other M2 work (rotation/HEVC/broader colour conversions/audio editing/application integration) is separate.

## Completed evidence

39 tests pass, including 100 native cancellation schedules, 1,000 presentation permutations and native variable-duration/nonzero-start cases. Five release corpus cases (one synthetic, four real ALi) match independent display-order decoded plane hashes and full rendered timelines. Relocated offline CLI and dependency audit pass. See [validation report](../../validation/bframes.md) and `.work/bframes/progress.md`. Independent review found no blocking defects; dedicated malformed-DTS branch injection remains a documented coverage minor. This completes the requested B-frame increment, not all M2 application readiness.
