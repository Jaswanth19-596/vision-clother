Vision Clother — Production Readiness Architecture Review

Overall: the code is unusually well-documented and several past defects are visibly already fixed (batched pull/push yields, coarse-grained lock guards, fail-open/fail-closed postures). That said, the system has real structural debt: two duplicated LLM round-trips can fire on a single user turn, a cache invalidation bug can silently serve stale personalization data, quota is debited before the expensive call it gates even runs, and the backend's own "thin proxy" charter has already been violated four times over. None of this is cosmetic — these are the things that will surface first at 10x traffic.

1. Overall Architecture

[High] No server-side hotfix path for AI behavior
Location: docs/backend/conventions.md (mandate), backend/functions/src/routes/openrouterChat.ts, Vision_clother/Domain/StylistBrain.swift
Problem: 100% of prompt construction, JSON schemas, and model selection live client-side (Config/ModelConfig.swift, Domain/StylistBrain.swift). The backend is an intentionally dumb passthrough with zero business logic.
Why it matters: a broken/regressed prompt, a bad model swap, or an OpenRouter schema change can only be fixed by shipping a new App Store build and waiting for review — there is no remote-config or server-mediated way to adjust recommendation behavior in production. For an AI-driven core feature, that's a multi-day MTTR for what should be a same-hour fix.
Recommended fix: keep prompt authorship client-side (correct call for iteration speed today), but put the model name and a couple of prompt-affecting feature flags behind Firebase Remote Config so a bad rollout is a config flip, not a release.

[Medium] Backend has silently outgrown its "thin 3-route proxy" charter
Location: backend/functions/src/app.ts:66-96 vs. docs/backend/architecture.md:11-19
Problem: the docs describe "3 routes, no business logic." The actual buildApp() mounts 9 routes, 4 of which (/account/delete, /iap/verify, /entitlement/limits, /analytics/config) contain real business logic (Admin SDK bulk deletes, StoreKit JWS verification + ledgering, tier resolution).
Why it matters: this isn't wrong on its own (those 3 exceptions are individually justified in comments), but the doc/code drift is a leading indicator — every one of those routes was added as a "deliberate exception," and the pattern of exceptions is how thin proxies become accidental monoliths. There's no test or lint gate enforcing the "no business logic past verifyAuth" rule the docs claim.
Recommended fix: either update the architecture doc to reflect reality (it currently misleads anyone onboarding), or split the two credential-privileged/stateful routes (iap/verify, account/delete) into a second codebase/function so the passthrough proxy stays provably dumb.

[Medium] Monolithic single Cloud Function mixes cheap and expensive/sensitive traffic
Location: backend/functions/src/index.ts:14-26
Problem: one onRequest function (timeoutSeconds: 180, memory: 256MiB, no maxInstances/minInstances/concurrency set) serves Pexels stock-photo search, OpenRouter chat/image generation, IAP verification, and account deletion — all sharing one instance pool and one timeout budget.
Why it matters: at 10x traffic, a burst of cheap /pexels/search calls (browsing stock photos) competes for the same scaling headroom as /iap/verify (checkout-path, must stay responsive) and /openrouter/images (real-money generation). A 180s timeout sized for image generation applies uniformly to a request that should return in 200ms. No maxInstances cap also means a traffic spike or abuse burst scales cost with no ceiling, and no minInstances means every scale-up event pays a cold start (Admin SDK + Apple root-cert parsing on every fresh instance).
Recommended fix: split into at least two functions with independent scaling — a proxy function (chat/images/pexels, short timeout) and an account function (iap/delete, needs different scaling/timeout characteristics) — and set maxInstances on both as a cost backstop.

