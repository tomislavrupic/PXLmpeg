# PXLmpeg app identity

## Current selected asset: v5 proportional PL

The user selected [v5](v5/PXLmpeg.png): P and L share one vertical spine, with a shorter, lighter L and a more compact footprint. The ice-blue glass, violet depth and dark housing preserve the app-family direction. [Exact imagegen edit prompt](v5/prompt.md).

Generated with the built-in imagegen tool on 14 October 2026:

- `v5/PXLmpeg-master.png`: original generated artwork, unchanged.
- `v5/PXLmpeg.png`: 1024-pixel preview derivative.
- `v5/PXLmpeg.icns`: native macOS family, 16 through 1024 pixels.
- `v5/PXLmpeg.icon/`: native Icon Composer source with explicit dark backing.

`Scripts/build-app-icon.sh` defaults to v5; an optional folder argument selects another master/derivative folder. Apple's `sips` and `iconutil` derive the legacy size family. `Scripts/build-search-app.sh` compiles the native icon with `actool`, bundles `Assets.car` plus legacy ICNS and sets both icon-name keys before signing. Bundle build number 6 identifies the selected proportional PL. Explicit dark backing avoids the white plate observed with legacy-only assets on this Mac. The app header uses bundled artwork; the unbundled CLI fallback reads PL.

The monogram direction grew from the user's reference to a 1970s Japanese symbol-design book. That exact book was not identified or supplied; this is an original geometric sign rather than a reproduction of a particular book or trademark.

## Preserved versions

- `v4/`: first shared-spine PL, retained with its original longer L.

- `v3/`: overlapping PXL exploration, retained with its artwork, native source and prompt.
- `v2/`: interlocking glass X exploration. The user liked its material treatment, then refined the sign.
- Root `PXLmpeg-master.png`, `PXLmpeg.png`, `PXLmpeg.icns` and `prompt.md`: unchanged v1 mint pixel/play design, also present in earlier banners/architecture illustrations as historical artwork.

No source code or artwork was copied from the reference products into the app. Artwork changes do not change early research status or establish notarized distribution.
