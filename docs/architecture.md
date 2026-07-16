# System Architecture

Vision Clother is, for V1, a **single-target iOS app with no backend service**. Everything described in PRD.md §2's "4-Stage Execution Flow" runs either on-device or as a direct call from the app to a third-party API — there is no Node.js server sitting between the client and those providers.

This document is the system-wide view; see `docs/ios/architecture.md` for the SwiftUI/Swift-specific structure and `docs/domain/vision-clother-concepts.md` for the domain vocabulary and scoring math.

## Why no backend in V1

The project's `CLAUDE.md` originally scaffolded build commands for a `backend/` Node service. That was written before the architecture was actually decided. Once the four blocked guardrails (LLM driver, diffusion provider, iOS persistence, ingestion location) were resolved, every one of them resolved to an **on-device or direct-API-call** answer — so a backend would add infrastructure without a job to do yet. If the app later needs to run the scoring engine server-side (e.g. to share state across a user's devices, or to stop shipping API keys in the client — see `docs/approach/conventions.md`), that's the point to introduce `backend/` for real. See `docs/backend/architecture.md` for what that would look like.

## The 4-Stage Execution Flow (PRD.md §2.1), as actually built

```
┌────────────────────────────────────────────────────────────────┐
│  1. Intent Extraction (OpenRouter, openai/gpt-4o-mini)          │
│     free text + weather  ──▶  StyleConstraints (JSON schema)   │
│     Services/OpenRouterIntentExtractionService.swift            │
└──────────────────────────────┬───────────────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  2. Candidate Retrieval (on-device, SwiftData)                 │
│     StyleConstraints  ──▶  filtered [WardrobeItem]              │
│     + Ghost Element injection for empty slots (PRD §3.2)       │
│     Data/WardrobeRepository.swift, Domain/GhostElementProvider  │
└──────────────────────────────┬───────────────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  3. Permutation & Heuristic Engine (on-device, pure Swift)      │
│     [WardrobeItem]  ──▶  scored, sorted [OutfitCombination]     │
│     Domain/PairCompatibilityScoring.swift,                       │
│     Domain/OutfitRecommendationEngine.swift                     │
└──────────────────────────────┬───────────────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────────┐
│  4. Visual Generation Canvas (OpenRouter, synchronous request)  │
│     [WardrobeItem] + base portrait  ──▶  rendered image         │
│     Services/OpenRouterTryOnRenderService.swift                  │
└────────────────────────────────────────────────────────────────┘
```

**The core invariant holds exactly as PRD.md states it**: stage 1 (the only stage that talks to an LLM) never receives the wardrobe. It only ever sees free text and returns a `StyleConstraints` value. Stages 2–3 are pure, deterministic, on-device Swift with no network access — this is also what makes them unit-testable without mocking a server (see `Vision_clotherTests/`).

## Manual Outfit Pairing with AI Virtual Try-On

A second entry point into stage 4, alongside the engine-recommended flow above: the user manually picks a top and bottom from `ClosetView` (real ingested items only — Ghost Elements have no backing photo file) instead of getting a scored `OutfitCombination` from the recommendation engine, and generates a try-on preview of themselves wearing both.

- **Model**: `ModelConfig.imageToImage` (currently `google/gemini-3.1-flash-lite-image`), a Gemini image-generation model called through OpenRouter — the concrete model behind `Services/OpenRouterTryOnRenderService.swift`'s abstraction. See `docs/decisions/resolved-v1.md` § Diffusion Provider (superseded Fal + fashn/tryon/v1.6) for the history.
- **A single call composes every garment at once.** The base portrait plus one reference image per non-ghost item are sent together as `image_url` parts in one request, with the prompt instructing the model how to layer them (top under outerwear, footwear on the feet, etc.) — no per-garment call chaining. `TryOnRenderService.renderTryOn` takes the full `items: [WardrobeItem]`; footwear/outerwear/headwear/accessories/bags are all visually represented, unlike the superseded FASHN-based plan which only modeled tops/bottoms. This applies to both the manual-pairing flow and the existing recommendation-engine "how does it look on me?" flow (which passes `outfit.items` instead of the whole `OutfitCombination`).
- **Photo validation** (`Services/PersonPhotoValidationService.swift`) runs entirely on-device via Vision framework before anything is sent to OpenRouter — single person (`VNDetectHumanRectanglesRequest`), full body visible (`VNDetectHumanBodyPoseRequest` landmark presence), basic lighting (`CIAreaAverage`). These are heuristic gates, not a quality guarantee.
- **Storage**: the user's portrait is a single fixed file (`Services/UserPortraitStorage.swift`), overwritten on re-capture — no SwiftData row, since presence-on-disk is the only state that exists. The generated preview image itself is never persisted anywhere.
- **"Save this outfit?"** records a positive signal through the existing three-tier feedback tables (`WardrobeRepository.recordPairFeedback`/`recordOutfitFeedback`) — no new SwiftData schema. There is no browsable "saved outfits" list; this only affects future pair-compatibility scoring inputs.

## Data flow ownership

| Concern | Owner | Notes |
|---|---|---|
| Wardrobe inventory, feedback history | SwiftData (`Data/WardrobeRepository.swift`) | Local only. No sync in V1. |
| Constraint extraction | OpenRouter (`ModelConfig.textToText`) | Stateless per-request; no conversation history kept. |
| Compatibility scoring | Pure Swift (`Domain/`) | No I/O — a function of `(inventory, constraints, feedback history)`. |
| Try-on rendering | OpenRouter (`ModelConfig.imageToImage`) | Single synchronous request (120s timeout); no persistent connection, no async poll job. |

## Known limitations of this architecture (flag before shipping)

- **API keys ship in the app bundle** (`Config/Secrets.plist`) for OpenRouter. This is explicitly a dev-only posture — see `docs/approach/conventions.md` § API keys.
- **No cross-device sync.** SwiftData is local to the device; there's no CloudKit/iCloud mirroring wired up yet.
- **Base portrait capture has no dedicated onboarding flow.** It's captured the first time the user opens Manual Outfit Pairing (`Services/UserPortraitStorage.swift`) rather than during first-run onboarding; `DailyAssistantView`'s "how does it look on me?" now reads the same stored portrait, so it'll fail with a normal error state (not crash) if the user hasn't captured one via Manual Outfit Pairing yet.
- **Photo validation is heuristic, not exact.** On-device Vision framework checks (single person, full-body landmarks, basic brightness) can false-accept or false-reject at the margins.
