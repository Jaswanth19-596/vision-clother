# Resolved V1 Decisions

Historical architectural decisions locked for V1. Read this when you need the *why* behind a current constraint.

## LLM Driver: OpenRouter + minimax/minimax-m3
- OpenRouter provides a single OpenAI-compatible endpoint for model-hopping without code changes.
- minimax-m3 selected for cost-effective structured JSON output via `response_format: json_schema`.
- The LLM is used **only** as an intent/constraint extractor — it never sees wardrobe inventory.

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
