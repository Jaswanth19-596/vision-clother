# Backend Architecture — Firebase Proxy

`backend/` (Firebase Cloud Functions, Node/TypeScript) exists and holds the OpenRouter and Pexels API keys server-side, so distributed builds (TestFlight/App Store) never ship an extractable provider key. See `backend/README.md` for setup/deploy instructions.

## Why

Every OpenRouter/Pexels call previously went straight from the iOS client to the provider with a key embedded in `Config/Secrets.plist` (`docs/approach/conventions.md`) — dev-only, explicitly flagged as unsafe to distribute. See `docs/decisions/resolved-v1.md`'s "Backend Platform: Firebase" entry for the full decision rationale (App Attest requirement, accounts/sync roadmap) and the alternatives considered (bare Cloudflare Worker, an AI Gateway).

**Correction to an earlier draft of this doc:** Fal was never actually called anywhere in this codebase — `APIKeys.fal` had zero call sites before it was removed. Try-on render (`OpenRouterTryOnRenderService.swift`) and background isolation (`BackgroundIsolationService.swift`'s `OpenRouterBackgroundIsolationService`) both go through OpenRouter, not Fal. The proxy covers **OpenRouter and Pexels only**.

## Design: passthrough proxy + 4 server-side routes, split across 3 Cloud Functions

Three Cloud Functions (`backend/functions/src/index.ts`), each its own Express app (`backend/functions/src/app.ts`'s `buildProxyApp`/`buildHeavyApp`/`buildAccountApp`), grouped by cost/latency profile rather than deployed as one monolithic function:

| Function | Routes | Timeout | Why |
|---|---|---|---|
| `proxyApi` | `/openrouter/chat`, `/openrouter/recommend`, `/pexels/search` | 60s | Timeout is 60s (not the original 15s) because `/openrouter/chat` and `/openrouter/recommend` are real LLM completion calls that routinely exceed 15s |
| `heavyApi` | `/openrouter/tryon`, `/openrouter/images` | 180s | Real image-generation cost, slow upstream — needs headroom on timeout |
| `accountApi` | `/account/delete`, `/iap/verify`, `/entitlement/limits`, `/analytics/config` | 30s | Payments/account-management, isolated so a provider outage or quota spike on the other two can never starve deletes, purchase verification, or config reads |

**CPU/memory/concurrency/`maxInstances`/`minInstances` are centralized in `backend/functions/src/config/scaling.ts`'s `scalingConfig`**, spread into each `onRequest(...)` call in `index.ts` (`...scalingConfig.proxyApi`, etc.) rather than hardcoded per function — capacity is retuned by editing that one file, never `index.ts` itself. All three explicitly set `cpu: 1`: Cloud Functions v2 silently caps `concurrency` at 1 whenever CPU is fractional (the default below 1GiB memory), so `cpu: 1` is required for `concurrency > 1` to have any effect regardless of memory tier.

**Current values are early-development defaults sized for ~10 active users** (not yet the 1,000-concurrent-user production target), with `minInstances: 0` on all four for scale-to-zero:

| Function | memory | concurrency | maxInstances | Max in-flight (concurrency × maxInstances) |
|---|---|---|---|---|
| `proxyApi` | 256MiB | 5 | 3 | 15 |
| `heavyApi` | 512MiB | 2 | 2 | 4 |
| `accountApi` | 256MiB | 5 | 3 | 15 |
| `wardrobeImageProcessing` | 512MiB | 2 | 4 | 8 |

Before scaling toward production traffic, raise these values in `scaling.ts` (a prior pass sized `proxyApi`/`heavyApi`/`accountApi` at 512MiB–1GiB memory with concurrency 40–80 and `maxInstances` 20–30 for a ~4,800 in-flight ceiling — treat that as the production reference point, not these dev defaults).

All three share the same request pipeline (`app.ts`'s `baseApp()`: request-id + logging → `verifyAuth`) and are `invoker: "public"` at the Cloud Run/IAM layer for the same reason the original single function was — the real auth gate is `middleware/verifyAuth.ts` (Firebase ID token bearer), not IAM. Governance (rate limit + credit gate) is deliberately NOT in `baseApp()` — see "Credit gate middleware" below. `proxyApi` and `heavyApi` bind `openRouterApiKey`/`pexelsApiKey` as needed; `accountApi` binds no provider secrets since none of its four routes call OpenRouter or Pexels.

**iOS client impact:** `Config/ProxyConfig.swift` now holds three base URLs (one per function) instead of one — see that file's TODO for filling in the real per-function URLs after `firebase deploy --only functions`.

These 9 routes fall into two categories:

### Passthrough proxy routes (5)

These hold API keys server-side and forward requests verbatim — no business logic past `verifyAuth`:

| # | Route | Upstream | Middleware |
|---|---|---|---|
| 1 | `POST /openrouter/recommend` | `https://openrouter.ai/api/v1/chat/completions` | `prefetchPreLLMReads()` → `idempotencyGate("RECOMMENDATION")` → `responseCache("recommendation")` → `creditGate("RECOMMENDATION")` |
| 2 | `POST /openrouter/tryon` | `https://openrouter.ai/api/v1/chat/completions` | `idempotencyGate("IMAGE_GEN")` → `creditGate("IMAGE_GEN")` |
| 3 | `POST /openrouter/chat` | `https://openrouter.ai/api/v1/chat/completions` | `rateLimitOnly` |
| 4 | `POST /openrouter/images` | `https://openrouter.ai/api/v1/images` | `idempotencyGate("IMAGE_GEN")` → `creditGate("IMAGE_GEN")` |
| 5 | `GET /pexels/search` | `https://api.pexels.com/v1/search` | `rateLimitOnly` |

Routes 1, 2, and 4 are credit-gated (real generation cost) via `creditGate`; 3 and 5 are uncapped beyond `rateLimitOnly`'s daily guardrail. `/openrouter/recommend` and `/openrouter/tryon` reuse the same `openrouterChatRouter` handler as `/openrouter/chat` — the separate mount points exist solely to attach per-operation `idempotencyGate`, `creditGate`, and `responseCache` middleware. `/openrouter/images` is the dedicated-Images-API branch the try-on and background-isolation services fall back to when `ModelConfig.isChatCompletionImageModel` is false.

Each passthrough route: verify Firebase Auth ID token → governance (`rateLimitOnly` daily cap, or `creditGate` credit/cap check on the 3 credit-gated routes) → optional idempotency gate / response cache → loose top-level body-shape check (Zod) → model allowlist check (see "Model allowlist" below) → inject the real provider key → forward verbatim → return the upstream status/body unchanged. On `/openrouter/recommend` specifically, `prefetchPreLLMReads()` (`middleware/prefetchGates.ts`) runs first and kicks off the response-cache lookup, the pricing-config read, and the model-allowlist read all at once — see "Pre-LLM read prefetch" below — so those three independent reads overlap with `idempotencyGate`'s lock-claim transaction instead of stacking sequentially after it.

### Credit gate middleware: `middleware/creditGate.ts` + `pricing.config.ts`

Replaces the earlier `middleware/governance.ts`'s `governanceGate`/`refundQuota` (guest/free/premium fixed monthly counters plus separate per-feature purchased balances). The credit & tier management engine is a **split fungible wallet** per user — `subscription_credits_remaining` (the tier's monthly/one-time allocation, refilled by `autoReset`) and `purchased_credits_remaining` (IAP top-ups, never reset) — with per-operation costs and tier definitions (`UPLOAD`/`IMAGE_GEN`/`RECOMMENDATION`; `GUEST`/`FREE`/`PRO` and any ops-added tier) resolved from `pricing.config.ts` — Firestore-backed (`config/pricing`) with a hardcoded fallback, same pattern as "Model allowlist" below. `middleware/governance.ts` is trimmed to just `rateLimitOnly` (the coarse daily request cap, unrelated to credits). The wallet is split (rather than one pool) for Apple IAP compliance: a paid consumable top-up must remain the user's property until spent, and a single pool that a subscription's monthly reset flat-overwrites would otherwise silently erase it.

- **`rateLimitOnly`** — unchanged; mounted on every route with no per-operation credit cost (`/openrouter/chat`, `/pexels/search`, and all four `accountApi` routes).
- **`creditGate(operation)`** — mounted on the 3 credit-gated routes instead of `rateLimitOnly`. Always transactional (`runTransaction` over `users/{uid}/meta/usage`, no warm-instance fast-path cache — costs/tiers are now config-driven and can change at ops pace, so the old fixed-safety-margin cache trick doesn't generalize; an accepted latency/Firestore-cost tradeoff for correctness). Runs, in order: (1) lazy init/migration for a doc with no `tier_id` yet (new account, or a pre-rewrite legacy user — see `docs/timeline.md`'s migration write-up), (2) billing reset for recurring (`autoReset: true`) tiers past their `billing_cycle_start` monthly anniversary — refills `subscription_credits_remaining` only, `purchased_credits_remaining` is never touched by this step, (3) hard-cap check (`tierConfig.hardCaps[operation]` vs this cycle's usage count — this is how GUEST's `IMAGE_GEN` block is expressed, no special-cased guest logic), (4) credit-balance check (`OPERATION_COSTS[operation]` vs `totalCredits(subscription, purchased)`). Returns `429 { error: "cap_reached" }` / `429 { error: "insufficient_credits" }` / allows through, debiting the operation's cost from `subscription_credits_remaining` first and only drawing on `purchased_credits_remaining` for any remainder, incrementing the usage counter — only on the allowed outcome does the transaction write anything, same minimalism as the old `governanceGate`. `refundCredit` (called by `idempotency.ts` on a downstream failure) now runs inside its own `runTransaction` and restores credits to the exact bucket(s) the original debit drew from (recorded on `req.quotaDebit.subscriptionDebited`/`purchasedDebited`), plus decrements the usage counter.
- **`pricing.config.ts`** — `OPERATION_COSTS` and `TIER_CONFIGS` (each tier: display name, monthly price, credit allocation, `autoReset`, optional per-operation hard caps, wardrobe item cap). Firestore-backed (`config/pricing`), hardcoded `DEFAULT_OPERATION_COSTS`/`DEFAULT_TIER_CONFIGS` fallback, **1-minute** warm-instance TTL cache (shortened from 5 minutes so an ops price/cap change propagates to every warm instance quickly), stale-cache-preferred-on-failure — never fails open. Ops can retune a cost or add a brand-new tier (e.g. a test `ULTRA_PRO`) by writing to `config/pricing`, with zero backend redeploy or code change.

`users/{uid}/meta/usage` now holds `tier_id`, `subscription_credits_remaining`, `purchased_credits_remaining`, `billing_cycle_start`, `usage_counts` (a map, one entry per operation type), `welcome_pack_claimed`, plus `rateLimitOnly`'s own `dayKey`/`dailyRequestCount` — all writes field-scoped `merge: true` (or `FieldValue.increment`), never a full-doc overwrite, so `rateLimitOnly`, `creditGate`, and `iapVerify.ts`'s top-up grant stay commutative on the same doc. `iapVerify.ts` only ever increments `purchased_credits_remaining`. `users/{uid}/meta/entitlement` (the old tier field) is legacy and no longer written — kept read-only for `creditGate`'s one-time migration lookup.

`backend/firestore.rules`' `itemCap()` now reads `config/pricing` **live** via `get()` as the primary source of truth for a tier's item cap (this works because Rules' `get()`/`exists()` calls bypass the target document's own security rules — that restriction only gates client-initiated requests to that document directly), with the previous hardcoded per-tier numbers demoted to an emergency fallback used only if `config/pricing` doesn't exist yet. A tier added *only* via `config/pricing` is therefore fully enforced at the rules layer immediately too — no hand-edit/redeploy needed.

### Model allowlist: `modelAllowlist.ts`

`openrouterChatRouter`/`openrouterImagesRouter` (and therefore every route that mounts them — 1, 2, 3, 4) previously accepted any non-empty `model` string and forwarded it to OpenRouter with the project's own API key — combined with free/unlimited Firebase anonymous guest-account creation (`AuthService.ensureGuestSession()`) and `rateLimitOnly`'s per-uid-only cap, a scripted caller could mint guest accounts and drive real spend by always requesting the most expensive model available. `modelAllowlist.ts`'s `getAllowedModels(requestId)` (the current allowlist, cache-aware) + `isModelAllowed(model, allowedModels)` (the exact-match check) close this, called right after the route's Zod body-shape check and before the upstream `fetch()`. A rejected model gets `403 { error: "model_not_allowed" }`, distinct from the existing `400 { error: "invalid_request_body" }` (a well-formed, authenticated request rejected on policy, not a malformed one). On `/openrouter/recommend`, the router awaits `req.modelAllowlistPrefetch` (see "Pre-LLM read prefetch" below) instead of calling `getAllowedModels` fresh; every other route has no prefetch and calls it directly.

The allowlist is Firestore-backed (`config/openrouterModels`, `{ allowedModels: string[] }`) so ops can add a newly adopted model — the client's model names are Remote-Config-hotfixable with no app rebuild, see "AI model hotfix via Firebase Remote Config" in `docs/backend/conventions.md` — without a backend redeploy: write the updated list to that doc via the Firebase Console or an Admin SDK/MCP tool. A hardcoded `DEFAULT_ALLOWED_MODELS` array in `modelAllowlist.ts` is the fallback-of-last-resort (used when the doc doesn't exist yet, is malformed, or Firestore is unreachable with no prior cache), so the feature works correctly with zero manual seeding. A module-scope, 5-minute-TTL in-memory cache (same pattern as `governance.ts`'s warm-instance cache, simplified to a single global slot since there's only one config doc) avoids a Firestore read on every request; on a Firestore read failure, a still-cached-but-expired value is served in preference to the hardcoded defaults, so a transient outage doesn't transiently un-allow a model ops added between deploys. This never fails open to "allow everything."

`config/openrouterModels` is a new top-level, Admin-SDK-only Firestore collection (`backend/firestore.rules` denies all client read/write) — this is the first global (non-`users/{uid}`) config doc in this codebase; see the "Three kinds" → "Four kinds" comment at the top of `firestore.rules`.

### Pre-LLM read prefetch: `middleware/prefetchGates.ts` (route 1 only)

`/openrouter/recommend` used to run `idempotencyGate` → `responseCache` → `creditGate`'s pricing-config read → `creditGate`'s debit transaction → the router's model-allowlist read fully sequentially before ever calling OpenRouter — up to 4-5 stacked Firestore round trips of pure latency tax. Two of those steps (`idempotencyGate`'s lock claim, and the debit half of `creditGate`'s transaction) atomically read *and* write, and the debit must never fire before `idempotencyGate` has confirmed the request isn't a duplicate/racing one — that ordering is a correctness requirement, not an artifact of code structure, so those two stay sequential. The other three — `responseCache`'s doc lookup, `creditGate`'s pricing-config read, and the model-allowlist read — are pure, side-effect-free reads with no dependency on `idempotencyGate`'s outcome.

`prefetchPreLLMReads()` is mounted first in the `/openrouter/recommend` chain (before `idempotencyGate`) and kicks off all three of those reads immediately, stashing each as an in-flight promise on `req` (`responseCachePrefetch`/`pricingConfigPrefetch`/`modelAllowlistPrefetch`, `types.ts`). They run concurrently with `idempotencyGate`'s transaction instead of after it. `responseCache.ts`, `creditGate.ts`, and `openrouterChat.ts` each prefer their own prefetched promise over a fresh call when present; every other route (no prefetch mounted) falls back to fetching fresh, unchanged. If `idempotencyGate` ends up short-circuiting (a `COMPLETED` replay or an in-flight `conflict`), the three prefetched promises are simply never consumed — a wasted read, never a wasted write. None of the three prefetched calls can reject (`getPricingConfig`/`getAllowedModels` already catch every Firestore error internally; `responseCache.ts`'s `lookupResponseCache` is written the same way), so there's no unhandled-rejection risk in the window before a downstream middleware awaits them.

