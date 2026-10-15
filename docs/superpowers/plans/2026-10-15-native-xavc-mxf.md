# Native XAVC Intra MXF for Pixel Deck

Goal: play the staged FS7 footage through PXLmpeg's own MXF reader and Apple
VideoToolbox, preserving camera code values, all eight PCM channels and rational
timestamps. No FFmpeg calls in the admitted playback path; no third-party core
dependencies. Execute inline on the existing research branches.

First admission profile: closed, complete OP-1a MXF, one indexed body stream,
25p progressive XAVC High 4:2:2 Intra 10-bit, square pixels, eight frame-wrapped
48 kHz signed 24-bit little-endian mono PCM tracks. Reject unproved layouts,
long-GOP, interlacing, changing parameter sets and incomplete indexes. This is
not a claim to support all MXF or all XAVC.

1. Add bounded BER/KLV, primer/local-set and index readers with malformed-input
   tests. Resolve source-package track references, descriptors and essence keys;
   validate bounds before allocations or seeks. Keep originals read-only and
   detect identity/size/mtime changes.
2. Normalize Annex B to AVCC, validate the separate XAVC SPS contract, create
   Core Media samples and reuse synchronous VideoToolbox/lease budgets. Share
   the professional session fence with an MXF worker. Seek by index; retain no
   clip-sized pixel/audio queues. Preserve eight-channel PCM without remix.
3. Route admitted MXF in Pixel Deck research, retain the existing S-Log3/full-code
   monitoring path on every frame. Monitor source channel 1 duplicated to stereo
   explicitly, matching the former first-mono-track monitoring behavior. Native
   thumbnails and a force-native validation mode must avoid compatibility calls.
4. Validate first frames, 30 seconds of PCM and distant seeks on the guarded disposable copy;
   compare selected decoded code values and PCM samples with independent prior
   reference data. Run bounded real-clock playback with transform/audio enabled,
   record actual backend, hardware participation, memory and sync. Retest MOV.
5. Review changes, run focused/full checks and research/normal consumer builds,
   run the separate research app inside the probe guard and push scoped research commits.
   Do not replace an installed app or launch unrestricted validation.

Evidence belongs in public sanitized validation notes; footage, paths, extracts
and machine logs stay ignored. Speed superiority and a full-clip frame-perfect
claim require their own measurements and are outside this first milestone.
