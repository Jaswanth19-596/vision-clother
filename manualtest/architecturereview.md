Production Readiness Architecture Review — Vision Clother

Scope reviewed: docs/decisions/*, docs/architecture.md (iOS/backend), Domain/, Data/, Services/, Models/, Features/JobQueue, Features/DailyAssistant, Vision_clotherApp.swift, ModelConfig.swift. This is a client-only SwiftUI app with no backend of any kind — every "service" is a direct URLSession call from the device to a third-party LLM/image API. That single fact drives most of the findings below.

---
1. Overall Architecture

Severity: Critical
Location: Entire app — Services/APIKeys.swift, docs/decisions/resolved-v1.md §"No Node.js Backend in V1"
Problem: There is no backend tier. The iOS client holds OpenRouter, Fal, and Pexels API keys directly (Config/Secrets.plist, bundled into the IPA), and calls the LLM/image providers straight from the device.
Why it matters: This isn't a hidden risk — the docs themselves flag it as "dev-only, not for distribution" — but the codebase has already grown ~8 SwiftData schema versions, a job queue, conversation loops, prospective-purchase evaluation, and swipe-to-learn ML on top of this dev-only foundation, with no proxy layer scaffolded and no ticket/plan tracking it. Any TestFlight/App Store build today ships a static, extractable API key (trivial via strings/class-dump on the IPA) that anyone can lift and burn against your OpenRouter/Fal/Pexels billing. There's also no user auth, no per-user rate limiting, and no way to revoke a compromised key without an app-store-review-gated update.
Recommended fix: Before any distributed build, stand up the "thin proxy" the docs already describe (POST /intent, POST /recommend, POST /try-on, POST /tag), holding keys server-side. Since every client call already goes through a protocol (IntentExtractionService, OutfitRecommendationService, TryOnRenderService, VisionMetadataExtractionService), this is mechanically a new conformance + ServiceFactory swap — but it needs to actually be scheduled, since right now it's a documented "later" with no owner.

Severity: High
Location: docs/decisions/resolved-v1.md, docs/ios/architecture.md, docs/backend/architecture.md vs. actual Services/ directory
Problem: All three architecture docs describe the try-on renderer as Fal + fashn/tryon/v1.6 with an async submit→poll pattern. The actual code has no Fal*.swift file anywhere in the tree — a grep -ri fal across all Swift sources returns zero hits. The real implementation is OpenRouterTryOnRenderService using Gemini image models via OpenRouter chat completions (ModelConfig.imageToImage).
Why it matters: This is a live ADR describing an architecture that was fully replaced without the decision doc being updated. CLAUDE.md explicitly tells Claude Code (and by extension, engineers) to read these docs before touching a layer — right now they'd plan around a provider and async-poll contract (TryOnState.polling, 45s budget) that doesn't match reality, and would miss that the real service is a synchronous chat-completions call with different failure modes, latency, and cost characteristics.
Recommended fix: Update resolved-v1.md, docs/ios/architecture.md, and docs/backend/architecture.md to reflect OpenRouter/Gemini as the current try-on provider, or explicitly mark the Fal decision as superseded (matching how the LLM-as-Recommender reversal was documented).

Severity: Medium
Location: Data/WardrobeRepository.swift vs. Vision_clother/Data/CLAUDE.md
Problem: Data/CLAUDE.md states as a hard rule: "This layer never imports Domain/ — they are peers, not dependencies." The actual SwiftDataWardrobeRepository.fetchFeedbackHistory() directly calls AttributePreferenceProfile.build(...), constructs RatedAttributes/OutfitDimensionRatedAttributes/ItemAttributeSnapshot, reads VisualPreferenceProfile, and calls VisualClusterUpdater.update — all Domain/ types — plus logs via Domain/MLLog.swift.
Why it matters: The documented boundary (storage tech can be swapped without touching business logic)computation, not just persistence. This is exactly the kind of drift that compounds: the next engineer who trusts the CLAUDE.md guarantee and tries to swap SwiftData for something else will discover mid-migration that half the scoring pipeline lives inside the persistence layer.
Recommended fix: Either (a) update Data/CLAUDE.md to honestly describe the current coupling, or (b) move the AttributePreferenceProfile.build call out of fetchFeedbackHistory() into the view-model layer (which already calls both repository and Domain/ functions), leaving WardrobeRepository responsible only for returning raw rows.

Severity: Low
Location: Vision_clother/Vision_clother/Vision_clother/DesignSystem/
Problem: Triple-nested identically-named directories (Vision_clother/Vision_clother/Vision_clother/...), alongside a split where Services/ exists at two different nesting levels with genuinely different files in each (root Services/ vs. Vision_clother/Services/), disambiguated only by a per-directory CLAUDE.md telling readers "not to be confused with the root Services/ layer."
Why it matters: This is a real maintainability tax — new files land in the wrong Services/ by accident, and Xcode's file-system-synchronized groups make it easy to nest one level too deep without noticing. It's already needed a dedicated doc just to disambiguate two folders with the same name.
Recommended fix: Flatten the nesting; there's no technical reason for Vision_clother/Vision_clother/Vision_clother/, and one Services/ directory (not two) should exist.

---
2. Data Flow

Severity: High
Location: Data/WardrobeRepository.swift:399-434 (fetchFeedbackHistory), called from DailyAssistantViewModel.resolveOutfits on every conversation turn
Problem: fetchFeedbackHistory() does, on every turn: 4 full-table SwiftData fetches with a 180-day predicate (PairFeedback, ItemFeedback, ItemRating, OutfitFeedback), a full WardrobeItem fetch (twice, in two separate blocks), a full SavedCombination fetch (twice), a full WardrobeItemEmbedding fetch, and then — inline, in a serial for loop, not a TaskGroup — a Vision-framework embedding(for:) call for every non-ghost item whose cached embedding is missing or stale. resolveOutfits separately calls repository.fetchInventory() again on top of this.
Why it matters: None of this is cached across turns within the same conversation, let alone across app sessions. For a wardrobe with a few hundred items, a fresh install (or one bad cache invalidation) means every single message the user sends re-embeds a large fraction of their closet synchronously before the LLM call even starts. Because WardrobeRepository is @MainActor, this entire sequence — including the Vision computations — runs on the main actor, so it's not just slow, it's UI-blocking. This is the first thing that breaks under "10x users with real wardrobes": latency per message scales with closet size, not with prompt complexity.
Recommended fix: Parallelize the embedding computation with a TaskGroup instead of a serial await loop; cache the assembled FeedbackHistory/inventory snapshot for the duration of a conversation (invalidate on closet mutation) instead of rebuilding it every turn; move the Vision embedding work off the main actor into a background actor, writing results back through the repository.

Severity: Medium
Location: DailyAssistantViewModel.resolveOutfits (Features/DailyAssistant/DailyAssistantViewModel.swift:328-346)
Problem: weather, inventory, history, and profile are all fetched with sequential awaits even though none of them depend on each other's results.
Why it matters: This directly and unnecessarily adds latency to every recommendation request — weather (a network call to Open-Meteo), user-profile resolution (potentially a full LLM call if undreived), and the SwiftData fetches could all run concurrently. On a slow connection this is the difference between ~1 round-trip and ~3-4 stacked round-trips before the primary recommendation call even starts.
Recommended fix: Use async let to fan these out concurrently; only the catalog build needs to wait on all of them.

Severity: Medium
Location: Features/JobQueue/JobQueueStore.swift (performUpload) vs. isolateAndTag (same file, lines 168-199)
Problem: The two-stage isolate pipeline (Gemini preprocess → on-device Vision cutout, each with a fallback-to-previous-stage-on-failure) is duplicated almost verbatim between performUpload (job-tracked path) and isolateAndTag (prospective-purchase path) — acknowledged directly in the code's own comment ("duplicating ~10 lines here is lower-risk than restructuring").
Why it matters: Any future change to the isolation fallback behavior (e.g., adding a third stage, changing what counts as failure) has to be applied twice, and nothing enforces that — a classic "two implementations quietly drift" risk, currently latent but real.
Recommended fix: Extract the shared isolate-with-fallback sequence into one function both call sites use; low risk since it's a pure sequencing extraction with identical inputs/outputs.

Severity: Medium
Location: Features/JobQueue/JobQueueStore.swift — unbounded concurrent Tasks per upload/try-on
Problem: enqueueUpload/enqueueTryOn each spawn an independent, uncapped background Task hitting OpenRouter/Fal-equivalent endpoints directly. There is no maximum in-flight job count, no client-side rate limiting, and no backoff/queueing if many jobs are enqueued at once (e.g., a bulk closet import).
Why it matters: Combined with the embedded, extractable API key (Architecture §1), this means the app has no defense against either an accidental burst (user selects 50 photos to import) or a deliberate abuse pattern — every job fires immediately and independently against a paid third-party API. At "10x users" this is a direct, uncapped cost multiplier with no circuit breaker.
Recommended fix: Cap concurrent in-flight jobs (e.g., a semaphore of 3-4) and queue the rest; this is complementary to, not a replacement for, moving keys server-side.

Severity: Low
Location: Services/CachedTryOnRenderService.swift
Problem: Cache lookup is a full linear scan (first(where:)) over every SavedCombination on every try-on request, matching on Set equality of item IDs plus a portrait fingerprint.
Why it matters: Fine at today's scale (a personal closet's worth of saved combos), but this is an O(n) scan with no index and no cap on the "Combinations" table's growth over the life of an account — will show up as a real cost in Data/WardrobeRepository.swift's already-heavy fetchFeedbackHistory (which also full-scans SavedCombination) if usage grows.
Recommended fix: Not urgent at current scale; worth a Dictionary-backed lookup keyed on (portraitFingerprint, itemIDSet) if SavedCombination counts grow into the thousands.

---
3. Service Boundaries

Severity: Medium
Location: Domain/WardrobeCatalogBuilder.swift vs. its own header comment and Domain/CLAUDE.md
Problem: The file's own doc comment says "Pure, no I/O (Domain/CLAUDE.md)", and Domain/CLAUDE.md says "Pure business logic." But rank(_:history:) calls MLLog.logger.debug(...) (an os.Logger side effect) inside the ranking loop, gated on isTrainedProfile.
Why it matters: Small in isolation, but it's the same class of drift as the Data→Domain violation above: a layer's own stated invariant ("pure," "no I/O") is already not true, which erodes the value of the layering rule for the next person who relies on it to keep Domain/ unit-testable without side effects or a logging harness.
Recommended fix: Either drop the "pure, no I/O" framing for this file, or push the logging call out to the caller (WardrobeRepository or the view model), which already imports Domain/ and could log the returned ranking instead.
protocols + Mock* at the root; ServiceFactory + notification/try-on wiring at the feature level) that's only discoverable by reading two separate CLAUDE.md files and noticing the disambiguating sentence in the second one.
Why it matters: This is a service-boundary problem, not just a naming one — ServiceFactory (feature-level) is the actual composition root deciding mock vs. real for every protocol defined at the root level, which means the dependency-injection decision point is structurally separated from the protocols it wires. A new service added at the root layer requires remembering to also touch the feature-level factory, with no compiler-enforced link between the two.
Recommended fix: Collapse to one Services/ directory, or if the root/feature split is intentional (e.g. Domain-adjacent vs. UI-adjacent services), make ServiceFactory live next to the protocols it wires rather than in a differently-scoped directory.

Severity: Low
Location: Data/WardrobeRepository.swift, Domain/CLAUDE.md
Problem: WardrobeRepository is a single ~30-method god-protocol covering inventory CRUD, three separate feedback tiers, ratings, saved combinations, user profile, visual-taste swipe state, item embeddings, and impression/selection events — one interface for at least seven materially different concerns.
Why it matters: Every consumer (view model) depends on the entire surface even when it uses a fraction of it, and every new feature (visual taste, impressions, ratings) has extended this same protocol rather than introducing a new one — the ADR history in docs/decisions/stylist-intelligence-engine.md shows this pattern repeating across at least 6 feature additions. This isn't breaking anything today, but it's the single biggest source of coupling in the app: changing the storage technology (the explicit stated goal of this abstraction) now means reimplementing all of it atomically, not incrementally.
Recommended fix: Not urgent to fix retroactively, but new persistence concerns (there will be more) should get their own protocol (e.g., VisualTasteRepository, ImpressionRepository) rather than growing this one further — matches the "peers, not one dependency" spirit the layering doc already claims.

Severity: Low
Location: JobQueueStore ↔ DailyAssistantViewModel ↔ WardrobeRepository
Problem: JobQueueStore and DailyAssistantViewModel both hold direct references to the same @MainActor WardrobeRepository instance and both call into it independently and concurrently (job-queue writes racing against a conversation turn's reads). There's no coordination beyond MainActor serialization.
Why it matters: Not a bug today — MainActor isolation genuinely prevents data races — but it's an implicit coupling that only holds because both happen to be MainActor-isolated singletons wired at app launch. It's not enforced by any interface; a future contributor adding a third MainActor-isolated consumer, or moving one of these off MainActor for performance (a likely fix for the §2 latency issue above), silently reintroduces races.
Recommended fix: No immediate change needed, but flag this coupling explicitly in Data/CLAUDE.md — the "safety" here is incidental to MainActor isolation, not a designed guarantee, and any future actor-isolation change to either consumer needs to account for it.

---
4. Production Readiness

Severity: Critical
Location: Vision_clotherApp.swift:79-90 (recreatingContainerAfterStoreReset)
Problem: If ModelContainer initialization fails for any reason (a botched migration, corrupted store metadata, a schema version SwiftData can't resolve), the app's recovery path is to delete the user's entire local database and image directory (store, -shm, -wal files) and start over — silently, with no user confirmation, no export, no backup, and no telemetry that this happened.
Why it matters: Given this app has already shipped 8 schema versions in its short history (per SchemaMigrations.swift), each one a hand-written MigrationStage, the probability of a future migration bug triggering this path is not hypothetical — it's a matter of when, and every wardrobe photo, every feedback/rating history entry, every saved combination the user has built up is on-device only (per the "SwiftData On-Device, no server-side persistence" decision) with no other copy anywhere. This is a single bug away from a silent, total, unrecoverable data-loss event for real users, with no way for the team to even know how often it's firing.
Recommended fix: At minimum, log (locally + eventually to any telemetry) when this path triggers, and consider attempting a lightweight on-disk backup/export before destructive recovery. Given there is genuinely no server-side copy of user data, this is the single highest-priority reliability gap in the app — it should be fixed before this pattern of frequent schema changes continues, not treated as an edge case.

Severity: High
Location: App-wide — no backend, Services/APIKeys.swift
Problem: (Restating from an operational angle) Every user's device independently calls OpenRouter/Fal/Pexels directly, with no server-side aggregation point.
Why it matters: At "10x users," there is no way to: apply a global rate limit, cache/dedupe identical requests across users, negotiate volume pricing, kill-switch a misbehaving model version centrally, or even measure aggregate spend without per-device instrumentation. Traffic spikes (e.g. a viral moment) translate 1:1 into API provider spend and rate-limit exposure with zero buffering. This is the same root cause as the Critical finding in §1, called out again here specifically because it's also the first thing to break operationally, not just the security exposure.
Recommended fix: Same as §1 — proxy backend is the prerequisite for any meaningful traffic-spike handling.

Severity: High
Location: Data/WardrobeRepository.swift fetchFeedbackHistory, DailyAssistantViewModel.resolveOutfits
Problem: (Restating from a scale angle) Per-turn cost is O(closet size) for embeddings + O(total feedback history) for the 180-day-windowed fetches, all on the main actor.
Why it matters: This is the first on-device thing that breaks as individual users' data grows — a power user with a large wardrobe and a year of feedback history will see every single chat message get slower over time, with no pagination or incremental-recompute strategy in sight. There's no per-app-version telemetry to notice this degrading either (no analytics backend, per the point above).
Recommended fix: As in §2 — parallelize, cache within a conversation, and consider capping the embeddable-item recompute per turn (e.g., only recompute embeddings for items touched since last successful history fetch, with a persisted "embeddings up to date" watermark) rather than scanning the full inventory every time.

Severity: Medium
Location: Services/OutfitRecommendationService.swift (logPromptForDebugging)
Problem: The full request body — including the entire wardrobe catalog and system prompt — is dumped via print() on every recommendation call, explicitly because "unified logging truncates... by default."
Why it matters: print() output isn't gated by build configuration here (no #if DEBUG), so this ships in release builds too unless stripped elsewhere. It's also a real, if minor, privacy surface: wardrobe descriptions and (indirectly) derived style-profile data land in the device's stdout/console log on every request, retrievable via a connected Mac or crash-log tooling in ways os.Logger's privacy annotations (used everywhere else, e.g. MLLog) are specifically designed to prevent.
Recommended fix: Gate behind #if DEBUG, or migrate to os.Logger with explicit .private/.public annotations like the rest of the codebase already does for MLLog/PerfLog.

Severity: Medium
Location: No monitoring/observability layer anywhere in the codebase
Problem: Logging is os.Logger/print()-based only (PerfLog, MLLog), read locally via Console.app. There is no crash reporting, no remote analytics, no error-rate dashboard, and (per §1) no backend to aggregate any of it even if added.
Why it matters: Combined with the Critical data-loss finding above, this means the team has no way to know if/how often users are hitting the store-reset path, how often the LLM recommendation call is failing validation and falling back, or what the real-world latency distribution looks like — all of which the code clearly already cares about internally (PerfLog.time, RejectionReason, RecommendationImpressionEvent are all designed as if for future analysis) but nothing ships that data anywhere observable in production.
Recommended fix: This is explicitly deferred in docs/decisions/stylist-intelligence-engine.md ("not wired to telemetry yet") for the validator rejection reasons and impression events — worth prioritizing once any server component exists, since the instrumentation hooks are already built, just not connected.

---
Summary — what breaks first, in order

1. A migration bug wipes local data with no recovery (Vision_clotherApp.swift's reset-on-failure path) — the single highest-severity risk given 8 schema versions already shipped and zero backup.
2. Extracted API key from a distributed IPA turns into unbounded third-party billing exposure — inherent to the "no backend" architecture, acknowledged in docs but with no scheduled remediation.
3. Per-message latency degrades with wardrobe/history size, not prompt complexity, because fetchFeedbackHistory re-scans everything on every turn on the main actor — this is the first thing power users personally feel.
4. Everything else (doc/code drift on the try-on provider, layering-rule violations, god-protocol repository) is real technical debt but not yet load-bearing for an incident — worth fixing opportunistically, not urgently.