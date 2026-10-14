# Semantic Search Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, with one fresh whole-change review.

**Goal:** Native local semantic indexing and timestamped text search, validated on real footage and profiled for ANE.
**Architecture:** Optional PXLAnalysis owns model admission, a serial worker, explicit frame sampling, records and Core ML encoders. pxl-search exposes index/query/profile commands. Core libraries do not depend on analysis.
**Tech Stack:** Swift 6, Core ML, AVFoundation, Core Image/Core Graphics, CryptoKit; no third-party runtime.
**Spec:** docs/superpowers/specs/2026-10-14-semantic-prototype.md

## Global constraints

- macOS 15 floor remains declared; current-Mac verification only.
- Original footage and other repositories are read-only.
- Model/tokenizer assets stay outside Git; record pinned provenance.
- Planned device allocation and measured execution are distinct evidence.

## Review focus

- Oversized/malformed indexes, token limits and nonfinite vectors must fail before unbounded work.
- Cancellation/replacement cannot publish a partial index or mix model identities.
- Missing colour, HDR conversion, rotation and actual PTS must be explicit.
- Unsupported model inputs/tokenizer data and zero embeddings must fail clearly.
- Runtime traces may expose only partial device execution; reports must not overclaim coverage.

## Task 1: Contracts, tokenizer and ranking

Files: Sources/PXLAnalysis/{Records,Tokenizer,Search}.swift; Tests/PXLAnalysisTests/*; Package.swift.
Interface: Tokenizer.encode(_:) -> [Int32]; SemanticIndex/FrameEmbedding/SearchHit; normalized vector validation and search.
- [x] Write failing conformance/ranking/malformed/length tests and observe red.
- [x] Implement bounded validated records, original CLIP BPE tokenizer and cosine search.
- [x] Verify green and pinned tokenizer conformance.

## Task 2: Core ML, sampling and CLI

Files: Sources/PXLAnalysis/{Analyzer,Model,Sampler,ComputePlan}.swift; Sources/PXLSearchCLI/*; Scripts/fetch-semantic-model.py.
Interface: SemanticAnalyzer.index/query/computePlan; pxl-search index/query/profile.
- [x] Write failing native sampling and optional real-model lifecycle tests.
- [x] Implement matched model identity, serial cancellable operations, explicit image preprocessing and atomic new sidecar publication.
- [x] Verify real footage indexing and expected search candidates with actual timestamps.

## Task 3: Validation and publication

Files: docs/validation/semantic-search.md, docs/architecture/semantic-analysis.md, README.md, site/index.html.
- [x] Compare S0/S2 and CPU/ANE/all timings on real samples; capture runtime trace and audit its schema/evidence.
- [x] Run full regression/release/dependency checks; independent review and address important issues.
- [x] Sanitize evidence and update truthful docs/site.
- [x] Commit/push and verify deployment.

Verification: 86 tests passed with real models/camera, zero failures/skips; release build and three-product dependency audit passed. Independent review addressed and cleared important issues. Public evidence excludes paths/media/weights/raw traces.

Publication: feature commit `bac8426c25c4083b1cd4979f31177c8a1759a1b4` pushed to public main. [Pages run 38571205797](https://github.com/tomislavrupic/PXLmpeg/actions/runs/38571205797) succeeded. Live v0.7 site verified at 390/1440 px, assets HTTP 200, no horizontal overflow or console errors.
