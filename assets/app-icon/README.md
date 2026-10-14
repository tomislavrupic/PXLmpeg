# PXLmpeg app identity

## Proportion study: v5

The user's next refinement asks for more harmony and a smaller L. [V5 preview](v5/PXLmpeg.png) shortens and lightens the L and brings its right edge closer to the P bowl. [Imagegen edit prompt](v5/prompt.md). This is a visual candidate; packaging still references v4.

## Current packaged asset: v4 shared-spine PL

The active icon combines P and L into one sculpted glass sign with a shared vertical spine, open P counter and strong L baseline. The user explicitly removed X from the previous PXL exploration. Ice-blue faces, violet depth, a quiet dark housing and the family resemblance to Pixel Deck and Zogg remain.

Generated with the built-in imagegen tool on 14 October 2026:

- `v4/PXLmpeg-master.png`: original generated artwork, unchanged.
- `v4/PXLmpeg.png`: 1024-pixel preview derivative.
- `v4/PXLmpeg.icns`: native macOS family, 16 through 1024 pixels.
- `v4/PXLmpeg.icon/`: native Icon Composer source with explicit dark backing.
- [`v4/prompt.md`](v4/prompt.md): exact edit prompt and reference role.

`Scripts/build-app-icon.sh` defaults to v4; an optional folder argument selects another master/derivative folder. Apple's `sips` and `iconutil` derive the legacy size family. `Scripts/build-search-app.sh` compiles the [native icon asset](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer) with `actool`, bundles `Assets.car` plus legacy ICNS and sets both icon-name keys before signing. Bundle build number 5 identifies the PL refinement. Explicit dark backing avoids the white plate observed with legacy-only assets on this Mac. The app header uses bundled artwork; the unbundled CLI fallback reads PL.

The monogram direction grew from the user's reference to a 1970s Japanese symbol-design book. That exact book was not identified or supplied; this is an original geometric sign rather than a reproduction of a particular book or trademark.

## Preserved versions

- `v3/`: overlapping PXL exploration, retained with its artwork, native source and prompt.
- `v2/`: interlocking glass X exploration. The user liked its material treatment, then refined the sign.
- Root `PXLmpeg-master.png`, `PXLmpeg.png`, `PXLmpeg.icns` and `prompt.md`: unchanged v1 mint pixel/play design, also present in earlier banners/architecture illustrations as historical artwork.

No source code or artwork was copied from the reference products into the app. Artwork changes do not change early research status or establish notarized distribution.
