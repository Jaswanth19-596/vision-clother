# Vision Clother — Change Timeline

---

## 2026-07-19 — Analytics & Insights, Phase 10: Style DNA (Style sub-tab) — feature complete

**Status:** ✅ Shipped — Build Succeeded

### Context
Ninth and final implementation slice of Analytics & Insights, closing out
the approved Phase 1 plan's execution order. All 10 phases (architecture →
backend/infra → feedback improvements → Overview → Favorite Colors →
interactive charts → Trends → Wardrobe Insights → Shopping Insights → Style
DNA) are now shipped.

### What shipped
1. **`Domain/StyleDNAScorer.swift`** — 12 named 0-100 spectrum scores (50 =
   neutral/no lean), each derived from a specific real signal, never an
   invented number: Color Boldness, Pattern Adventurousness, Formality
   Lean, Silhouette Consistency, and Fabric Weight Lean all read from
   `AttributePreferenceProfile`'s learned affinity maps (two computation
   shapes: "difference" dimensions default a missing affinity to neutral
   0.5, same convention `affinityBonus` already uses; "weighted centroid"
   dimensions use only affinity keys with real data, since defaulting
   missing bands to neutral would flatten the centroid regardless of how
   lopsided the real signal is); Signature Style Strength and Color
   Palette Breadth also read `AttributePreferenceProfile`; Wear Loyalty
   reads raw `WornLogEntry` concentration (top-20%-of-worn-items' share of
   total wears); Practicality Orientation, Confidence Boost, and Occasion
   Versatility read detailed `OutfitFeedback` fields (the latter from
   Phase 3's `occasionRaw`); Comfort Priority reads raw `ItemRating`. The
   whole section is gated behind `AnalyticsConfigResponse.styleDNAMinRatings`
   (added in Phase 2, unused until now) — locked with an honest "rate N
   more" nudge below threshold, all 12 scores plus a stored real "why"
   sentence per score above it.
2. **`StyleViewModel.swift`** — now computes a `styleDNASnapshot` in the
   same pass as the color snapshot, reusing the `attributeProfile` already
   fetched via `WardrobeRepository.fetchFeedbackHistory()` — no duplicate
   computation.
3. **`StyleView.swift`** — new "Style DNA" card appended below Favorite
   Colors (added a `wornLogEntries` `@Query`, since Style DNA needed it and
   nothing on this screen had queried it before): all 12 dimensions as a
   `RankedBarShareChart` (reusing Phase 6's chart component — each score
   passed as `score/100`), plus the "why" text for the 3 most distinctive
   dimensions (largest deviation from neutral 50) surfaced below it.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. One thing caught and fixed during implementation: `styleDNACard`'s locked-state nudge initially referenced the view's `viewModel` property directly, but that property is `StyleViewModel?` (optional) at the call site inside a helper method — not the body's locally-shadowed non-optional `viewModel` — fixed with `viewModel?.thresholds ?? .conservativeDefault`. Simulator walkthrough of the full Insights tab (all 5 phases 4–10 of UI) is still deferred at the user's request across this entire session — recommended as the first thing to do next, now that every phase is shipped and there's a complete surface to exercise end-to-end. Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 9: Shopping Insights (folded into the Wardrobe sub-tab)

**Status:** ✅ Shipped — Build Succeeded

### Context
Eighth implementation slice of Analytics & Insights, continuing the
approved Phase 1 plan's execution order right after Phase 8's Wardrobe
Insights. Per the plan, Shopping Insights isn't a separate sub-tab — it
folds into the same Wardrobe screen as a new card, since suggestions are
derived directly from the wardrobe-balance data Phase 8 already computes.

### What shipped
1. **`Domain/ShoppingInsightsAggregator.swift`** — pure, NaN-safe
   (Domain/CLAUDE.md) aggregation that takes Phase 8's already-computed
   `WardrobeInsightsSnapshot` as input rather than recomputing wear
   counts/redundancy itself. Every suggestion is a literal count-based
   fact, never a guess at what the user "needs": (1) seasonal coverage gaps
   — for each of the 3 required slots (top/bottom/footwear) × 3 seasons,
   zero real items tagged for that combination is a real, reportable gap;
   (2) the bottleneck slot Phase 8 already identifies, rephrased as an
   actionable "consider adding X" line; (3) a "don't overbuy" suggestion
   from Phase 8's largest redundant group (≥3 items), only surfaced when
   there's enough wear data to know the duplicates are genuinely underused,
   not just "you own multiples." Capped at 4 suggestions, gated on the same
   `wardrobeInsightsMinItems` threshold Phase 8 already uses — no new
   config fields needed.
2. **`WardrobeInsightsViewModel.swift`** — now computes the shopping
   snapshot right after the wardrobe snapshot each recompute, passing the
   latter in directly (no redundant work).
3. **`WardrobeInsightsView.swift`** — new "Shopping Suggestions" card,
   appended after Closet Balance, shown only when there's at least one real
   suggestion.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Simulator walkthrough still deferred at the user's request. Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 8: Wardrobe Insights (Wardrobe sub-tab)

**Status:** ✅ Shipped — Build Succeeded

### Context
Seventh implementation slice of Analytics & Insights, continuing the
approved Phase 1 plan's execution order after Phase 7's Trends. Phase 9
(Shopping Insights) stays a separate follow-up phase even though it shares
this same sub-tab, per the plan's numbered ordering.

### What shipped
1. **`Domain/WardrobeInsightsAggregator.swift`** — pure, NaN-safe
   (Domain/CLAUDE.md) aggregation over `WardrobeItem` + `WornLogEntry` only:
   utilization rate (% of real items with ≥1 logged wear), most-worn /
   least-worn item lists, redundant-item groups (items sharing the same
   slot + color vibe + pattern — a real attribute-duplication signal, not
   an invented similarity score — sorted most-worn-first within each group
   so the view can call out "only 1 of these 3 gets worn"), and closet
   balance (per-slot counts via the existing `AnalyticsAggregator.shareBreakdown`,
   plus a bottleneck callout: the required slot — top/bottom/footwear, via
   the existing `Slot.isRequired` — with the fewest items, since that's
   what actually caps how many complete outfits the wardrobe can produce).
   Utilization/most-worn/least-worn are all gated on
   `AnalyticsConfigResponse.wardrobeInsightsMinWornLogs`; the whole screen
   is gated on `wardrobeInsightsMinItems` — both config fields added in
   Phase 2 for exactly this, unused until now.
2. **`Features/Insights/WardrobeInsightsView.swift` + `WardrobeInsightsViewModel.swift`**
   — utilization stat, most-worn/rarely-worn thumbnail lists (reusing
   `ClosetView`'s `CachedWardrobeImage`-with-color-fallback pattern),
   redundant-items list, and a closet-balance chart (reusing Phase 6's
   `RankedBarShareChart`) with the bottleneck text callout. Two distinct
   honest empty states: no items at all, vs. items present but below
   `wardrobeInsightsMinItems`.
3. **`InsightsView.swift`** — wired the Wardrobe segment.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Simulator walkthrough still deferred at the user's request. Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 7: Style Trends (Trends sub-tab)

**Status:** ✅ Shipped — Build Succeeded

### Context
Sixth implementation slice of Analytics & Insights, continuing straight
through the approved Phase 1 plan's execution order after Phase 6's chart
infrastructure.

### Design decision: trends track engagement frequency, not per-bucket rating averages
The spec asks for "evolution charts (color/category/pattern/style)."
`WardrobeItem` has no acquisition date, so wardrobe *composition* still
isn't time-series data (same scope cut as Phases 4/5) — only real per-event
timestamps can be plotted. Considered two honest options: (a) per-bucket
average rating (e.g. "average color-harmony star for earth-tone items in
June"), or (b) per-bucket engagement count (how often you rated/wore
items of that color/category/pattern/style in June). Went with (b):
per-bucket sample sizes are typically tiny for most users, and averaging a
handful of stars per bucket would produce a noisier, less honest line than
a plain count. Every point plotted traces to a real `ItemRating.recordedAt`,
detailed `OutfitFeedback.recordedAt` (joined to its `SavedCombination`'s
items), or `WornLogEntry.wornAt` — the same three signals Phase 4's
Overview activity deltas already draw from.

### What shipped
1. **`Domain/TrendsAggregator.swift`** — pure, NaN-safe (Domain/CLAUDE.md)
   aggregation: flattens the three engagement sources into timestamped
   `(date, item)` events, divides the selected `AnalyticsTimeRange` into 6
   equal-width buckets (`.allTime` anchors its start to the earliest real
   event instead of `.distantPast`, avoiding one degenerate final bucket),
   picks the top 3 most-frequent values per dimension (color vibe / slot /
   pattern / style tag) over the whole interval — fixed draw order, never
   re-sorted per bucket — and counts each series' engagement events per
   bucket. Gated on the existing `AnalyticsConfigResponse.trendsMinDataPoints`
   (added in Phase 2 for exactly this) so a chart never renders on too few
   real events; the caller shows an honest empty state instead.
2. **`Features/Insights/InsightCharts.swift`** gained `TrendLineChart` — a
   multi-series Swift Charts `LineMark` component. The one other genuine
   categorical-color case in this feature (besides Phase 6's
   `PeriodComparisonChart`): up to 3 series share the same x-axis (bucket)
   positions, so color is the only way to disambiguate them, using
   `VCChartPalette.categorical` in the aggregator's fixed frequency-rank
   order with Swift Charts' automatic `foregroundStyle(by:)` legend.
3. **`Features/Insights/TrendsView.swift` + `TrendsViewModel.swift`** — four
   cards (Color/Category/Pattern/Style Trend), each either a `TrendLineChart`
   or an honest "rate more outfits and log wears" empty state per
   `hasEnoughData`. Same `@Query`-raw-rows-in / pure-aggregator-out shape as
   every other Insights screen.
4. **`InsightsView.swift`** — wired the Trends segment to `TrendsView`
   instead of the "Coming Soon" placeholder.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded (one real compile error caught and fixed along the way: `TrendChart`'s nested `SeriesPoint` needed explicit `Equatable` conformance for the parent struct's synthesized `Equatable` to compile). Simulator walkthrough still deferred at the user's request. Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 6: Interactive charts (Swift Charts)

**Status:** ✅ Shipped — Build Succeeded

### Context
Fifth implementation slice of Analytics & Insights, continuing straight
through the approved Phase 1 plan's execution order after Phase 5's
Favorite Colors. Invoked the `dataviz` skill before writing any chart code,
per its own trigger rule.

### What shipped
1. **Palette promotion**: `Features/Profile/ProfileChartPalette.swift` →
   `DesignSystem/VCChartPalette.swift` (enum renamed `ProfileChartPalette` →
   `VCChartPalette`), so Profile and Insights both depend on one
   DesignSystem-level definition instead of Insights reaching into a
   Profile-owned file. Re-validated the categorical palette with the
   dataviz skill's `scripts/validate_palette.js` before reusing it: light
   mode passes lightness/chroma/CVD-separation, WARNs on contrast-vs-surface
   for 2 of the 4 hues (meaning those two need visible direct labels rather
   than color alone — already this codebase's convention for every chart
   row); dark mode fully passes. Updated the 3 call sites in
   `ProfileView.swift` plus Phase 4/5's Insights references.
2. **`Features/Insights/InsightCharts.swift`** — two reusable Swift Charts
   components: `RankedBarShareChart` (single-hue horizontal `BarMark` for a
   ranked/magnitude series — one bar per row, direct percentage labels
   always visible since row counts here are small, tap-to-highlight via
   `chartOverlay`) and `PeriodComparisonChart` + `PeriodLegend` (the one
   genuine two-series comparison in this feature — current vs. previous
   period — current highlighted in the brand hue, previous in muted gray,
   with a single shared legend rendered once by the hosting card rather than
   per chart instance).
3. **Rewired both existing Insights screens** off their Phase 4/5
   hand-rolled `GeometryReader`/`Capsule` bars: `OverviewView.swift`'s Top
   Colors/Top Categories composition cards and Activity card (now
   `PeriodComparisonChart` per metric) now use real Swift Charts;
   `StyleView.swift`'s Color Vibe Breakdown, Dark/Medium/Light, Warm/Cool,
   and Favorite Combos sections now use `RankedBarShareChart`.

### Scope note — corrected which sections get which chart type
The Phase 6 plan as proposed grouped Dark/Medium/Light and Warm/Cool/Neutral
under "categorical chart with a legend," alongside the genuinely
comparative Activity current-vs-previous metric. On implementation, that
grouping didn't hold up against the dataviz skill's own rule ("color
follows the entity, never decoration for its own sake"): Dark/Medium/Light
and Warm/Cool/Neutral are single-series ranked breakdowns already
disambiguated by their axis label, identical in structure to Top
Colors/Color Vibe Breakdown — so they use the single-hue
`RankedBarShareChart`, not a colored/legended chart. Only Activity
(current vs. previous period) is a real two-series comparison where color
carries meaning beyond the axis label, so only it got
`PeriodComparisonChart`'s two-color treatment. Flagging this since it
refines (not changes the intent of) what was approved.

Swatch galleries (Style) stay as literal color chips — nothing to
chart-ify, they already are the real colors. Seasonal Colors stays a text
list — proper time-series charting arrives with Phase 7's Trends.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Simulator walkthrough still deferred at the user's request (continuing straight through the phase sequence). Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 5: Favorite Colors (Style sub-tab)

**Status:** ✅ Shipped — Build Succeeded

### Context
Fourth implementation slice of Analytics & Insights, continuing the approved
Phase 1 plan's execution order right after Phase 4's Overview tab. Favorite
Colors is the spec's highest-priority item, so this phase goes to full depth
rather than a thin slice.

### What shipped
1. **`Domain/ColorInsightsAggregator.swift`** — pure, NaN-safe aggregation
   (Domain/CLAUDE.md) covering every angle the spec asks for, all from real
   data already on `WardrobeItem`/`SavedCombination`, none invented:
   swatch gallery (actual distinct hex chips from `colorProfile.primaryHex`,
   deduplicated exactly, sized by frequency), color-vibe category
   composition (reuses `AnalyticsAggregator.shareBreakdown`, now `internal`
   instead of `private` so both aggregators share one count/sort/percentage
   implementation), dark/light split (reuses `Domain/ColorHarmony.swift`'s
   existing HSL parser's lightness component — no new luminance math),
   warm/cool/neutral breakdown (from the existing optional `Undertone`
   field), seasonal color affinity (top colors per `Season` using
   `WardrobeItem.seasonality`), primary-vs-accent usage (% of items with a
   `secondaryHex`, plus its own swatch gallery), favorite color combos
   (co-occurring color-vibe pairs across `SavedCombination` — every saved
   outfit is an implicit "I liked this enough to keep it" signal — windowed
   by `savedAt`, ghost elements excluded), and a natural-language "why"
   insight contrasting wardrobe composition (what you own) against learned
   taste affinity (what you rate highly, via the existing
   `AttributePreferenceProfile.colorVibeAffinity`) — gated on
   `AnalyticsConfigResponse.stillLearningBelowRatings` so it never makes a
   taste claim before there's enough rating data.
2. **`Features/Insights/StyleView.swift` + `StyleViewModel.swift`** — the
   Style sub-tab's screen. Unlike `OverviewViewModel`, this needs learned
   taste affinity, so `StyleViewModel` calls the existing
   `WardrobeRepository.fetchFeedbackHistory()` (already version-cached)
   rather than re-deriving `AttributePreferenceProfile` itself.
   `ratingSampleSize` for confidence gating uses the identical definition
   Overview's snapshot does (`itemRatings.count` + detailed
   `outfitFeedbacks.count`, passed in from `StyleView`'s own `@Query`
   results), keeping confidence gating consistent across sub-tabs.
3. **`InsightsView.swift`** — wired the Style segment to `StyleView`
   instead of the "Coming Soon" placeholder.

### Scope notes
Composition sections (swatches, dark/light, warm/cool, seasonal,
primary/accent) are current-wardrobe snapshots, not time-windowed —
`WardrobeItem` has no acquisition date (same scope cut as Phase 4's
Overview). The shared `TimeRangeSelector` is used only by the Favorite
Combos section, the one sub-section with real per-row dates
(`SavedCombination.savedAt`). Style DNA, mapped to this same Style sub-tab
per the Phase 1 plan, stays deferred to Phase 10.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Simulator walkthrough deferred at the user's request (continuing straight through the phase sequence); this phase is purely additive (new Domain file, new feature files, one `switch` case rewired in `InsightsView.swift`) so no regression risk to existing screens. Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 4: Overview tab (5th "Insights" nav tab, on-device aggregation engine)

**Status:** ✅ Shipped — Build Succeeded

### Context
Third implementation slice of Analytics & Insights, following the approved
Phase 1 plan's execution order (Phase 2 backend/infra scaffolding shipped
2026-07-18, Phase 3 feedback collection shipped 2026-07-19 earlier). This is
the first phase with a real user-facing surface — the Insights tab shell and
its first sub-tab, Overview — and the first phase that reads the data Phase
2/3 wired up.

### What shipped
1. **`Domain/AnalyticsTimeRange.swift`** — the shared 30d/3mo/6mo/1yr/all-time
   selector every Insights sub-tab will reuse (per the Phase 1 plan's "built
   once" note), with `currentInterval`/`previousInterval` for
   current-vs-previous-period comparisons. Pure, no I/O.
2. **`Domain/AnalyticsAggregator.swift`** — pure, NaN-safe, on-device
   aggregation (Domain/CLAUDE.md isolation rules) building an
   `OverviewSnapshot` from `WardrobeItem`/`ItemRating`/`OutfitFeedback`/
   `WornLogEntry`: current wardrobe color/category composition, rating and
   wear-log activity deltas (current period vs. previous), a one-sentence
   style summary, and up to 3 natural-language discoveries. Deliberately
   does **not** report a wardrobe-growth stat — `WardrobeItem` has no
   acquisition-date field, and this phase didn't add one just to synthesize
   a number (see the Phase 4 plan's scope note); every figure traces back to
   a real timestamped row.
3. **`Domain/AnalyticsLog.swift`** — dedicated `[Insights]` logger, mirroring
   `Domain/MLLog.swift`'s pattern (`Diagnostics/AppLog.swift` is explicitly
   off-limits below the Domain layer).
4. **`Features/Insights/`** — new feature folder: `InsightsView` (the 5th tab
   shell, segmented control across Overview/Style/Trends/Wardrobe/Discover
   per the Phase 1 plan's nav mapping — only Overview is functional this
   phase, the rest show a "Coming Soon" `ContentUnavailableView` placeholder
   so the nav shell is complete for later phases), `OverviewView` +
   `OverviewViewModel` (the glanceable summary screen — composition bars,
   activity deltas with a confidence badge via `Domain/AnalyticsConfidence.swift`,
   discoveries card with an honest empty-state nudge when there isn't enough
   data yet), and `TimeRangeSelector` (shared segmented picker wrapping
   `AnalyticsTimeRange`). `OverviewView` reads `WardrobeItem`/`ItemRating`/
   `OutfitFeedback`/`WornLogEntry` via `@Query` directly — same "declarative
   binding, not a Service call" convention `Features/Profile/ProfileView.swift`
   already established for full-history aggregate reads — and hands the raw
   rows to `OverviewViewModel.recompute(...)`, which also fetches
   `AnalyticsConfigResponse` via the existing `AnalyticsConfigService`.
5. **`RootTabView.swift`** — added the 5th `.tabItem` ("Insights",
   `chart.bar.xaxis`), staying within Apple's un-collapsed 5-tab limit per
   the Phase 1 plan's nav decision.

### Scope cut, flagged not silently skipped
Not yet pushing to `AnalyticsSnapshot` (the Firestore cross-device cache from
Phase 2) — deferred until more phases land so the `payloadJSON` shape isn't
locked in on a single metric. On-device recompute is cheap and instant
either way; cross-device first-paint caching can be added later without
reworking the aggregation math itself.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Simulator walkthrough of the new tab and the still-unexercised Phase 3 UI was deferred at the user's request (moving straight to Phase 5); no functional regressions expected since this phase is purely additive (new tab, new files, one new tab-item line in `RootTabView.swift`). Tests skipped per standing project instruction.

---

## 2026-07-19 — Analytics & Insights, Phase 3: Better Feedback Collection (symmetric like-reason chips, occasion tag, would-buy/save-for-inspiration, replacement suggestion, "Wore This" quick action)

**Status:** ✅ Shipped — Build Succeeded

### Context
Second implementation slice of Analytics & Insights, following the approved
Phase 1 plan's execution order (Phase 2 backend/infra scaffolding shipped
2026-07-18). This phase collects richer, still-lightweight feedback signals
that later phases (Wardrobe Insights, Style Trends, Style DNA) will read, and
fixes a real gap the Phase 1 analysis flagged: the app had no real-world wear
signal at all, only recommendation-selection proxies.

### What shipped
1. **`OutfitFeedback` gained five optional/defaulted columns**
   (`Models/FeedbackEvent.swift`): `likeReasonsRaw` (new `OutfitLikeReason`
   enum — the positive-side counterpart to the existing `OutfitChangeReason`,
   kept deliberately symmetric per the Stylist Intelligence Engine's
   "symmetric taste injection" precedent), `occasionRaw` (new
   `OutfitOccasion` tag — distinct from the existing `occasionMatch`
   satisfaction rating; this records *what* the occasion was), `wouldBuySimilar`
   (tri-state `Bool?` — `nil` is genuinely "unanswered," not "No"),
   `savedForInspiration` (plain `Bool`), and `replacementSuggestionRaw` (new
   bounded `ReplacementSuggestion` enum — a structured alternative to a
   free-text box for the Weakest Piece pick, matching this feature's
   "avoid long forms" rule). `SchemaV11` added (`Models/SchemaMigrations.swift`,
   `SchemaV10` froze the pre-Phase-3 `OutfitFeedback` shape as a nested type
   per this file's established pattern), purely additive `.lightweight`
   migration.
2. **New `WornLogEntry` model** (`Models/WornLogEntry.swift`) — the "Wore
   This" quick action, a leading swipe action on `Features/Combinations/CombinationsView.swift`'s
   saved-outfit rows (`CombinationsViewModel.logWorn(_:)`). Event-sourced,
   append-only, synced like ordinary user-authored feedback (unlike the
   internal-only `RecommendationImpressionEvent`, which stays local).
3. **Full Cloud Sync wiring** for `WornLogEntry` and the extended
   `OutfitFeedback` payload, matching the existing pattern exactly:
   `SyncEntityType.wornLogEntry`, `WornLogEntryDTO`/extended
   `OutfitFeedbackDTO` (`Data/Sync/FirestoreDTOs.swift`), push/pull on
   `Services/WardrobeSyncService.swift` (new `users/{uid}/wornLogEntries`
   collection, no rules change needed), dispatch in
   `Data/SyncOutboxWorker.swift`, bootstrap-push/pull-apply in
   `Data/WardrobeSyncCoordinator.swift`, `WardrobeRepository.fetchWornLogEntries()`/`logWorn(savedCombinationID:itemIDs:)`
   on both `SwiftDataWardrobeRepository` and the `SyncingWardrobeRepository`
   decorator (the decorator recovers the SwiftData-minted id via
   `fetchWornLogEntries().first`, same technique `recordItemRating` already
   uses, so the pushed DTO's id always matches the local row's id).
4. **UI** (`Features/Rating/RateCombinationView.swift`/`RateCombinationViewModel.swift`):
   like-reason chips (shown only when `overallSatisfaction >= 4`, mirroring
   the existing change-reason checklist's style), an occasion menu picker, a
   Yes/No/unanswered tri-state chip for "would buy," a plain toggle for
   "save for inspiration," and a replacement-suggestion checklist shown only
   when a Weakest Piece is picked — all optional, all one extra tap, no new
   required steps in the existing rating flow.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. Not run in Simulator (no dev-server/UI-automation tooling invoked this session); the new chips/toggle/swipe-action follow existing, already-verified UI patterns exactly (same `Form`/`Section`/checklist-row idioms already shipped in this same view). Tests skipped per standing project instruction.

---

## 2026-07-18 — Analytics & Insights, Phase 2: backend/infra scaffolding (Style DNA/Trends/Wardrobe/Shopping tabs come in later phases)

**Status:** ✅ Shipped — Build Succeeded

### Context
First implementation slice of the Analytics & Insights feature (full spec:
favorite colors, interactive charts, style trends, richer feedback,
wardrobe/shopping insights, Style DNA). Phase 1 was an architecture-analysis
plan (no code) concluding that all analytics math should run **on-device**
(reusing `WardrobeItem`/`ItemRating`/`OutfitFeedback`/`ItemFeedback`/
`PairFeedback`/`RecommendationImpressionEvent`, already local and already
cross-device synced) rather than a new server-computed aggregation pipeline —
avoiding duplicate logic in TypeScript, avoiding the repo's first
cross-user-scale scheduled Cloud Function, and getting offline support for
free. The backend's role is intentionally small: a durable cross-device cache
of the client's own computation, plus one server-resolved config endpoint.
This phase builds only the plumbing; Overview/Style/Trends/Wardrobe/Discover
tab UI and the actual aggregation math land in later phases.

### What shipped
1. **New SwiftData models** — `Models/AnalyticsSnapshot.swift` (opaque
   `payloadJSON` blob per computed period, so future metrics never need a
   schema migration) and `Models/RecommendationAnalyticsSnapshot.swift`
   (internal-only shown/selected funnel rollup — spec: "implemented
   internally but should not yet become a major user-facing feature").
   `SchemaV10` added (`Models/SchemaMigrations.swift`), purely additive
   `.lightweight` migration; `Vision_clotherApp.swift` now builds its
   `ModelContainer` from `SchemaV10.models`.
2. **Full Cloud Sync wiring** for both new tables, matching the existing
   delta+outbox+conflict-resolution pattern exactly (`Data/CLAUDE.md`):
   `SyncEntityType` gained `.analyticsSnapshot`/`.recommendationAnalyticsSnapshot`
   (`Models/SyncMetadata.swift`); new DTOs in `Data/Sync/FirestoreDTOs.swift`;
   push/pull methods on `Services/WardrobeSyncService.swift` (new Firestore
   collections `users/{uid}/analyticsSnapshots` and
   `users/{uid}/recommendationAnalyticsSnapshots`, no rules change needed —
   the existing generic per-uid catchall already covers them); dispatch cases
   in `Data/SyncOutboxWorker.swift`; bootstrap-push and pull-apply logic in
   `Data/WardrobeSyncCoordinator.swift` (the pull-apply path also reconciles
   the "one row per periodKey" invariant across devices, since two devices
   can independently mint a snapshot for the same not-yet-synced period);
   new `WardrobeRepository` methods (`fetch*`/`upsert*ByPeriodKey`) on both
   `SwiftDataWardrobeRepository` and the `SyncingWardrobeRepository`
   decorator.
3. **Backend: `GET /analytics/config`** — `backend/functions/src/analyticsConfig.ts`
   (canonical thresholds, mirrors `entitlementLimits.ts`) +
   `routes/analyticsConfig.ts` (fourth deliberate business-logic exception,
   alongside accountDelete/iapVerify/entitlementLimits), mounted in `app.ts`
   behind `responseCache`. Resolves confidence/unlock thresholds
   (`stillLearningBelowRatings`, `highConfidenceAtRatings`,
   `styleDNAMinRatings`, `trendsMinDataPoints`, `wardrobeInsightsMinItems`,
   `wardrobeInsightsMinWornLogs`) server-side — not tier-gated (confirmed:
   advanced analytics ship unlocked for all tiers in this pass).
4. **iOS client for that endpoint** — `Models/AnalyticsConfigResponse.swift`,
   `Services/AnalyticsConfigService.swift` (Remote/Mock/AuthGated, mirrors
   `EntitlementLimitsService.swift` exactly), `ProxyConfig.analyticsConfigURL`,
   `ServiceFactory.makeAnalyticsConfigService()`.
5. **`Domain/AnalyticsConfidence.swift`** — shared `ConfidenceLevel`
   (stillLearning/moderate/high) banding, driven entirely by the fetched
   config, never a re-literaled threshold.

### Product gap flagged, not yet filled
No wear-tracking exists anywhere in the app (`lastWorn`/`wearCount`/etc. —
none). Wardrobe Insights (a later phase) needs a real signal beyond
recommendation-selection proxies; a lightweight "Wore this" log is planned
for the Phase 3 feedback-improvements slice, not this one.

### Verification
`xcodebuild -project Vision_clother.xcodeproj -scheme Vision_clother -sdk iphonesimulator clean build` — succeeded. No UI surface yet to walk through (infra-only phase); tests skipped per standing project instruction.

---

## 2026-07-18 — UX Fix: User message appeared only after AI response; generic spinner replaced with themed multi-stage loading indicator

**Status:** ✅ Shipped — Build Succeeded

### Problem
In `DailyAssistantViewModel.sendTurn`/`performProspectivePurchaseCheck`, the
UI-facing chat timeline (`rounds: [ConversationRound]`) was only appended to
*after* `await workTask.value` resolved the full LLM chain — each
`ConversationRound` bundled the user's text and the AI's outcome together in
one struct, appended in the same `switch outcome` block. So tapping Send
showed nothing until the whole request/response round trip finished, at
which point the user's own message and the AI's reply popped in
simultaneously. Loading itself was a single generic `ProgressView` + static
"Thinking through your closet…" caption with no indication of which step
(fetch wardrobe, build catalog, call the LLM, validate picks) was actually
running.

### Fix
1. **Immediate message display.** `ConversationRound.Outcome` gained a
   `.pending` case. `sendTurn`/`performProspectivePurchaseCheck` now append a
   `.pending` round with the user's text *synchronously*, before any
   `async`/network work starts — so the user's bubble renders the instant
   Send is tapped. The same round's `outcome` is mutated in place
   (`rounds[index].outcome = ...`) once the real result arrives, or the round
   is removed entirely on failure/timeout/supersession (mirrors the
   pre-existing no-round-shown-on-failure behavior).
2. **Themed multi-stage loading indicator.** Added
   `DailyAssistantViewModel.LoadingStage` (`.analyzingPhoto`,
   `.fetchingWardrobe`, `.buildingCatalog`, `.consultingStylist`,
   `.validatingPicks`), each with a label + SF Symbol (`tshirt`,
   `square.grid.2x2`, `sparkles`, `checkmark.seal`, `camera.viewfinder`).
   `resolveOutfits`/`resolveProspectivePurchase` set `loadingStage` at each
   real stage boundary (these already run on the `@MainActor` view model, so
   no extra hop is needed). `DailyAssistantView`'s new `LoadingStageView`
   renders the current stage as the assistant side of the latest `.pending`
   round — right under the user's message, with `symbolEffect(.pulse)` and a
   crossfade between stages — replacing the old flat spinner in
   `statusView`, which now only handles `.failed` (loading is inline on the
   round itself).

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantViewModel.swift` | Added `ConversationRound.Outcome.pending`; added `LoadingStage` enum + `var loadingStage`; `sendTurn`/`performProspectivePurchaseCheck` append a `.pending` round synchronously before their `async` work, then mutate it in place or remove it based on outcome; `resolveOutfits`/`resolveProspectivePurchase` set `loadingStage` at each stage boundary |
| `Features/DailyAssistant/DailyAssistantView.swift` | `roundView` handles `.pending` via new `LoadingStageView`; `statusView` no longer renders a `.loading` case (moved inline); added `LoadingStageView` (pulsing SF Symbol + stage label, crossfades between stages) |

---

## 2026-07-17 — Fix: Recommendation 401s traced to invalid OpenRouter key, not a secret-encoding bug; upstream error bodies were unlogged

**Status:** ✅ Shipped — Cloud Functions deployed

### Problem
`/openrouter/recommend` returned `HTTP 401` past `verifyAuth.ok`/`quota.ok`
(i.e. auth and quota gates were fine; OpenRouter itself was rejecting the
call). Initial hypothesis was a trailing newline baked into
`OPENROUTER_API_KEY`/`PEXELS_API_KEY` from `plutil -extract ... raw` (which
does append `\n`) — re-provisioned both secrets stripped and redeployed, but
the 401 persisted on a verified-fresh post-deploy Cloud Run instance
(`DEPLOYMENT_ROLLOUT` log confirmed a new instance, still 401'd). Root cause
turned out to be simpler and unrelated to encoding: `curl`'d
`https://openrouter.ai/api/v1/auth/key` directly with the raw key from
`Secrets.plist` (bypassing Firebase entirely) and got 401 straight from
OpenRouter — the key itself (well-formed `sk-or-v1-...`, 73 chars) is
invalid/revoked on OpenRouter's side. Also note: `firebase functions:secrets:access`
always appends its own trailing `\n` on stdout, which had made an
already-clean secret version look corrupted under a naive `wc -c`/`xxd`
check — a debugging red herring in its own right.
Separately, and the real process failure: `openrouterChat.ts`/`openrouterImages.ts`/
`pexelsSearch.ts` all read the upstream response body into `text` and forwarded
it to the client, but only logged `status`/`durationMs` on failure — never the
provider's own `error.message` (e.g. "Invalid API key"), which would have
identified "bad key" vs. "malformed request" vs. "provider outage" in one log
line instead of the above investigation.

### Fix
- `backend/functions/src/logger.ts`: added `upstreamErrorSnippet(rawBody)` —
  parses a failed upstream JSON body, pulls just `error.message` (or a raw
  text fallback), truncates to 200 chars. Kept within the existing redaction
  rule (never log raw bodies/keys) by extracting only the provider's message,
  not the full body.
- `backend/functions/src/routes/openrouterChat.ts`,
  `openrouterImages.ts`, `pexelsSearch.ts`: on non-`ok` upstream responses,
  `upstreamResponse` warn logs now include `upstreamErrorMessage` via the
  helper above.
- Re-provisioned `OPENROUTER_API_KEY`/`PEXELS_API_KEY` into Secret Manager
  via a pipeline that strips any trailing newline before `--data-file -`
  (`plutil -extract ... raw -o - Secrets.plist | tr -d '\n' | firebase
  functions:secrets:set ... --data-file -`) and redeployed. This did not fix
  the 401 (the stored key was already effectively clean).
- Confirmed via the new `upstreamErrorMessage` logging: OpenRouter returns
  `"User not found."` for every model/route on this key — the key's
  associated OpenRouter account no longer exists (deleted/removed org), not
  a malformed-key issue.
- User generated a fresh `OPENROUTER_API_KEY` from a live OpenRouter account.
  Verified directly against `https://openrouter.ai/api/v1/auth/key` (200,
  real account, no usage limit) before touching Secret Manager, then
  provisioned via the same newline-safe pipeline and redeployed
  (`OPENROUTER_API_KEY` secret version 4).

| File | Change |
|---|---|
| `backend/functions/src/logger.ts` | Added `upstreamErrorSnippet` helper |
| `backend/functions/src/routes/openrouterChat.ts` | Logs `upstreamErrorMessage` on failed upstream calls |
| `backend/functions/src/routes/openrouterImages.ts` | Logs `upstreamErrorMessage` on failed upstream calls |
| `backend/functions/src/routes/pexelsSearch.ts` | Logs `upstreamErrorMessage` on failed upstream calls |
| Secret Manager (`visionclother` project) | `OPENROUTER_API_KEY`, `PEXELS_API_KEY` re-provisioned via newline-safe pipeline |

---

## 2026-07-17 — Fix: Backend never deployed — quota tracking had no persistent home

**Status:** ✅ Shipped — Cloud Functions deployed, secrets provisioned, `xcodebuild clean build` succeeded

### Problem
While verifying the `UsageTracker` display fix below, found the actual dominant
cause of "quota not working at all": **Cloud Functions had never been enabled
or deployed** in the `visionclother` Firebase project (`403: Cloud Functions
API has not been used in project visionclother before or it is disabled`), and
`Vision_clother/Config/ProxyConfig.swift`'s `#if DEBUG` branch was hardcoded to
a local Firebase emulator tunneled through a personal ngrok URL. That
emulator's Firestore is a separate, in-memory-only store from real production
Firestore, and gets wiped on every emulator restart (not run with
`--import`/`--export-on-exit`). Confirmed via direct Firestore/Auth queries:
zero `users/{uid}/meta/usage` documents existed anywhere in real production
Firestore, for any account, including the developer's own long-lived Google
account — the server-side quota counter (`quota.ts`, otherwise verified
correct/transactional) had simply never run against persistent storage.
Restarting the local emulator during normal backend iteration wiped all
locally-tracked quota state, which looked identical to "quota reset to
maximum" from the app's point of view.

### Fix
- Provisioned `OPENROUTER_API_KEY`/`PEXELS_API_KEY` into Secret Manager
  (`firebase functions:secrets:set`, piped from `Vision_clother/Config/Secrets.plist`
  — values never printed) — this also auto-enabled the previously-disabled
  Secret Manager API.
- `backend/functions/src/index.ts`: added `invoker: "public"` to the `api`
  `onRequest` config — the first deploy attempt succeeded but Cloud Run
  rejected every request with a 403 at the IAM layer (separate from the app's
  own `verifyAuth` Firebase-ID-token check) because nothing had granted
  `allUsers` invoke access. Without this, a valid ID token still never reaches
  Express.
- Deployed via `firebase deploy --only functions --project visionclother` —
  live at `https://api-z3sgjy64ga-uc.a.run.app`, confirmed with `curl` (401
  `missing_id_token` from the app's own middleware, not Cloud Run's 403).
- `Vision_clother/Config/ProxyConfig.swift`: both `#if DEBUG` and `#else`
  branches now point at the deployed URL — DEBUG previously pointed at the
  ephemeral local-emulator/ngrok setup described above. Local backend-code
  iteration should still swap DEBUG back to `localhost`/ngrok as needed, but
  start the emulator with `--import`/`--export-on-exit` to avoid this same
  class of bug re-appearing locally.

| File | Change |
|---|---|
| `backend/functions/src/index.ts` | Added `invoker: "public"` to `onRequest` config |
| `Vision_clother/Config/ProxyConfig.swift` | Both DEBUG and Release `baseURL` now point at the deployed function URL |
| Secret Manager (`visionclother` project) | `OPENROUTER_API_KEY`, `PEXELS_API_KEY` provisioned |
| Cloud Functions (`visionclother` project) | `api` (2nd gen, us-central1) deployed for the first time |

---

## 2026-07-17 — Fix: Quota display resetting to maximum on relaunch / mid-session

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Reported: the recommendations/combinations quota shown in the app renewed to
maximum as soon as the app was closed and reopened, and sometimes reset
mid-session while switching views or typing. Server-side enforcement
(`backend/functions/src/middleware/quota.ts`) and Firestore rules
(`backend/firestore.rules`, client write access to `meta/usage` is `false`)
were both confirmed correct — the bug was entirely in the new client-side
read model, `Vision_clother/Data/UsageTracker.swift`:
1. `refreshUsage()` did `usage = try? await syncService.fetchUsage(uid:)`,
   collapsing *any* failure (network blip, permission-denied while a fresh ID
   token propagates, decode error) into `nil`. Since the used-count computed
   properties fall back to `?? 0` on a `nil` `usage`, any transient fetch
   failure displayed as "quota reset to maximum" — indistinguishable from a
   real reset. Every foreground (`Vision_clotherApp.swift`'s
   `scenePhase == .active` handler) triggers this fetch, explaining the
   "renews on reopen" symptom.
2. Three uncoordinated call sites (`UsageTracker.init`'s `AuthService.shared.$uid`
   subscription, the app's `scenePhase` handler, and `AccountSectionView`'s
   `.task(id:)`/manual refresh) had no in-flight guard, so an older, slower
   fetch could resolve after a newer one (or after an optimistic
   `record*Used()` bump) and silently overwrite it — explaining the
   "sometimes while changing views/typing" resets.
3. Separately, `recordRecommendationUsed()`/`recordCombinationUsed()` never
   checked `usage.periodKey` against the current month before incrementing,
   so a stale cross-month DTO would keep accumulating instead of resetting.
Confirmed `AuthService.uid` itself does not flicker during normal use (only
on explicit sign-out/delete-account) — ruled out as a contributing cause.

### Fix
All changes in `Vision_clother/Data/UsageTracker.swift`:
- `refreshUsage()` now uses `do`/`catch` instead of `try?`: a genuinely
  missing Firestore doc (`nil`, no throw) is adopted as real "0 used", but a
  thrown error is logged and leaves `usage` untouched (keeps last-known-good
  value) instead of wiping it.
- Added `refreshGeneration`, a monotonic counter captured per-call before the
  `await`; a fetch only commits its result if it's still the most recently
  *started* one, so a slow/stale fetch can no longer clobber a newer read or
  an optimistic increment.
- Added a `UserDefaults`-backed cache (`UsageTracker.cachedUsage.\(uid)`,
  `UsageDTO` is already `Codable`) — `init` seeds `usage` from the cache
  before the first network refresh completes, so a cold launch shows the
  last known count immediately instead of a blank/zero state; the cache is
  updated on every successful fetch and optimistic increment.
- `recordRecommendationUsed()`/`recordCombinationUsed()` now route through a
  new `currentPeriodUsage()` helper that resets to a fresh zeroed `UsageDTO`
  when the cached `periodKey` doesn't match the current UTC month, instead of
  incrementing stale counts.

| File | Change |
|---|---|
| `Vision_clother/Data/UsageTracker.swift` | `refreshUsage()` error handling + generation guard; `UserDefaults` last-known-usage cache (seed on init, write on fetch/optimistic increment); `currentPeriodUsage()` cross-month reset guard for optimistic increments |

---

## 2026-07-17 — Fix: Six High-severity scale/cost findings (prompt caching, response caching, quota loopholes, fail-open abuse vector, unbounded sync pull, View/ViewModel layering)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A review of the app's readiness for multi-user scale (not personal single-device use — see `docs/decisions/resolved-v1.md`) flagged six High-severity findings, all pointing at cost/availability paths that work fine today but break first at 10x users:
1. The recommendation call's ~75-80KB catalog + system prompt was retransmitted in full on every clarification turn, with no prompt-caching breakpoints.
2. No response-level caching for identical/near-identical recommendation requests — a retry or repeat ask cost a full paid inference call every time.
3. `AccountSectionView`, `ProfileView`, `DailyAssistantView` each held their own `@ObservedObject AuthService.shared` and read its published state directly, bypassing their ViewModels (`Features/CLAUDE.md`: "Views never call Services directly").
4. `/openrouter/images` was mounted with no quota gate at all — reachable directly with a valid ID token, bypassing the try-on quota by construction (gated by URL path, not by feature).
5. `rateLimit`/`quotaGate` both failed open on any Firestore error, for every caller including anonymous/guest accounts — a free-to-mint cost-abuse vector.
6. `WardrobeSyncService.fetchCollection`'s Firestore pull had zero pagination across all 7 synced collections — fine for a delta pull, unbounded on a fresh-device full/bootstrap pull for an engaged user's history.

### Fix
- **Prompt caching:** `OutfitRecommendationService.encodeRequestBody` now wraps the system prompt and turn-0's catalog/scenario/weather content in OpenRouter's `cache_control: {"type": "ephemeral"}` content-array form (`cacheableContent` helper) — both blocks are byte-identical across a clarification session's turns, so this turns each later turn's full-catalog resend into a cached-prefix read on models that support it, and is inert/additive on models that don't. Also decodes+logs `usage.prompt_tokens_details.cached_tokens` when present, for observability.
- **Response cache:** new `backend/functions/src/middleware/responseCache.ts` — hashes the raw request body per-uid, checks/writes a 10-minute-TTL Firestore doc (`users/{uid}/responseCache/{hash}`), and short-circuits before `quotaGate` on a hit (zero quota charged, zero upstream call). Mounted only on `/openrouter/recommend` in `app.ts` (not `/openrouter/tryon` — image responses are a poor fit for a Firestore doc cache).
- **Quota loophole:** `/openrouter/images` is now mounted behind `quotaGate("tryOn")` in `app.ts`, same feature as `/openrouter/tryon` (it's the dedicated-Images-API fallback branch of the same two services).
- **Fail-open abuse vector:** `rateLimit.ts`/`quota.ts` now fail **closed** (503) specifically for `req.isAnonymous` requests on a Firestore error, and keep failing open for linked accounts — targets the actual free-to-mint abuse vector without risking an outage-wide availability regression for real users.
- **Unbounded pull:** `WardrobeSyncService.fetchCollection` now pages with `.order(by: "updatedAt")` + `.limit(to: 300)` + `.start(afterDocument:)`, looping until a short page — no `firestore.indexes.json` change needed (single-field index, automatic).
- **View/ViewModel layering:** `AccountSectionViewModel`/`ProfileViewModel`/`DailyAssistantViewModel` each gained Combine-backed mirrors (`bindAuthState()`) of the `AuthService.shared` `@Published` fields they need (`isSignedIn`/`isAnonymous`/`uid`/`guestSessionError`, subset per screen) — a plain computed forwarding property wouldn't be reactive under `@Observable`, since its change tracking only fires on the class's own stored-property writes. The three views dropped their `@ObservedObject AuthService.shared` and read the mirrored ViewModel properties instead.

Deliberately **not** touched: App Check/attestation (blocked on a paid Apple Developer account, per the existing ADR) and the `4.2` "what's next" items (Firestore transaction contention, empty `firestore.indexes.json`) — no concrete failure evidence yet for either, flagged as follow-ups rather than silently fixed.

| File | Change |
|---|---|
| `Vision_clother/Services/OutfitRecommendationService.swift` | `cacheableContent` cache-control wrapper on system + turn-0 messages; decode+log `usage.prompt_tokens_details.cached_tokens` |
| `backend/functions/src/middleware/responseCache.ts` | New — per-uid response cache middleware |
| `backend/functions/src/app.ts` | Mount `responseCache` ahead of `quotaGate` on `/openrouter/recommend`; gate `/openrouter/images` behind `quotaGate("tryOn")` |
| `backend/functions/src/middleware/rateLimit.ts`, `quota.ts` | Fail-closed (503) for `req.isAnonymous` on a Firestore error; unchanged fail-open for linked accounts |
| `Vision_clother/Services/WardrobeSyncService.swift` | `fetchCollection` rewritten with `.order`/`.limit`/`.start(afterDocument:)` pagination loop |
| `Features/Profile/AccountSectionView.swift`, `AccountSectionViewModel` (same file) | Added `isSignedIn`/`isAnonymous`/`uid`/`guestSessionError` Combine mirrors + `bindAuthState()`; view drops `@ObservedObject AuthService.shared` |
| `Features/Profile/ProfileView.swift`, `ProfileViewModel.swift` | Added `uid` mirror + `bindAuthState()`; view drops `@ObservedObject AuthService.shared` |
| `Features/DailyAssistant/DailyAssistantView.swift`, `DailyAssistantViewModel.swift` | Added `isAnonymous`/`uid` mirrors + `bindAuthState()`; view drops `@ObservedObject AuthService.shared` |

---

## 2026-07-17 — Fix: Duplicate `ForEach` ID warning in `ProfileView`'s "Best Pairings" list

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Console warning: `ForEach<...>: the ID ... occurs multiple times within the collection, this will give undefined results!` — non-fatal but persistent. `ProfileView.swift:564` keyed `ForEach(pairs.prefix(5), id: \.itemA.id)` off only the first item of each top-pair tuple. Since the same wardrobe item can appear as `itemA` in more than one top pair (paired with different partners), two distinct rows collided on the same `UUID`.

### Fix
Switched the `ForEach` to key off the array index (`Array(pairs.prefix(5).enumerated())`, `id: \.offset`) — matching the existing convention already used elsewhere in this same file (`tasteSignals`, `buckets` at lines 471/529/539) for non-`Identifiable` derived collections, rather than inventing a compound-pair identifier.

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Vision_clother/Features/Profile/ProfileView.swift` | "Best Pairings" `ForEach` keyed by array offset instead of `itemA.id` |

---

## 2026-07-17 — Fix: Concurrent Cloud Sync passes racing on the same pulled `WardrobeItem` rows

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Crash recurred after the same-day `markMutated()` fix below, still on the same `WardrobeItem.slot` "backing data detached from context" fault, but this time with **duplicated** `[Sync] pullChanges: starting`/`ok items=1` log lines at the same instant. Traced to two independent entry points with no reentrancy guard: `WardrobeSyncCoordinator.init`'s `AuthService.shared.$uid` Combine subscription (which delivers immediately on subscribe) calls `handleUIDChange` → `handleSignIn`, while `Vision_clotherApp.swift`'s `scenePhase → .active` hook independently calls `reconcileIfSignedIn` → `reconcile`. At launch with an already-signed-in user both fire near-simultaneously, landing two overlapping `pullAndApply` passes that each independently discover and delete-and-reinsert the *same* pulled `WardrobeItem` row — doubling the odds that some other reference (e.g. a cached inventory array) gets orphaned mid-window, on top of the missing-`markMutated` issue.

### Fix
Added a single `isSyncOperationInFlight` reentrancy gate (`runExclusiveSyncOperation`) in `WardrobeSyncCoordinator.swift`, wrapping the three true entry points — `reconcileIfSignedIn`, `retrySync`, `handleUIDChange` — so only one full sync pass (`handleSignIn`/`reconcile`/`pullAndApply`) ever runs at a time; a second concurrent call now logs and no-ops instead of racing.

| File | Change |
|---|---|
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` | Added `isSyncOperationInFlight` + `runExclusiveSyncOperation`; wrapped `reconcileIfSignedIn`/`retrySync`/`handleUIDChange` bodies with it |

---

## 2026-07-17 — Fix: Crash reading `WardrobeItem.slot` after a Cloud Sync pull ("backing data detached from context")

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
User-reported crash: searching Daily Assistant triggered a foreground Cloud Sync pull (`pullChanges: ok items=1`), the recommendation call succeeded, and then the app hit `SwiftData/BackingData.swift:249: Fatal error: This backing data was detached from a context without resolving attribute faults — \WardrobeItem.slot`.

Root cause: `WardrobeSyncCoordinator.applyWardrobeItemChange` (and every sibling `apply*Change`) applies a pulled change by **deleting** the existing row and **inserting a brand-new model instance** with the same `id` — never mutating in place. `DailyAssistantViewModel.wardrobeSnapshot()` caches `inventoryCache: [WardrobeItem]` keyed by `WardrobeMutationTracker.shared.version`, specifically so any wardrobe change invalidates it — but `WardrobeSyncCoordinator`'s pull path (`pullAndApply`) and account-switch wipe (`wipeLocalMirror`) never called `markMutated()`. So a `DailyAssistantViewModel` that had already cached its inventory kept serving `WardrobeItem` references to now-deleted rows after a pull/wipe; the next property read on one of them (`.slot`, during catalog building/outfit resolution) crashed. Confirmed pre-existing — unrelated to the same-day performance-audit changes (investigated and ruled out before fixing).

### Fix
Added `WardrobeMutationTracker.shared.markMutated()` in two places in `WardrobeSyncCoordinator.swift`: at the end of `pullAndApply`, gated on `!delta.wardrobeItems.isEmpty` (matches the existing save/update/delete call sites' granularity); and unconditionally in `wipeLocalMirror`, right after the local-mirror delete loop (every `WardrobeItem` is gone at that point regardless of what changed).

| File | Change |
|---|---|
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` | `pullAndApply`: bump `WardrobeMutationTracker` when a pull touches `WardrobeItem` rows. `wipeLocalMirror`: bump unconditionally after wiping. |

---

## 2026-07-17 — Perf: Data-Scaling Audit (Power-User Closet/History Growth)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Requested audit for hidden data-scaling bottlenecks that would surface once a power user accumulates thousands of wardrobe items/combinations/impressions and years of feedback history — even though everything works fine at demo scale today. Three parallel codebase sweeps (SwiftData query bloat, synchronous I/O/crypto in serial paths, view-body/collection-algorithm/retain-cycle patterns) turned up 9 concrete findings, prioritized by impact, fixed in order.

### Fixes
1. **Cached/backgrounded image loading (8 views):** Every wardrobe/photo grid cell (`ClosetView`, `ItemDetailView`, `ManualPairingView`, `CombinationsView`, `CombinationDetailView`, `RateItemView`, `RateCombinationView`, `OutfitCardView`) called `UIImage(contentsOfFile:)` synchronously inside a `@ViewBuilder`, re-decoding from disk on every re-render with zero caching. Added `ImageStorage.cachedImage(for:)` (bounded `NSCache`, off-main-actor decode via `Task.detached`, invalidated in `write`/`delete`/`wipeAll`) and a shared `CachedWardrobeImage` SwiftUI view (`DesignSystem/CachedWardrobeImage.swift`); replaced all 8 call sites.
2. **`WardrobeSyncCoordinator.pushEverythingLocal` unbounded fetches:** Bootstrap sync fetched entire `OutfitFeedback`/`ItemFeedback`/`PairFeedback`/`ItemRating`/`SwipeEvent` tables (esp. `SwipeEvent`) in one shot onto `@MainActor`. A time-window predicate would be *incorrect* here (bootstrap must push all-time history to establish the cloud mirror) — instead added `pushAllInBatches` (500-row pages, `Task.yield()` + incremental `modelContext.save()` between batches) to bound peak memory/main-actor monopolization without changing which rows sync.
3. **`ClosetView.displayItems`:** Recomputed ghost-fill + full sort once per `Slot.allCases` section (7x per render) via a computed property called from inside the loop. Hoisted to a single `let allItems = displayItems` at the top of `body`, threaded through `slotSection`/tap handler.
4. **Query bounds — `ProfileView`/`CombinationsView`/`fetchFeedbackHistory`:** `ProfileView.itemRatings` was a full-table `@Query` used only for an `.isEmpty` check — replaced with a `fetchLimit: 1` existence query. (`outfitFeedbacks` was left full-history: `.count`/weekday-mode/most-recent are genuine all-time aggregates with no cheaper SwiftData query shape, and are bounded by human rating cadence, not swipe/impression volume — a limit there would have been a silent correctness regression.) `CombinationsView`/`CombinationDetailView`'s `SavedCombination` `@Query` capped to the most recent 300 (a real browse list, unlike Profile's aggregates). `WardrobeRepository.fetchFeedbackHistory()`'s `SavedCombination` fetch was scoped from a full-table fetch down to exactly the ids referenced by the already-180-day-windowed `outfitFeedbacks` — bounded *and* correctness-safe even when an old combo is rated again recently.
5. **`ItemRatingScoring`:** `score(for:history:)` rescanned all of `history.pairFeedback` per item — O(items × pairFeedback) when called once per rendered cell. Added `scores(for:history:)` batch form that folds `pairFeedback` onto each item id once, then does O(1) lookups; `ClosetView` now calls it once per render instead of `score(for:)` per cell. Original `score(for:history:)` left untouched so existing direct-construction tests keep passing.
6. **`JobQueueStore`:** `jobs` is app-session-lifetime and append-only, each `Job.thumbnail` holding a full-resolution photo forever. Thumbnails are now downscaled (`ImageStorage.downscaledJPEGForUpload`, 200px/0.6 quality) at enqueue time instead of storing originals; array capped at 200 retained jobs, evicting oldest *terminal* jobs first (in-flight jobs never evicted).
7. **`AddItemView` fingerprint loop + `SyncOutboxWorker.drainNow`:** Up to 20 photos' SHA256 fingerprinting ran sequentially on the main actor inside a plain `Task {}`; each hash now runs via `Task.detached`. `drainNow` pushed dirty rows one at a time; now fans out up to 5 concurrent pushes via `withTaskGroup`, with row mutations still serialized on `@MainActor`.
8. **`RecommendationImpressionEvent` retention:** Table had a `shownAt` field but no reader and no prune — pure unbounded growth. Added a 90-day retention prune (`WardrobeRepository.pruneOldImpressionEvents`), run opportunistically at the top of `recordImpressions`.

### Changes

| File | Change |
|---|---|
| `Vision_clother/Data/ImageStorage.swift` | Added bounded `NSCache`-backed `cachedImage(for:)`, cache invalidation in `write`/`delete`/`wipeAll` |
| `Vision_clother/Vision_clother/Vision_clother/DesignSystem/CachedWardrobeImage.swift` (new) | Shared cache-first async image view |
| `Vision_clother/Vision_clother/Features/{Closet/ClosetView,Closet/ItemDetailView,Pairing/ManualPairingView,Combinations/CombinationsView,Combinations/CombinationDetailView,Rating/RateItemView,Rating/RateCombinationView,DailyAssistant/OutfitCardView}.swift` | Replaced synchronous `UIImage(contentsOfFile:)` with `CachedWardrobeImage` |
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` | `pushEverythingLocal`: batched/yielding `pushAllInBatches` instead of 5 unbounded full-table fetches |
| `Vision_clother/Vision_clother/Features/Closet/ClosetView.swift` | `displayItems` computed once per `body`; batch rating-score lookup |
| `Vision_clother/Vision_clother/Features/Profile/ProfileView.swift` | `itemRatings` → `fetchLimit: 1` existence query |
| `Vision_clother/Vision_clother/Features/Combinations/{CombinationsView,CombinationDetailView}.swift` | `SavedCombination` query capped to most recent 300 |
| `Vision_clother/Data/WardrobeRepository.swift` | `fetchFeedbackHistory()`'s `SavedCombination` fetch scoped to referenced ids; added `pruneOldImpressionEvents()` (90-day retention) called from `recordImpressions` |
| `Vision_clother/Domain/ItemRatingScoring.swift` | Added `scores(for:history:)` batch form |
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | Downscaled thumbnails at enqueue time; capped `jobs` to 200 with terminal-job eviction |
| `Vision_clother/Vision_clother/Features/Closet/AddItemView.swift` | Per-photo SHA256 fingerprinting moved to `Task.detached` |
| `Vision_clother/Data/SyncOutboxWorker.swift` | `drainNow` fans out up to 5 concurrent pushes via `withTaskGroup` |

Deliberately out of scope / flagged as follow-ups: `Job.kind`'s retained payload `Data` (`rawImageData`/`baseImageData`) still isn't cleared after a job succeeds (only `thumbnail` is downscaled) — clearing it would need `Job.kind`/`UploadPayload`/`TryOnPayload` to become mutable, a slightly larger model change than this pass's risk budget. A true "load more" pagination UI for `CombinationsView` beyond the 300-item cap wasn't built (out of scope for a low-risk audit pass).

---

## 2026-07-17 — Fix: Main-actor disk I/O + hashing on every closet-photo cache check in `fetchFeedbackHistory()`

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Code review flagged `WardrobeRepository.fetchFeedbackHistory()`/`DailyAssistantViewModel.resolveOutfits` as O(closet size) per turn with no incremental-recompute strategy. Investigation confirmed `DailyAssistantViewModel.wardrobeSnapshot()` already caches inventory/history across conversation turns (invalidated only by `WardrobeMutationTracker`, i.e. an actual item add/edit/delete) — so the "every message" framing didn't match current code. The real, still-live bug: whenever `fetchFeedbackHistory()` *does* run (on a wardrobe mutation or cold app launch), its embedding cache-validity check read every non-ghost item's photo off disk and SHA256-hashed it synchronously **on the main actor**, for every item — including the hundreds that hadn't changed — before any of that work reached the existing off-main-actor `WardrobeEmbeddingWorker`.

### Fix
Added `WardrobeItem.imageFingerprint: String?` — a plain additive optional field (no `SchemaV10`; matches the existing `ColorProfile.undertone` precedent that this exact shape of change needs no schema-version bump under SwiftData's lightweight migration). Set once, at every site that writes fresh photo bytes for a `WardrobeItem` (`JobQueueStore.performUpload` — reusing a fingerprint already computed there for log correlation, `DailyAssistantViewModel.resolveProspectivePurchase`, `WardrobeSyncCoordinator.downloadMissingPhotos`'s Cloud Sync photo backfill). Deliberately local-only, not added to `WardrobeItemDTO` — same posture as the already-local-only `WardrobeItemEmbedding` table it exists to cheapen lookups against.

`fetchFeedbackHistory()`'s embedding section now does a cheap, synchronous, pure in-memory pass first: an item with a persisted `imageFingerprint` matching its cached embedding's fingerprint resolves with zero disk I/O and zero hashing. Only items that can't be resolved this way — a pre-existing row saved before this field existed, or a genuine cache miss — go through a new `WardrobeEmbeddingWorker.computeFingerprints(for:)`, parallelized off the main actor via `withTaskGroup` (same pattern as the existing `computeEmbeddings`). Results backfill `imageFingerprint` on first sight so every later fetch for that item takes the cheap branch. No migration script needed — nil fields resolve themselves lazily, once, the first time each pre-existing item is seen.

### Changes

| File | Change |
|---|---|
| `Vision_clother/Models/WardrobeItem.swift` | Added `var imageFingerprint: String? = nil` + init param |
| `Vision_clother/Services/WardrobeEmbeddingWorker.swift` | Added `FingerprintRequest`/`FingerprintResult` + `computeFingerprints(for:)`, parallel off-actor disk read + hash |
| `Vision_clother/Data/WardrobeRepository.swift` | `fetchFeedbackHistory()`: replaced the unconditional main-actor disk-read+hash loop with a fast in-memory-compare path plus an off-actor backfill pass for unresolved items |
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | `performUpload`: sets `item.imageFingerprint` from the fingerprint already computed for ingestion log correlation |
| `Vision_clother/Vision_clother/Features/DailyAssistant/DailyAssistantViewModel.swift` | `resolveProspectivePurchase`: sets `prospectiveItem.imageFingerprint` at save time |
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` | `downloadMissingPhotos`: sets `imageFingerprint` on `WardrobeItem` rows whose photo bytes were just backfilled from Cloud Storage, `modelContext.save()`s directly (not through `SyncingWardrobeRepository`, matching this file's existing pull-mutation posture) |

Deliberately out of scope: the four 180-day-windowed SwiftData fetches (`pairFeedbacks`/`itemFeedbacks`/`itemRatings`/`outfitFeedbacks`) stay serial on the main actor — true parallelization would need a second background `ModelContext` off the same `ModelContainer`, a bigger change that cuts against this layer's "only place that touches `ModelContext`" invariant (`Data/CLAUDE.md`) and risks object-identity issues across contexts. Flagged to the user as a follow-up if profiling shows it's still a bottleneck after this fix.

---

## 2026-07-17 — UX Polish: Move Account/Debug Controls into a Gear-Icon Sheet

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
`AccountSectionView` (Sign In/Out, Delete Account, sync status, Debug Log export) rendered as the very first item in `ProfileView`'s `List`, pushing the user's avatar, photo actions, and style attributes below account/debug chrome most users touch rarely. This doesn't match standard iOS convention, where account/settings controls live behind a gear icon, not inline at the top of a profile screen.

### Changes
`AccountSectionView` itself is unchanged — only its call site moved. `ProfileView` gained a `gearshape` toolbar button (`.primaryAction`, alongside the existing `JobQueueBadgeButton()`) that presents a `.sheet` wrapping `AccountSectionView()` in its own `NavigationStack { List { ... } }` with a "Done" dismiss action (`.cancellationAction`), so the `Section("Account")` styling still renders correctly outside the main list. `WardrobeSyncCoordinator`'s environment value propagates into the sheet automatically since it's presented from within `ProfileView`. The main `List` now starts directly with `identitySection` (avatar, photo actions, style attributes), followed by "Discover Your Style" and "Test Your Style".

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Features/Profile/ProfileView.swift` | Added `isSettingsPresented` state, gearshape toolbar button, `.sheet` wrapping `AccountSectionView()`; removed `AccountSectionView()` from the top of the main `List` |

---

## 2026-07-16 — Feature: Firestore + Cloud Storage Wardrobe Sync (Delta + Durable Outbox)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Signing in with a different Google/phone account showed the exact same local closet every time. `AuthService`/`isSignedIn` only ever gated which network services `ServiceFactory` picked (real vs. mock) — it was never consulted by `WardrobeRepository`, which lived in one shared, ownerless local `ModelContainer`. The user asked for the full fix (real per-account cloud sync), and — once told this targets a real App Store release at production scale, not a personal single-device app — specifically asked for delta sync (not full snapshot push/pull), a durable local outbox/dirty-bit (not fire-and-forget writes), real per-record conflict resolution, and compressed/lazy photo transfer, rather than the cheaper personal-app shortcuts an initial pass had proposed.

### Changes
Firestore is the source of truth once an account has synced; local SwiftData stays a full on-device cache/mirror, wiped-and-reloaded on account switch (no per-record `ownerUID`). Every synced doc carries a Firestore-authoritative `updatedAt` (`FieldValue.serverTimestamp()`, merged in server-side, never trusted from a client field); steady-state pulls query only `updatedAt > lastPulledAt`; deletes are soft (`isDeleted` tombstones, since a hard delete is invisible to a `>` query). One new local-only table, `SyncMetadata` (`SchemaV9` — the only schema change), holds a JSON-encoded DTO snapshot per dirty entity; `SyncingWardrobeRepository` (decorates `WardrobeRepository`, same idiom as `CachedTryOnRenderService`) upserts a dirty row in the same local save as every mutation, and `SyncOutboxWorker` drains dirty rows with exponential backoff on every mutation and every foreground. Conflict resolution is per-record last-write-wins with the dirty side protected — a pull never overwrites a local row that's dirty and at least as new. First sign-in for an account pushes this device's existing local data up if the account has no cloud history yet (protects pre-auth data), or wipes-and-fully-pulls if it does (a second device/reinstall); every later reconcile is delta-only. Sign-out does not wipe local data (matches the existing "sign-in is optional" posture) — the wipe happens lazily on the next *different* account's sign-in. 9 of 11 `@Model` types sync (`WardrobeItemEmbedding`/`RecommendationImpressionEvent` stay local-only). Photos upload to Cloud Storage at upload time only — PNG (alpha-preserving, wardrobe cutouts) or JPEG (opaque, saved-combination renders) — downscaled to 1024px; pull applies metadata immediately and downloads missing photo bytes in an unawaited background pass. No backend involvement — the client talks to Firestore/Storage directly, gated by security rules keyed on `request.auth.uid`.

| File | Change |
|---|---|
| `Vision_clother/Models/SyncMetadata.swift` (new) | Local-only outbox/conflict-resolution table (`SchemaV9`) |
| `Vision_clother/Models/SchemaMigrations.swift` | `SchemaV9` added (lightweight migration, new independent table) |
| `Vision_clother/Data/Sync/FirestoreDTOs.swift` (new) | One `Codable` DTO per synced type, framework-agnostic (no `updatedAt`/`isDeleted` fields — those are sync metadata, handled at the Firestore call site) |
| `Vision_clother/Services/WardrobeSyncService.swift` (new) | Protocol + `FirestoreWardrobeSyncService`/`MockWardrobeSyncService` — push (server-timestamp merge), delta/full pull, sync status, image upload/download |
| `Vision_clother/Data/SyncingWardrobeRepository.swift` (new) | Decorates `WardrobeRepository`, marks `SyncMetadata` dirty + best-effort image upload on every mutation |
| `Vision_clother/Data/SyncOutboxWorker.swift` (new) | Drains dirty `SyncMetadata` rows with exponential backoff |
| `Vision_clother/Data/WardrobeSyncCoordinator.swift` (new) | Bootstrap (push-local-up / wipe-and-pull) + delta reconcile + account-switch wipe, driven by `AuthService.shared.$uid` |
| `Vision_clother/Data/ImageStorage.swift` | Added `write(_:filename:)`, `wipeAll()`, `downscaledPNGForUpload`, `downscaledJPEGForUpload` |
| `Vision_clother/Services/AuthService.swift` | Added `@Published uid: String?` |
| `Vision_clother/Vision_clother/Services/ServiceFactory.swift` | Added `makeWardrobeSyncService()` |
| `Vision_clother/Vision_clotherApp.swift` | Constructs `WardrobeSyncCoordinator`; `scenePhase` foreground hook calls `reconcileIfSignedIn()`; repository construction renamed to `SyncingWardrobeRepository` |
| 18 call sites across `Features/` | Mechanical rename `SwiftDataWardrobeRepository(modelContext:)` → `SyncingWardrobeRepository(modelContext:)` |
| `Vision_clother.xcodeproj/project.pbxproj` | `FirebaseStorage` SPM product linked (via the `xcodeproj` Ruby gem, same approach as prior Firebase package additions) |
| `backend/storage.rules` (new), `backend/firestore.rules`, `backend/firebase.json`, `backend/firestore.indexes.json` (new) | Per-uid Storage rules; Firestore rules opened from deny-all to `users/{uid}/**` scoped to `request.auth.uid` (`rateLimits` stays admin-only); both deployed live |
| `docs/decisions/resolved-v1.md`, `CLAUDE.md`, `Vision_clother/Data/CLAUDE.md`, `docs/ios/architecture.md` | Cloud Sync decision section; Core Invariant reworded (photos now leave the device via Cloud Storage; the recommendation LLM call itself still never sees images) |

## 2026-07-16 — Fix: Cap Concurrent In-Flight Jobs in `JobQueueStore`

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A security review flagged that `enqueueUpload`/`enqueueTryOn` each spawned an independent, uncapped background `Task` hitting the OpenRouter-backed API directly, with no maximum in-flight job count. Combined with the embedded API key, a bulk action (e.g. importing 50 photos) or deliberate abuse could fire dozens of concurrent requests against a paid third-party API with no circuit breaker.

### Changes
Added a `maxConcurrentJobs = 3` cap enforced via a `pendingStarts` FIFO queue: `scheduleStart(_:_:)` starts a job immediately if under the cap, otherwise queues its start closure (job stays `.queued`, already the existing status for this case). `startNextPendingIfAny()` drains the queue by one whenever a running job frees a slot — wired into `finishJob` (covers all upload terminal paths and explicit cancellation) and both terminal cases of `handleTryOnUpdate` (try-on succeeded/failed). `cancelJob` also removes a still-queued (not yet started) job from `pendingStarts` so cancelling before a slot opens doesn't later start it anyway.

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | Added `maxConcurrentJobs`/`pendingStarts`/`scheduleStart`/`startNextPendingIfAny`; `enqueueUpload`, `retryUpload`, `enqueueTryOn` now go through `scheduleStart` instead of starting their `Task` unconditionally; `finishJob` and `handleTryOnUpdate`'s terminal cases drain the pending queue; `cancelJob` also prunes `pendingStarts` |

## 2026-07-16 — Refactor: Deduplicate Two-Stage Isolate Fallback in `JobQueueStore`

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A code-review pass flagged that `JobQueueStore.performUpload` (the tracked-upload path) and `JobQueueStore.isolateAndTag` (the prospective-purchase path) duplicated the same two-stage isolate sequence — Gemini preprocess falling back to the raw photo, then on-device Vision falling back to stage 1's output — almost verbatim, with a code comment explicitly acknowledging the duplication as a deliberate lower-risk tradeoff over restructuring.

### Changes
Extracted the fallback sequencing (not the job-status/cancellation interleaving, which genuinely differs between the two call sites) into two small private helpers, `isolateStage1(_:)` and `isolateStage2(_:)`, each a one-line `try? ... ?? fallback`. `performUpload` still sets job status and checks `Task.isCancelled` between stages; `isolateAndTag` calls both helpers back-to-back with no interleaving, matching its one-shot, non-job-tracked nature.

| File | Change |
|---|---|
| `Vision_clother/Vision_clother/Features/JobQueue/JobQueueStore.swift` | Added `isolateStage1`/`isolateStage2` private helpers; `performUpload` and `isolateAndTag` both call them instead of duplicating the do/catch fallback logic |

## 2026-07-16 — Backend: Google Sign-In + Phone Auth Replace Sign in with Apple; Firestore Provisioned

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`), backend tests 12/12 passing

### Problem
The Firebase proxy shipped earlier the same day assumed Sign in with Apple + App Check (App Attest) as the only auth path — both require a paid Apple Developer account, which isn't available yet. The user asked to wire the app to their existing Firebase project (`visionclother`, number `1008598090428`), use Google Sign-In + Phone Number auth instead, register the iOS app in that project, and provision Firestore.

### Changes

| File | Change |
|---|---|
| `backend/.firebaserc` | Points at project `visionclother` (via `npx -y firebase-tools@latest use`) |
| Firebase project (via CLI, no console clicks except the one below) | iOS app registered (`apps:create IOS`), `GoogleService-Info.plist` fetched (`apps:sdkconfig IOS`), Firestore Standard-edition default database created, Google Sign-In enabled (`firebase.json`'s `auth` block + `deploy --only auth`) |
| `backend/firestore.rules`, `backend/firebase.json` | New deny-all Firestore rules (only the Admin SDK's rate-limit counter touches it) |
| `backend/functions/src/app.ts` | Middleware chain drops `verifyAppCheck` — App Check deferred, same paid-account blocker |
| `backend/functions/src/middleware/verifyAppCheck.ts` | Deleted (never actually built — the SPM product was never linked) |
| `backend/functions/test/middleware.test.ts` | App-Check test cases removed |
| `Vision_clother.xcodeproj/project.pbxproj` | `FirebaseDatabase` (Realtime Database, mistakenly linked) swapped for `FirebaseFirestore`; `GoogleSignIn-iOS` package added; `INFOPLIST_FILE` set on the app target (Debug/Release) to a supplemental `Config/URLSchemes.plist`, kept alongside `GENERATE_INFOPLIST_FILE = YES` — done via a one-off script using the same `XcodeProj` Swift library `xcode-project-setup`'s vetted script uses, not hand-edited text |
| `Vision_clother/Config/URLSchemes.plist` (new) | `CFBundleURLTypes`: Google's `REVERSED_CLIENT_ID` + the app's bundle ID (for phone auth's reCAPTCHA redirect) |
| `Vision_clother/Config/GoogleService-Info.plist` (new) | Firebase client config for the `visionclother` project — not a secret, safe to commit |
| `Vision_clother/Services/AuthService.swift` | Sign in with Apple (`AuthenticationServices`/nonce/delegate) replaced with `signInWithGoogle()` (`GoogleSignIn` SDK), `startPhoneSignIn`/`confirmPhoneSignIn` (`PhoneAuthProvider`), new `signOut()` |
| `Vision_clother/Config/FirebaseBootstrap.swift` | App Check provider registration dropped; configures `GIDSignIn` with Firebase's client ID |
| `Vision_clother/Services/ProxyAuthHeaders.swift` | Drops the `X-Firebase-AppCheck` header |
| `Vision_clother/Vision_clotherApp.swift` | `.onOpenURL` routes the Google consent redirect and phone-auth reCAPTCHA redirect back into the app |
| `Vision_clother/Vision_clother/Features/Profile/AccountSectionView.swift` (new) | Google button + phone number/OTP two-step flow + sign-out, wired as the first section in `ProfileView.swift` |
| `docs/backend/architecture.md`, `docs/backend/conventions.md`, `docs/decisions/resolved-v1.md`, `backend/README.md` | Reflect Google/Phone auth, dropped App Check, Firestore on `visionclother` |

## 2026-07-16 — Docs: Reconcile Try-On Architecture Docs with OpenRouter Reality

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
A code-review pass flagged that `docs/decisions/resolved-v1.md`, `docs/ios/architecture.md`, `docs/architecture.md`, and `docs/backend/architecture.md` all still described the try-on renderer as Fal + `fashn/tryon/v1.6` (async submit → poll queue, one garment per call). No `Fal*.swift` file has ever existed in the tree — the app moved to `Services/OpenRouterTryOnRenderService.swift` (Gemini image models via OpenRouter, single synchronous request, all garments composed in one call) before the Fal path was ever implemented, and the docs were never updated to match.

### Changes

| File | Change |
|---|---|
| `docs/decisions/resolved-v1.md` | Diffusion Provider decision marked **superseded**; new decision documents OpenRouter/Gemini (`ModelConfig.imageToImage`), single-call multi-garment compose, no async poll |
| `docs/architecture.md`, `docs/ios/architecture.md`, `docs/backend/architecture.md`, `docs/backend/conventions.md`, `docs/approach/conventions.md` | All Fal/FASHN references (diagrams, model names, "async submit → poll", per-garment chaining, API key mentions) replaced with the actual OpenRouter/Gemini single-request architecture |
| `CLAUDE.md`, `Vision_clother/Services/CLAUDE.md` | "Fal pipeline" async-boundary guardrail rewritten to describe `OpenRouterTryOnRenderService`'s single bounded-timeout request instead of a poll loop |
| `Vision_clother/Vision_clother/Features/DailyAssistant/DailyAssistantViewModel.swift` | Stray comment citing `FalTryOnRenderService`'s precedent renamed to `OpenRouterTryOnRenderService` |
| `Vision_clother/Services/APIKeys.swift` | Removed dead `APIKeys.fal` (no remaining caller) |
| `Vision_clother/Config/README.md`, `Secrets.example.plist`, `Secrets.plist` | Removed `FAL_API_KEY` — never read by any real service |

## 2026-07-15 — Feature: Multi-Accessory Outfits

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #1 from `docs/decisions/stylist-intelligence-engine.md`: an outfit could only ever carry one accent item, so "bag + belt + jewelry" couldn't be recommended simultaneously.

### Root Cause
Cross-slot accessorizing (bag + headwear + accessory) already worked — `Slot` already had three independent accent cases. The real gap was the single `.accessory` slot being an explicit catch-all ("one per outfit, not several simultaneously" — `StylistBrain.swift`/`OutfitRecommendationService.swift`), so belt and jewelry collided for the one slot.

### Changes

| File | Change |
|---|---|
| `Domain/FashionKnowledgeConstants.swift` | New `maxSupplementaryAccessories = 2` |
| `Models/OutfitRecommendationResponse.swift` | `RecommendedOutfitWire.supplementaryAccessoryIDs: [String]`, decoded/encoded via the existing dynamic-key container |
| `Services/OutfitRecommendationService.swift` | JSON schema gained `supplementary_accessory_ids` (array, capped, required key/optional-empty) |
| `Domain/OutfitRecommendationValidator.swift` | New explicit resolution step alongside (not inside) the existing per-slot loop; extends the duplicate-id check; truncates over-cap rather than rejecting |
| `Models/OutfitCombination.swift` | New `supplementaryAccessories: [WardrobeItem]`, folded into `items` |
| `Domain/StylistBrain.swift` | Prompt rewritten: business/interview/formal must leave it empty; casual/going-out may use up to the cap |
| `Models/SavedCombination.swift`, `SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `supplementaryAccessoryItemIDs`/`Labels`; new `SchemaV8`, additive `.lightweight` migration |
| `Features/JobQueue/JobQueueStore.swift`, `Features/Combinations/CombinationsViewModel.swift` | Both `SavedCombination` build/resolve integration points carry the new fields |
| `Features/DailyAssistant/OutfitCardView.swift`, `DailyAssistantViewModel.swift` | One card row per supplementary accessory; included in the LLM replay summary |

## 2026-07-15 — Feature: "What Would You Change?" Checklist (Level 3 Outfit Feedback)

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #2 from `docs/decisions/stylist-intelligence-engine.md`: Level 1/2 dimension-based outfit feedback shipped, but the "what specifically was wrong" structured edit checklist (Level 3) was scoped and never built.

### Changes

| File | Change |
|---|---|
| `Models/FeedbackEvent.swift` | New `OutfitChangeReason` enum (7 cases); `OutfitFeedback.changeReasonsRaw: [String]` |
| `Domain/AttributePreferenceProfile.swift` | `OutfitDimensionRatedAttributes` gained `pattern`/`patternDissatisfaction`; `build(from:)` folds it into `patternAffinity` — a new outfit-level entry point for that map |
| `Data/WardrobeRepository.swift` | `OutfitRatingSubmission.changeReasons`; `fetchFeedbackHistory()` clamps the flagged dimension(s) to `min(existing, 0.1)` per rated outfit |
| `Features/Rating/RateCombinationViewModel.swift`, `RateCombinationView.swift` | New checklist section + `toggleChangeReason` (tooFormal/tooCasual mutually exclusive) |
| `Models/SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `SchemaV7` — additive `[String]` column, `.lightweight` migration |

## 2026-07-15 — Feature: Impression/Selection Event Capture

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Closes deferred item #3 from `docs/decisions/stylist-intelligence-engine.md`: the app logs ML drift (`[AI-Stylist-ML]`) but never captured which of several shown candidate outfits the user actually picked/ignored — the highest-value signal for tuning the ranker.

### Changes

| File | Change |
|---|---|
| `Models/RecommendationImpressionEvent.swift` (new) | Event-sourced `@Model` — one row per candidate shown (`roundID`, `rank`, denormalized `itemIDsBySlot`, `shownAt`), `selectedAt` filled in later |
| `Data/WardrobeRepository.swift` | New `recordImpressions(roundID:outfits:)` / `recordSelection(outfitID:)`, both best-effort, logged under `[AI-Stylist-ML]` |
| `Features/DailyAssistant/DailyAssistantViewModel.swift` | `sendTurn`'s success branch calls `recordImpressions`; `startTryOn` calls `recordSelection` |
| `Models/SchemaMigrations.swift`, `Vision_clotherApp.swift` | New `SchemaV6` — purely additive new table, `.lightweight` migration |

Not wired into any ranker yet — this phase only makes the data exist, same posture as `OutfitRecommendationValidator.RejectionReason`.

## 2026-07-15 — Bug Fix: "How does it look on me?" → "Render failed: Invalid image data-url"

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Tapping "How does it look on me?" on a Daily Assistant recommendation failed with an opaque render-API error instead of rendering the try-on image.

### Root Cause
`DailyAssistantView.placeholderBaseImageData` fell back to empty `Data()` whenever the user hadn't captured a base portrait yet (`UserPortraitStorage.load() == nil`). That empty data base64-encoded to an empty `data:image/png;base64,` URL, which OpenRouter rejected with `"Invalid image data-url"`, surfaced as `TryOnError.renderFailed`. Not a regression — a known, previously-commented gap. `ManualPairingView`/`ManualPairingViewModel` already guard this exact precondition elsewhere in the app.

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | `onStartTryOn` now checks `UserPortraitStorage.exists` before enqueuing the try-on job; shows an alert ("Add a photo of yourself on your Profile tab to try on outfits.") instead of sending empty image data |

## 2026-07-15 — Feature: Item Rating question redesign + Swipe-to-Learn implicit swipe bridge

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Two related asks: (1) the per-item rating form's questions (Confidence, Versatility, Predicted Wear Frequency, Quality Perception) read as generic/out-of-scope, and (2) close the loop between the new rating flow and the Swipe-to-Learn visual taste system so ratings — not just the discovery deck — keep the k-means centroids fresh.

### Root cause (question redesign)
`Domain/AttributePreferenceProfile.swift`'s `RatedAttributes` carried one blended `value` (`ItemRating.normalizedValue`, an average across all 8 old questions) that was reused as the signal for three unrelated affinities — color, pattern, and formality — despite no dedicated color or pattern question existing anywhere. Versatility/Frequency/Quality Perception fed nothing else; they only diluted the blend.

### Changes

| File | Change |
|---|---|
| `Models/ItemRating.swift` | Replaced Confidence/Versatility/Frequency/Quality Perception with `colorLike`, `patternLike` (optional, skipped for solid-pattern items), `formalityFit`; rewrote `FitRating.normalizedRating`; clean-break schema (no shipped users) |
| `Domain/AttributePreferenceProfile.swift` | `RatedAttributes` gained dedicated `colorLike`/`patternLike`/`formalityFit`/`silhouetteFit`/`fabricComfort` fields (replacing the blended `value`); `build()`'s accumulation loop feeds each into its matching affinity map directly |
| `Domain/VisualPreferenceProfile.swift` | `VisualClusterUpdater.update` gained an optional `learningRate: Float?` (default `nil` = unchanged `1/weight` step); added `implicitLearningRate = 0.05` for rating-derived nudges |
| `Data/WardrobeRepository.swift` | `recordItemRating` signature updated; new `applyImplicitSwipe`/`loadOrCreateVisualPreferenceState` helpers fold a rating's liked/disliked signal into the same centroids `recordSwipe` maintains, using the gentle learning rate; best-effort, no `SwipeEvent` written |
| `Features/Rating/RateItemViewModel.swift`, `RateItemView.swift` | New question set: Fit, Comfort, Color, Pattern (conditional), Formality Fit, Style Identity, Wear Again |

See `docs/decisions/stylist-intelligence-engine.md` for full rationale, including why `dislikePenaltyWeight = 1.2` / `maxBonusMagnitude = 0.3` were left untouched.

## 2026-07-14 — Feature: Swipe-to-Learn Visual Taste + Embedding-Ranked Catalog Retrieval

**Status:** ✅ Shipped — Build Succeeded (`xcodebuild clean build`)

### Problem
Two related asks: (1) let the app learn visual taste from a Tinder-style like/dislike swipe deck of stock fashion photos, and (2) `Domain/WardrobeCatalogBuilder.swift`'s slot-capping truncation (`slotBalancedSample`) dropped overflow items in arbitrary insertion order once a closet's per-slot item count exceeded its share of `maxItems` — a real user with, say, 40 tops and a 20-item budget would have half their tops silently invisible to the recommendation LLM for no principled reason.

### Fix
Both are solved by the same on-device embedding infrastructure rather than two separate systems:
1. **On-device embeddings, no bundled ML.** `Services/ImageEmbeddingService.swift`'s `VisionFeaturePrintEmbeddingService` uses Apple's free `VNGenerateImageFeaturePrintRequest` to turn any photo into an L2-normalized vector — no CoreML model to ship, no network call.
2. **Online mini-batch k-means.** `Domain/VisualPreferenceProfile.swift`'s `VisualClusterUpdater` maintains up to 3 centroids per liked/disliked side (nearest-centroid nudge, not a single running mean) so genuinely bimodal taste (e.g. "goth-grunge" + "pastel-preppy") doesn't collapse into a meaningless average. `VisualPreferenceProfile.affinityBonus` scores a candidate embedding via bounded (±0.3) cosine similarity against those centroids.
3. **A second, independent re-scoring signal — never touches the LLM.** The app's Core Invariant is that the recommendation LLM only ever sees text/hex attributes, never images. `Domain/OutfitRecommendationEngine.swift`'s `outfitScore` folds in a new `meanVisualBonus` term structurally identical to the existing `AttributePreferenceProfile.affinityBonus` re-rank step — it only runs after LLM candidates return.
4. **Embedding-ranked catalog truncation.** `WardrobeCatalogBuilder.slotBalancedSample` now ranks a slot's candidates by learned visual affinity before capping to `perSlot`, replacing the old arbitrary `.prefix(perSlot)` order. Hard filters (ghost-exclusion, season/formality) are untouched — this only reorders which already-valid items survive the cap. A cold-start (untrained) profile scores every item 0, so with Swift's stable sort this is a byte-for-byte no-op until the user actually swipes.
5. **Swipe deck UI.** `Features/SwipeDiscovery/` — a card-stack `DragGesture` view sourcing photos from a new licensed stock-photo service (`Services/StockImageFeedService.swift`, Pexels — simpler attribution-only licensing than Unsplash), entered from a new "Discover Your Style" row in `Features/Profile/ProfileView.swift`.

### Changes

| File | Change |
|---|---|
| `Models/SwipeDiscovery.swift` (new) | `SwipeEvent`, `VisualCentroid`, `VisualPreferenceState`, `WardrobeItemEmbedding` |
| `Models/SchemaMigrations.swift` | Added `SchemaV4` (purely additive, `.lightweight` V3→V4 migration) |
| `Vision_clotherApp.swift` | `Schema(SchemaV3.models)` → `Schema(SchemaV4.models)` |
| `Services/ImageEmbeddingService.swift` (new) | Protocol + `VisionFeaturePrintEmbeddingService` + `MockImageEmbeddingService` |
| `Services/StockImageFeedService.swift` (new) | Protocol + `PexelsImageFeedService` + `MockStockImageFeedService`; `APIKeys.pexels` |
| `Domain/VisualPreferenceProfile.swift` (new) | `VisualClusterUpdater` (online k-means) + `VisualPreferenceProfile` (affinity scoring) |
| `Domain/OutfitRecommendationEngine.swift` | `FeedbackHistory.visualProfile`/`.itemEmbeddings`; `outfitScore`'s `meanVisualBonus` term |
| `Domain/WardrobeCatalogBuilder.swift` | `slotBalancedSample` ranks by visual affinity before capping (`rank(_:history:)`) |
| `Data/WardrobeRepository.swift` | `recordSwipe`/`fetchVisualPreferenceState`/`updateVisualPreferenceState`/`fetchWardrobeItemEmbedding`/`saveWardrobeItemEmbedding`; `fetchFeedbackHistory()` reads visual-taste state and lazily caches per-item embeddings |
| `Features/SwipeDiscovery/` (new) | `SwipeDiscoveryViewModel` + `SwipeDiscoveryView` (card stack, drag gesture, like/dislike buttons) |
| `Features/Profile/ProfileView.swift` | New "Discover Your Style" entry point |
| `ServiceFactory.swift` | `makeImageEmbeddingService()`, `makeStockImageFeedService()` |
| `Config/` | `PEXELS_API_KEY` added to `Secrets.plist`/`Secrets.example.plist`/`README.md` |
| `Vision_clotherTests/*` | New: `VisualClusterUpdaterTests`, `VisualPreferenceProfileTests`, `ImageEmbeddingServiceTests`, `SchemaV4MigrationTests`, `SwipeDiscoveryViewModelTests`. Extended: `OutfitRecommendationEngineTests`, `WardrobeCatalogBuilderTests`, `WardrobeRepositoryTests`. Updated 6 `WardrobeRepository` test doubles with the 5 new protocol methods. |

---

## 2026-07-14 — Optimization: Database Query Pruning & Background Preference Rebuilding (Bottleneck C)

**Status:** ✅ Shipped — Build Succeeded

### Problem
In `fetchFeedbackHistory()`, the app fetched all database rows for feedback and ratings and processed them sequentially in memory on `@MainActor`. Recomputing the entire historical feedback history on every view appearance causes linear degradation of responsiveness as history grows, freezing the UI.

### Fix
1. **Time-window predicates:** Added a 180-day time-window predicate to SwiftData queries for `PairFeedback`, `ItemFeedback`, `ItemRating`, and `OutfitFeedback` inside `fetchFeedbackHistory()`, resolving the query bloat at the database level.
2. **Background processing:** Overloaded `AttributePreferenceProfile.build()` with a `[ItemAttributeSnapshot]` payload and offloaded the computation to `Task.detached` to avoid blocking `@MainActor`.
3. **Async Signatures:** Made `fetchFeedbackHistory()` async and updated all 4 call sites (`ClosetView`, `ItemDetailView`, `ProfileViewModel`, `DailyAssistantViewModel`) to run the fetch concurrently.

### Changes

| File | Change |
|---|---|
| `Domain/AttributePreferenceProfile.swift` | Added `ItemAttributeSnapshot` sendable struct; added overload for `build(from:outfitDimensionRatings:inventorySnapshots:now:)` |
| `Data/WardrobeRepository.swift` | Updated `fetchFeedbackHistory()` to be async; added 180-day query predicate pruning; offloaded profile rebuilding using `Task.detached` |
| `Features/Closet/ClosetView.swift` | Made `loadFeedbackHistory()` fetch asynchronously inside a `Task` block |
| `Features/Closet/ItemDetailView.swift` | Made `loadFeedbackHistory()` fetch asynchronously inside a `Task` block |
| `Features/Profile/ProfileViewModel.swift` | Updated `refreshFeedbackHistory()` to fetch asynchronously in a `Task` block |
| `Features/DailyAssistant/DailyAssistantViewModel.swift` | Updated `resolveOutfits()` to call `fetchFeedbackHistory()` asynchronously with `await` |
| `Vision_clotherTests/*` | Updated test mock stubs in 7 test suites to conform to the updated async protocol signature |

---

## 2026-07-14 — Fix: Try-On Button Allows Duplicate Queue Submissions

**Status:** ✅ Shipped — Build Succeeded

### Problem
After tapping "How does it look on me?", the button showed "Added to queue" for 1.5 seconds then reset back to the original label — letting the user submit the same outfit combination to the try-on queue multiple times.

### Fix
Replaced `justQueuedTryOn: Bool` + `Task.sleep` reset with `queuedOutfitIDs: Set<OutfitCombination.ID>`. Each outfit's queued state is now **permanent and per-outfit**:
- Once queued, the button stays locked as "Added to queue ✓" for that outfit forever
- Swiping to a different (unqueued) outfit shows a fresh active button for that card
- Swiping back to an already-queued outfit keeps it locked — no re-submission possible

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `@State var justQueuedTryOn: Bool` + `Task.sleep` reset with `@State var queuedOutfitIDs: Set<OutfitCombination.ID>`; removed the Task entirely |

---

## 2026-07-14 — Fix: Outfit Carousel Unswipeable + Screen Scroll Frozen

**Status:** ✅ Shipped — Build Succeeded

### Problem
After the previous UX pass, the outfit recommendation carousel was completely unswipeable and tapping anywhere inside the card area froze the entire screen's vertical scroll. Root cause was a three-layer gesture conflict:

```
ScrollView (vertical)   ← outer chat timeline
  └── TabView(.page)    ← UIKit page controller stealing horizontal drags
       └── OutfitCardView
            └── ScrollView (vertical)  ← inner scroll competing with outer
```

The `TabView(.page)` UIKit gesture recognisers intercept horizontal drags before the outer `ScrollView` can route them correctly. The `highPriorityGesture(DragGesture)` workaround added previously made things worse — it claimed *all* drag directions, freezing the outer vertical scroll entirely.

### Fix
Replaced the entire carousel stack with orthogonal `ScrollView`s — iOS routes horizontal drags to the inner one and vertical drags to the outer one automatically, with no workarounds:

```
ScrollView (vertical)       ← outer chat timeline
  └── ScrollView(.horizontal) ← new carousel, orthogonal = no conflict
       └── OutfitCardView      ← plain VStack, inner scroll removed
```

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `TabView(.page)` + broken `highPriorityGesture` with `ScrollView(.horizontal)` + `scrollTargetBehavior(.viewAligned)` + `scrollTargetLayout()`; added custom animated dot-indicator row |
| `Features/DailyAssistant/OutfitCardView.swift` | Removed inner vertical `ScrollView` — was competing with the outer chat `ScrollView` and causing scroll freeze on tap |

---

## 2026-07-14 — UX Polish: Daily Assistant & Recommendations Navigation

**Status:** ✅ Shipped — Build Succeeded

### Problem
Buttons in the Daily Assistant and Recommendations screens felt sticky and unresponsive:
- Swiping between outfit cards in the carousel was intercepted by the outer scroll view
- Collapse/expand of historical outfit rounds had no animation (jarring instant layout jump)
- Clarification chips could be double-tapped with no visual feedback during async wait
- Item picker tiles in Try-On used `.onTapGesture` — no press-down highlight
- Button spring animation was too slow (0.35s response) making all presses feel laggy

### Changes

| File | Change |
|---|---|
| `DesignSystem/VCButtonStyles.swift` | Tightened spring `response: 0.35 → 0.22`, increased scale/opacity travel for crisper press feedback |
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel; animated expand/collapse; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` |
## 2026-07-14 — UX Polish: Daily Assistant & Recommendations Navigation

**Status:** ✅ Shipped — Build Succeeded

### Problem
Buttons in the Daily Assistant and Recommendations screens felt sticky and unresponsive:
- Swiping between outfit cards in the carousel was intercepted by the outer scroll view
- Collapse/expand of historical outfit rounds had no animation (jarring instant layout jump)
- Clarification chips could be double-tapped with no visual feedback during async wait
- Item picker tiles in Try-On used `.onTapGesture` — no press-down highlight
- Button spring animation was too slow (0.35s response) making all presses feel laggy

### Changes

| File | Change |
|---|---|
| `DesignSystem/VCButtonStyles.swift` | Tightened spring `response: 0.35 → 0.22`, increased scale/opacity travel for crisper press feedback |
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel to claim horizontal swipes from the outer ScrollView; animated expand/collapse with `.spring`; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps before async round completes |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` to horizontal item picker |
