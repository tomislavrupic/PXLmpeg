# Camera metadata and interpretation

`CameraMetadataInspector.inspect(url)` provides a camera-independent capture
metadata contract in `PXLProfessionalMedia`. It keeps normalized gamma/gamut
separate from raw evidence, source URL/location, derivation, sampling scope and a
file-identity comparison token. No original file or card metadata is rewritten.
The label namespace identifies who defined the label; it does not infer camera
manufacturer or model. Unknown formats/labels return no supported interpretation; I/O/source-change
errors remain explicit. The token detects identity/size/mtime changes and is not
a cryptographic content checksum.

## First proven reader

The first adapter reads Sony camera acquisition sets carried in 8-bit SMPTE ST436
MXF ANC packets, using the label definitions in
[SMPTE RDD18:2021 sections 5.4.25–26](https://pub.smpte.org/pub/rdd18/rdd18-2021.pdf).
It recognizes exact Sony S-Log3 labels and requires corresponding primaries.
The Cine gamma label explicitly defines the S-Gamut3.Cine pairing; if primaries
are derived that way, the report says so and retains the original gamma label.
Generic S-Log3 without primaries is not assigned an assumed gamut. The reader also
retains EI, ISO, raw luminance code range (including unknown/reserved values), and
a bounded Sony UDAM monitoring-look name. Those are separate facts, not changes
to capture gamma or automatic exposure compensation.

This is independent of generic codec/container transfer tags and does not admit
MXF/XAVC for native decoding. Probe limits: 4,096 outer KLV headers, first 64 MiB of
file offsets, at most 1 MiB actually read, and 64 KiB per ANC element. Picture values
are skipped with seeks. Source admission requires a regular file; nonblocking,
no-follow descriptor validation and identity checks fence replacement. Packet
fragments must be in sequence and malformed/truncated data is not guessed.
Only the first supported acquisition record is sampled; dynamic metadata changes
and whole-clip consistency are not validated. 10-bit ANC coding, BiM decoding and
other camera adapters remain future work.

```sh
swift run pxl-prores metadata /absolute/path/camera-original.mxf
```

JSON includes the local source URL and comparison token; keep private reports
outside Git. Pixel Deck's research consumer reads this off the main actor,
validates source identity after opening playback, and selects its input transform
from the capture result. Existing XML card-LUT references remain a separate look;
conflicting XML capture values are surfaced and inhibit the conflicting look.

A real FS7 original with absent M01 XML color fields and a generic BT.709 transfer
tag contains the embedded S-Log3.Cine label. The PXL probe read 6,958 bytes; Pixel
Deck selected S-Log3 / S-Gamut3.Cine automatically. The recorded look is `SonyProf2:LC-709typA`, with EI 800 / ISO 2000. A bounded
120-frame 4K render initially showed a pixel change, but that alone did not prove
correct color. A subsequent overblown-picture report exposed a wrong display
transfer and a range mismatch; see the verification below. The compatibility decoder's
actual hardware flag was true. See [sanitized evidence](../validation/2026-10-15-camera-metadata-performance.json).

## Monitoring color verification

Pixel Deck's built-in S-Log3 inverse now explicitly applies the Rec.709 OETF once.
The previous use of a display ICC transfer returned 125/255 for S-Log3 code 420;
the corrected Metal path returns 104/255. Code 95 returns 0 and code 598 returns
241 (reference 242, tolerance 3), for both full-range reference buffers and the
camera decoder's video-range x422 buffers interpreted as full code values.

The FS7 decoder preserves the original full-range Y codes but labels its buffer
video-range. The monitoring view retains the original lease and reverses that
normalization on the GPU; original data and attachments stay unchanged. Explicit
RDD18 range 2 enables this mapping, while 6 and unknown/reserved values disable
it. When the tag is absent, the embedded Sony S-Log reader uses the documented
S-Log full-scaled default in [RDD18 section 5.4.28](https://pub.smpte.org/pub/rdd18/rdd18-2021.pdf)
and labels it as a derived default. XML-only/manual input choices do not imply
that range policy. Playback and thumbnails share the predicate.

At source PTS 594.12, the actual Metal LC-709 Type A render was compared with an
independent software full-range BT.709 decode through the same Sony LUT. Mean
absolute channel error was 0.612/255; 99.30% of pixels had all three channels
within 3/255, with a maximum difference of 25/255 across differing resampling
paths. This is a one-frame numeric reference check, not calibrated display,
whole-clip metadata, or grading approval. The captured EI/ISO are displayed with
first-record sampling scope; no EI exposure offset is automatically applied.

## Wider camera support

The intended coverage is Sony, Panasonic, Canon, ARRI and other camera families
when declared metadata can be read and mapped reliably. The common contract is
available now; the current implementation is not an all-camera detector. Add
readers against documented fields and real originals, preserving original vendor
names/labels, raw values, file/track/frame location and unresolved conflicts.
A file extension or camera model alone must not establish a log curve or gamut.
Keep capture metadata, viewing LUTs, exposure adjustments and output transforms
separate; they describe different parts of the signal.

## Semantic enrichment boundary

Semantic observations belong in a separate owned sidecar or search index linked
to the source identity and rational media-time range. Each observation should
carry model/version, inference settings, confidence/similarity, creation time and
whether it was model-generated or human-reviewed. New model runs create another
version; they do not replace camera capture facts. A changed source invalidates
the association until revalidated.

The existing semantic search index is already separate from the original footage.
A universal metadata/semantic-sidecar writer and semantic indexing of all camera
formats are not implemented by this reader. Core capture inspection requires no
model; optional AI enrichment must have its own resource and device policy.
