# Resolved V1 Decisions

Historical architectural decisions locked for V1. Read this when you need the *why* behind a current constraint.

## LLM Driver: OpenRouter + google/gemini-3.1-flash-lite
- OpenRouter provides a single OpenAI-compatible endpoint for model-hopping without code changes.
- minimax-m3 selected for cost-effective structured JSON output via `response_format: json_schema`.
- The LLM is used as the primary outfit recommender (see "LLM-as-Recommender Reversal" below), plus intent/constraint extraction as the fallback path, plus single-garment vision tagging at ingestion and one-time user-profile derivation from the onboarding portrait.

## LLM-as-Recommender Reversal (2026-07-10)
- **Superseded:** the original V1 decision that "the LLM is used only as an intent/constraint extractor — it never sees wardrobe inventory."
- **New decision:** the LLM is the primary outfit recommender. It receives the user's prompt, a *bounded* catalog of wardrobe item text descriptions (id, slot, formality, color/hex, undertone, pattern, seasonality, fabric weight, short description — never images), the derived User Style Profile, weather, and color-theory guidance, and returns outfit picks by item ID (PRD §3.7).
- **Why:** the deterministic-only engine plateaued on recommendation quality — color matching was a single flat vibrant/vibrant penalty ignoring captured hex values, there was no personalization, and weather was wired but unused. Letting the LLM reason over descriptions (not raw wardrobe images, to control cost) unlocks materially better combination judgment while text-only payloads keep per-request cost bounded.
- **Safety net kept:** `Domain/OutfitRecommendationValidator.swift` hard-rejects any LLM pick referencing an unknown ID, wrong slot, duplicate ID, or Ghost Element, then re-scores survivors with the existing Pair-Compatibility Scoring Engine. `Domain/OutfitRecommendationEngine.swift` (the original deterministic engine) is unchanged and used as a full fallback whenever the recommendation call fails or validation yields zero outfits — the app never surfaces an outfit referencing a garment the user doesn't own, and it fully works offline/keyless.
- **Privacy:** the wardrobe catalog is a bounded text payload (never garment images) sent only when a user has not opted out; the portrait image is sent once per profile derivation, never per recommendation. A settings toggle forces the fully deterministic §2.1 path, skipping the recommendation LLM call entirely.

## Diffusion Provider: Fal + fashn/tryon/v1.6 — **superseded**

**Superseded (2026-07-16):** Fal was the original V1 pick — async submit → poll queue pattern, single-garment-per-call `fashn/tryon/v1.6`, multi-garment outfits built by chaining one call per garment. No `Fal*.swift` file was ever shipped; the app moved to OpenRouter before this path was implemented.

**New decision:** try-on rendering goes through `Services/OpenRouterTryOnRenderService.swift`, the same OpenRouter account already used for the LLM driver, calling Google's Gemini image models (`ModelConfig.imageToImage`, currently `google/gemini-3.1-flash-lite-image`) via OpenRouter's `/chat/completions` endpoint (`modalities: ["text", "image"]`) — or a dedicated Images-API model such as `bytedance-seed/seedream-4.5` via `/images`, selected by `ModelConfig.isChatCompletionImageModel`.
- **Why:** one provider account instead of two, and Gemini image models compose an arbitrary number of garment reference images (base portrait + top + bottom + outerwear + …) in a single call/prompt — no per-garment chaining needed, unlike FASHN's one-category-per-call limit.
- **Call shape:** a single synchronous `URLSession` POST (120s timeout to absorb multi-image base64 upload + generation time), not an async submit/poll job. `TryOnState` still models `submitting` / `polling(elapsedSeconds:)` / `succeeded` / `failed` for UI purposes, but the real service only ever emits `.submitting` then `.succeeded`/`.failed` — `.polling` exists for `MockTryOnRenderService`'s staged preview UX, not a real polling loop.
- Images are downscaled to a max 1280px dimension client-side before base64 encoding (portrait as JPEG, garments as PNG to preserve transparency) — full-resolution camera captures were too large to upload inside the timeout.

## State Store: SwiftData On-Device
- All persistence via SwiftData `@Model` classes (`WardrobeItem`, `FeedbackEvent`).
- `WardrobeRepository` protocol isolates storage tech from Domain and Features layers.
- No server-side persistence in V1.

## No Node.js Backend in V1 — **superseded**

**Superseded (2026-07-16):** the original V1 decision to run entirely on-device with API keys embedded in `Config/Secrets.plist` — acceptable for personal dev only, explicitly called out as unsafe to distribute.

## Backend Platform: Firebase (2026-07-16)