[Low] Tier/item-cap numbers are structurally duplicated with no shared source
Location: backend/functions/src/entitlementLimits.ts:27-43 vs. backend/firestore.rules:51-54
Problem: ITEM_CAP_LIMITS is hand-copied into Firestore Security Rules because Rules has no module system — the code's own comment admits this ("must stay hand-kept in sync ... by hand"). Currently in sync, but nothing enforces it staying that way.
Why it matters: a future tier-limit change that only touches the TypeScript file silently leaves the enforced Firestore Rules cap stale — either over-permissive (a real security/cost gap) or under-permissive (users hit a wall the client doesn't know about, since /entitlement/limits would report the new number). This is invisible until someone hits it.
Recommended fix: add a CI check that diffs the two literal number sets (a small script comparing entitlementLimits.ts against firestore.rules) so drift fails the build instead of shipping silently.

2. Data Flow

[High] A single user turn can trigger two full, sequential LLM round-trips
Location: Vision_clother/Vision_clother/Features/DailyAssistant/DailyAssistantViewModel.swift:518-524 (resolveTurn), :532-573 (resolveWardrobeQuestion), :575-684 (resolveOutfits)
Problem: QuestionIntentHeuristic.looksLikeWardrobeQuestion triggers on any message starting with "what/how/can/should/…" or ending in "?" — which includes ordinary recommendation requests ("What should I wear to a rooftop party?"). When it fires, resolveWardrobeQuestion does a full network call to StylistQAService (its own catalog rebuild + full InsightsSummaryBuilder aggregation). If the QA model correctly classifies it as isWardrobeQuestion == false (or the call fails), the code falls through to resolveOutfits, which independently rebuilds the catalog from scratch and makes a second, separate LLM call to OutfitRecommendationService.
Why it matters: this is duplicated processing and an unnecessary network call on a code path the docs describe as "adds no latency/cost to a normal 'dress me for X' request" (docs/decisions/resolved-v1.md's Wardrobe/Insights Q&A section) — that claim is false for any question-phrased scenario prompt, which is a large fraction of real user input. Worse, both calls internally retry (structured→unstructured fallback), so the worst case is four sequential OpenRouter round-trips for one user turn, all racing the single 15s deadline described in the next finding.
Recommended fix: have the QA call's response double as the routing signal before any catalog/insights work is done for the fallback path — i.e., reuse the QA call's classification to decide whether to proceed to resolveOutfits, but pass along data already fetched (wardrobeSnapshot(), catalog) instead of rebuilding it; and consider widening QuestionIntentHeuristic to exclude common recommendation-scenario phrasings ("what should I wear to...") so it doesn't fire in the first place.

[Medium] Insights aggregation runs synchronously on the main actor for every question-shaped turn
Location: InsightsSummaryBuilder.swift:22-83 called from DailyAssistantViewModel.swift:542-549
Problem: buildSummaryText runs 5 full aggregators (AnalyticsAggregator, ColorInsightsAggregator, WardrobeInsightsAggregator, ShoppingInsightsAggregator, StyleDNAScorer) over the entire inventory/rating/feedback history, synchronously, on @MainActor (the whole view model is @MainActor), with no memoization — and it runs on every turn the cheap heuristic flags as question-shaped, even ones that turn out not to be.
Why it matters: this scales with total feedback/rating history, which only grows over a user's lifetime. It's currently masked by small test wardrobes; it will show up as UI jank on main-actor-blocking recomputation for long-time users — exactly the users retention depends on.
Recommended fix: move the aggregation off the main actor (Task.detached, mirroring the pattern already used for AttributePreferenceProfile.build in WardrobeRepository.swift:526-533), and cache the summary text keyed off the same mutation-version counter used elsewhere.

[Medium] Every AI request pays a serialized chain of Firestore round-trips before reaching the model
Location: backend/functions/src/app.ts:70-93, middleware/verifyAuth.ts, middleware/rateLimit.ts, middleware/quota.ts, middleware/responseCache.ts
Problem: the middleware chain is strictly sequential — verifyAuth → rateLimit (Firestore get+set) → responseCache (Firestore get, recommend route only) → quotaGate (1–2 more Firestore reads, sometimes a transaction) — each awaiting the previous before the actual OpenRouter fetch starts.
Why it matters: none of this is intrinsically parallelizable (each step gates the next), but it means every single AI call pays 3-4 sequential Firestore round-trips as pure overhead on top of the upstream latency. At scale this is a fixed latency tax per request that grows the P50/P99 gap under load, and it's the first place users will notice slowness as traffic grows — not the LLM call itself.
Recommended fix: collapse rate limiting and quota into one Firestore document/transaction (they're both per-uid counters already) so it's one round trip instead of two; consider an in-memory/edge rate-limit check (e.g. Cloud Functions v2 + Firestore-backed but cached briefly) for the coarse daily guardrail specifically, since it's explicitly documented as "not a hard billing boundary."
**RESOLVED 2026-07-21:** `rateLimit.ts`/`quota.ts` merged into `middleware/governance.ts` — one shared `users/{uid}/meta/usage` doc, one read/transaction per quota-gated request instead of two, plus a short-TTL warm-instance in-memory cache in front of it (see below and `docs/backend/architecture.md`'s "Governance middleware" section).

[High] responseCache's cache key makes real hits nearly impossible while growing Firestore storage unboundedly
Location: backend/functions/src/middleware/responseCache.ts:33-78
Problem: the cache key is sha256(JSON.stringify(req.body)) — the recommend/QA request body includes the full conversation history, weather, and the entire wardrobe catalog text. Any change to scenario text, conversation turn count, or weather effectively guarantees a cache miss; a hit realistically only happens on a byte-identical retry. Meanwhile every miss writes a new document to users/{uid}/responseCache/{hash} with expiresAt checked only at read time — I confirmed there is no Firestore TTL policy configured anywhere in the repo (backend/firestore.indexes.json is empty, and no TTL-policy IaC exists).
Why it matters: this is a "missing caching opportunity" finding stacked on top of a "unbounded growth" finding — the cache barely helps the thing it's for (avoiding a duplicate paid inference call), while creating a Firestore collection per user that grows forever with no automated cleanup. At 10x users this is a real, avoidable, silently-accumulating storage/cost line item.
Recommended fix: either configure a Firestore TTL policy on responseCache.expiresAt (this is a console/gcloud config, not something the client can enforce), or narrow the cache key to just the fields that actually indicate "nothing changed" (e.g. last user message + a wardrobe version hash) instead of the full payload, so it actually catches the "same scenario against an unchanged wardrobe" case the doc comment claims it targets.

[Medium] No batched writes in the sync layer — one Firestore write per dirty row
Location: Vision_clother/Services/WardrobeSyncService.swift:171-226 (setDocument, called once per push method), Vision_clother/Data/SyncOutboxWorker.swift:31,94-114 (maxConcurrentPushes = 5)
Problem: every push (pushWardrobeItem, pushItemRating, etc.) is an individual ref.setData(...) call. The outbox worker fans these out with a concurrency cap of 5 — there is no use of Firestore's native batched-write API (up to 500 ops per network round trip).
Why it matters: WardrobeSyncCoordinator.pushEverythingLocal (the first-sign-in bootstrap) explicitly calls out that rating/feedback tables "can run into the thousands of rows for a long-time user." That bootstrap will issue thousands of individual network writes, 5 at a time — a multi-minute first-sync experience for exactly the engaged users the product most wants to retain, and needless per-write billing/latency overhead versus a handful of 500-op batches.
Recommended fix: batch pushes by entity type using WriteBatch (bounded at 500 per commit), keeping the existing per-row SyncMetadata dirty-tracking for retry granularity but committing in groups.

3. Service Boundaries

[High] Correctness bug: two feedback-recording paths never invalidate the cache they should
Location: Vision_clother/Data/WardrobeRepository.swift:625-633 (recordItemFeedback, recordPairFeedback) vs. :619-623 (recordOutfitFeedback, for comparison)
Problem: fetchFeedbackHistory()'s cache (WardrobeRepository.swift:295-299) is invalidated purely by comparing against WardrobeMutationTracker.shared.version. recordOutfitFeedback, save, update, and delete all call WardrobeMutationTracker.shared.markMutated() after writing. recordItemFeedback and recordPairFeedback do not.
Why it matters: this is a silent, hard-to-reproduce correctness bug in the personalization pipeline. A user records item or pair feedback ("I don't like these together"), and the very next recommendation call can serve the stale cached FeedbackHistory — missing that signal entirely — until some unrelated mutation (adding/editing/deleting an item) happens to bump the shared counter. Since this is timing-dependent, it won't show up in most manual testing but will quietly degrade recommendation quality in production.
Recommended fix: add the missing WardrobeMutationTracker.shared.markMutated() calls to both methods. Longer-term, this class of bug argues for scoping the cache-invalidation contract explicitly (see next finding) rather than relying on every future write method remembering to call a shared side-effecting function.

[Medium] One global mutation counter conflates two independent caches
Location: Vision_clother/Data/WardrobeRepository.swift:252-255 (inventoryCache/feedbackHistoryCache, both keyed off the same WardrobeMutationTracker.shared.version)
Problem: fetchInventory() and fetchFeedbackHistory() are logically independent (item list vs. an aggregate of feedback/ratings/embeddings), but they share one invalidation signal. Any write anywhere — including ones that only affect one of the two — invalidates both.
Why it matters: this is what makes the previous bug possible in the first place (a missing markMutated() call breaks both caches, not just the relevant one, so there's no way to reason locally about which write needs to invalidate what). It also means routine item-only edits force a full, expensive fetchFeedbackHistory() recompute (including the Vision-embedding pass) on the next call, even when no feedback changed.
Recommended fix: split into two independent version counters (or two independently-invalidated caches) so a write can precisely declare what it invalidates, and the compiler/type system can help enforce it rather than a shared mutable global.

[Medium] Local-mutation vs. sync-pull-applied-mutation is not a first-class distinction
Location: Vision_clother/Data/WardrobeSyncCoordinator.swift:13-17 (file header), Vision_clother/Data/SyncingWardrobeRepository.swift:1-16 (file header)
Problem: the codebase enforces "a pull-applied write must never re-enter the sync-marking decorator" purely by convention — WardrobeSyncCoordinator is careful to hold a bare SwiftDataWardrobeRepository, never SyncingWardrobeRepository, and several methods (downloadMissingPhotos, applyWardrobeItemChange) call modelContext.save() directly rather than through any repository method, with comments warning why. There is no type-level guard against a future call site accidentally routing a pull-applied write through the decorator and creating an infinite dirty-push loop.
Why it matters: this is exactly the kind of invariant that survives fine under the original author's care and breaks under a different engineer's otherwise-reasonable refactor six months later — "don't do X" enforced only by doc comments is a known failure mode at team scale.
Recommended fix: make the distinction structural — e.g. a SyncOrigin marker on write calls, or a dedicated RemoteApplyingRepository type that explicitly can't be constructed as a SyncingWardrobeRepository's underlying, so the invariant is enforced by the type system rather than a comment.

4. Production Readiness

[Critical] No idempotency protection on quota-gated, real-money routes
Location: backend/functions/src/middleware/quota.ts:113-121, 184-194 (quota debited before next()), backend/functions/src/routes/openrouterChat.ts / openrouterImages.ts (no request dedup)
Problem: quotaGate increments (or draws down a purchased credit for) the user's usage counter before calling next(), which is what actually performs the upstream OpenRouter call — a call the docs themselves describe as up to 120–180s. There is no idempotency key on the request, and no dedup of in-flight/recently-completed identical requests.
Why it matters: a client-side timeout, an app backgrounding/kill during a long try-on render, or a simple retry-on-failure will re-send the request, consuming a second unit of quota and triggering a second real-money image-generation call for what the user experiences as one action. This gets worse, not better, under the exact conditions (network flakiness, cellular handoffs, backgrounding) that increase with a larger, more diverse user base — it's a scaling-shaped bug.
Recommended fix: have the iOS client generate a UUID per user-initiated try-on/recommend action and send it as an idempotency key; have quotaGate/the route dedupe on that key (a Firestore doc similar to processedTransactions in iapVerify.ts, which already implements exactly this pattern for purchases) before debiting quota or calling upstream.

[High] AI request governance costs scale linearly with AI traffic, with no cache tier
Location: backend/functions/src/middleware/rateLimit.ts, middleware/quota.ts (Firestore reads/writes on every request)
Problem: every proxied AI call costs a minimum of ~3 Firestore document operations purely for auth/rate-limit/quota bookkeeping, with no in-memory or edge caching layer in front of Firestore for these per-request checks.
Why it matters: at "thousands of concurrent users" (the stated target), this is thousands of extra Firestore reads/writes per second that scale 1:1 with legitimate AI traffic — and, per the Critical finding above, also scale with abusive retry traffic, since a hung/timed-out request still costs a full governance round trip on each retry. This is a real, currently-unbudgeted cost and latency driver as usage grows, separate from the OpenRouter bill itself.
Recommended fix: as noted above, collapse rate-limit + quota into a single document/transaction; consider a short-TTL in-memory cache per warm Cloud Function instance for the common "well under quota" case, falling back to Firestore only near the cap (the code already has this fast/slow-path split for the transaction, but not for the read).
**RESOLVED 2026-07-21:** `middleware/governance.ts` adds a 20s-TTL per-warm-instance `Map` cache in front of the unified doc — a fresh, comfortably-under-limit hit skips Firestore reads entirely and fires the increment write unawaited. Purchased-balance drawdown is deliberately excluded from this fast path (stays transactional, serialized against `iapVerify.ts`'s grant) — real money never takes the bypass. Trade-off worth tracking: the cache is per-instance, so the free-tier fast path's overshoot bound now scales with concurrent warm-instance count × TTL, not just TTL — tune `CACHE_TTL_MS`/the safety margins in `governance.ts` if that proves too loose in practice.

[Medium] Client-side timeout budget doesn't account for the new two-call turn shape
Location: Vision_clother/Vision_clother/Features/DailyAssistant/DailyAssistantViewModel.swift:59 (requestTimeoutNanoseconds = 15_000_000_000)
Problem: the 15s deadline wraps the entire resolveTurn, but as documented in finding #5, a single turn can now involve up to two sequential LLM calls (QA, then recommend), each with its own structured→unstructured fallback attempt.
Why it matters: this deadline was clearly sized for "one recommendation call" (matching the original single-call architecture) and was never revisited when the QA call was added in front of it. Expect a measurable rise in "This is taking too long" failures for ordinary, question-phrased prompts — a UX regression that will look like "the AI got slower" to users and is entirely explainable by the architecture, not model latency.
Recommended fix: either raise the deadline to account for the worst-case two-call path, or (better, ties into finding #5) restructure so the fallback to resolveOutfits reuses already-fetched data instead of re-running the full pipeline, shrinking the worst case back toward one real network round trip.

[Medium] Monolithic Cloud Function has no scaling ceiling or floor
Location: backend/functions/src/index.ts:14-26
Problem: no maxInstances, minInstances, or concurrency set on the api function; timeoutSeconds: 180 applies uniformly across all 9 routes regardless of expected cost/duration.
Why it matters: no maxInstances means a traffic spike (organic or abusive — note the governance checks in the previous finding don't reject a request until after it's already cost a Firestore round trip) has no cost ceiling. No minInstances means every scale-up event pays a cold start that includes initializing the Admin SDK and the Apple App Store server library, adding latency variance under exactly the bursty conditions a spike produces.
Recommended fix: set a maxInstances cap sized to a sane worst-case bill as a backstop, and evaluate minInstances: 1 once traffic is steady enough to justify the always-on cost, in addition to the route-splitting recommended in Section 1.

---
If I had to pick the two to fix first: the missing markMutated() calls (silent personalization-quality bug, trivial one-line fix, Section 3) and the missing idempotency key on quota-gated routes (real-money double-spend risk that gets worse with scale, Section 4). Everything else here is a genuine scaling concern but degrades gracefully; those two either silently corrupt data or silently cost money.

✻ Crunched for 5m 39s

───────────────────────────────────────────────────── 1 new message ─────────────────────────────────────────────────────

※ recap: I completed a full architecture review of Vision Clother, finding 16 issues across backend, data flow, and sync layers. Next: decide which fixes to prioritize, starting with the stale-cache bug and the missing idempotency key on paid AI calls. (disable recaps in /conf