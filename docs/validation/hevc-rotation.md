# HEVC Main8 and rotation validation — 2026-10-13

The 0.3 increment added required-hardware HEVC Main8 input/output and 0/90/180/270 display-rotation baking. H.264 remains the default output for old requests. Coded source dimensions remain decoder metadata; planning uses display dimensions. Output has an identity transform.

`Scripts/test.sh` passed 47 tests, including every-pixel GPU/CPU affine-reference rotation checks on both NV12 planes, native HEVC timeline checks, encoded upright-picture probes for both codecs, portrait resize, low-budget rotation-surface rejection, rotated HEVC cancellation cleanup and legacy request defaults. `Scripts/acceptance-wide.sh` passed 12 release cases: eight generated codec/orientation combinations, two real HEVC clips, one real ALi H.264 clip and a labeled passthrough-rotated derivative of a real HEVC source. Original decoded plane hashes, CPU-oriented luma hashes, all output PTS/durations, codec/hardware/identity-transform checks and source SHA256 matched. Relocated network-denied CLI produced HEVC output.

Evidence directory: `../../Artifacts/wide.cazBlf/`, especially `wide.json`, `validation.log`, standalone job files, `run.jsonl` and representative movies. Local test/audit logs are `.work/hevc-rotation/`. No source footage or other product was modified.

The Metal pass rotates luma exactly and re-sites left chroma using bilinear sampling and edge clamping. An extra orientation surface is charged before allocation; planning includes it and uses rotated scratch geometry. This is a deliberate extra surface for simpler provable ownership.

One independent read-only review found no blocking defect. Deferred coverage minor: multi-temporal-sublayer HEVC parser branches have narrower synthetic coverage than the parser's accepted syntax. Native decode is also required; parsing a supported prefix does not validate every remaining coded bit.

The user then requested Main10/HDR in the same active task. Those additions have their own plan/report; this snapshot documents the completed Main8/rotation boundary. Mirrors, arbitrary affine transforms, non-square pixels, broad containers and minimum-OS runtime verification remain separate.