**New decision:** `backend/` (Firebase Cloud Functions, Node/TypeScript) now exists — a thin passthrough proxy holding the OpenRouter and Pexels keys server-side, in front of Firebase Auth (Sign in with Apple) and Firebase App Check (App Attest). See `docs/backend/architecture.md` for the full design and `backend/README.md` for setup.

- **Why Firebase over a bare Cloudflare Worker or an AI Gateway (Portkey/Cloudflare AI Gateway):** device attestation was a stated requirement, and Firebase App Check has first-party Apple App Attest support in its iOS SDK — neither alternative does. Accounts/cross-device sync are also on the roadmap, so Firebase Auth covers that on the same platform instead of a second vendor integration later. An AI Gateway alone doesn't cover Fal/Pexels-shaped calls (moot now that Fal is confirmed unused, but it also doesn't natively proxy Pexels).
- **Scope:** 3 passthrough routes (`/openrouter/chat`, `/openrouter/images`, `/pexels/search`) — no per-iOS-service Cloud Function, no business logic server-side. `Domain/` is untouched.
- **Correction discovered during implementation:** the "Diffusion Provider: Fal" entry above was already marked superseded — confirmed here that `APIKeys.fal` had zero call sites and has been removed; the proxy covers OpenRouter + Pexels only.
- **`ServiceFactory`'s mock/real gate** moved from "provider API key present" to "`AuthService.shared.isSignedIn`" (`Services/AuthService.swift`) — same fallback-to-mock behavior for previews/tests/signed-out Simulator runs.
- **Firestore-backed wardrobe sync:** built — see "Cloud Sync: Firestore + Cloud Storage, Delta + Outbox" below.

## Auth Providers: Google Sign-In + Phone (2026-07-16) — supersedes Sign in with Apple for now

**Superseded:** the "Backend Platform: Firebase" entry above assumed Sign in with Apple as the sole auth provider and Firebase App Check (App Attest) as a device-attestation gate.

**New decision:** neither is usable without a paid Apple Developer account — Apple locks the Sign in with Apple capability, and most App ID capability configuration (including App Attest) behind paid membership. Since the account isn't available yet, the app uses **Google Sign-In** (native `GoogleSignIn-iOS` SDK, not a generic web-redirect `OAuthProvider`) and **Phone Number sign-in** instead, and **App Check is dropped** rather than left half-wired.

