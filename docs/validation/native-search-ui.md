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
