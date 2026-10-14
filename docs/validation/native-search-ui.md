# Native search UI — research build, 14 October 2026

The optional `PXLSearchUI` target and `pxl-search-app` / `PXLSearch.app` compose the existing local semantic analyzer and AppKit player. The first trial supports choosing real footage, indexing, text search, thumbnails and click-to-play at actual indexed timestamps. No third-party runtime was added and no other product was changed.

**Stability investigation is open.** The user reported whole-Mac unresponsiveness during the first interactive trial and the Mac was forcibly restarted. The revised app has not been reopened for hardware validation. The code is a draft research change; passing functional tests must not be presented as evidence that the machine-wide freeze is fixed.

## User workflow

1. Explicitly fetch MobileCLIP-S2 with the existing developer script and build `Scripts/build-search-app.sh`. Model weights remain external. The development bundle can point to the local fetched folder; Models changes that location.
2. Add Footage accepts up to 32 supported local MOV/MP4 files across different selections/folders. File → Replace Footage replaces the selection. Explicitly enable the Rec.709 assumption only for known untagged SDR.
3. Index Footage uses one-second sampling, capped at min(256, floor(4096/sourceCount)) requests per source. Partial coverage is visible. Initial model loading takes seconds.
4. Enter a visual description and click Search or press Return. At most 12 ranked candidates appear, up to three per source with one-second separation. This avoids filling the list with adjacent frames; it does not infer event spans. Similarity is not probability.
5. Click a thumbnail/result to open its source, seek to actual index PTS and begin muted playback. Play/pause, timeline and mute remain available. File → Open Index / Save Index As reuses new sidecars without overwriting existing files.

The CPU compatibility selector explicitly excludes ANE/GPU inference. It does not disable hardware video decoding, thumbnails, Core Image preprocessing or native playback. The default remains Neural Engine + CPU. `--query` only prefills the field; startup/reopening cannot automatically submit inference. There is no runtime download or silent device fallback.

This is an unsandboxed, ad hoc signed local development bundle, not a notarized release. Security-scoped bookmark support and product catalog integration remain future work.

## Functional evidence before the incident

**11 UI/workspace tests passed**, including real model inference and native image extraction on the seven-source sidecar from the semantic prototype. The native flow exercised actual AppKit Search and result button actions, not a mock player:

- Query: “a frightened woman in a white spacesuit”.
- First candidate matched source SHA-256 `15cab67cd81f72e5f53ca5e506936564ace981147388867ca3ff43440fc9ad93`.
- 12 visible candidates, all 12 with native thumbnails bounded to 320 × 180.
- Actual result PTS: **3.000 s**; completed native seek landed at **3.000 s**.
- AVPlayer position advanced past **3.19 s**, with playback requested and mute enabled.
- New indexing from the iPhone original and an ALi source succeeded; a new saved sidecar reopened successfully.
- Source-change/missing-source rejection, replacement/close during search, superseded thumbnail updates, missing model configuration and exclusive save behavior passed.

A local bitmap and a separate window capture were inspected. Private footage pixels and raw system logs are not published. Bitmap rendering does not capture the video layer and is not evidence of presented video pixels or audio quality. Automated playback progress does not substitute for manual listening/HDR display acceptance.

## Incident evidence and limits

The reset record indicates a button-triggered restart around **15:59 Europe/Zagreb**. No matching kernel panic report was found. The inspected pre-restart unified log stops around 15:57:24 without a recorded GPU timeout or ANE firmware fault. This absence does not rule out a driver/system failure; a forced reset can lose diagnostic evidence. The exact triggering user action remains unconfirmed.

An ANECompilerService disk-write diagnostic records **8.59 GB dirtied over approximately 4015 seconds**, attributed mainly to repeated native tests and `pxl-search` processes, with some search-app activity. It spans work earlier than the freeze and does not establish causation. Post-restart memory pressure was normal, but that does not establish memory pressure immediately before the stall.

Review found concrete defects independently of the machine-wide cause:

- Each new analyzer compiled fresh temporary model bundles and never cleaned those files. Repeated tests amplified compilation and storage churn.
- Thumbnail extraction waited indefinitely for a native callback and did not forward cancellation; replacement work could wait behind a stalled request.
- The app build script copied over a potentially running signed executable before completing signing.

No OS service, global model cache, original footage or unrelated app was deleted or modified during investigation.

## Revised safeguards and current verification

The revised code includes:

