# B-frame input validation — 2026-10-13

PXLmpeg 0.2.0-bframes processes reordered H.264 through hardware decode, bounded display ordering, original Metal scaling, hardware H.264 encode and MOV publication. It passed one generated native fixture and four real ALi output files. Originals were opened read-only and their full SHA-256 hashes matched before and after testing. Applications and timelines were not modified.

## Evidence

- [Raw real/native receipts](2026-10-13-bframes.json).
- [39 passing XCTest cases](2026-10-13-bframes-tests.log), including the original tests and new native B-frame, parser, reference-picture, budget, timing, cancellation and strict-colour tests.
- [Zero third-party dependency audit](2026-10-13-bframes-dependencies.log). Apple system frameworks and Swift runtime only.
- One independent read-only review found no blocking implementation defects. A nonzero-start coverage recommendation was covered by the final native VFR/leading-gap test; targeted malformed-DTS injection tests remain a deferred coverage minor.
- Host remains Apple M3 Ultra / macOS 27.0.1 / Xcode 27 / Swift 6.4. No minimum-OS or other-device claim.

## Accepted corpus

| Input | Display frames | SPS reorder bound | Retained decode peak | Engine-owned peak |
|---|---:|---:|---:|---:|
| 0: native-bframes-aac.mov | 240 | 5 | 6 | 16.62 MiB |
| 1: generation-4step.mp4 | 9 | 2 | 3 | 2.94 MiB |
| 2: candidate-generation-warm.mp4 | 9 | 2 | 3 | 2.94 MiB |
| 3: continuous-121f.mp4 | 121 | 2 | 3 | 29.80 MiB |
| 4: import-25fps-audio.mp4 | 30 | 2 | 3 | 3.51 MiB |

Each compressed stream was independently checked to contain actual backward PTS transitions in decode order. For every displayed source frame, both decoded NV12 planes were hashed over every active pixel and compared with independent AVAssetReader display-order decoding. All hashes and PTS matched. Every re-encoded output frame's PTS and duration matched sorted original compressed **output** timing, including the final frame. Every receipt confirms actual hardware decode and encode.

The native fixture contains 10 seconds of 1280×768 B-frame video and AAC. Real samples include short generation outputs, 121-frame continuous LTX footage, and an audio-bearing import. All five selected files have audio; native unit tests also compare copied AAC buffer bytes and mapped timestamps/durations exactly. The corpus tool checks video pixels/timing and output audio presence/duration; it does not independently hash every real clip's copied audio.

These are technical validation results, not subjective audiovisual approval. Encoded output is lossy, so source/output encoded pixel identity is not claimed. No quality-equivalent speed comparison or general production-media readiness is claimed.

## How ordering and memory work

VideoToolbox decodes samples in decode order with both asynchronous and temporal-processing flags clear. The installed Apple SDK documents synchronous callback completion with these flags. Each call must produce exactly one valid NV12 frame; its buffer remains retained through sorting and later GPU work.

The original SPS parser reads profile/depth/subsampling, progressive geometry, level and VUI restrictions. `max_num_reorder_frames` supplies the display-order bound when present. Otherwise the parser uses the level-derived decoded-picture-buffer maximum, capped at 16 (and proven zero for the restricted profile cases). Multiple same-geometry SPS use the largest safe bound. Syntax loops, parameter-set count/size, dimensions and allocation arithmetic are bounded; malformed or unsupported streams fail explicitly.

The queue retains at most `bound + 1` decoded frames, emits the lowest display PTS after that window is filled, and drains the remainder at EOF. Planner estimates, runtime frame credits and byte reservations use this same bound (up to 17 decoded frames). A budget unable to hold the full required window fails before output creation. This replaces the original four-frame proof cap for B-frame input; it does not create unbounded concurrency. Scaling/encoding still process one emitted frame at a time.

