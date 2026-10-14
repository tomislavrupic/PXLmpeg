# Selected PL identity and public site refresh

Date: 2026-10-14

The user selected the proportional v5 PL icon, requested a corrected infographic and authorized GitHub publication and landing-page updates. The built-in imagegen edit produced [signal-flow v2](../../assets/pxlmpeg-signal-flow-v2.png); [exact prompt and input roles](../../assets/pxlmpeg-signal-flow-v2.prompt.md). The former artwork remains preserved. The search return now targets Pixel Deck transport, separate from audio routing.

## Publication boundary

- Research implementation and all selected artwork: `3d6b89c03cf2f1dc165785239fd8fd9639c00988` on `codex/native-search-ui-research`.
- Site/assets/roadmap-only publication: `2d9fd9a793370b1237db309c6703716788901f37` on `main`. The native search implementation was not merged. PR #1 remains a draft.
- [GitHub Pages deployment](https://github.com/tomislavrupic/PXLmpeg/actions/runs/38622649538): completed successfully.
- [Public site](https://tomislavrupic.github.io/PXLmpeg/): HTTP 200 and byte-for-byte matches against the prepared HTML, CSS, JavaScript, selected 1024/64/256-pixel icon assets and infographic.

The page foregrounds professional media for Pixel Deck, labels ProRes/PCM as next and MXF/XAVC as research, and describes the search UI as a draft with an open stability investigation. Its v0.7 measurements are explicitly historical, not a fresh regression result. No new codec, AI capability or production download is advertised.

## Verification

Release app build, native icon compilation, strict staged/installed signatures, installed binary/plist/icon/catalog SHA-256 matches, shell syntax, dependency audit and diff checks passed. The installed build number is 6; NSWorkspace resolved the selected v5 icon with dark backing. The preceding local bundle is preserved. No app launch or model/media runtime operation was performed.

The static site built successfully. Browser inspection at 1440 and 390 pixels found no horizontal overflow. Desktop and mobile layouts, the transcode/copy switch, command-copy action and anchor navigation were checked. Live browser inspection confirmed the selected identity, professional-media copy and loaded 1774 × 887 signal-flow image. These checks do not establish media-engine or whole-Mac stability.
