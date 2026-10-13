# HEVC and display rotation implementation plan

> Execute the user-authorized M2 continuation inline with executing-plans, TDD, native verification and one final independent review. No Git initialization or app integration.

**Goal:** Process hardware HEVC Main 8-bit SDR input and bake quarter-turn display rotation for H.264/HEVC into correctly oriented pixels; expose optional HEVC hardware output.
**Spec:** Architecture M2 roadmap, existing bounded B-frame contract, and the constraints below.
**Architecture:** Original bounded HEVC SPS prefix parser proves Main/8-bit/4:2:0/progressive geometry and per-sublayer ordering limits. Existing synchronous decode + bounded presentation queue is reused. An original Metal pass rotates luma and re-sites left chroma onto a canonical left-chroma NV12 surface; existing separable scale follows. Output has identity transform. Public dimensions retain coded width/height plus optional rotation; planning uses display dimensions. Output codec defaults to H.264, optional HEVC. Owned budgets include the extra oriented surface and actual scratch geometry.

## Constraints and review focus

- Apple Silicon, macOS 15 target, Swift/Metal + Apple frameworks, no third-party core dependency or source.
- Existing strict BT.709 limited-range/left-chroma policy and explicit assumption for untagged media persist. Main10/HDR and arbitrary affine/mirrored transforms remain explicitly unsupported.
- HEVC SPS limits: Main profile, one layer, up to seven temporal sublayers; 8-bit 4:2:0; progressive frame flags; even displayed dimensions 16…4096; DPB <=16, reorder <= DPB-1; highest safe bound across same-geometry SPS/sublayers. Reject malformed/truncated/unsupported prefix before codec use.
- Rotation classification accepts proper orthogonal quarter turns with tolerance 1e-5, zero translation or standard positive-bounds translation. Reject skew/scale/mirror/custom translation, preserve square pixels/full aperture checks.
- Rotation cannot simply transpose UV samples: preserve the declared left chroma lattice using bounded bilinear resiting and edge clamp. Every luma/chroma output pixel is checked against an independent CPU reference.
- Planner must reserve decoded window + one optional oriented surface + output + scratch + packets; no uncharged GPU surface, late buffer release or overwrite.
- Test HEVC B-frame EOF/timestamps/real hardware, all four orientations, portrait resize dimensions, AAC bytes/timing, cancellation and older request defaults.
- Test source metadata/profile conflicts and unknown transform with typed rejection; source hashes unchanged on real-footage runs.
- Real footage may still be outside the Main8/SDR contract. Do not claim HDR/Main10 support from HEVC codec name or silently convert to 8-bit.

## Task 1: HEVC stream and codec contract

Files: HEVCFormat.swift, AssetInspector.swift, MediaDescriptions.swift, JobRequest.swift, VideoEncoder.swift, MediaEngine.swift, JobRunner.swift; HEVCFormatTests.swift, HEVCPipelineTests.swift, FixtureFactory.swift.
- [ ] RED native HEVC input rejection and optional output-codec schema; malformed/unsupported SPS prefix tests.
- [ ] Implement bounded original parser, propagate reorder info, select required hardware encode profile/codec, verify output codec.
- [ ] GREEN native HEVC pictures/PTS against independent AVFoundation and both hardware flags; old request stays H.264.

## Task 2: Display rotation

Files: DisplayRotation.swift, DisplayTransform.swift, PlaneOrienter.swift, Scale.metal, MediaPlanner.swift, JobRunner.swift; DisplayTransformTests.swift, PlaneOrientationTests.swift, HEVCPipelineTests.swift.
- [ ] RED 90/180/270 transform classification/geometry and rotated native input execution.
- [ ] Implement proper quarter-turn classification, display-aware planning and charged oriented pool.
- [ ] Implement original Metal rotation/chroma resiting; preserve PTS/duration, encode identity transform.
- [ ] GREEN every-pixel CPU reference tests for all rotations, native portrait/landscape execution for both codecs, low-budget/cancellation checks.

## Task 3: Wider-footage acceptance and handoff

Files: WideFootage.swift, acceptance-wide.sh, README and docs/validation/hevc-rotation.md.
- [ ] Probe a small local corpus read-only for compatible HEVC/rotation samples.
- [ ] Generate native HEVC+B-frame+rotation corpus, process real compatible source footage, record exact timing/reference/codec/hardware/source-preservation evidence.
- [ ] Full tests, release/audit, relocated offline CLI; one independent review and focused fixes for significant findings.
- [ ] Save results, examples and precise remaining format/platform boundaries.