- A serial, bounded process pool of at most two compiler-produced model identities. Raw source hashes, native model loading and contracts are validated before pool admission/reuse. Failed validation evicts the entry. Arbitrary host `.mlmodelc` caches remain ignored.
- Ownership cleanup on failed compilation and final lease release. Normal-exit cleanup tries its lock without waiting for a stalled compiler and explicitly removes cached owned files. A forced kill or active/stalled compiler at exit can still leave temporary files for OS cleanup. This is not a persistent cross-launch cache or a promise to remove Apple's own specialization caches.
- Native thumbnail/HDR image cancellation forwarding, an eight-second logical deadline and exactly-once continuation completion. At most two native requests may remain outstanding; timed-out work retains its permit until the native callback finishes. Late callbacks cannot publish into newer UI work. These controls cannot force hung OS/driver work to stop.
- Utility-priority analysis and explicit CPU compatibility. Model release is handed to utility work where possible; this is not proof every native teardown runs away from the main thread. Synchronous Core ML compilation/inference still has cooperative cancellation boundaries.
- Launch only prefills a query. Real-model tests refuse to run alongside the interactive search app. Packaging signs/verifies a staged bundle, then renames it into place and preserves the previous bundle.
- Dark-row contrast and preview-width fixes with regression checks.

**12 lightweight tests passed after these changes**, without real model inference or media decoding: compiler reuse/ownership, failed validation eviction, nonblocking exit during simulated stalled compilation, native callback timeout/cancellation/outstanding-request bounds, source hashing, visible-candidate selection, missing-model admission and empty-window layout. Relevant failures were observed before each resource fix.

The release build, development bundle signing verification and runtime dependency audit are recorded separately in the structured report. These are build/link checks, not hardware runtime acceptance. Independent static review found no remaining Important/Critical findings after corrections.

**Full native suite and revised real-footage UI flow remain unrun after the incident.** The app is deliberately left closed. The next controlled trial should establish the triggering action and use explicit CPU compatibility first if investigating the inference path; native decode/playback still needs separate observation. No claim of freeze resolution, production readiness, reference HDR approval or minimum-macOS validation is made.

## Reproduction when ready

```sh
./Scripts/build.sh -c release
./Scripts/build-search-app.sh
./Scripts/verify-dependencies.sh
# This opens the app but performs no search until Search/Return:
./.build/release/pxl-search-app --compute cpuOnly \
  --models .work/semantic/models --index /absolute/path/index.json --query "a room"
# Run real-model tests only with the app closed and after the stability investigation permits:
PXL_SEMANTIC_MODELS="$PWD/.work/semantic/models" \
PXL_SEARCH_INDEX=/absolute/path/index.json \
PXL_PLAYBACK_SOURCE=/absolute/path/camera-original.MOV ./Scripts/test.sh
```

The versioned sidecars and original [semantic benchmark](semantic-search.md) remain compatible. The v0.7 timing/device measurements are historical evidence; they are not fresh latency/stability measurements of this revised build.

## App identity and interface pass — 14 October 2026

The draft app now has a mint/cyan glass pixel-and-play icon, an About panel, charcoal surfaces, compact analysis controls, labelled matches/preview panes, empty-workspace guidance and selected-result outlines. Pixel Deck, Sirius and Zogg were read-only visual references; only PXLmpeg changed. The core libraries, inference/device policy, index schema and playback behaviour were not changed by this pass.

Artwork, original generation prompt and macOS packaging derivatives are tracked in [`assets/app-icon`](../../assets/app-icon/README.md). The native bundle declares `CFBundleIconFile` and packages the ICNS before signing; the header uses that icon in bundled launches and the four-pixel vector identity in unbundled launches. `Scripts/build-app-icon.sh` can reproduce all sizes with Apple tools.

Verification: release app build, staged ad hoc signing/strict verification and zero-third-party package/runtime audit passed. The UI suite ran without model/media environment variables: **4 passed, 8 skipped, 0 failures**. Empty-workspace layout was checked at 1160 × 760 and 920 × 620; a native AppKit bitmap was visually inspected. That bitmap uses the unbundled vector header and contains no private footage. ICNS decoding confirms the packaged resolution family. No revised model inference, real-footage playback, Dock/Finder appearance acceptance or full hardware regression was performed; the app remains closed and the whole-Mac stability investigation remains open.

## Local installation — 14 October 2026

The user requested installation. The latest development bundle was staged into `/Applications/PXLmpeg Search.app`, checked for matching executable/plist/icon SHA-256 against the build, strictly signature-verified before and after placement, and registered with Launch Services. No previous installation at that path was present. The app was not launched.

Installation inspection found that bundle packaging and the unbundled launch fallback checked `manifest.json`, while the actual analyzer/downloader use `download-manifest.json`. Both discovery checks now use the actual filename. A rebuilt, signed bundle was verified to include the absolute external model directory and its existing manifest before installation. No model compilation/inference, footage decoding, full regression suite, Gatekeeper/notarization acceptance or freeze-resolution test was performed. Models remain outside the app, at the developer cache location; moving/deleting that cache requires choosing a new folder through Models.

