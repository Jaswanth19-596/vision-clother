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
}
