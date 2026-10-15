# Development media isolation

All development media tests use independent disposable copies. Originals are
opened read-only only by the staging reader. Engine libraries themselves keep
read-only input handles; this developer guard adds a separate OS boundary around
editing, builds and validation processes.

## Commands

Run from the PXLmpeg checkout on macOS with Python 3 and sandbox-exec available:

```sh
# Copy bytes into a fresh ignored directory; print its absolute fixture path.
python3 Scripts/safe-dev.py stage /absolute/path/to/camera-file.mxf

# Build/test synthetic fixtures with only development locations writable.
python3 Scripts/safe-dev.py edit -- Scripts/test.sh --disable-sandbox \
  --cache-path .build/SafeCache --config-path .build/SafeConfig \
  --security-path .build/SafeSecurity

# Use the fixture path printed above. The shell expands these inside the guard.
python3 Scripts/safe-dev.py probe --fixture /absolute/fixture/path -- \
  /bin/bash -c '.build/debug/pxl-prores probe "$PXL_DISPOSABLE_SOURCE" > "$PXL_DISPOSABLE_OUTPUT/probe.json"'

python3 Scripts/safe-dev.py verify /absolute/fixture/path
python3 Tests/test_safe_dev.py
```

Do not set real-footage test variables to original paths. Build separately, then
run prebuilt real-media checks in probe mode. That mode provides
`PXL_DISPOSABLE_SOURCE`, `PXL_TEST_XAVC_SOURCE` and `PXL_DISPOSABLE_OUTPUT`.
The staged file is mode 0444; SHA-256, source/copy identities and copy method are
recorded in its private manifest. Copies use streamed byte I/O, exclusive output
creation and different file identities; no hard links or shared writer handles.
A changed source during copying is rejected. Verification never reopens the
original. Staging one file does not copy its camera-card sidecars.

Pixel Deck builds use `--workspace /absolute/Pixel-Deck-checkout`; add
`--with-pxl-package` only when Xcode needs to update local PXLmpeg package build
state. Both are explicit repository allowlist entries. Their real paths must be
unsymlinked. Native research Xcode builds also need
`-IDEPackageSupportDisableManifestSandbox=YES` and the compiler's
`-disable-sandbox` flag to avoid unsupported nested sandbox application on the
validated Mac. These disable inner tool sandbox setup; the outer file guard
remains active and inherited by directly launched children.

## Enforced boundary

- Edit children cannot read external volumes, staged inputs or registered originals.
  They cannot write outside the selected development repository,
  optional PXL package checkout, dedicated task temp and the named Apple build
  cache/temp exceptions. Existing unsymlinked JSON reports directly in fixture
  output directories are readable for preparing validation documentation; inputs
  and private manifests remain denied.
- Staging children can write only their newly allocated fixture tree. Originals
  are opened O_RDONLY/O_NOFOLLOW and cannot be a writable destination.
- Probe media output is writable only in that fixture's output directory.
  Registered originals and their inputs remain protected. External volumes,
  ordinary home media directories, other Documents projects and other staged
  fixtures are denied reads.
- Write denials also cover registered originals located inside an otherwise
  writable repository. Protected ancestor directories cannot be renamed or
  removed to relocate those paths outside the policy.
- Apple tools ignore TMPDIR for some caches and atomic saves on this OS. The
  guard therefore permits the SwiftPM compiler cache in edit mode, xcrun cache files, named
  NSIRD tool directories, Swift temporary/build directories (including TemporaryDirectory and swbuild.tmp) and an identifiable
  synthetic compiler-test subtree. It never grants the entire system temp tree
  or a source volume write access. Registered originals remain explicitly denied
  even if located in a permitted cache/temp location.
- Missing sandbox support, invalid fixtures and source identity changes fail
  closed. Do not retry an operation without the guard after a denial.

Eight synthetic safety tests check normal allowed writes, direct truncation,
symlink/hard-link escapes, original-read denial, input protection, independent
copies, provenance and protected-ancestor relocation. Test files are harmless
explicit decoys, not user originals.

## Limits

The guard restricts launched child processes, not the entire assistant session,
other apps or independent system services. Probe reads use explicit exclusions,
not a complete filesystem read allowlist. Keeping all mutation and media commands
behind this entry point remains necessary. Do not use Launch Services `open` as
protected validation: execute the research app binary directly inside probe mode.
No source volumes are remounted and no original permissions are changed.
Python and sandbox-exec are development tools; the Swift media core gains no
third-party runtime dependency. Protection was verified on the current Mac;
other OS/toolchain versions must pass the decoy tests before use.
