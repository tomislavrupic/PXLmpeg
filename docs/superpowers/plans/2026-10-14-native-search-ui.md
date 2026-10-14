# Native Search UI Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, then one fresh whole-change reviewer.

**Goal:** A working native footage search window with thumbnails and click-to-play at actual result timestamps.
**Architecture:** Optional PXLSearchUI target composes PXLAnalysis and PXLPlayback; a small executable owns the Mac app lifecycle. Analysis/source checks run off the main actor, UI/playback on it, with task cancellation and generation fencing.
**Tech Stack:** Swift6, AppKit, Core ML, AVFoundation, CryptoKit; no external packages.
**Spec:** docs/superpowers/specs/2026-10-14-native-search-ui.md

## Global constraints
- Declared macOS15 floor; only current M3 Ultra/macOS27 verification.
- Originals/other products read-only; external models remain ignored, no runtime download.
- Core does not depend on the UI. New sidecars never overwrite.
- Existing direct-main publication authorization persists; clean owning checkout verified.

## Review focus
- Replacement/close during native work cannot update old rows or resume wrong playback.
- Changed/missing/FIFO media must fail before playback; no blind trust in sidecar paths.
- Thumbnail errors retain result, but successful thumbnails retain source/timestamp identity.
- Missing models, empty queries and resource caps are actionable UI errors.
- Playback time is actual index PTS, never list rank/request time or inferred event span.

## Task 1: Source verification and search workspace
Files: Sources/PXLAnalysis/SourceVerifier.swift; Sources/PXLSearchUI/{SearchWorkspace,ResultSelection,ThumbnailRenderer}.swift; Tests/PXLSearchUITests/*; Package.swift.
Interfaces: SemanticSourceVerifier.verify(index:) / verify(source:sha256:) async actor methods; @MainActor SearchWorkspace chooses/indexes/opens/saves/searches/cancels/selects and publishes onChange; result rows retain SearchHit and optional CGImage. One analysis task awaited on replacement, independent playback task/generation.
- [x] Write failing source-change/display-selection/missing-model/replacement tests; observe RED.
- [x] Implement source verifier, bounded candidate selection, native thumbnail renderer and workspace.
- [x] Initial GREEN with native models/real sidecar; post-incident revised hardware check pending.

## Task 2: Native window, app and actual result action
Files: Sources/PXLSearchUI/SearchWindowController.swift; Sources/PXLSearchApp/main.swift; Scripts/build-search-app.sh; Tests/PXLSearchUITests/SearchWindowTests.swift.
Interfaces: SearchWindowController(workspace:) renders UI, action button calls workspace.select(result); app parses --models/--index/--query and creates window; build script creates ad hoc .build/PXLSearch.app with external model-folder default only.
- [x] Write failing native window flow test: loaded sidecar -> search -> thumbnail -> perform actual result button action -> correct source/time -> advancing playback.
- [x] Implement compact native controls, menus/panels, errors/status and close teardown.
- [x] Initial real flow/thumbnail/click/advancing playback verified; local capture inspected and initial app launched. Revised app left closed after reported machine stall.

## Task 3: Verification and publication
Files: README.md, docs/validation/native-search-ui.md, version and dependency audit.
- [ ] Full suite with camera/models/real sidecar; release/app build; four-product dependency audit.
- [x] Fresh whole-change review; important cache-admission/shutdown/cancellation/bundle issues fixed with regression evidence.
- [x] Publish sanitized evidence/docs on draft branch `codex/native-search-ui-research`; [draft PR1](https://github.com/tomislavrupic/PXLmpeg/pull/1). Full revised hardware validation remains pending.

Incident steering: hardware tests paused after user-reported whole-Mac stall/reset. Confirmed resource fixes passed12light tests; independent review cleared Important issues. Full revised hardware regression and UI flow remain pending. Preserve work as a draft research branch, not a verified main release.

Build verification: full release build, revised ad hoc bundle sign/strict verification and four-product system-library audit passed.12post-incident light tests passed with no real models/decoding. Original7 sourceSHAvalues unchanged. Full/hardware revalidation remains pending; app not reopened.
