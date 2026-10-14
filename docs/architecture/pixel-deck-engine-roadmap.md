# Pixel Deck engine priorities

Date: 2026-10-14
Status: product direction and proposed milestone order; not an implemented codec-support claim.

## Direction

The user selected professional codec support as PXLmpeg's main priority because it is intended to become Pixel Deck's main media engine. Professional playback, precise media handling and native frame/audio delivery take precedence over further semantic-search features. The search app remains a useful optional research consumer of the engine.

Swift, Metal and Apple system frameworks remain the implementation foundation, with zero third-party dependencies in the core. Pixel Deck retains product UI, catalogues, audio-device clocks/routing, monitoring transforms and external-output scheduling. No Pixel Deck source or installed app is changed by this roadmap.

## Consumer requirements verified in source

Pixel Deck's README declares MOV/MP4/MKV/MXF/MTS/M2TS/AVI/WebM, ProRes and common delivery codecs. Its `FFmpegPlaybackEngine` consumes timestamped retained CVPixelBuffers and independently decoded PCM. Audio is delivered to its existing 48 kHz playback pipeline. These are consumer contracts, not proof of every advertised codec/device combination.

Pixel Deck's architecture specifically documents BURANO H.264 High 4:2:2 Intra 10-bit camera media using its software compatibility backend and precision-preserving `x422` buffers. Sony MXF sidecars carry gamma/gamut and card-LUT information. This camera path is a priority requirement, but its current implementation is not evidence of a native dependency-free decoder in PXLmpeg.

PXLmpeg currently supports a narrow H.264/HEVC MOV/MP4 processing recipe. Its AVPlayer-backed playback view does not expose decoded-frame leases or PCM to Pixel Deck. Native ProRes, 4:2:2/4:4:4 surfaces, PCM decoding/output, MXF demux, SMPTE timecode values and DNxHR are not implemented. Read-only admission of a `tmcd` track is not SMPTE timecode extraction or preservation through export.

## Milestone order

| Priority | Milestone | Required proof |
| --- | --- | --- |
| 1 | Native ProRes MOV ingest: Proxy, LT, 422 and HQ, with PCM audio; establish the frame/PCM delivery contract Pixel Deck needs | Inspect original samples; return bounded timestamped CVPixelBuffers and PCM; retain 10-bit 4:2:2 precision; verify actual backend; exact seek/flush/cancel semantics; original hashes unchanged |
| 2 | Professional transport and sound: long clips, rational frame rates, precise seeking, audio track selection/channel layout, production timecode | Bound decode-ahead and memory; reject stale frames after seek/replacement; preserve offsets and channel identity; prove repeated opens/seeks and sustained A/V sync against reference media |
| 3 | Sony camera ingest: explicit MXF demux and XAVC profile feasibility, beginning with actual production-card samples | Separate container, elementary codec, pixel layout and sidecar interpretation; measure native backend availability for the exact profile; identify original parser/decoder work where Apple APIs are insufficient; no unsupported-profile acceleration promise |
| 4 | ProRes 4444/XQ, alpha, wider bit-depth/range/chroma handling and professional derivatives | Define precision, alpha and color contracts before conversion; validate rendered pixels and round trips independently; prove native encoder availability before offering encode/export recipes |
| 5 | Further production codecs such as DNxHD/DNxHR according to actual library needs | Establish native feasibility and implementation scope separately; do not label support from a container extension or an AVPlayer open alone |

ProRes MOV is the recommended first implementation slice because Apple documents direct ProRes decoding through AVFoundation and VideoToolbox. This is an API path, not a guarantee that every profile, pixel format or operation uses hardware on every M-series device. Playback/decode support and encode/export support must be admitted and tested separately. ProRes RAW is a separate research task, not included in the ProRes 422/4444 milestones.

Sony/MXF discovery should begin early alongside the first slice so that a difficult camera requirement is not hidden behind successful MOV demos. It must not silently broaden the dependency boundary or become an unbounded codec rewrite inside the ProRes milestone.

## First implementation acceptance boundary

The first slice should be deliberately small: a real ProRes 422 HQ MOV with tagged color, known timing and PCM audio, read without altering the original. It must produce retained native video frames and timestamped audio chunks for a small engine harness; a standalone AVPlayer window does not prove the Pixel Deck adapter contract. Verify one additional ProRes 422-family variant before generalizing the family claim. Export remains a later, explicitly admitted operation.

Declare pixel format, bit depth, chroma siting, color primaries/matrix/transfer, range, orientation and time base at the engine boundary. Keep source precision separate from the monitoring/output transform. Do not force professional 4:2:2 input through the existing NV12/P010 4:2:0 kernels merely to make a demo play.

Record measured backend, open/first-frame/seek latency, decode throughput, owned-buffer high-water mark, process footprint and A/V timing separately. GPU compute activity is not proof of codec hardware acceleration. Core ML/ANE model tests are unnecessary for codec acceptance. The earlier whole-Mac unresponsiveness remains an open stability issue; controlled native runtime validation must record the test boundary and must not be reported as complete from builds alone.

## Migration and optional analysis

Keep capability routing explicit while each native path is proven. Pixel Deck's existing broader compatibility backend can cover unsupported assets during migration without becoming a dependency of PXLmpeg. Main-engine adoption requires an actual Pixel Deck frame/PCM adapter and real monitoring/output validation, not only format inspection.

Pixel Deck currently declares macOS 14; PXLmpeg declares macOS 15. Resolve that deployment boundary before adoption rather than silently dropping supported systems.

Semantic indexing can reuse the eventual native frame sampler. Further model changes, OCR, audio semantics and search-library features follow the professional media milestones unless the user explicitly reprioritizes them. Necessary search-app correctness/stability fixes remain maintenance work.

## References and provenance

- Local read-only consumer assessment: [Pixel Deck fit](../validation/pixel-deck-fit.md), plus the current Pixel Deck README, ARCHITECTURE.md, FFmpegPlaybackEngine.swift and FFmpegAudioBridge.mm. Those files describe consumer requirements and existing implementation, not PXLmpeg support.
- Apple: [Decode ProRes with AVFoundation and VideoToolbox](https://developer.apple.com/videos/play/wwdc2020/10090/).
- Apple: [ProRes format white paper](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf).

This document supersedes semantic-search feature expansion as the next development priority. Earlier architecture and validation documents remain historical records of their implementation phases.
