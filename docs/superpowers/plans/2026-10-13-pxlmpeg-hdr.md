# Main10 and HDR implementation plan

> Continue the explicitly requested M2 format work inline, TDD and native verification. Keep the completed Main8/rotation snapshot and Pixel Deck assessment. No other-product edits.

**Goal:** Preserve 10-bit HEVC SDR/BT.2020 HLG/PQ through hardware decoding, Metal rotation/scaling and HEVC Main10 encoding, including real iPhone IMG_6703.MOV.
**Architecture:** Add an explicit bit-depth/colour contract shared by metadata, surfaces, GPU mapping and encoder. P010 uses native 16-bit plane textures with 10-bit code quantization; pool/decoder budgets account doubled storage. Existing reorder/rotation/time/publication semantics persist. Output H.264 is rejected for 10-bit/HDR, requiring explicit HEVC. Keep PQ/HLG encoded-space plane filtering; no implicit tone mapping or linear-light composition claim.
**Spec/reference:** Architecture format roadmap; Apple TN3145 and installed VT/CoreVideo headers. Input iPhone is 3840×2160, Main10, BT.2020 HLG, 180° display transform, Dolby Vision 8.4 with ambient-viewing metadata.

## Required boundaries

- Main/Main10 progressive 4:2:0, 8 or 10-bit only; reject malformed depth/profile mixtures. HDR requires explicitly consistent 2020/HLG or 2020/PQ tags and 10-bit HEVC. Existing strict/default SDR assumption cannot invent HDR tags.
- Preserve static mastering/content-light/ambient data when supplied (24/4/8-byte structures); clear stale attachments on reused surfaces. After transforms, Apple encoder may regenerate dynamic HDR metadata: explicitly set PreserveDynamicHDRMetadata=false + HDRMetadataInsertionMode=Auto. Do not copy old Dolby Vision RPU across changed pixels or claim Dolby certification.
- Accept supported single-layer Dolby Vision 8.4 HLG /8.1 PQ base-layer signalling; reject enhancement-layer/other profiles. Report actual output metadata, not assumed dynamic-metadata presence.
- Preserve actual 10-bit surfaces and low-bit precision through scale/orient; output 16-bit storage must encode 10-bit values correctly. Test every pixel against scalar references within one 10-bit code value, including values beyond 8-bit precision.
- Required hardware encoder Main10 profile and accepted output bit depth; output inspection verifies bit depth and colour. No silent 8-bit fallback.
- Extra owned storage preflighted; explicit acceptance budget can be raised for 4K Main10 reorder window. No original media edits.

## Tasks

1. RED native Main10 HLG/PQ inspection; extend stream/model/pixel/metadata contracts, decoder/pool/texture/encoder, strict HDR routing. GREEN native encode/decode plus schema and profile/depth failures.
2. RED 10-bit GPU/filter/rotation and metadata tests; add bit-depth-aware quantization, metadata propagation, precise budgets. GREEN numerical precision and actual output HDR tags/static metadata, cancellation.
3. Real phone validation: independently decode to 10-bit reference, compare every input decoded plane and oriented luma, full output timeline, Main10 tags/metadata/audio, source SHA256; relocated offline CLI, full suite/audit; final independent review and documented limitations.

Review focus: hidden 8-bit conversion; conflicting/missing HDR tags; stale static/dynamic metadata; 4K P010 budgets/leases; iPhone rotation/VFR/AAC/extra metadata tracks. Pixel Deck integration remains recommendation only; its HDR display/DeckLink output boundary needs separate work.

## Execution status

All three tasks completed with 57 passing tests and 13 release cases, including genuine IMG_6703.MOV, relocated offline CLI and dependency audit. Independent review findings were fixed and rechecked. Evidence and remaining display/RPU/minimum-OS/general-timing limits: `docs/validation/hdr.md`. Source footage and Pixel Deck were not modified; no Git initialization, installation or publication occurred.
