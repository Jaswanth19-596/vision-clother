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

    static func makeTryOnRenderService() -> TryOnRenderService {
        APIKeys.openRouter != nil ? OpenRouterTryOnRenderService() : MockTryOnRenderService()
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

    /// Defaults to the mock — `WeatherKitWeatherProvider` needs the
    /// WeatherKit entitlement added to the app target first (follow-up, see
    /// Services/WeatherProvider.swift's header), so this keeps the app fully
    /// interactive in Simulator without it.
    static func makeWeatherProvider() -> CurrentWeatherProviding {
        MockCurrentWeatherProvider()
    }

    /// On-device (CLAUDE.md guardrail #4) — no API key gate, real
    /// implementation runs everywhere including Simulator.
    static func makeBackgroundIsolationService() -> BackgroundIsolationService {
        VisionBackgroundIsolationService()
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
}