- **Project:** the app is wired to the user's existing Firebase project, ID `visionclother` (number `1008598090428`) — confirmed fresh/empty before use, so `firebase deploy --only auth` (config-as-code) was safe to run without risking other apps' provider config.
- **Firestore:** Standard edition (not the Firebase tooling's Enterprise default) — the only workload is a single rate-limit counter document per uid via a plain transaction, no BigQuery-style joins/pipelines needed. Security rules (`backend/firestore.rules`) deny all client access; only the Admin SDK (Cloud Functions) touches it.
- **Google Sign-In** needs the `REVERSED_CLIENT_ID` (from `GoogleService-Info.plist`) registered as a URL scheme; **Phone sign-in** (no APNs auth key configured — also paid-account-gated) falls back to Firebase's reCAPTCHA-in-Safari verification, which needs the app's bundle ID registered as a second URL scheme. Both live in `Vision_clother/Vision_clother/Config/URLSchemes.plist`, wired via the `INFOPLIST_FILE` build setting (kept alongside `GENERATE_INFOPLIST_FILE = YES` — Apple's supported merge mechanism, same as adding "URL Types" through Xcode's Info tab) rather than hand-converting every existing `INFOPLIST_KEY_*` setting into a full plist.
- **`FirebaseDatabase` → `FirebaseFirestore`:** the SPM package the user had already added via Xcode linked Realtime Database, not Firestore — swapped to match the actual requirement.
- **App Check dropped, not stubbed** — the previous session's `AuthService.swift`/`FirebaseBootstrap.swift`/`ProxyAuthHeaders.swift`/backend `verifyAppCheck` middleware referenced it, but the build was never green (the SPM product was never linked), so removing it is a simplification, not a regression from a working state. Revisit once a paid Apple Developer account exists.
- **Sign-in UI:** a compact "Account" section (`Features/Profile/AccountSectionView.swift`) now exists in the Profile tab — Google button, phone number + OTP two-step flow, sign-out. Still optional, not a hard gate — `ServiceFactory` keeps falling back to mocks when signed out.

## Cloud Sync: Firestore + Cloud Storage, Delta + Outbox (2026-07-16) — supersedes "State Store: SwiftData On-Device"

**Superseded:** the "State Store: SwiftData On-Device" section above — specifically its "no server-side persistence in V1" line. Signing in with a different Google/phone account showed the exact same local closet every time, because `AuthService`/`isSignedIn` only ever gated which network services `ServiceFactory` picked — it was never consulted by `WardrobeRepository`, which lived in one shared, ownerless local `ModelContainer`.

**New decision:** wardrobe data now syncs per-account to Firestore + Cloud Storage, designed for real App Store scale (thousands of concurrent users), not a personal-app shortcut:

- **Architecture:** Firestore is the source of truth once an account has synced; local SwiftData stays a full on-device cache/mirror. No per-record `ownerUID` — the `ModelContainer` stays one shared store; account switches wipe-and-reload the local mirror instead (see below for exactly when).
- **Delta sync, not full snapshots:** every synced doc carries a Firestore-authoritative `updatedAt` (`FieldValue.serverTimestamp()`, merged in by `Services/WardrobeSyncService.swift` at the write call site — never trusted from a DTO field, to dodge cross-device clock skew). Steady-state pulls (every foreground) query only `updatedAt > lastPulledAt` per collection. Deletes are soft (`isDeleted` tombstone), since a hard Firestore delete is invisible to a `>` query.
- **Durable outbox, not fire-and-forget:** `Models/SyncMetadata.swift` is one new local-only table (added in `SchemaV9`, the only schema change — the 9 synced types themselves are untouched) holding a JSON-encoded DTO snapshot per dirty entity. `Data/SyncingWardrobeRepository.swift` (decorates `WardrobeRepository`, same idiom as `Services/CachedTryOnRenderService.swift`) upserts a dirty row in the same local save as every mutation — crash-safe, since an app kill before any network call still leaves the row on disk. `Data/SyncOutboxWorker.swift` drains dirty rows with exponential backoff, on every mutation and every foreground.
- **Conflict resolution:** per-record last-write-wins, but dirty-side protected — a pull never overwrites a local row whose `SyncMetadata.isDirty` is true and whose `localUpdatedAt` is at least as new as the incoming remote `updatedAt`. No merge UI; acceptable for a personal-closet app with rare concurrent same-record edits.
- **Bootstrap vs. steady-state:** first sign-in for an account checks `users/{uid}/meta/syncStatus` — no remote history yet means *this device's existing local data* is the source of truth and gets pushed up (protects data that predates auth entirely); remote history already existing (a second device, or a reinstall) means the local mirror is wiped and fully pulled. Either way is a one-time cost per device/account; every later reconcile is delta-only.
- **Sign-out does not wipe local data** — matches this app's existing "sign-in is optional, not a hard gate" posture (`Features/Profile/AccountSectionView.swift`). The wipe happens lazily, the moment a *different* account signs in on the same device (tracked via a single `currentMirrorUID` value, not per-account history) — the only property actually being protected (no cross-account data mixing) holds either way.
- **9 of 11 `@Model` types sync** (`WardrobeItem`, `OutfitFeedback`, `ItemFeedback`, `PairFeedback`, `ItemRating`, `SavedCombination`, `UserStyleProfile`, `SwipeEvent`, `VisualPreferenceState`); **2 stay local-only**: `WardrobeItemEmbedding` (pure on-device Vision cache, cheap to recompute) and `RecommendationImpressionEvent` (best-effort local analytics, meaningless across an account switch).
- **Photos:** `Services/WardrobeSyncService.swift` uploads to `users/{uid}/wardrobeImages/{imageAssetName}` in Cloud Storage. Upload-time-only re-encoding (the on-device original is never touched): `WardrobeItem` cutouts stay PNG (alpha required for try-on compositing) but downscaled to 1024px; `SavedCombination` renders are opaque and get downscaled + re-encoded as JPEG. Pull applies item/combination metadata immediately (cheap, text-only) and downloads missing photo bytes in an unawaited background pass afterward — not a full eager download blocking sign-in, and not full per-view lazy loading either (every existing `UIImage(contentsOfFile:)` call site is untouched; a photo that hasn't finished prefetching just shows the same "no image" placeholder state ghost elements already hit).
- **No backend involvement:** the iOS client talks to Firestore/Storage directly via their SDKs, gated by security rules keyed on `request.auth.uid` (`backend/firestore.rules`, `backend/storage.rules`) — routing this through the Node proxy would contradict its own documented "no business logic server-side" scope for no benefit.
- **Wardrobe photos now leave the device** (Cloud Storage), which revises the root `CLAUDE.md` Core Invariant's "never leaves the device" line — see that file for the exact reworded text. The recommendation LLM call itself is unaffected: it still never receives images, only the bounded text/hex catalog.

## Testing Framework: Swift Testing
- Project uses Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
- Domain layer tested with zero mocking — pure function calls with constructed values.
- No test or `#Preview` requires a real API key — `ServiceFactory` returns mocks by default.
