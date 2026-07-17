//
//  ServiceFactory.swift
//  Vision_clother
//
//  Picks the real (Firebase-proxy-backed) network service when a signed-in
//  Firebase Auth session exists (`AuthService.shared.isSignedIn`) and falls
//  back to the mock otherwise — so the app is fully interactive out of the
//  box in Simulator with no Firebase sign-in, per Config/README.md. Prior to
//  the Firebase proxy, this gate was API-key presence
//  (`Config/Secrets.plist`) — see docs/backend/architecture.md.
//

import Foundation

enum ServiceFactory {
    /// `AuthGatedIntentExtractionService` re-checks `isSignedIn` on every
    /// call rather than baking in a one-time snapshot — see that type's doc
    /// comment in `Services/OpenRouterIntentExtractionService.swift` and
    /// `AuthGatedWardrobeSyncService`'s original fix for this class of bug.
    static func makeIntentExtractionService() -> IntentExtractionService {
        AuthGatedIntentExtractionService()
    }

    /// Wrapped in `CachedTryOnRenderService` so a request for an item set
    /// that already has a saved render (against the same base portrait)
    /// reuses that image instead of paying for a fresh AI generation — see
    /// `Services/CachedTryOnRenderService.swift`. `AuthGatedTryOnRenderService`
    /// re-checks `isSignedIn` on every call rather than baking in a one-time
    /// snapshot — see that type's doc comment.
    static func makeTryOnRenderService(repository: WardrobeRepository) -> TryOnRenderService {
        CachedTryOnRenderService(repository: repository, underlying: AuthGatedTryOnRenderService())
    }

    /// `AuthGatedVisionMetadataExtractionService` re-checks `isSignedIn` on
    /// every call rather than baking in a one-time snapshot — see that
    /// type's doc comment in `Services/VisionMetadataExtractionService.swift`.
    /// A one-time snapshot here previously froze `JobQueueStore`'s upload
    /// pipeline on the mock's fixed placeholder description for the rest of
    /// the process's life whenever construction raced ahead of sign-in.
    static func makeVisionMetadataExtractionService() -> VisionMetadataExtractionService {
        AuthGatedVisionMetadataExtractionService()
    }

    /// User Style Profile derivation (PRD §3.8) — sends the onboarding
    /// portrait once per derivation, never per recommendation request.
    /// `AuthGatedUserProfileDerivationService` re-checks `isSignedIn` on
    /// every call rather than baking in a one-time snapshot — see that
    /// type's doc comment in `Services/UserProfileDerivationService.swift`.
    static func makeUserProfileDerivationService() -> UserProfileDerivationService {
        AuthGatedUserProfileDerivationService()
    }

    /// Primary recommendation call (PRD §3.7) — the LLM-as-Recommender path.
    /// The mock reads the real catalog it's given, so the signed-out
    /// Simulator path still exercises `Domain/OutfitRecommendationValidator.swift`
    /// with genuinely valid picks. `AuthGatedOutfitRecommendationService`
    /// re-checks `isSignedIn` on every call rather than baking in a one-time
    /// snapshot — see that type's doc comment in
    /// `Services/OutfitRecommendationService.swift`.
    static func makeOutfitRecommendationService() -> OutfitRecommendationService {
        AuthGatedOutfitRecommendationService()
    }

    /// `OpenMeteoWeatherProvider` needs no API key/entitlement — CoreLocation
    /// + Open-Meteo's free REST API — so it's always the real one here, no
    /// key gate like the OpenRouter-backed services above.
    static func makeWeatherProvider() -> CurrentWeatherProviding {
        OpenMeteoWeatherProvider()
    }

    /// On-device (CLAUDE.md guardrail #4) — no API key gate, real
    /// implementation runs everywhere including Simulator.
    static func makeBackgroundIsolationService() -> BackgroundIsolationService {
        VisionBackgroundIsolationService()
    }

