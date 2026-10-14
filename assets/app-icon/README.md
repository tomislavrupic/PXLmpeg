# PXLmpeg app identity

The mint/cyan glass pixel-and-play icon was generated with the built-in imagegen tool on 14 October 2026. Pixel Deck, Sirius and Zogg icon artwork supplied visual references for their shared dark housing, luminous glass and fine technical details. No source code or artwork was copied from those products into this app.

- `PXLmpeg-master.png`: original generated artwork, retained unchanged.
- `PXLmpeg.png`: 1024-pixel derivative for previews.
- `PXLmpeg.icns`: native macOS icon family, 16 through 1024 pixels.
- `prompt.md`: generation prompt and reference roles.

Regenerate the packaged sizes using `Scripts/build-app-icon.sh` (Apple `sips` and `iconutil` only). `Scripts/build-search-app.sh` includes the icon in the development bundle before signing it. The app header uses the bundle icon; an unbundled CLI launch uses the existing four-pixel vector motif.

The icon does not change the research status of the app. No notarized distribution is implied.
