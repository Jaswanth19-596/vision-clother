//
//  StylistBrain.swift
//  Vision_clother
//
//  Created on 2026-07-10.
//
//  Encapsulates the rules of the Stylist Brain: the Decision Hierarchy,
//  the dynamic prompt composer, and conflict resolution rules.
//

import Foundation

enum StylistBrain {
    /// The priority hierarchy professional stylists follow when evaluating/composing outfits.
    /// Woven into prompt composition to guide LLM reasoning discipline.
    ///
    /// Each tier also declares how it's *enforced* (Stylist Intelligence Engine
    /// ADR, `docs/decisions/stylist-intelligence-engine.md`, §5): a lower tier
    /// always dominates a higher one — a gorgeous outfit that violates the
    /// dress code is a wrong answer, not a low-scoring one. `.reject`/`.penalize`
    /// tiers have a deterministic projection enforced by
    /// `Domain/OutfitRecommendationValidator.swift` / `outfitScore`; `.guide`
    /// tiers (aesthetic trend) exist only as prompt guidance and can never
    /// out-rank a lower tier — they only break ties among otherwise-equal outfits.
    enum DecisionHierarchy: Int, CaseIterable {
        case hardConstraints = 1     // E.g. slot category matching, no duplicated items
        case dressCode               // E.g. matching formality range (casual/business/formal)
        case weatherContext          // E.g. seasonality, layers, fabric weight
        case userStyleProfile        // E.g. recommended colors, avoided colors, body type
        case colorHarmony            // E.g. complementary, analogous, neutral anchorage
        case fitAndSilhouette        // E.g. balanced proportions (loose + slim)
        case aestheticTrend          // E.g. style keywords, vibe matching

        /// How this tier is enforced once the LLM has proposed picks — see
        /// the type-level doc comment.
        enum Enforcement {
            /// A structural violation the validator hard-drops (Tier A).
            case reject
            /// A soft violation the rubric/`outfitScore` scores down.
            case penalize
            /// Prompt guidance only, never a deterministic term — may only
            /// break ties, never outrank a lower tier.
            case guide
        }

        var enforcement: Enforcement {
            switch self {
            case .hardConstraints: return .reject
            case .dressCode, .weatherContext, .userStyleProfile: return .penalize
            case .colorHarmony, .fitAndSilhouette: return .penalize
            case .aestheticTrend: return .guide
            }
        }

        var description: String {
            switch self {
            case .hardConstraints: return "1. Hard Constraints: Only pick items from the catalog. One item per slot. Never repeat items."
            case .dressCode:       return "2. Dress Code: Align formality exactly with the scenario range. Items whose formality differs by more than \(FashionKnowledgeConstants.DressCode.majorFormalityMismatchDelta.formatted()) points read as a hard mismatch; by more than \(FashionKnowledgeConstants.DressCode.minorFormalityMismatchDelta.formatted()) as a soft one — avoid both."
            case .weatherContext:  return "3. Weather context: Layer with outerwear if cold/wet. Match fabric weights to weather."
            case .userStyleProfile:return "4. Personal Preferences: Honor user style profile colors, body type, and avoid colors."
            case .colorHarmony:    return "5. Color Theory: Apply complementary, analogous, or monochrome color pairings."
            case .fitAndSilhouette:return "6. Proportions: Pair fits and silhouettes harmoniously (e.g., oversized with slim)."
            case .aestheticTrend:  return "7. Aesthetics: Match user style keywords and general aesthetic vibe. This tier may only break ties — it can never justify violating a higher tier."
            }
        }
    }

