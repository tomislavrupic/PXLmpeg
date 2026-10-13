# Pixel Deck as PXLmpeg's first consumer — read-only assessment

Pixel Deck is a strong first consumer for native preview-copy/export jobs, followed by a deliberately designed frame-decoding adapter. Its existing full player requires substantially more than PXLmpeg's offline MOV/MP4 job facade.

Inspected repository: `$PIXEL_DECK_REPO`. Existing dirty files were observed and left untouched: app/iPad Info.plist, three build/package scripts, project.yml. No builds, installation or source edits were performed in Pixel Deck.

## Actual format needs

| Pixel Deck path | Requirement | PXLmpeg fit |
|---|---|---|
| Local H.264/HEVC review | MOV/MP4, B-frames, orientation, 8/10-bit, SDR/HLG/PQ | Best native first subset; Main10 HLG/PQ now has native/iPhone validation; display integration remains separate |
| Sony professional camera cards | MXF, H.264 High 4:2:2 Intra 10-bit, sidecars, S-Log3/gamut/LUTs | Separate format and colour work; unsupported hardware profiles cannot be solved by simply selecting VideoToolbox |
| General movie/library playback | MKV/WebM/MTS/AVI, VP9/AV1/legacy, network/progressive seeks, multiple audio/layouts | Far beyond current local MOV/MP4 core |
| Playback engine | Pull decoded CVPixelBuffers, exact timestamps, fast seeks, generation flush, bounded decode-ahead | Current public engine returns completed files; a separate playback-session API is required |
| Core Audio | PCM stereo 48 kHz, preroll, selected device, sample-time master clock | Current core copies AAC compressed samples; it does not provide PCM playback |
| DeckLink/HDMI/iPad | Host-specific scheduling, output modes and colour/display handling | Remains Pixel Deck-owned; not part of media transcoding core |
| Thumbnails/contact sheets/proxies | Bounded frame extraction and useful lightweight derivatives | Good early follow-on; frame extraction API still needs to be added |

Evidence: README/ARCHITECTURE/master document plus `PixelDeck/Media/FFmpegPlaybackEngine.swift`, `MediaSourceColor.swift`, `VideoColorPipeline.swift`, playlist and DIT exporter sources. The decoder bridge returns CVPixelBuffers and independently decoded PCM; source-colour classification recognizes HLG/PQ. The inspected external-output pool creates 32BGRA buffers and its normal render target is Rec.709. Recognizing an HDR source is therefore not proof of HDR reference output; do not call that display boundary HDR-correct without testing it.

## Recommended first integration

1. Add a bounded **Generate preview copy / Export compatible copy** operation for supported local sources. A versioned request produces a new file, progress and receipt. Keep original media untouched; preserve HDR by default when supported and require a separate explicit choice for any future SDR conversion.
2. Add a native frame-extraction service for thumbnails/contact sheets. Define precise seek and result-colour behavior before changing existing thumbnail paths.
3. Define a `PlaybackSession` adapter providing open/seek/read/flush/cancel, retained frame leases and PCM audio. Let Pixel Deck retain audio clocks, late-frame/drop policy, LUT/monitoring, DeckLink and UI state. Start with local supported codecs behind capability routing.
4. Expand containers/professional formats according to actual use. PXLmpeg's core can remain dependency-free while Pixel Deck keeps its broader compatibility backend during migration. A full FFmpeg removal would require independent demux/codec implementations for the remaining matrix; it is not established by H.264/HEVC support.

Pixel Deck targets macOS 14 while PXLmpeg currently targets 15. An adapter must deliberately reconcile that deployment boundary (raise the app floor or keep the native feature conditional on supported OS). Do not silently drop Mac support.

No integration is implemented or authorized by this assessment alone. The user asked for inspection and fit; the separate PXLmpeg HDR/format work continues in its owning project.
