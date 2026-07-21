# Services Layer

All services implement a protocol-first pattern.
- API clients use raw URLSession (no SDK) with typed Codable request/response.
- OpenRouter calls: model comes from `Config/ModelConfig.swift` (`textToText`, `imageToText`, `imageToImage` — one constant per call shape, edit there to swap models), always try `response_format: json_schema` first, fall back to prompt-embedded schema.
- Try-on rendering (`OpenRouterTryOnRenderService`): a single synchronous OpenRouter request (120s timeout), not an async submit/poll job — all garments for an outfit go in one call as reference images, not chained one-per-garment. `TryOnState` still models a `polling` case for the UI, but the real service never emits it (only `MockTryOnRenderService`'s simulated delay does).
- API keys come from Secrets.plist (see Config/ directory).
- `StylistQAService` (wardrobe/Insights Q&A) reuses `ProxyConfig.openRouterRecommendURL` — the same quota-gated route `OutfitRecommendationService` uses, since the proxy gates by path, not payload shape — with its own separate, smaller prompt (`Domain/StylistQABrain.swift`). Never extend `Domain/StylistBrain.swift`'s recommendation prompt to also answer questions.
