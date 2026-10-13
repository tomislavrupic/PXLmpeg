# Main10/HDR and genuine iPhone validation — 2026-10-13

PXLmpeg **0.4.0-main10-hdr** preserves supported 10-bit HEVC SDR, BT.2020 HLG and PQ through hardware decoding, Metal rotation/scaling and hardware Main10 MOV encoding. Core dependencies remain Apple system frameworks and Swift only. This is a bounded native transcode capability, not HDR reference-display approval.

## Evidence

- `Scripts/test.sh`: **57 tests passed**, including 10-bit every-pixel scalar area/bilinear and affine rotation comparisons on both planes, low-bit precision/packing, supplied PQ mastering/content-light/ambient metadata through encode and resize, stale attachment clearing, strict Dolby configuration failures, multi-sublayer SPS bounds, explicit timed-metadata policy/default compatibility and rotated Main10 HLG cancellation cleanup.
- `bash Scripts/acceptance-hdr.sh $IPHONE_ORIGINAL`: **13 release cases passed**. Twelve generated cases cover 10-bit BT.709, HLG and PQ at 0/90/180/270 degrees, each with 48 B-frame pictures and AAC. The thirteenth is the user's camera original.
- Independent AVAssetReader x420 decode matched every active byte of both PXL-decoded planes; CPU quarter-turn luma hashes matched all oriented pictures. Every output video PTS/duration and hardware flag matched the contract. Output bit depth, transfer/matrix, identity rotation and every supplied static/ambient metadata field were inspected.
- AAC validation normalizes individual compressed access units because AVFoundation regrouped the phone's sample buffers after remuxing. Every access-unit payload hash and raw sample PTS/duration, trim-at-start/end fields, rendered audio span and complete audio format description matched. Eight source sample-buffer groups do not mean eight AAC access units.
- Every source SHA256 matched before/after. Relocated release CLI ran from `/tmp` with network denied and produced the 960×540 Main10 HLG copy.
- Earlier 8-bit/ALi paths passed **12 release regression cases**, including two real HEVC originals, one real ALi H.264 original and controlled rotation; relocated offline CLI also passed. [Regression results](2026-10-13-hdr-wide-regression.json); artifacts: `$PXL_WORKSPACE/Artifacts/wide.rDKIUf`.
- Manifest audit found zero external packages/binary targets; runtime audit found only Apple frameworks and Swift libraries.

Evidence directory: `$PXL_WORKSPACE/Artifacts/hdr.znJdWB`. Machine: Apple M3 Ultra, macOS27.0.1, Xcode27/Swift6.4. Snapshot: [results](2026-10-13-hdr.json), [tests](2026-10-13-hdr-tests.log), [dependencies](2026-10-13-hdr-dependencies.log). Earlier [Main8/rotation evidence](hevc-rotation.md) remains separate.

## iPhone result

| Boundary | Verified result |
|---|---|
| Source | `$IPHONE_ORIGINAL` — 3840×2160 HEVC Main10, 91 pictures, 2275/600 seconds |
| Colour/geometry | Limited-range BT.2020 HLG, left chroma, 180° transform |
| Source HDR | Dolby Vision 8.4 configuration with RPU-present signalling; ambient bytes `002fe9a03d134042` |
| Output | 960×540 HEVC Main10 HLG MOV, identity transform, 91 pictures, unchanged duration and stereo48k AAC |
| Metadata | Ambient bytes unchanged; output Dolby configuration also signals RPU availability; five timed metadata tracks explicitly discarded |
| Hardware | Actual required decoder and encoder sessions both verified |
| Owned storage peak | 156,182,770 bytes, with an explicit 1GiB acceptance budget |
| Process footprint sample peak | 385,926,224 bytes; opaque codec/driver allocations and sampling gaps prevent a strict total-memory claim |
| Single functional run | 2.267s; not a repeat-run performance benchmark |
| Source SHA256 | `869d328924d5a3df27163822c0f69c104e900c9c2ae102face9906a8ca11ccc6` unchanged |

Representative outputs and explicit jobs are in the local acceptance artifact directory; generated media is excluded from the repository. Regenerate using the documented script.

## Architecture and metadata decisions

`AssetDescriptor` exposes bit depth, transfer-family, supplied static metadata, timed-metadata track count and Dolby RPU configuration signalling. The backend's `PixelContract` carries the actual pixel format and metadata across decoding, surfaces, GPU mapping and encoding. P010 uses native high-ten-bit 16-bit storage, `R16Unorm`/`RG16Unorm` mappings, float scratch textures and final 10-bit quantization. Allocation reservations account doubled sample storage. Matching bit depths are enforced across GPU/encoder boundaries.

Main10 requires explicit `outputCodec=hevc`; there is no silent H.264/eight-bit fallback. HDR requires consistent explicit BT.2020 + HLG/PQ tags and limited range. The SDR missing-tag policy cannot invent HDR tags. Dolby input is restricted to supported v1.0 single-layer profile8 HLG/PQ-compatible base-layer records (8.4/8.1); malformed records and missing required configuration are rejected.

Only colour/chroma/static HDR/ambient attachments propagate to changed pixels; absent static keys are cleared on reused surfaces. Supplied 24-byte mastering-display, 4-byte content-light and 8-byte ambient data must survive output inspection before atomic publication. Encoder-generated extra HDR10 fields are allowed and reported separately in actual output metadata. Apple documents ambient viewing metadata as important to HLG appearance in [TN3145](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata).

Apple encoder settings use `HDRMetadataInsertionMode=Auto` and `PreserveDynamicHDRMetadata=false`. This requests metadata generation for processed pixels without copying stale source RPU metadata. `hasDynamicHDR` means the inspected Dolby configuration has its RPU-present bit set; it does **not** prove every frame contains a valid RPU or certify Dolby Vision delivery.

The phone's five extra timed-metadata tracks are inspected but excluded from the video/AAC output only through explicit `timedMetadataPolicy=discard`. Legacy requests default to `reject`; the receipt records the discarded count. Native source footage is never modified.

## Review and limits

Independent read-only review found no remaining important issue after fixing unconditional metadata-regeneration wording, RPU signalling detection/configuration validation and AAC validation across buffer regrouping. Targeted follow-up confirmed the fixes. The earlier sublayer-coverage minor was addressed with new synthetic PTL/skipping/monotonic-bound tests.

No calibrated HDR display/DeckLink validation, subjective encoded-image approval, per-frame RPU integrity or Dolby certification occurred. Filtering stays in encoded YCbCr space, not linear light; no SDR tone map or wide-gamut composition is provided. Hardware/profile support on other Macs and the declared macOS15 floor remain untested. General trims/edit lists/priming, arbitrary affine transforms, 4:2:2/full-range, other containers and ProRes remain separate milestones.

[Pixel Deck assessment](pixel-deck-fit.md): start with supported preview/proxy/export copies. Its full player additionally needs a public frame/seek/flush API, PCM audio, broader containers/profiles and separately validated output colour. Pixel Deck was inspected read-only and remains unchanged.
