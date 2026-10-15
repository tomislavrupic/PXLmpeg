# Native XAVC Intra MXF playback research

Validated on Apple Silicon/macOS 27 with a separately staged 125.32-second UHD
FS7 camera clip. All new media checks used disposable copies inside the
[development guard](../development-media-safety.md). Originals were opened
read-only by the independent-byte-copy stager; neither their permissions nor
volume mount state was changed. Copy SHA-256 was checked again after validation.

## Admitted engine profile

- Closed complete OP-1a MXF with one contiguous body stream and complete VBE
  index, zero stream origin and 25p edit rate.
- One progressive square-pixel XAVC High 4:2:2 Intra 10-bit video track, 16–4096
  even dimensions; independent IDR pictures with stable SPS/PPS.
- Eight mapped frame-wrapped signed PCM24LE mono tracks, 48 kHz, 1920 samples
  per picture. The engine returns all eight interleaved float32 channels in order.
- Read-only Swift BER/KLV, primer/descriptor/track graph and index parsing;
  compressed Annex B → AVCC samples go directly to Apple VideoToolbox.
  AVFoundation cannot open this MXF on the validated Mac.
- O(1) index seeks, rational PTS/duration, generation fencing, actual hardware
  reporting, retained frame leases and owned-memory reservations including
  admission scratch/index storage. Source identity changes fail the session.
- Default hardware requirement remains enforced. Truncated/malformed data,
  temporal index offsets, overlapping/out-of-bounds rows and unsupported layouts
  reject. Long-GOP XAVC, other frame rates/audio layouts, arbitrary partitions,
  growing files, MXF export and RAW remain unsupported by this path.

Coded color metadata is not capture metadata. A transfer declaration alone does
not prove primaries or YCbCr matrix: `ProfessionalAssetDescriptor.colourSpace`
is now optional and remains nil for incomplete coded declarations. Explicit
conflicting VUI color/SAR is rejected. Pixel Deck admits the tested untagged
triplet through source-bound Sony RDD18 S-Log3/S-Gamut3.Cine monitoring metadata,
retaining full camera code values and applying the captured Sony Type A look.
It does not silently label unknown camera footage Rec.709.

## Evidence

The release native ingest probe reached video EOF with all 3,133 pictures of the
125.32-second clip, then sought to three distant points. It delivered 1,440,000
PCM sample frames (30 seconds; the probe's intentional audio cap). All decoded
pictures used actual VideoToolbox hardware; output is ten-bit 4:2:2 x422.
Open was 64.74 ms, first decoded frame 12.65 ms and sequential video decode took
32.47 seconds. These are individual ingest observations, not realtime GUI
playback, a speed comparison or a production benchmark.

The conservative reserved owned-memory peak was 101,647,312 bytes. Sampled
whole-process footprint was 55,919,432 bytes; reservations are conservative
allowances, not measured physical allocation. The initial CLI checksum loop
retained temporary Foundation buffers and inflated process footprint to
3,988,966,976 bytes. Draining an autorelease pool per 1 MiB hash chunk removed
that retention. The corrected run retained the same source-copy SHA-256 and
frame count. This fixes probe hashing, not a claim about all app memory use.

Independent FFmpeg decoding was used only as a developer reference against the
same disposable input. Five luma samples at the middle picture and 123 samples
from each of the eight audio channels matched exactly. FFmpeg is absent from
PXLmpeg's runtime dependency graph and from the standalone Pixel Deck native
Metal/audio-clock check executable.

The consumer check completed 60 seconds with 1,500/1,500 hardware-decoded frames,
2,880,000 stereo monitoring sample frames, S-Log3 transform and Type A LUT enabled.
Maximum frame-selection/audio-clock error was 18.67 ms. Pause held the clock;
seeks to 50% and 97% returned the first picture at/after target and sample-aligned
PCM. Engine output retains all eight channels; Pixel Deck explicitly monitors
source channel 1 duplicated to stereo, matching the former first-mono-track
monitor behavior. No microphone summing occurs.

ProRes regression retained 49 pictures and 98,000 PCM frames; Pixel Deck Metal
lease-lifetime and real Core Audio checks passed on its disposable MOV copy.
The PXLmpeg suite executed 146 tests: 130 passed, 16 optional tests skipped, with real MXF
checks run separately through the guarded prebuilt test bundle: all 10 passed,
including the independent reference comparisons. Eight synthetic
safety tests passed, including the reproduced ancestor-relocation bypass.

The strict GUI attempt stopped before playback because paused-frame presentation
callbacks reported zero timestamps, despite completed GPU work. A retry confirmed the application was active and its
window visible, on the active space and not occluded; timestamps still remained
zero. The guard was kept in place. Onscreen scanout,
full-clip frame-perfect delivery, physical audio latency, audible lip sync,
energy use and speed superiority over FFmpeg are not established by the
60-second offscreen/clock check. Local research app build success is separate
from installation or release; no installed app was replaced for these checks.

## Pixel Deck integration

The research router admits MOV and this MXF profile through PXLmpeg; native
thumbnails, every frame and every seek retain camera monitoring treatment.
`--pxl-require-native` forbids compatibility opens/thumbnails during validation.
Other unsupported product formats retain the existing compatibility route.
The complete Pixel Deck app still contains its FFmpeg compatibility libraries;
the admitted native media path does not demux or decode through them.
