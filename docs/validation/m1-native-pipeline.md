# First native pipeline — 2026-10-13

## Outcome

The first Swift/Metal pipeline is working on real Apple Silicon: native compressed sample read → verified hardware H.264 decode → original Metal NV12 resampling → verified hardware H.264 encode → MOV muxing and inspection → atomic no-replace publication. Optional AAC copying preserves packet payloads and timestamps on the tested fixture. A Swift library and JSON-lines CLI expose this path without third-party core dependencies.

This delivers the first native pipeline. It does **not** close the entire original M1 adversarial-test backlog or establish application readiness. Production ALi/Sirius/Pixel Music paths remain untouched.

## Reproduction and environment

- Host: Apple M3 Ultra, 28 CPU cores, 96 GiB RAM; macOS 27.0.1 (26A434).
- Toolchain: Xcode 27.0, Swift 6.4, Swift 6 language mode; arm64 release build.
- Declared deployment floor: macOS 15; neither that OS nor the oldest Apple Silicon generation was tested.
- Full Xcode compiles first-party `.metal` source ahead of time. No downloaded shader/compiler/codec binaries.
- Commands: `Scripts/test.sh`, `Scripts/build.sh -c release`, `Scripts/verify-dependencies.sh`, `Scripts/acceptance.sh`.
- Tests: [23 passing XCTest cases](2026-10-13-tests.log), zero failures. These include real GPU, codec, muxer, full pipeline, and CLI subprocess execution.
- [11 additional release CLI checks](2026-10-13-cli-checks.json) passed. Their one-off developer harness lives in `.work/check-cli.py`; Python is not a build, test-suite, or runtime requirement. Native CLI signal/broken-pipe regressions are permanent XCTest cases.
- [Dependency audit](2026-10-13-dependencies.log): zero external package dependencies or binary targets; linked runtime closure contains only Apple system frameworks and Swift libraries. All project Swift/Metal source is first-party.
- Build-system limitation: `--build-system native` is explicitly selected and produces an Xcode 27 deprecation warning. No source compiler warnings remain in the last release build.

## Measurements

[Raw receipts and environment](2026-10-13-benchmark.json). Every case used one warm-up followed by five measured runs. Video is 24 fps, first-party synthetic H.264 with no reordering. 1080p includes generated stereo AAC; 4K cases are video-only. Encoder target bitrate is 12,000,000 bps, read back from the session. Every measured receipt confirms hardware decoding and encoding. “Copy-size” still decodes and re-encodes; it is not compressed passthrough.

| Case | Median | Range | Owned peak | Sampled process-footprint range |
|---|---:|---:|---:|---:|
| 1080p-copy-size | 2.195 s | 2.182–2.347 s | 8.48 MiB | 281.25–281.50 MiB |
| 4k-copy-size | 10.398 s | 8.751–10.446 s | 31.69 MiB | 291.08–291.20 MiB |
| 4k-to-1080p | 2.950 s | 2.798–3.019 s | 59.92 MiB | 322.27–362.14 MiB |
| 4k-120s-to-1080p | 33.863 s | 33.117–34.741 s | 59.92 MiB | 362.38–362.55 MiB |

First three inputs last 10 seconds; the final input lasts 120 seconds. Timing includes execution, output inspection, and publication, but excludes fixture generation and preparation. Acceptance rereads every encoded video sample and verifies exact expected PTS and frame count (240 or 2,880). These are synthetic development measurements, not a comparison with FFmpeg or a promise for production footage. Some short development checks ran concurrently; the desktop was not otherwise isolated. Thermal state at report capture was nominal. Energy/power was not instrumented.

The 10-second and 120-second resize cases have identical owned-memory peaks. Repeated long-run sampled footprints cluster within roughly 0.2 MiB; the short case also exhibits a ~40 MiB codec/cache step. This provides no evidence of duration-proportional retained owned frames in this run. It does not establish a hard RSS ceiling: driver/codec allocations are opaque, and process footprint is sampled per processed frame rather than continuously.

## What was verified

