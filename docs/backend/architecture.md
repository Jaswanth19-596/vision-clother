# Backend Architecture — Firebase Proxy

`backend/` (Firebase Cloud Functions, Node/TypeScript) exists and holds the OpenRouter and Pexels API keys server-side, so distributed builds (TestFlight/App Store) never ship an extractable provider key. See `backend/README.md` for setup/deploy instructions.

## Why

Every OpenRouter/Pexels call previously went straight from the iOS client to the provider with a key embedded in `Config/Secrets.plist` (`docs/approach/conventions.md`) — dev-only, explicitly flagged as unsafe to distribute. See `docs/decisions/resolved-v1.md`'s "Backend Platform: Firebase" entry for the full decision rationale (App Attest requirement, accounts/sync roadmap) and the alternatives considered (bare Cloudflare Worker, an AI Gateway).

**Correction to an earlier draft of this doc:** Fal was never actually called anywhere in this codebase — `APIKeys.fal` had zero call sites before it was removed. Try-on render (`OpenRouterTryOnRenderService.swift`) and background isolation (`BackgroundIsolationService.swift`'s `OpenRouterBackgroundIsolationService`) both go through OpenRouter, not Fal. The proxy covers **OpenRouter and Pexels only**.

## Design: passthrough proxy + 4 server-side routes, split across 3 Cloud Functions

Three Cloud Functions (`backend/functions/src/index.ts`), each its own Express app (`backend/functions/src/app.ts`'s `buildProxyApp`/`buildHeavyApp`/`buildAccountApp`), grouped by cost/latency profile rather than deployed as one monolithic function:

| Function | Routes | Config | Why |
|---|---|---|---|
| `proxyApi` | `/openrouter/chat`, `/openrouter/recommend`, `/pexels/search` | 256MiB, 60s timeout, 30 max instances | Low memory and a high instance ceiling for fan-out; timeout is 60s (not the original 15s) because `/openrouter/chat` and `/openrouter/recommend` are real LLM completion calls that routinely exceed 15s |
| `heavyApi` | `/openrouter/tryon`, `/openrouter/images` | 512MiB, 180s timeout, 10 max instances | Real image-generation cost, slow upstream — needs headroom on memory and timeout; capped lower since each instance is costlier |
| `accountApi` | `/account/delete`, `/iap/verify`, `/entitlement/limits`, `/analytics/config` | 256MiB, 30s timeout, 20 max instances | Payments/account-management, isolated so a provider outage or quota spike on the other two can never starve deletes, purchase verification, or config reads |

All three share the same request pipeline (`app.ts`'s `baseApp()`: request-id + logging → `verifyAuth` → `rateLimit`) and are `invoker: "public"` at the Cloud Run/IAM layer for the same reason the original single function was — the real auth gate is `middleware/verifyAuth.ts` (Firebase ID token bearer), not IAM. `proxyApi` and `heavyApi` bind `openRouterApiKey`/`pexelsApiKey` as needed; `accountApi` binds no provider secrets since none of its four routes call OpenRouter or Pexels.

**iOS client impact:** `Config/ProxyConfig.swift` now holds three base URLs (one per function) instead of one — see that file's TODO for filling in the real per-function URLs after `firebase deploy --only functions`.

These 9 routes fall into two categories:

### Passthrough proxy routes (5)

These hold API keys server-side and forward requests verbatim — no business logic past `verifyAuth`:

| # | Route | Upstream | Middleware |
|---|---|---|---|
| 1 | `POST /openrouter/recommend` | `https://openrouter.ai/api/v1/chat/completions` | `idempotencyGate("recommendation")` → `responseCache("recommendation")` → `quotaGate("recommendation")` |
| 2 | `POST /openrouter/tryon` | `https://openrouter.ai/api/v1/chat/completions` | `idempotencyGate("tryOn")` → `quotaGate("tryOn")` |
| 3 | `POST /openrouter/chat` | `https://openrouter.ai/api/v1/chat/completions` | _(none beyond global auth + rate limit)_ |
| 4 | `POST /openrouter/images` | `https://openrouter.ai/api/v1/images` | `idempotencyGate("tryOn")` → `quotaGate("tryOn")` |
| 5 | `GET /pexels/search` | `https://api.pexels.com/v1/search` | _(none beyond global auth + rate limit)_ |

Routes 1, 2, and 4 are quota-gated (real generation cost); 3 and 5 are uncapped beyond the global `rateLimit` guardrail. `/openrouter/recommend` and `/openrouter/tryon` reuse the same `openrouterChatRouter` handler as `/openrouter/chat` — the separate mount points exist solely to attach per-feature `idempotencyGate`, `quotaGate`, and `responseCache` middleware. `/openrouter/images` is the dedicated-Images-API branch the try-on and background-isolation services fall back to when `ModelConfig.isChatCompletionImageModel` is false.

Each passthrough route: verify Firebase Auth ID token → per-uid rate limit (Firestore counter) → optional idempotency gate / quota gate / response cache → loose top-level body-shape check (Zod) → inject the real provider key → forward verbatim → return the upstream status/body unchanged.

### Idempotency protection (routes 1, 2, 4 only)

`middleware/idempotency.ts`'s `idempotencyGate(feature)` sits in front of `quotaGate`/`responseCache` on the three quota-gated routes, closing a real-money concurrency gap: these upstream calls routinely take 60-180s, and a client retry, network flake, or app backgrounding/kill during that window would otherwise re-send the request, debiting quota and paying OpenRouter twice for one user action.

Every request to these three routes must carry an `X-Idempotency-Key` header (iOS: `Services/ProxyAuthHeaders.swift`, a fresh UUID minted once per logical upstream attempt — reused by URLSession-level retries of that same attempt, but never reused across `OutfitRecommendationService`'s structured→unstructured fallback, which is a genuinely different request). Missing the header is a `400`.

Lock doc `idempotencyKeys/{uid}_{idempotencyKey}` (Admin-SDK-only, `firestore.rules` denies all client access — mirrors `processedTransactions/{transactionId}` in `routes/iapVerify.ts`), keyed atomically inside a `runTransaction`, same pattern as that file:
- Doc missing, or `status: "FAILED"` — lock acquired (`status: "IN_PROGRESS"`), request proceeds to `quotaGate`/upstream.
- `status: "IN_PROGRESS"` — a duplicate arrived while the first attempt is still in flight: `409 Conflict`, no quota touched, no second upstream call.
- `status: "COMPLETED"` — the exact response (status/content-type/body) from the original attempt is replayed verbatim; `quotaGate` and OpenRouter are never reached again.

On the request finishing (`res.send` wrapped, not `res.on("finish")`, so the exact response body can be cached for a future replay): a 2xx marks the lock `COMPLETED` with the cached payload; anything else marks it `FAILED` and, if `quotaGate` actually debited usage for this request (`req.quotaDebit`, set by `quota.ts` at the moment of debit), calls `quota.ts`'s `refundQuota` to undo exactly that debit (a plain fast-path count, or a slow-path purchased-balance drawdown) — so a failed paid call never permanently costs the user a recommendation/try-on.

### Server-side routes with business logic (4)

These are **deliberate exceptions** to the passthrough posture, each individually justified in code comments (see `app.ts`):

| # | Route | What it does | Why it can't be client-side |
|---|---|---|---|
| 6 | `POST /account/delete` | Bulk Firestore recursive delete, Storage prefix wipe, Auth user deletion | Requires Admin SDK privileges the client can never safely hold; doing N separate client-side deletes would be slow and half-finished on a dropped connection |
| 7 | `POST /iap/verify` | StoreKit 2 JWS verification + Firestore transactional balance credit | The `users/{uid}/meta/usage` balance doc is server-only-write — the one mutation that must never be client-reachable — and deduplication (via `processedTransactions/{transactionId}`) must be atomic with the balance increment |
| 8 | `GET /entitlement/limits` | Resolves the caller's tier → concrete quota numbers | Prevents the client from hardcoding a tier→number table that could drift from `middleware/quota.ts`'s enforcement; read-only, no mutation |
| 9 | `GET /analytics/config` | Returns analytics confidence/unlock thresholds | Same rationale as entitlement/limits — prevents client/server threshold drift; read-only, wrapped in `responseCache("analyticsConfig")` |

> **Important:** every one of these exceptions was added as a "deliberate exception" to the original thin-proxy charter. The pattern of exceptions is how thin proxies drift toward accidental monoliths. Before adding a new server-side route, verify it genuinely requires Admin SDK privileges or server-only-write access — if it doesn't, keep the logic client-side and use the passthrough path.

### Shared architecture

This is intentionally **not** one Cloud Function per iOS service — the 3-way split above is grouped by cost/latency profile, not by service. All prompt/schema construction (`Config/ModelConfig.swift`'s `Prompts` enum, each service's JSON Schema) stays client-side, exactly as before — the passthrough proxy routes do no business logic (see `docs/backend/conventions.md`). Six iOS services all point at the same `/openrouter/chat`, `/openrouter/recommend`, `/openrouter/tryon`, or `/openrouter/images` routes (now split across `proxyApi`/`heavyApi` per the table above):

| Service | File | Route |
|---|---|---|
| `OpenRouterIntentExtractionService` | `Vision_clother/Services/OpenRouterIntentExtractionService.swift` | `/openrouter/chat` |
| `OpenRouterOutfitRecommendationService` | `Vision_clother/Services/OutfitRecommendationService.swift` | `/openrouter/chat` |
| `OpenRouterVisionMetadataExtractionService` | `Vision_clother/Services/VisionMetadataExtractionService.swift` | `/openrouter/chat` |
| `OpenRouterUserProfileDerivationService` | `Vision_clother/Services/UserProfileDerivationService.swift` | `/openrouter/chat` |
| `OpenRouterTryOnRenderService` | `Vision_clother/Vision_clother/AppWiring/OpenRouterTryOnRenderService.swift` | `/openrouter/chat` or `/openrouter/images` (branches on model, `ModelConfig.isChatCompletionImageModel`) |
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

Don't move `Domain/PairCompatibilityScoring.swift` or `Domain/OutfitRecommendationEngine.swift` server-side — no credentials touch that layer, and the offline-first requirement assumes it runs locally regardless of backend choice. Don't add business logic (prompt construction, response validation) to the **passthrough proxy routes** — see `docs/backend/conventions.md`. The 4 server-side routes documented above (`/account/delete`, `/iap/verify`, `/entitlement/limits`, `/analytics/config`) are deliberate, justified exceptions — don't add new exceptions without verifying the route genuinely requires Admin SDK privileges or server-only-write access.

## Not yet built

Firestore (Standard edition, project `visionclother`) is used only for the rate-limit counter — no wardrobe sync exists yet. Security rules (`backend/firestore.rules`) deny all client reads/writes since only the Admin SDK (Cloud Functions) touches it. Cross-device sync is a separately-scoped future feature once accounts are actually exercised end-to-end. A minimal sign-in section exists (`Features/Profile/AccountSectionView.swift`, wired into the Profile tab) — Google and Phone are the two providers; account linking across providers is not implemented.
