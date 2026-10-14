# Pixel Deck ProRes playback integration

User authorized the next professional-media integration slice. Implement inline with test-driven development; review the final cross-repository change independently.

## Boundary

Preserve Pixel Deck's dirty release files and normal macOS14 build. Add a separately identified macOS15 PXL research build with a local package dependency on PXLmpeg. No copying engine sources or overwriting the installed application. Initial native routing is tagged Rec.709, unrotated ProRes422-family MOV with supported PCM and no external audio override; existing compatibility paths remain separate. Pixel Deck owns its existing Metal monitoring pipeline and Core Audio clock. Native DeckLink output is not part of this first local-playback acceptance.

## Tasks

- [x] Add shared frame types and a native adapter. Use an IOSurface alias whose nonpropagating attachment retains the original PXL frame lease; avoid an attachment cycle on the original decoder buffer. Test retained lifetime through GPU completion, timestamps, seek/reset, source replacement and PCM normalization/gap handling.
- [x] Add explicit backend routing and host backpressure. Limit native decode-ahead to one; retain the currently displayed and GPU-in-flight buffers; flush picture/audio on seek. Surface the actual PXL backend in diagnostics. Preserve the FFmpeg path for the normal target.
- [x] Add isolated research scheme/package checks and a bounded real-time integration harness using Pixel Deck's actual VideoColorPipeline, PlaybackSynchronization and CoreAudioOutput. Validate decode -> Metal texture -> audio sample clock with the supplied real HQ/24-bit stereo clip. No production output or calibrated display approval inferred from the harness.
- [x] Build normal/research app configurations where dependencies permit, run appropriate checks in both repositories, independently review, commit scoped changes and preserve unrelated dirt. Leave a clearly identified research app for manual playback testing and document exact verification limits.

## Verification record

See [consumer acceptance](../../integrations/pixel-deck-playback.md). Both app configurations build; Pixel Deck make test passes with optional Sony SDK skipped. PXL full suite: 128 executed, 113 passed, 15 skipped, no failures. Real-clip harness and full-app EOF/seek/resume checks pass. Independent review findings were corrected and re-reviewed. Native DeckLink remains gated and long-session/audible-sync acceptance remains outstanding.