### Idempotency protection (routes 1, 2, 4 only)

`middleware/idempotency.ts`'s `idempotencyGate(operation)` sits in front of `creditGate`/`responseCache` on the three credit-gated routes, closing a real-money concurrency gap: these upstream calls routinely take 60-180s, and a client retry, network flake, or app backgrounding/kill during that window would otherwise re-send the request, debiting credits and paying OpenRouter twice for one user action.

Every request to these three routes must carry an `X-Idempotency-Key` header (iOS: `Services/ProxyAuthHeaders.swift`, a fresh UUID minted once per logical upstream attempt — reused by URLSession-level retries of that same attempt, but never reused across `OutfitRecommendationService`'s structured→unstructured fallback, which is a genuinely different request). Missing the header is a `400`.

Lock doc `idempotencyKeys/{uid}_{idempotencyKey}` (Admin-SDK-only, `firestore.rules` denies all client access — mirrors `processedTransactions/{transactionId}` in `routes/iapVerify.ts`), keyed atomically inside a `runTransaction`, same pattern as that file:
- Doc missing, or `status: "FAILED"` — lock acquired (`status: "IN_PROGRESS"`), request proceeds to `creditGate`/upstream.
- `status: "IN_PROGRESS"` — a duplicate arrived while the first attempt is still in flight: `409 Conflict`, no quota touched, no second upstream call.
- `status: "COMPLETED"` — the exact response (status/content-type/body) from the original attempt is replayed verbatim; `creditGate` and OpenRouter are never reached again.

On the request finishing (`res.send` wrapped, not `res.on("finish")`, so the exact response body can be cached for a future replay): a 2xx marks the lock `COMPLETED` with the cached payload; anything else marks it `FAILED` and, if `creditGate` actually debited credits for this request (`req.quotaDebit`, set by `creditGate.ts` at the moment of debit), calls `creditGate.ts`'s `refundCredit` to undo exactly that debit (the exact cost, `FieldValue.increment`d back) — so a failed paid call never permanently costs the user credits.

### Server-side routes with business logic (4)

These are **deliberate exceptions** to the passthrough posture, each individually justified in code comments (see `app.ts`):

| # | Route | What it does | Why it can't be client-side |
|---|---|---|---|
| 6 | `POST /account/delete` | Bulk Firestore recursive delete, Storage prefix wipe, Auth user deletion | Requires Admin SDK privileges the client can never safely hold; doing N separate client-side deletes would be slow and half-finished on a dropped connection |
| 7 | `POST /iap/verify` | StoreKit 2 JWS verification + Firestore transactional credit grant | The `users/{uid}/meta/usage` balance doc is server-only-write — the one mutation that must never be client-reachable — and deduplication (via `processedTransactions/{transactionId}`) must be atomic with the credit increment |
| 8 | `GET /entitlement/limits` | Resolves the caller's tier → concrete credit/cap numbers (`{tier, creditsRemaining, creditAllocation, operationCosts, operationCaps, billingCycleStart, autoReset, itemCap}`) | Prevents the client from hardcoding a tier→number table that could drift from `middleware/creditGate.ts`'s enforcement; read-only, no mutation |
| 9 | `GET /analytics/config` | Returns analytics confidence/unlock thresholds | Same rationale as entitlement/limits — prevents client/server threshold drift; read-only, wrapped in `responseCache("analyticsConfig")` |

> **Important:** every one of these exceptions was added as a "deliberate exception" to the original thin-proxy charter. The pattern of exceptions is how thin proxies drift toward accidental monoliths. Before adding a new server-side route, verify it genuinely requires Admin SDK privileges or server-only-write access — if it doesn't, keep the logic client-side and use the passthrough path.

### Storage-triggered functions (1)

Not an HTTP route — `wardrobeImageProcessing` (`backend/functions/src/index.ts`, handler in `backend/functions/src/triggers/wardrobeImageProcessing.ts`) is a Cloud Storage `onObjectFinalized` trigger, the first non-HTTP function in this codebase. It's the server-side counterpart to the client-only resize pipeline described in `docs/decisions/resolved-v1.md`'s "Cloud Sync" section (`ImageStorage.swift`'s `downscaledPNGForUpload`/`downscaledJPEGForUpload`), and is a deliberate exception to that section's former "no backend involvement" framing for the same reason the 4 HTTP routes above are exceptions to the passthrough charter: it needs Admin SDK write access the client can never safely hold (a client-writable thumbnail path would defeat the point of a server-generated, consistent variant).

Fires on every finalized object in the default bucket (v2 Storage triggers have no path-glob filtering) and filters to `users/{uid}/wardrobeImages/{fileName}` internally, no-op'ing on everything else, including its own writes back into the bucket. Two independent guards prevent a self-trigger loop: (1) the path regex structurally excludes the `thumbnails/` sub-path its own thumbnail write lands in; (2) its normalize-in-place overwrite (see below) is tagged with custom metadata (`vcNormalized: "1"`) that the handler checks first and no-ops on, so the re-triggered finalize event on that overwrite doesn't recurse.

Does two things per original upload, both via `sharp`:
1. **Thumbnail generation** — a ~384px-longest-edge variant written to `users/{uid}/wardrobeImages/thumbnails/{fileName}` (owner-read, client-write-false — `backend/storage.rules`), so grid/list views (`Vision_clother/Vision_clother/Vision_clother/DesignSystem/CachedWardrobeImage.swift`) never need to download the full ~1024px asset.
2. **Upload normalization** — if the original's longest edge exceeds ~1126px (10% over the 1024px target), it's re-encoded down to 1024px and overwritten in place. A safety net for a buggy/outdated client build that skipped or failed its own downscale — previously nothing server-side ever inspected an upload, so the entire storage/bandwidth budget rested on client behavior alone.

**Region requirement:** Cloud Functions v2 Storage triggers must run in the same region as the Storage bucket or the trigger silently fails to bind, with no other signal. This codebase pins no region anywhere else (all four functions default/explicitly assume `us-central1`) — verify this against the `visionclother` project's actual default bucket region before the first deploy of this function.

**Logging:** uses the same `logEvent` (`logger.ts`) convention as every other backend module, but since a Storage trigger has no inbound HTTP request, it logs the Storage object's `objectName`/`generation` in place of a route/`requestId` join key (`thumbnailGen.start`/`thumbnailGen.finish`/`thumbnailGen.failed`). Fails open — a processing error is logged and swallowed, never thrown, since an uncaught throw in an event-triggered function causes Cloud Functions to keep re-delivering the same finalize event.

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

Security rules (`backend/firestore.rules`) deny all client reads/writes on the governance/entitlement/idempotency collections since only the Admin SDK (Cloud Functions) touches them. `users/{uid}/responseCache` (the per-uid caching subcollection `middleware/responseCache.ts` writes to) gets the same server-only-write treatment as `meta/usage`/`meta/entitlement` — owner-read, deny-write — since a client-forged cache entry there would let an account serve itself a fabricated response and skip `creditGate`/the paid OpenRouter call entirely. A minimal sign-in section exists (`Features/Profile/AccountSectionView.swift`, wired into the Profile tab) — Google and Phone are the two providers; account linking across providers is not implemented.
