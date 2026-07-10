# Backend Architecture — Not Built in V1

There is no Node.js backend in this codebase yet, and no `backend/` directory exists. `CLAUDE.md`'s original `backend/` build commands (`npm install`, `npm run typecheck`, `npm test`, `npm run lint`) describe a service that hasn't been scaffolded — don't create one without an explicit instruction to do so.

## Why

See `docs/architecture.md` for the full reasoning. In short: all four previously-blocked architecture decisions (LLM driver, diffusion provider, iOS persistence, ingestion location) resolved to **on-device Swift or a direct client → third-party-API call** — OpenRouter for intent extraction, Fal.ai for try-on rendering, SwiftData for local persistence. None of that needs a server sitting in the middle.

## When a backend would become necessary

The current architecture has one real limitation that a backend directly addresses: **OpenRouter and Fal API keys ship inside the iOS app bundle** (`Vision_clother/Vision_clother/Config/Secrets.plist`), which is explicitly a dev-only posture (see `docs/approach/conventions.md`). Before any real distribution (TestFlight, App Store), a thin proxy backend should exist that:

1. Holds the OpenRouter and Fal API keys server-side (never shipped to the client).
2. Exposes two endpoints mirroring the two client-side service protocols already defined — `POST /intent` (wrapping `IntentExtractionService`) and `POST /try-on` (wrapping `TryOnRenderService`).
3. Requires no changes to `Domain/` — the recommendation/scoring engine stays on-device regardless (the core invariant — the LLM never sees the wardrobe — doesn't change just because the LLM call is proxied).

Because both client-side services are already hidden behind protocols (`Services/OpenRouterIntentExtractionService.swift`, `Services/FalTryOnRenderService.swift`), swapping in a "call our own proxy instead of OpenRouter/Fal directly" implementation later is a contained change — implement a new conformance to `IntentExtractionService`/`TryOnRenderService` and swap it in `Services/ServiceFactory.swift`.

## What NOT to do

Don't move the deterministic scoring engine (`Domain/PairCompatibilityScoring.swift`, `Domain/OutfitRecommendationEngine.swift`) server-side as part of adding a proxy. That engine has no reason to leave the device — it doesn't touch any credentials, and PRD.md §5's offline-first / SQLite-persisted-state requirement assumes it runs locally.
