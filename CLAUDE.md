# CLAUDE.md — Vision Clother

Operational guide for Claude Code execution in this workspace.

## 1. Project Overview
Vision Clother is a mobile-first AI stylist providing scenario-based flatlay recommendations via a local deterministic rules engine and visual try-on layering.

**Core Invariant:** The LLM strictly acts as an intent/constraint extractor (outputting validated JSON). The LLM NEVER receives the wardrobe inventory. Combinatorics, scoring, and filtering are performed entirely via local, unit-tested deterministic code.

## 2. Dev Build & Test Commands

### iOS Client (SwiftUI) — the only build target for V1
The Xcode project lives at the repo root.
* **Build:** `xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build`
* **Test:** `xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator test`

## 3. Reference Docs
Read the relevant doc **before** modifying a layer:
* Structural specs & metadata/rules: `PRD.md`
* iOS layer architecture & persistence: `docs/ios/architecture.md`
* Domain vocabulary (slots, formality, ghost elements, scoring): `docs/domain/vision-clother-concepts.md`
* Coding conventions (testing, error handling, wire schemas, API keys): `docs/approach/conventions.md`
* V1 resolved decisions (LLM driver, diffusion provider, state store): `docs/decisions/resolved-v1.md`

## 4. Key Invariants (Details in Subdirectory CLAUDE.md Files)
* **Schema bounds:** Explicit `CodingKeys` on all wire types — see `Models/CLAUDE.md`
* **Scoring isolation:** `Domain/PairCompatibilityScoring.swift` is mockable, NaN-safe, ghost-element-identical — see `Domain/CLAUDE.md`
* **Async boundaries:** Fal pipeline uses explicit `TryOnState` + bounded poll budget, never bare unbounded loops — see `Services/CLAUDE.md`

## 5. Workflow Rules
* Always propose a plan before making changes to 3+ files.
* Run `xcodebuild clean build` after every implementation task.
* Use Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest.

## Build Tool
Always verify builds with XcodeBuildMCP after any Swift change.
Never mark a task done until `xcodebuild` returns 0 errors.