## Editor timecode admission correction — 14 October 2026

An interactive screenshot exposed the strict processing inspector rejecting an ordinary editor export. Two supplied exports were inspected read-only: a 65.365-second 1920 × 1080 MOV and a 231.659-second 1080 × 1080 MP4, each with H.264 video, stereo 48 kHz AAC and an additional `tmcd` timecode track. No original was changed; before/after SHA-256 checks pass for both.

A package-scoped read-only track policy now permits editor timecode tracks for the semantic sampler and native playback. Processing, inspection for export, transcode and remux retain their strict default and reject timecode rather than silently discarding it. The optional `AssetDescriptor.timecodeTracks` count records the track without changing schema v1; legacy descriptors without that field remain readable. Search/playback timestamps remain source presentation timestamps; this change does not read or map SMPTE timecode values.

Every selected source now passes metadata and valid video-range admission before model compilation/loading begins. Preflight discards inspection handles and creates no readers/decoders. Sampling reinspects after the source hash, preserving the existing before/after source-content check. Inspection errors identify the source filename and unsupported track layout. Selected file names replace the initial empty guidance, with refresh on selection/phase changes.

The original source-admission and UI-state failures were reproduced before correction. Afterward, **25 lightweight checks passed, 8 model/media-dependent checks skipped, 0 failures**: both actual exports pass metadata admission, processing rejects their timecode, broken footage fails before a missing model directory is touched, invalid video ranges reject, old descriptor JSON decodes, and source selection updates the UI. A separate final UI/admission run for the MP4 passed 10 checks with 8 skips. Release app build, strict development signature verification and system-dependency audit passed. Static review has no remaining Important/Critical findings after sharing video-range admission.

The corrected bundle was installed over the prior development app using staged copy/verification and a preserved prior bundle, then registered with Launch Services. It was left closed. No real model compilation/inference, frame sampling, real-footage playback or full native regression was run for this correction. Timecode-bearing playback uses the corrected admission path but still needs a controlled runtime trial; the whole-Mac freeze remains unresolved.

## Action-button contrast correction — 14 October 2026

The user's screenshot showed disabled Index/Search labels fading into AppKit's translucent mint accent bezels. Those two controls now use an app-only `NSButton` subclass with opaque paired colors: dark text on mint when enabled, secondary light text on charcoal when disabled, plus disabled-reason tooltips. Native target/action, keyboard and accessibility behaviour remain inherited; sizing, pressed appearance and focus-ring drawing are explicit. Admission and analysis behaviour are unchanged.

The no-model UI suite passed **5 checks, 8 skipped, 0 failures**. A temporary, noncommitted visual probe rendered both button states without dispatching actions; the native bitmaps were inspected. Nominal solid-color text contrast is 14.05:1 enabled and 7.26:1 disabled; these are palette calculations, not an accessibility certification of the whole app. Normal/minimum window layout, release build, staged strict signature verification and the dependency audit passed. Static review found no Important/Critical issues. No model or real-footage operation was run.

The corrected development bundle was installed atomically with the previous installed bundle preserved. The already running instance was left untouched; quitting and reopening is required to load the new drawing code.

## PXL monogram icon refinement — 14 October 2026

The user compared PXLmpeg with their existing app family, liked a blue/violet sculpted glass X exploration (v2), then requested overlapping P, X and L inspired by a 1970s Japanese design book. The exact book was not supplied or identified; the original v3 monogram uses that general direction. V1 and v2 artwork remain preserved; the v3 master, native family, Icon Composer source and exact generation prompt are tracked under `assets/app-icon`.

The installed legacy-only icon initially resolved with a white backing plate on this Mac. Native Icon Composer assets now declare an explicit dark base, are compiled with Apple's `actool`, and are bundled as `Assets.car` alongside the legacy ICNS. Both `CFBundleIconName` and `CFBundleIconFile` identify PXLmpeg. Build number 4 distinguishes the corrected packaging. A fresh NSWorkspace icon-resolution capture of the installed app was visually inspected and shows the intended dark housing; this is an OS-resolved icon check, not a live Dock screenshot. The 64-pixel derivative was also inspected.

The no-model UI suite passed **5 checks, 8 skipped, 0 failures**. Release build, icon asset compilation, shell syntax, strict staged/installed signature verification, installed executable/plist/icon/catalog SHA-256 comparisons and the zero-third-party package/runtime audit passed. The app-only text fallback now reads PXL for unbundled launches. No media engine, inference or playback behavior changed. No model/footage operation or app launch was performed; the earlier stability investigation remains open.
