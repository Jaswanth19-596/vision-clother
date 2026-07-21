//
//  StylistQAResponse.swift
//  Vision_clother
//
//  Wire type for `Services/StylistQAService.swift`'s dedicated, separate
//  wardrobe/insights Q&A call — deliberately not a variant of
//  `OutfitRecommendationResponse.swift` (Wardrobe/Insights Q&A, 2026-07-20):
//  that response's job stays exactly what it always was, picking outfits.
//  This one answers a question, or reports that the message wasn't
//  actually a question so the caller falls through to the ordinary
//  recommendation flow unchanged.
//

import Foundation

struct StylistQAResponse: Codable, Equatable {
    /// True for anything that should be answered in words rather than as a
    /// built outfit — questions about the user's wardrobe/computed Insights
    /// (colors, utilization, shopping gaps, Style DNA), general style/
    /// fashion advice, and shopping guidance, whether or not it's grounded
    /// in the user's own data (see `Domain/StylistQABrain.swift`). False
    /// means "this is actually a request to be dressed for a named occasion
    /// from real owned items (or a refinement of outfits already shown)" —
    /// the caller should fall through to
    /// `Services/OutfitRecommendationService.swift`'s existing flow, which
    /// already has full clarification/off-topic handling.
    var isWardrobeQuestion: Bool
    /// The natural-language answer — grounded in the wardrobe catalog and
    /// Insights summary given in the prompt for anything about the user's
    /// own data, and general fashion expertise for style/shopping advice
    /// beyond that. Nil when `isWardrobeQuestion` is false.
    var answerText: String?

    enum CodingKeys: String, CodingKey {
        case isWardrobeQuestion = "is_wardrobe_question"
        case answerText = "answer_text"
    }
}
