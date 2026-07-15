//
//  ServiceFactory.swift
//  Vision_clother
//
//  Picks the real network service when a dev API key is configured
//  (Config/Secrets.plist) and falls back to the mock otherwise — so the app
//  is fully interactive out of the box in Simulator with no keys set, per
//  Config/README.md.
//

import Foundation

enum ServiceFactory {
    static func makeIntentExtractionService() -> IntentExtractionService {
        APIKeys.openRouter != nil ? OpenRouterIntentExtractionService() : MockIntentExtractionService()
    }

    /// Wrapped in `CachedTryOnRenderService` so a request for an item set
    /// that already has a saved render (against the same base portrait)
    /// reuses that image instead of paying for a fresh AI generation — see
    /// `Services/CachedTryOnRenderService.swift`.
    static func makeTryOnRenderService(repository: WardrobeRepository) -> TryOnRenderService {
        let underlying: TryOnRenderService = APIKeys.openRouter != nil ? OpenRouterTryOnRenderService() : MockTryOnRenderService()
        return CachedTryOnRenderService(repository: repository, underlying: underlying)
    }

    static func makeVisionMetadataExtractionService() -> VisionMetadataExtractionService {
        APIKeys.openRouter != nil ? OpenRouterVisionMetadataExtractionService() : MockVisionMetadataExtractionService()
    }

    /// User Style Profile derivation (PRD §3.8) — sends the onboarding
    /// portrait once per derivation, never per recommendation request.
    static func makeUserProfileDerivationService() -> UserProfileDerivationService {
        APIKeys.openRouter != nil ? OpenRouterUserProfileDerivationService() : MockUserProfileDerivationService()
    }

    /// Primary recommendation call (PRD §3.7) — the LLM-as-Recommender path.
    /// The mock reads the real catalog it's given, so the keyless Simulator
    /// path still exercises `Domain/OutfitRecommendationValidator.swift`
    /// with genuinely valid picks.
    static func makeOutfitRecommendationService() -> OutfitRecommendationService {
        APIKeys.openRouter != nil ? OpenRouterOutfitRecommendationService() : MockOutfitRecommendationService()
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
    /// itself throws `.missingAPIKey` per call if no key is configured
    /// (`APIKeys.openRouter`), which `JobQueueStore` catches and falls back
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

    /// Swipe-to-Learn Visual Taste's photo deck — same key-gated mock/real
    /// swap as `makeIntentExtractionService`, so the swipe deck stays
    /// interactive in Simulator with no Pexels key configured.
    static func makeStockImageFeedService() -> StockImageFeedService {
        APIKeys.pexels != nil ? PexelsImageFeedService() : MockStockImageFeedService()
    }
}
