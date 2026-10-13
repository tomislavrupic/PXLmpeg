# Interactive Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reusable local interactive playback with a native Mac demo.
**Architecture:** Optional PXLPlayback owns a main-actor AVPlayer backend and AppKit AVPlayerLayer surface, independent of processing jobs. Generation identifiers invalidate replaced work and seeks.
**Tech Stack:** Swift 6, AVFoundation, AppKit; no third-party dependencies.
**Spec:** docs/superpowers/specs/2026-10-13-pxlmpeg-playback.md

## Global constraints

- macOS 15 declared floor; current-Mac validation only.
- Original files are read-only. Host owns access lifetimes and app state.
- Backend and memory/hardware limits are explicit; no custom Metal playback claim.

## Review focus

- Replacement/close during pending open and seek must not resurrect stale content.
- Cancellation and reentrant observation callbacks must terminate exactly once.
- End/replay and audio-longer-than-video files use the native item timeline.
- Invalid/missing sources, nonfinite and out-of-range seeks fail explicitly.
- HDR/rotation playback admission does not imply approved display colour.

## Task 1: Session and surface

Files: Package.swift, Sources/PXLPlayback/*, Tests/PXLPlaybackTests/*.
Interface: PlaybackSession.open(_:colourPolicy:), play(), pause(), seek(to:), close(), snapshot and onChange; PlaybackView(session:).
- [x] Write native behavioral tests; run and observe missing module failure.
- [x] Implement bounded asynchronous session operations and direct native surface.
- [x] Verify native playback and failure/race tests.

## Task 2: Demo and integration

Files: Sources/PXLPlayer/*, README.md, docs/integrations/sirius-preview.md, site/index.html.
- [x] Implement open-file, play/pause, timeline and audio controls using Task cancellation on replacement.
- [x] Build release, run full suite and dependency audit; validate iPhone original read-only.
- [x] Update truthful docs/site; fresh whole-change review and address important findings.
- [x] Commit, push and verify Pages deployment under existing user authorization.

Implementation published in `cc29af9`; Pages workflow `38402178555` succeeded, and the live site returned the v0.6 playback/research content.
