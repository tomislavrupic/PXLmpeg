# PXLmpeg app identity

## Current: v3 overlapping PXL

The active icon combines P, X and L into one sculpted glass sign: P and L share a spine, the P has an open upper counter, X crosses through the middle and L anchors the base. It retains the ice-blue/violet glass and quiet dark housing used by Pixel Deck and Zogg.

The user's direction was an overlapping P-over-X-over-L sign inspired by a 1970s Japanese symbol-design book. The exact book was not identified or supplied. This is an original monogram using that general geometric direction, not a reproduction of a specific book or trademark.

Generated with the built-in imagegen tool on 14 October 2026:

- `v3/PXLmpeg-master.png`: original generated artwork, unchanged.
- `v3/PXLmpeg.png`: 1024-pixel preview derivative.
- `v3/PXLmpeg.icns`: native macOS family, 16 through 1024 pixels.
- `v3/PXLmpeg.icon/`: native Icon Composer source with an explicit dark background.
- [`v3/prompt.md`](v3/prompt.md): exact generation prompt and reference roles.

Regenerate using `Scripts/build-app-icon.sh`; it defaults to `assets/app-icon/v3`. An optional folder argument selects another master/derivative folder. Apple's `sips` and `iconutil` derive the legacy size family. `Scripts/build-search-app.sh` compiles the [native icon asset](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer) with `actool`, includes `Assets.car` plus legacy ICNS, and sets both icon-name keys before signing. Bundle build number 4 identifies the final native packaging. The explicit dark base avoids the white backing plate observed with the legacy-only icon on this Mac. The app header reads the bundled icon; an unbundled CLI launch uses a lightweight PXL wordmark.

## Preserved versions

- `v2/`: the interlocking glass X exploration, with its original artwork, native sizes and prompt. The user liked its material treatment and requested the PXL monogram refinement.
- Root files `PXLmpeg-master.png`, `PXLmpeg.png`, `PXLmpeg.icns` and `prompt.md`: unchanged initial v1 mint pixel/play design. It remains in earlier banners/architecture illustrations as historical artwork.

No source code or artwork was copied from the reference products into the app. Artwork changes do not change the app's early research status or establish notarized distribution.