    /// Gemini-based image preprocessing (via OpenRouter) — runs
    /// unconditionally as stage one of every upload
    /// (`JobQueueStore.performUpload`), so unlike the other OpenRouter-backed
    /// factory methods above there's no mock-swap gate here; the real class
    /// itself throws `.missingAPIKey` per call if the user isn't signed in
    /// (`ProxyAuthHeaders`), which `JobQueueStore` catches and falls back
    /// from to the raw photo.
    static func makeImagePreprocessingService() -> BackgroundIsolationService {
        OpenRouterBackgroundIsolationService()
    }

    /// On-device Vision framework, same posture as
    /// `makeBackgroundIsolationService` — no API key gate, runs everywhere.
    static func makePersonPhotoValidationService() -> PersonPhotoValidationService {
        VisionPersonPhotoValidationService()
    }

    /// On-device Photos framework, same posture as
    /// `makePersonPhotoValidationService` — no API key gate, runs everywhere.
    static func makePhotoLibrarySaver() -> PhotoLibrarySaver {
        PHPhotoLibraryImageSaver()
    }

    /// On-device `UNUserNotificationCenter`, same posture as
    /// `makePhotoLibrarySaver` — no API key gate, runs everywhere.
    static func makeNotificationService() -> JobNotificationService {
        UNUserNotificationJobService()
    }

    /// On-device Vision framework (`VNGenerateImageFeaturePrintRequest`),
    /// same posture as `makeBackgroundIsolationService` — no API key gate,
    /// runs everywhere. Powers Swipe-to-Learn Visual Taste.
    static func makeImageEmbeddingService() -> ImageEmbeddingService {
        VisionFeaturePrintEmbeddingService()
    }

    /// Swipe-to-Learn Visual Taste's photo deck — `AuthGatedStockImageFeedService`
    /// re-checks `isSignedIn` on every call rather than baking in a one-time
    /// snapshot, so the swipe deck stays interactive in Simulator with no
    /// Firebase sign-in and doesn't freeze on the mock after a later sign-in.
    static func makeStockImageFeedService() -> StockImageFeedService {
        AuthGatedStockImageFeedService()
    }

    /// Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section) —
    /// `AuthGatedWardrobeSyncService` re-checks sign-in state on every call
    /// rather than baking it in at construction time, since some holders
    /// (`Vision_clotherApp.init()`'s app-root `WardrobeSyncCoordinator`/
    /// `SyncingWardrobeRepository`) are built once and held for the app's
    /// entire lifetime — a one-time mock/real snapshot would go stale the
    /// moment auth state changed after construction. See
    /// `Services/WardrobeSyncService.swift`'s doc comment for the incident
    /// this fixes.
    static func makeWardrobeSyncService() -> WardrobeSyncService {
        AuthGatedWardrobeSyncService()
    }

    /// Account deletion — a one-shot, user-triggered action constructed
    /// fresh at the call site, so unlike the services above it doesn't need
    /// an `AuthGated` wrapper (no long-lived holder to go stale). Real
    /// implementation regardless of sign-in state is safe: the UI
    /// (`AccountSectionView`) only ever offers deletion while signed in, and
    /// a signed-out call would just fail with `.missingAPIKey`.
    static func makeAccountDeletionService() -> AccountDeletionService {
        RemoteAccountDeletionService()
    }

    /// StoreKit purchase verification (`Services/IAPVerificationService.swift`).
    /// Gated on a *linked* (non-anonymous) session, stricter than the plain
    /// `isSignedIn` gate above: purchases hang off the Firebase uid, and a
    /// guest uid is destroyed by sign-out/reinstall, which would orphan paid
    /// credits — the backend 403s anonymous callers for the same reason.
    /// `StoreKitPaymentManager` holds this via a factory closure and
    /// re-resolves per call, so there's no stale-snapshot risk and no need
    /// for a dedicated `AuthGated` wrapper type.
    static func makeIAPVerificationService() -> IAPVerificationService {
        if AuthService.shared.isSignedIn && !AuthService.shared.isAnonymous {
            return RemoteIAPVerificationService()
        }
        return MockIAPVerificationService()
    }
}
