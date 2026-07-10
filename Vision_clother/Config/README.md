# Config/Secrets.plist

Dev-only API keys, read at runtime by `Services/APIKeys.swift`. **`Secrets.plist` is gitignored** — this file only exists locally and is bundled into the app so the OpenRouter/Fal services can pick up real keys during local development.

## Setup

1. Copy `Secrets.example.plist` to `Secrets.plist` (already done for you — `Secrets.plist` ships with blank placeholder values so the project builds out of the box using the mock services).
2. Fill in your keys:
   - `OPENROUTER_API_KEY` — from [openrouter.ai](https://openrouter.ai) (used by `Services/OpenRouterIntentExtractionService.swift`)
   - `FAL_API_KEY` — from [fal.ai](https://fal.ai) (used by `Services/FalTryOnRenderService.swift`)
3. Rebuild. With blank keys, `APIKeys.swift` returns `nil` and the app should be wired (in the ViewModel layer) to fall back to `MockIntentExtractionService` / `MockTryOnRenderService`.

## ⚠️ Do not ship this

Embedding provider keys in the app bundle is acceptable **only** for personal development and testing on your own device. **Never** distribute a build (TestFlight, App Store, or otherwise) with real keys in `Secrets.plist` — anyone with the `.ipa` can extract them. Before any real distribution, move these calls behind a thin proxy backend that holds the keys server-side (see CLAUDE.md §5).
