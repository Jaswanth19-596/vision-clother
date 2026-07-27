//
//  IntentRouterBrain.swift
//  Vision_clother
//
//  Intent routing (2026-07-27): the prompt for `Services/IntentRoutingService.swift`'s
//  cheap classification call, which replaces `Domain/QuestionIntentHeuristic.swift`'s
//  on-device keyword/"?" pre-filter. That heuristic false-negatived on any
//  question phrased without a leading interrogative word or trailing "?"
//  ("summarize my style", "hit me with some style tips") and silently sent
//  the turn straight to the outfit recommender. This prompt classifies from
//  conversation text alone — deliberately no wardrobe catalog, Insights
//  summary, or profile is ever attached here, so this call stays cheap and
//  fast; `Domain/StylistQABrain.swift` still gets that data and still has
//  the real, final say via `StylistQAResponse.isWardrobeQuestion` when intent
//  routes to GENERAL_QA.
//
//  Deliberately small and single-purpose, same posture as `StylistQABrain`:
//  no Decision Hierarchy, no outfit schema, no answer content — just a
//  two-way classification.
//

import Foundation

enum IntentRouterBrain {
    static let systemPrompt = """
    ROLE: Classify the LATEST user message in this styling-app conversation into exactly one of two intents. You do not have the user's wardrobe, Insights, or style profile in this call — classify from the conversation text alone.

    - RECOMMENDATION: a concrete request to be dressed — a specific outfit built from the user's real wardrobe for a named occasion/scenario (e.g. "what should I wear to X", "give me an outfit for Y", "dress me for Z"), or a refinement/follow-up on outfits already shown earlier in this conversation.
    - GENERAL_QA: everything else that should be answered in words rather than as a built outfit — questions about the user's existing wardrobe or computed Insights, general style/fashion/shopping advice (grounded in their data or not), small talk, or anything ambiguous.

    If genuinely unsure which of the two this is, prefer GENERAL_QA — only a concrete request to be dressed for an occasion should route to RECOMMENDATION. A downstream call has the user's real data and the final say on whether this is actually answerable in words; this classification only decides which path even gets attempted.

    OUTPUT: intent ("RECOMMENDATION" or "GENERAL_QA") only.
    """
}
