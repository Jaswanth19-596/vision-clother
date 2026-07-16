# Coding Conventions

Practical conventions this codebase actually follows, derived from how the iOS scaffold was built. See `docs/ios/architecture.md` for the layer structure these conventions apply within.

## Testing

- **Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.** The project template already used Swift Testing for its default test file (`Vision_clotherTests/Vision_clotherTests.swift`) — stay consistent with that rather than mixing frameworks.
- **`Domain/` is tested with zero mocking.** Every test constructs plain `WardrobeItem`/`StyleConstraints` values and calls the pure function directly — no `ModelContext`, no network, no `Mock*` service. If a `Domain/` change requires a mock to test it, that's a sign the function has an I/O dependency that belongs in `Data/` or `Services/` instead.
- **No test or `#Preview` may require a real API key.** `Services/ServiceFactory.swift` exists specifically so tests/previews always get `Mock*` implementations by default; the real `OpenRouterIntentExtractionService`/`OpenRouterTryOnRenderService` are only reachable through that factory when a key is actually configured.

## Error handling

- **Every failure mode gets a named case in a typed `Error` enum**, not a bare `throw SomeGenericError()` or a silently-swallowed `try?` in a place a user would notice. Compare `IntentExtractionError` (`.missingAPIKey`, `.network`, `.httpStatus`, `.emptyChoices`, `.decoding`) and `TryOnError` (`.missingAPIKey`, `.network`, `.renderFailed`, `.timedOut`, `.cancelled`) — each case maps to a specific `errorDescription` the UI can show directly.
- **Decide retry behavior per failure class, not per call site.** `OpenRouterIntentExtractionService` retries automatically exactly once, only for `.decoding`/`.emptyChoices` (a one-off provider hiccup) — never for `.network`/`.httpStatus` (more likely a real outage, where an immediate retry just doubles the wait). Don't add ad-hoc retry loops elsewhere; extend the service's own retry policy instead.
- **Long-running async work gets an explicit state enum**, not a bare `async throws` the caller has to guess a loading state around. `TryOnState` (`idle`/`submitting`/`polling(elapsedSeconds:)`/`succeeded`/`failed`) is the pattern to follow for any future multi-step async operation (e.g. a real ingestion pipeline) — note that `OpenRouterTryOnRenderService` itself only drives `submitting` → `succeeded`/`failed` (a single synchronous request, no real poll loop); `polling` is reserved for a genuinely multi-step provider and is currently only exercised by `MockTryOnRenderService`'s simulated delay.
- **New OpenRouter-backed services clone the existing resilience pattern, not their own.** `Services/OutfitRecommendationService.swift` and `Services/UserProfileDerivationService.swift` (added in the 2026-07-10 LLM-as-Recommender reversal) follow `OpenRouterIntentExtractionService`'s exact shape: try `response_format: json_schema` first, one silent retry on `.emptyChoices`/`.decoding`, then a prompt-embedded-schema fallback with its own single retry, and an HTTP 400 jumping straight to that fallback. Each still gets its own named `Error` enum per the rule above — don't share one across services.

## Wire schemas

- **Every JSON-facing type gets explicit `CodingKeys`** mapping to the exact snake_case field names in `PRD.md` (see `StyleConstraints`) — don't rely on a global snake-case decoding strategy, since some payloads (OpenRouter's own response envelope) are already camelCase-free JSON that doesn't need the mapping.
- **Non-standard JSON shapes get a custom `Codable` implementation**, not a workaround at the call site. `FormalityRange` decodes/encodes as a bare 2-element array (matching `formality_range: [min, max]` in PRD §3.3) via a hand-written `init(from:)`/`encode(to:)` rather than asking every caller to unwrap an array themselves.

## API keys (dev-only — see `docs/architecture.md` § Known limitations)

- Real provider keys never go in code, in `Info.plist`, or in anything tracked by git — they live in `Config/Secrets.plist`, which is gitignored. `Config/Secrets.example.plist` is the only template that gets committed.
- Any code reading a key must treat "key present but blank" and "key file missing" identically (`Services/APIKeys.swift`'s `value(for:)` returns `nil` for both) — never crash or throw just because `Secrets.plist` hasn't been filled in yet; fall back to the mock service instead (`ServiceFactory`).
- **Local Path Fallback (Debug):** During simulator execution, if the bundle resource `Secrets.plist` fails to load (due to target copy issues), `APIKeys.value(for:)` has a fallback under `#if DEBUG` to read directly from the absolute workspace file path `/Users/jaswanth/mydocs/ios-apps/vision_clother/Vision_clother/Vision_clother/Config/Secrets.plist`.
- Before any distributed build, this whole mechanism needs to be replaced — see `docs/architecture.md` and `CLAUDE.md` §5.

## Ghost elements (PRD §3.2)

Ghost elements are **scored identically to real items** — never add an `isGhostElement` branch to anything in `Domain/PairCompatibilityScoring.swift` or `Domain/OutfitRecommendationEngine.swift`. If ghost-item provenance needs to affect behavior, that belongs in the UI layer (a badge, a label) via `OutfitCombination.containsGhostElements` / `WardrobeItem.isGhostElement`, not in the math.
