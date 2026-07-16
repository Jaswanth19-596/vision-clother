# Backend Architecture — Firebase Proxy

`backend/` (Firebase Cloud Functions, Node/TypeScript) exists and holds the OpenRouter and Pexels API keys server-side, so distributed builds (TestFlight/App Store) never ship an extractable provider key. See `backend/README.md` for setup/deploy instructions.

## Why

Every OpenRouter/Pexels call previously went straight from the iOS client to the provider with a key embedded in `Config/Secrets.plist` (`docs/approach/conventions.md`) — dev-only, explicitly flagged as unsafe to distribute. See `docs/decisions/resolved-v1.md`'s "Backend Platform: Firebase" entry for the full decision rationale (App Attest requirement, accounts/sync roadmap) and the alternatives considered (bare Cloudflare Worker, an AI Gateway).

**Correction to an earlier draft of this doc:** Fal was never actually called anywhere in this codebase — `APIKeys.fal` had zero call sites before it was removed. Try-on render (`OpenRouterTryOnRenderService.swift`) and background isolation (`BackgroundIsolationService.swift`'s `OpenRouterBackgroundIsolationService`) both go through OpenRouter, not Fal. The proxy covers **OpenRouter and Pexels only**.

## Design: thin passthrough, 3 routes

One Cloud Function (`api`, `backend/functions/src/index.ts`) serving three HTTPS routes via Express (`backend/functions/src/app.ts`):

1. `POST /openrouter/chat` → `https://openrouter.ai/api/v1/chat/completions`
2. `POST /openrouter/images` → `https://openrouter.ai/api/v1/images`
3. `GET /pexels/search` → `https://api.pexels.com/v1/search`

Each route: verify Firebase Auth ID token → per-uid rate limit (Firestore counter) → loose top-level body-shape check (Zod) → inject the real provider key → forward verbatim → return the upstream status/body unchanged.

This is intentionally **not** one Cloud Function per iOS service. All prompt/schema construction (`Config/ModelConfig.swift`'s `Prompts` enum, each service's JSON Schema) stays client-side, exactly as before — the proxy does no business logic (see `docs/backend/conventions.md`). Six iOS services all point at the same `/openrouter/chat` or `/openrouter/images` route:

| Service | File | Route |
|---|---|---|
| `OpenRouterIntentExtractionService` | `Vision_clother/Services/OpenRouterIntentExtractionService.swift` | `/openrouter/chat` |
| `OpenRouterOutfitRecommendationService` | `Vision_clother/Services/OutfitRecommendationService.swift` | `/openrouter/chat` |
| `OpenRouterVisionMetadataExtractionService` | `Vision_clother/Services/VisionMetadataExtractionService.swift` | `/openrouter/chat` |
| `OpenRouterUserProfileDerivationService` | `Vision_clother/Services/UserProfileDerivationService.swift` | `/openrouter/chat` |
| `OpenRouterTryOnRenderService` | `Vision_clother/Vision_clother/Services/OpenRouterTryOnRenderService.swift` | `/openrouter/chat` or `/openrouter/images` (branches on model, `ModelConfig.isChatCompletionImageModel`) |
| `OpenRouterBackgroundIsolationService` | `Vision_clother/Services/BackgroundIsolationService.swift` | `/openrouter/chat` or `/openrouter/images` |
| `PexelsImageFeedService` | `Vision_clother/Services/StockImageFeedService.swift` | `/pexels/search` |

## Auth

- **Firebase Auth:** Google Sign-In and Phone Number sign-in (`Services/AuthService.swift`) — `ServiceFactory` gates every real-vs-mock service choice on `AuthService.shared.isSignedIn`, replacing the old API-key-presence gate. Sign in with Apple is deferred (needs a paid Apple Developer account for the capability) — see `docs/decisions/resolved-v1.md`.
- **Google Sign-In:** the native `GoogleSignIn-iOS` SDK, not a generic web-redirect OAuth flow — configured via `Config/FirebaseBootstrap.swift` (`GIDSignIn.sharedInstance.configuration`) and the `REVERSED_CLIENT_ID` URL scheme in `Config/URLSchemes.plist`.
- **Phone Number sign-in:** no APNs auth key is configured (also paid-account-gated), so it always falls back to Firebase's reCAPTCHA-in-Safari verification rather than silent push — this needs the app's bundle ID registered as a second URL scheme (also in `Config/URLSchemes.plist`) so the verification redirect returns to the app.
- **App Check is deferred** — App Attest needs a paid Apple Developer account to configure; the debug provider alone would no-op in release. Revisit once a paid account exists.
- **Token attachment:** `Services/ProxyAuthHeaders.swift` builds `Authorization: Bearer <ID token>` for every proxied request. Per `Services/CLAUDE.md`'s "raw URLSession, no SDK" rule, the Firebase Auth SDK is used only to mint the token — the actual HTTP calls stay on plain `URLSession`, not `httpsCallable`.
- **`Vision_clotherApp.swift`'s `onOpenURL`** routes both the Google consent redirect (`GIDSignIn.sharedInstance.handle(url)`) and the phone-auth reCAPTCHA redirect (`Auth.auth().canHandle(url)`) back into the app.

## What NOT to do

Don't move `Domain/PairCompatibilityScoring.swift` or `Domain/OutfitRecommendationEngine.swift` server-side — no credentials touch that layer, and the offline-first requirement assumes it runs locally regardless of backend choice. Don't add business logic (prompt construction, response validation) to the proxy — see `docs/backend/conventions.md`.

## Not yet built

Firestore (Standard edition, project `visionclother`) is used only for the rate-limit counter — no wardrobe sync exists yet. Security rules (`backend/firestore.rules`) deny all client reads/writes since only the Admin SDK (Cloud Functions) touches it. Cross-device sync is a separately-scoped future feature once accounts are actually exercised end-to-end. A minimal sign-in section exists (`Features/Profile/AccountSectionView.swift`, wired into the Profile tab) — Google and Phone are the two providers; account linking across providers is not implemented.
