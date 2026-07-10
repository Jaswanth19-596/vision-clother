# Resolved V1 Decisions

Historical architectural decisions locked for V1. Read this when you need the *why* behind a current constraint.

## LLM Driver: OpenRouter + minimax/minimax-m3
- OpenRouter provides a single OpenAI-compatible endpoint for model-hopping without code changes.
- minimax-m3 selected for cost-effective structured JSON output via `response_format: json_schema`.
- The LLM is used as the primary outfit recommender (see "LLM-as-Recommender Reversal" below), plus intent/constraint extraction as the fallback path, plus single-garment vision tagging at ingestion and one-time user-profile derivation from the onboarding portrait.

## LLM-as-Recommender Reversal (2026-07-10)
- **Superseded:** the original V1 decision that "the LLM is used only as an intent/constraint extractor — it never sees wardrobe inventory."
- **New decision:** the LLM is the primary outfit recommender. It receives the user's prompt, a *bounded* catalog of wardrobe item text descriptions (id, slot, formality, color/hex, undertone, pattern, seasonality, fabric weight, short description — never images), the derived User Style Profile, weather, and color-theory guidance, and returns outfit picks by item ID (PRD §3.7).
- **Why:** the deterministic-only engine plateaued on recommendation quality — color matching was a single flat vibrant/vibrant penalty ignoring captured hex values, there was no personalization, and weather was wired but unused. Letting the LLM reason over descriptions (not raw wardrobe images, to control cost) unlocks materially better combination judgment while text-only payloads keep per-request cost bounded.
- **Safety net kept:** `Domain/OutfitRecommendationValidator.swift` hard-rejects any LLM pick referencing an unknown ID, wrong slot, duplicate ID, or Ghost Element, then re-scores survivors with the existing Pair-Compatibility Scoring Engine. `Domain/OutfitRecommendationEngine.swift` (the original deterministic engine) is unchanged and used as a full fallback whenever the recommendation call fails or validation yields zero outfits — the app never surfaces an outfit referencing a garment the user doesn't own, and it fully works offline/keyless.
- **Privacy:** the wardrobe catalog is a bounded text payload (never garment images) sent only when a user has not opted out; the portrait image is sent once per profile derivation, never per recommendation. A settings toggle forces the fully deterministic §2.1 path, skipping the recommendation LLM call entirely.

## Diffusion Provider: Fal + fashn/tryon/v1.6
- Fal chosen for async submit → poll queue pattern with explicit status tracking.
- fashn tryon v1.6 selected for single-garment virtual try-on quality.
- Multi-garment outfits require chaining one call per garment (not batching).

## State Store: SwiftData On-Device
- All persistence via SwiftData `@Model` classes (`WardrobeItem`, `FeedbackEvent`).
- `WardrobeRepository` protocol isolates storage tech from Domain and Features layers.
- No server-side persistence in V1.

## No Node.js Backend in V1
- The deterministic scoring engine runs entirely on-device in Swift.
- API keys are embedded in `Config/Secrets.plist` (gitignored) — acceptable for personal dev only.
- Before any distributed build (TestFlight/App Store), keys must move behind a thin proxy backend. See `docs/backend/conventions.md` for planned architecture.

## Testing Framework: Swift Testing
- Project uses Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
- Domain layer tested with zero mocking — pure function calls with constructed values.
- No test or `#Preview` requires a real API key — `ServiceFactory` returns mocks by default.
