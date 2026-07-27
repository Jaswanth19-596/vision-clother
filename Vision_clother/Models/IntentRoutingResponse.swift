//
//  IntentRoutingResponse.swift
//  Vision_clother
//
//  Wire type for `Services/IntentRoutingService.swift`'s intent-routing call
//  (replaces `Domain/QuestionIntentHeuristic.swift`, 2026-07-27). Deliberately
//  not a variant of `StylistQAResponse` — that type's job is answering a
//  question; this one only decides which of the two downstream flows a turn
//  belongs to, before either is attempted.
//

import Foundation

/// `.recommendation` — a concrete request to be dressed for a named
/// occasion from real owned items, or a refinement of outfits already shown;
/// routes to `Services/OutfitRecommendationService.swift`.
/// `.generalQA` — everything else that should be answered in words —
/// wardrobe/Insights questions, general style/fashion/shopping advice, small
/// talk; routes to `Services/StylistQAService.swift`, which still has the
/// final say via `StylistQAResponse.isWardrobeQuestion`.
enum RoutedIntent: String, Codable {
    case recommendation = "RECOMMENDATION"
    case generalQA = "GENERAL_QA"
}

struct IntentRoutingResponse: Codable, Equatable {
    var intent: RoutedIntent
}
