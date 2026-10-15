# Disposable-media safeguards before native MXF continuation

User-approved order: establish safeguards first, then resume native playback
using disposable copies only. No original-media writes are authorized.

1. Reproduce the destination-variable mistake using harmless decoys. Verify
   OS sandbox denial for direct writes, symlink escapes, truncation and source
   reads from probes; verify allowed repository/output writes still work.
2. Provide guarded edit, independent read-only staging and probe entry points.
   Record copy provenance/identity/SHA-256; fail closed on absent sandbox or
   changed/symlinked fixture. Check originals only through the staging reader.
3. Persist repository instructions and use guarded children for every subsequent
   mutation/build and every media probe. Preserve existing user changes.
4. Resume the unfinished native reader against a staged alternative FS7 original
   or generated fixture. Finish review findings and malformed-index coverage.
5. Validate native hardware decode, multichannel PCM, seeking and Pixel Deck
   Metal/color/audio-clock behavior within the guard. Record actual verification
   boundaries, then commit/push scoped research changes. Installation is a
   separate boundary and must not run a validation app on original paths.

The guard is a local macOS development tool, not a runtime third-party core
library and not a sandbox around the entire assistant session. Full read
allowlisting prevents process bootstrap on this OS; probes instead deny known
media trees plus every registered original while retaining a strict write
allowlist. All safety tests use disposable decoys, never user originals.