Cancellation after synchronous native return releases the decoded window. Tests run 100 deterministic native cancellation schedules and 1,000 seeded bounded permutations across depths 0–16. All cancelled windows have zero charged bytes and frame credits after teardown. The existing watchdog limitation for a genuinely hung OS call still applies.

## Timeline findings

ALi compressed buffers exposed media PTS two frames later than their presentation timeline. `CMSampleBufferGetOutputPresentationTimeStamp`, output DTS and output duration incorporate container edit offsets. The pipeline now schedules mapped output time, verified against independent decoded display time; it does not subtract a guessed constant.

Valid numeric DTS must increase strictly. Streams with absent DTS retain strictly increasing PTS; switching DTS presence midstream fails. Apple's own B-frame fixture sometimes exposes DTS later than PTS, so DTS is not used as a presentation watermark. Duplicate/late display times or a declared reorder window too small for actual input fail before destination publication.

The native VFR case uses frame durations [1,2,1,3,1] in units of 1/24 second, with starts at zero and 0.5 seconds. It verifies all output timestamps, all compressed durations and the retained initial empty-edit duration. AVAssetReader synthesizes a black image for that leading gap; the independent reference excludes empty track segments, and the test verifies the gap separately. Decoder references can omit duration on some frames, so compressed mapped durations are checked independently through the encoded output.

## Untagged ALi colour

The selected ALi files omit BT.709 colour tags. Default behavior remains strict. Tests explicitly request:

```json
"inputColourPolicy": "assumeBT709Limited"
```

This supplies missing BT.709/limited-range interpretation, not a colour conversion or proof of the creator's intent. Conflicting explicit colour tags and full-range signals remain rejected; left chroma and supported geometry are still required. The normalized request digest and receipt notes record the policy and whether tags were actually assumed. Omitting the field preserves the strict behavior of older requests. Inspect remains strict; `plan` can inspect a request with its explicit policy.

One additional probed ALi face-upscale sample has non-square pixels and remains unsupported. It was not counted as a successful corpus case.

## Reproduction

```sh
./Scripts/test.sh
./Scripts/verify-dependencies.sh
./Scripts/acceptance-bframes.sh /absolute/path/to/ali-output.mp4
```

With no media arguments, acceptance generates its own native B-frame fixture. Additional paths are treated as read-only. The script creates a unique artifact directory, writes standalone job JSON, copies the release CLI and resource bundle, and executes that CLI from `/tmp` with networking denied when macOS sandbox-exec is available. The latest completed directory is recorded in `.work/latest-bframe-acceptance-path`.

This run's movies, jobs and relocated CLI JSON live in `../../Artifacts/bframes.xUetNK/`. `case-3-output.mov` is the processed 121-frame ALi sample. Raw receipts are copied above so generated movies can later be cleaned up independently.

## Decisions and remaining boundaries

- Continue the explicitly authorized existing M2 boundary inline, preserving the isolated unversioned workspace and local ledger. No Git initialization or other-product edits.
- Keep synchronous native decoding and a codec-derived presentation window. This trades some latency and memory for simple native ownership; conservative absent-VUI bounds can reject a small budget.
- Use mapped CoreMedia output timing, not raw media PTS, and rely on SPS ordering rather than DTS-vs-PTS inequalities. The observed native references justify these choices; a wrong mapping would affect display timing, so per-frame reference checks pin it down.
- Require an explicit recorded interpretation for untagged colour. Wrong caller interpretation can change displayed colour; it is never treated as established source metadata.
- HEVC, rotation, non-square pixels, HDR/10-bit, broader colour conversion and application integration remain separate work. General trim/preroll/reverse/rate-scaled edits are not established by simple edit-offset/VFR/gap validation and can fail explicitly.
- macOS 15 and other hardware remain unverified. A declared deployment floor is not runtime evidence.
- Deferred coverage minor: dedicated repeated/backward/mixed-validity DTS fault injection and explicit error-code assertions on every queue-negative test. Those branches return timingViolation in code, but the exact malformed stream conditions have not been induced by the native corpus.
