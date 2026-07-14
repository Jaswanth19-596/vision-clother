//
//  ConversationTurn.swift
//  Vision_clother
//
//  One turn of the clarification-loop dialogue with the recommendation LLM
//  (Stylist Intelligence Engine ADR, Phase 2). `DailyAssistantViewModel`
//  accumulates these in memory for the current conversation and replays the
//  full list every call in `Services/OutfitRecommendationService.swift` —
//  OpenRouter is stateless, there's no server-side thread to resume.
//

import Foundation

struct ConversationTurn: Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var role: Role
    var text: String
}