    struct DynamicPromptComposer {
        /// Generates the system prompt instructing the LLM on role, hierarchy, and reasoning steps.
        static func composeSystemPrompt(
            profile: UserStyleProfile?,
            attributeProfile: AttributePreferenceProfile?
        ) -> String {
            var prompt = """
            You are a professional personal stylist composing outfits for a user from their wardrobe catalog.

            FASHION CONSTITUTION (never overridden by any lower rule):
            - Only recommend items the user actually owns — never invent a garment.
            - If the wardrobe genuinely lacks a suitable item for this scenario, say so plainly in the rationale rather than forcing a poor match.
            - Use respectful, non-judgmental language about the user's body and appearance.
            - Return between 3 and 5 distinct outfits in the "outfits" array, unless the wardrobe catalog genuinely cannot support 3 valid, non-duplicate combinations — in that case return as many as are actually valid.

            You must reason strictly according to this Decision Hierarchy when picking items — a lower-numbered tier always outranks a higher one; tier 7 may only break ties, never justify violating tiers 1-6:
            \(DecisionHierarchy.allCases.map { " - \($0.description)" }.joined(separator: "\n"))

            """

            // 1. Personal Style Profile Integration
            if let profile {
                prompt += """
                
                USER PORTRAIT & STYLE PROFILE:
                - Skin Tone: \(profile.skinTone)
                - Undertone: \(profile.undertone.rawValue.capitalized)
                - Body Type: \(profile.bodyType)
                - Style Keywords: \(profile.styleKeywords.joined(separator: ", "))
                - Recommended Colors to feature: \(profile.recommendedColors.joined(separator: ", "))
                - Colors to absolutely avoid: \(profile.avoidColors.joined(separator: ", "))
                
                Ensure the generated outfits complement this profile. Avoid the "avoid" colors strictly unless absolutely necessary to complete an outfit due to a small catalog.
                
                """
            }

            // 2. Learned Historical Preferences Integration — symmetric:
            // both the attributes the user tends to rate well (affinity > 0.6)
            // AND the ones they tend to rate poorly (affinity < 0.4) are
            // surfaced. Discarding the negative half wastes the strongest
            // personalization signal collected (Stylist Intelligence Engine
            // ADR §9) — a stylist who only hears what you like, never what
            // you dislike, repeats the same mistakes.
            if let attributeProfile {
                var favoritesList: [String] = []
                var avoidList: [String] = []

                let highColors = attributeProfile.colorVibeAffinity.filter { $0.value > 0.6 }.map { $0.key.rawValue }
                if !highColors.isEmpty {
                    favoritesList.append("Color Vibes: \(highColors.joined(separator: ", "))")
                }
                let lowColors = attributeProfile.colorVibeAffinity.filter { $0.value < 0.4 }.map { $0.key.rawValue }
                if !lowColors.isEmpty {
                    avoidList.append("Color Vibes: \(lowColors.joined(separator: ", "))")
                }

                let highPatterns = attributeProfile.patternAffinity.filter { $0.value > 0.6 }.map { $0.key.rawValue }
                if !highPatterns.isEmpty {
                    favoritesList.append("Patterns: \(highPatterns.joined(separator: ", "))")
                }
                let lowPatterns = attributeProfile.patternAffinity.filter { $0.value < 0.4 }.map { $0.key.rawValue }
                if !lowPatterns.isEmpty {
                    avoidList.append("Patterns: \(lowPatterns.joined(separator: ", "))")
                }

                let highFormality = attributeProfile.formalityAffinity.filter { $0.value > 0.6 }.map { "\($0.key)" }
                if !highFormality.isEmpty {
                    favoritesList.append("Formality bands (1-5): \(highFormality.joined(separator: ", "))")
                }
                let lowFormality = attributeProfile.formalityAffinity.filter { $0.value < 0.4 }.map { "\($0.key)" }
                if !lowFormality.isEmpty {
                    avoidList.append("Formality bands (1-5): \(lowFormality.joined(separator: ", "))")
                }

                // Stylist Intelligence Engine Phase 1: Personal Style Match,
                // Fit & Silhouette, and Weather Suitability + Practicality
                // dimension-based outfit ratings.
                let highStyleTags = attributeProfile.styleTagAffinity.filter { $0.value > 0.6 }.map { $0.key }
                if !highStyleTags.isEmpty {
                    favoritesList.append("Style: \(highStyleTags.joined(separator: ", "))")
                }
                let lowStyleTags = attributeProfile.styleTagAffinity.filter { $0.value < 0.4 }.map { $0.key }
                if !lowStyleTags.isEmpty {
                    avoidList.append("Style: \(lowStyleTags.joined(separator: ", "))")
                }

                let highSilhouettes = attributeProfile.silhouetteAffinity.filter { $0.value > 0.6 }.map { $0.key }
                if !highSilhouettes.isEmpty {
                    favoritesList.append("Silhouettes: \(highSilhouettes.joined(separator: ", "))")
                }
                let lowSilhouettes = attributeProfile.silhouetteAffinity.filter { $0.value < 0.4 }.map { $0.key }
                if !lowSilhouettes.isEmpty {
                    avoidList.append("Silhouettes: \(lowSilhouettes.joined(separator: ", "))")
                }

                let highFabricWeights = attributeProfile.fabricWeightAffinity.filter { $0.value > 0.6 }.map { $0.key.rawValue }
                if !highFabricWeights.isEmpty {
                    favoritesList.append("Fabric weights for the conditions: \(highFabricWeights.joined(separator: ", "))")
                }
                let lowFabricWeights = attributeProfile.fabricWeightAffinity.filter { $0.value < 0.4 }.map { $0.key.rawValue }
                if !lowFabricWeights.isEmpty {
                    avoidList.append("Fabric weights for the conditions: \(lowFabricWeights.joined(separator: ", "))")
                }

                if !favoritesList.isEmpty {
                    prompt += """

                    USER HISTORICAL TASTE PREFERENCES (Derived from feedback, prioritize these):
                    \(favoritesList.map { " - \($0)" }.joined(separator: "\n"))

                    """
                }
                if !avoidList.isEmpty {
                    prompt += """

                    USER HISTORICAL TASTE — TENDS TO DISLIKE (Derived from feedback, avoid these unless the catalog leaves no better option):
                    \(avoidList.map { " - \($0)" }.joined(separator: "\n"))

                    """
                }
            }

            // 3. Styling rules and guidelines
            prompt += """
            
            STYLING RULES:
            - Every outfit must have a top_id, bottom_id, and footwear_id. outerwear_id is optional (null if not needed).
            - A top must be a top slot, bottom must be bottom slot, footwear must be footwear slot, outerwear must be outerwear slot.
            - Ensure fit & silhouette balance: E.g., pair boxy/oversized tops with straight/slim bottoms, or sleek/fitted tops with relaxed/flared bottoms.
            - Check material harmony: Pair complementary materials (e.g. Cotton and Denim, or Linen and Cotton). Avoid pairing heavy wool with lightweight linen.
            
            REASONING WORKFLOW (Reason internally on each candidate outfit):
            1. Intent & Formality: Evaluate scenario requirements and resolve them to a concrete formality range, weather-layering need, color palette vibe, and season.
            2. Weather: Check temperature. Is outerwear needed? Are fabric weights appropriate?
            3. Catalog lookup: Choose candidate pieces.
            4. Preferences check: Apply personal color and taste profile.
            5. Cohesion check: Do colors, fits, and materials coordinate harmoniously?
            6. Explain recommendation: Write the rationale as ONE short sentence (100 characters or fewer) stating why this outfit is correct. Do not write multiple sentences or a paragraph.

            OUTPUT CONTRACT: In addition to `outfits`, always populate the top-level `resolved_constraints` field with what you resolved in step 1 — this is what the on-device validator uses to confirm every pick actually honors the dress code, so it must reflect your real reasoning, not a placeholder.
            """

            return prompt
        }

        /// Generates the user prompt combining the scenario, weather, and wardrobe catalog JSON.
        static func composeUserContent(
            prompt: String,
            weather: WeatherContext?,
            catalogDataText: String
        ) -> String {
            var content = "Scenario: \(prompt)"
            
            if let weather {
                content += "\n\nCurrent Weather: Temperature \(weather.temperatureFahrenheit)°F, Condition: \(weather.conditions)."
            }
            
            content += "\n\nWardrobe Catalog (JSON Array - pick ONLY from these ids):\n\(catalogDataText)"
            
            return content
        }
    }
}