- Rational timestamp comparisons at integer extremes; schema, dimensions, budget and bitrate validation; deterministic request encoding.
- Real Metal identity/shrink/enlarge results compared pixel-by-pixel with an independent scalar reference on both NV12 planes (1–2 code-value tolerance).
- Required hardware VT sessions, accepted bitrate, synchronous callback completion and native MOV round trip.
- Exact 240-frame timeline in a full engine job; AAC sample bytes, PTS and durations unchanged after copy.
- Unequal audio/video durations: shorter and longer audio both copy correctly; dropping longer audio produces the shorter video timeline correctly.
- Budget denial and idempotent reservations; pool storage remains charged between frames and leased exclusively.
- Existing/raced destination preservation, source fingerprint changes, cancellation cleanup, engineBusy, and no publication on tested failures.
- Independent watchdog diagnosis while no worker check occurs. The failure remains latched after progress resumes.
- Missing/wrong chroma metadata and unsupported/truncated SPS prefix rejection; explicit supported 8-bit 4:2:0 proof.
- Release CLI: Unicode/spaced request paths, invalid command/JSON, bounded oversized-request read, SIGINT exit 130 with one final cancellation event, broken-pipe cleanup, existing destination preservation, and a missing entire shader bundle returning typed gpuFailure rather than trapping.
- A prefilled stdout pipe reaches its bounded failure path (about 4.12 seconds including the final error-output attempt).
- Relocated release CLI and resource bundle operate from `/tmp`; a whole native decode/resize/encode job completes with network access denied by the macOS sandbox.

## Review fixes and design decisions

One independent read-only review identified six issues; all received fixes and focused verification: mark audio EOF immediately and service ready mux tracks; independently diagnose blocked native work; verify retained-track duration when dropping audio; require proved chroma; avoid SwiftPM's fatal missing-bundle getter; join the progress task before terminal JSON. Release process testing additionally exposed a Swift 6 isolation trap in the SIGINT handler, corrected with an explicitly Sendable callback and a subprocess regression.

The executor intentionally admits one frame at a time on a dedicated Dispatch worker. It waits for native completion, drains the encoder per frame, and retains mapped textures and surfaces until safe release. This is within the plan's maximum-four limit and prioritizes inspectable ownership over throughput. Asynchronous overlap and reorder support are future work. The MaxFrameDelayCount property was rejected by this hardware encoder; explicit draining replaces that property without enabling software fallback.

The internal executable target is `PXLmpegCLI` because `PXLmpeg` and `pxlmpeg` collide in module output paths on a case-insensitive filesystem. The executable is still named `pxlmpeg`. Resource resolution uses checked installed bundle paths (and a debug-only test build path), with no runtime shader compilation.

## Remaining gates and limits

- B-frames/reordering, rotation, HDR, 10-bit, HEVC/ProRes, compositing, editing, audio DSP, and AI model execution are outside this first recipe.
- VFR, nonzero starts, AAC priming/edit lists, changing formats, broad malformed-media fixtures, and disk-full behavior still need the original plan's adversarial validation. Existing timing rejection is not evidence that every timeline/container combination is supported.
- The planned 100 cancellation schedules and 1,000 randomized lease orders have not run. Synchronous single-flight execution removes asynchronous completion ordering from this implementation, but does not replace future concurrent stress testing.
- A hung native OS call cannot safely be forcibly torn down. Progress reports `stalled-native-teardown-pending`; cancellation is acknowledged, admission stops, storage remains retained, and final error/cleanup waits for native return. The watchdog test verifies diagnosis, not recovery from an actual hung driver.
- Numerical scaler verification does not establish subjective encode quality or a quality-equivalent competitor benchmark. No audiovisual approval was requested or inferred.
- macOS 15 validation, reusable host-app resource packaging, and production application integration remain unverified. Deploying the CLI requires its adjacent resource bundle.

## Local artifacts

Representative input/output movies and CLI JSON are retained in `../../Artifacts/native.M7O8Nf/`. `.work/latest-acceptance-path` identifies this completed run. Raw benchmark evidence is also copied above so it survives optional cleanup of generated movies. Source files remain local and unversioned; no Git initialization, application installation, or publication was performed.
