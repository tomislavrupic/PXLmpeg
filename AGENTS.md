# PXLmpeg development safety

Source media is immutable. The user explicitly requires disposable copies for
all development playback, decode, analysis, metadata and acceptance tests.

## Required workflow

- Run every code/file mutation, formatter, build and Git write through
  `python3 Scripts/safe-dev.py edit -- <executable> <arguments...>`.
  For Pixel Deck use `--workspace` with that repository's real absolute path.
  The child receives an OS sandbox that denies file writes outside the selected
  repository and its dedicated temp folder, with narrow Apple tool cache/atomic-save
  paths required by this macOS; it denies writes to staged media and registered
  originals and prevents their ancestor directories being renamed or removed.
  Edit mode may read existing unsymlinked fixture output JSON reports for docs;
  staged inputs and private manifests remain denied.
- Stage a source only with `python3 Scripts/safe-dev.py stage /real/source/path`.
  It opens the original O_RDONLY, copies bytes to a fresh ignored fixture,
  verifies SHA-256 and records a receipt. Never hard-link or reuse originals.
  Do not open originals with write-capable tools, run ad hoc media scripts on
  them, change their permissions, delete them, or mount their drive writable.
- Run media operations with `python3 Scripts/safe-dev.py probe --fixture
  /absolute/fixture/path -- <executable> <arguments...>`. Only fixture/output is
  writable for media output, with the same narrow Apple tool cache/atomic-save
  exceptions. Use PXL_DISPOSABLE_SOURCE/PXL_DISPOSABLE_OUTPUT inside the child.
  The selected copy is read-only, all registered originals and external volumes
  are denied reads, and other staged fixtures cannot be read by that probe.
- Build separately with edit mode, then execute prebuilt validation binaries in
  probe mode. Verify the copy hash with `safe-dev.py verify` afterwards.
- Never use `exec()`/`eval()` to import probe scripts, share editor/probe globals,
  interpolate destination variables into shells, or infer a write path from a
  media path. Use explicit repository paths and isolated subprocess arguments.
- Do not bypass a sandbox denial or retry unprotected. Diagnose the exact
  necessary development/output path. Keep media protection in place. If the
  platform sandbox is unavailable, stop instead of running without protection.
- Run `python3 Tests/test_safe_dev.py` after guard changes. Its external files
  are explicitly synthetic decoys. Do not test denial by trying to write to
  an actual original.

This guard protects its child processes; it does not restrict the whole Codex
session or other apps. Maintain the command boundary and report this limitation.
Do not install or open an unrestricted app as evidence of protected validation.
Preserve unrelated dirty changes in both research repositories.
