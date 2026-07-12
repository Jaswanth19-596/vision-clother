//
//  ModelConfig.swift
//  Vision_clother
//
//  Single place to pick which OpenRouter model backs each of the three call
//  shapes this app makes. Change a value here and rebuild — no other file
//  needs to change, since every service's `model:` init parameter defaults
//  to one of these three constants (see each service's `init` for which
//  category it belongs to).
//
//  Categories:
//   - textToText:   free-text prompt (+ optional wardrobe catalog / weather)
//                    in, JSON text out. No images sent or received.
//   - imageToText:  one photo in (garment or portrait), structured JSON
//                    text out. Never returns an image.
//   - imageToImage: base portrait + garment reference photos in, a
//                    generated photo out.
//
//  Swap the active value by editing the constant; the commented
//  alternatives below are known-good OpenRouter slugs worth trying.
//

import Foundation

enum ModelConfig {
    /// Used by: `OpenRouterOutfitRecommendationService` (primary
    /// LLM-as-Recommender call, CLAUDE.md core invariant) and
    /// `OpenRouterIntentExtractionService` (deterministic-fallback
    /// constraint extraction). Both are pure text in, JSON text out.
//     static let textToText = "deepseek/deepseek-v4-flash"
    static let textToText = "google/gemini-3.1-flash-lite"
    
    // Alternatives: "google/gemini-3.1-flash-lite", "openai/gpt-5-mini",
    // "anthropic/claude-haiku-4.5"

    /// Used by: `OpenRouterVisionMetadataExtractionService` (garment
    /// tagging from one photo) and `OpenRouterUserProfileDerivationService`
    /// (style profile from the onboarding portrait). Both send exactly one
    /// image and return structured JSON text, never an image.
    static let imageToText = "minimax/minimax-m3"
    // Alternatives: "google/gemini-3.1-flash-lite", "openai/gpt-5-mini",
    // "qwen/qwen3-vl-30b-a3b-instruct"

    /// Used by: `OpenRouterTryOnRenderService` (virtual try-on render —
    /// base portrait + garment images in, a generated photo out).
    static let imageToImage = "bytedance-seed/seedream-4.5"
    // Alternatives: "google/gemini-2.5-flash-image" (chat-completion image
    // model — see OpenRouterTryOnRenderService's `isChatModel` branch)
}
