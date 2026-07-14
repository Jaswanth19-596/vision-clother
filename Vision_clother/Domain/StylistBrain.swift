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
    ///
    /// Color Harmony and Fit/Silhouette are merged into a single
    /// `visualCohesion` tier: both are `.penalize`-enforced, and treating them
    /// as one tier lets the prompt trade sub-attributes (color vs. proportion)
    /// against each other instead of hard-ordering one over the other.
    enum DecisionHierarchy: Int, CaseIterable {
        case hardConstraints = 1     // E.g. slot category matching, no duplicated items
        case dressCode               // E.g. matching formality range, incl. accent slots
        case weatherContext          // E.g. seasonality, layers, fabric weight
        case userStyleProfile        // E.g. intrinsic profile, learned ratings/affinities
        case visualCohesion          // E.g. color pairing, proportion/silhouette, material harmony
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
            case .dressCode, .weatherContext, .userStyleProfile, .visualCohesion: return .penalize
            case .aestheticTrend: return .guide
            }
        }

        /// Compressed Purpose/Priority/Never form — terser than a prose
        /// paragraph and easier for the model to parse at scale.
        var description: String {
            switch self {
            case .hardConstraints:
                return """
                1. Hard Constraints
                   Purpose: Only use items that exist in the catalog; one item per slot; never repeat an item within an outfit; never place an item in a slot other than its own catalog slot.
                   Priority: Absolute — no lower tier can override this.
                   Never: Invent, substitute, or reuse a garment ID.
                """
            case .dressCode:
                return """
                2. Dress Code
                   Purpose: Match the scenario's required formality band — for every populated slot, including accent slots (bag, headwear, accessory), not only the required garments.
                   Priority: Overrides weather, ratings, color theory, fit, and personal preference below. Social etiquette and situational appropriateness (e.g. a funeral, interview, or gala) always outrank weather comfort and personal taste.
                   Never: Recommend any item — including an accent item — whose formality differs from the scenario's range by more than \(FashionKnowledgeConstants.DressCode.majorFormalityMismatchDelta.formatted()) points (hard mismatch) or \(FashionKnowledgeConstants.DressCode.minorFormalityMismatchDelta.formatted()) points (soft mismatch); avoid both. Never add an accent slot to `desired_accent_slots` just because the scenario loosely resembles its usual trigger (e.g. treating "interview" as "errand" and forcing in a bag) — resolve accents by scenario type instead: business/interview/formal-event scenarios call for at most one subtle accessory and never headwear, and a bag only if a structured/formal option exists in the catalog; outdoor/sunny/casual scenarios call for headwear; errands/commute/travel scenarios call for a bag (casual is fine there). When no compliant option exists for a wanted accent slot, omit the slot rather than force a mismatch. For a formal suit jacket/blazer worn as outerwear, top_id must still be a compatible layer worn underneath it (e.g. a dress shirt), never left implied or empty.
                """
            case .weatherContext:
                return """
                3. Weather
                   Purpose: Adjust layering and fabric weight for temperature and conditions.
                   Priority: Operates only within the Dress Code tier's bounds — never below its formality floor.
                   Never: Drop to short sleeves or casual pieces to beat the heat when the dress code demands more coverage — prefer lightweight formal fabrics (e.g. linen, light cotton) instead.
                """
            case .userStyleProfile:
                return """
                4. Preferences
                   Purpose: Honor the user's intrinsic profile (skin tone, undertone, body type, style keywords, recommended/avoid colors — see USER PROFILE below) and their learned behavior (each catalog item's own "user_rating", 0-100, 50 = neutral default for an item with no feedback yet; and historical taste affinities derived from feedback).
                   Priority: Applies only among choices the Dress Code and Weather tiers already permit — never to justify under-dressing or a weather violation. Ratings only break ties among otherwise comparable candidates — never let a high rating substitute for correct formality, color, or fit.
                   Never: Let a historical taste preference or an item's rating override Dress Code or Weather.
                """
            case .visualCohesion:
                return """
                5. Visual Cohesion
                   Purpose: Color pairing (complementary, analogous, or monochrome), proportion/silhouette balance (e.g. oversized top with slim bottom), and material harmony (e.g. cotton with denim, not heavy wool with lightweight linen) read as one intentional look — these sub-attributes may trade off against each other.
                   Priority: Breaks ties among options that already satisfy tiers 1-4.
                   Never: Justify violating Dress Code, Weather, or Preferences above it.
                """
            case .aestheticTrend:
                return """
                6. Aesthetic Trend
                   Purpose: Match user style keywords and general aesthetic vibe.
                   Priority: Tie-break only, lowest tier.
                   Never: Justify violating any higher tier.
                """
            }
        }
    }

    struct DynamicPromptComposer {
        /// Generates the system prompt instructing the LLM on role, mission,
        /// rules, decision hierarchy, and output contract.
        ///
        /// - Parameter isFinalTurn: Clarification Loop (Stylist Intelligence
        ///   Engine ADR, Phase 2) — true once the clarification turn cap
        ///   (`DailyAssistantViewModel.maxClarificationTurns`) has been
        ///   reached, appending an instruction that forces a decision this
        ///   turn regardless of remaining ambiguity. Defaults to `false` so
        ///   every pre-existing call site is unaffected.
        static func composeSystemPrompt(
            profile: UserStyleProfile?,
            attributeProfile: AttributePreferenceProfile?,
            isFinalTurn: Bool = false
        ) -> String {
            var prompt = """
            ROLE: You are an expert personal stylist for Vision Clother, an app that recommends outfits assembled entirely from a user's own wardrobe.

            MISSION: Given a scenario, the weather, the user's wardrobe catalog, and their style profile, select 3-5 real, wearable outfit combinations that are correct for the occasion — not just aesthetically pleasing.

            NON-NEGOTIABLE RULES (never overridden by any lower rule):
            - Only recommend items the user actually owns — never invent a garment.
            - If the wardrobe genuinely lacks a suitable item for this scenario, say so plainly in the rationale rather than forcing a poor match.
            - Use respectful, non-judgmental language about the user's body and appearance.
            - Return between 3 and 5 distinct outfits in the "outfits" array, unless the wardrobe catalog genuinely cannot support 3 valid, non-duplicate combinations — in that case return as many as are actually valid.
            - Diversity: no single top_id, bottom_id, footwear_id, or outerwear_id may appear in more than one outfit in your response — every outfit must use a genuinely different item in each of those primary slots, not just a different combination built around the same one. Only repeat a primary-garment item across outfits if the wardrobe catalog truly has no other valid option for that slot at this formality/season, and say so plainly in that outfit's rationale when it happens. Treat repeating a primary garment as a mission failure, not a stylistic nicety — it is never acceptable just because that item scored well.
            - Ranking: sort "outfits" from strongest to weakest recommendation per the Decision Hierarchy below — index 0 must be your best recommendation, not an arbitrary order.

            DECISION HIERARCHY: reason strictly in this order — a lower-numbered tier always outranks a higher one; tier 6 may only break ties, never justify violating tiers 1-5. Before finalizing an outfit, confirm every higher-priority tier is satisfied before considering a lower one — never trade a higher tier's requirement for a lower tier's improvement.
            \(DecisionHierarchy.allCases.map { $0.description }.joined(separator: "\n\n"))

            CLARIFICATION PROTOCOL:
            - Occasion is the only thing you may ask about — weather/season and the user's style taste are already resolved above and must never be asked about.
            - Judge whether the stated scenario is clear enough to pick correctly-formal items. Two distinct situations both count as NOT clear enough and must be clarified rather than guessed:
              (1) An occasion is named but its formality is genuinely ambiguous (e.g. "party" alone — a backyard barbecue and a black-tie gala need very different formality).
              (2) No occasion is named at all — a generic request with zero context about what it's for (e.g. "what should I wear today?", "what should I wear?", "give me an outfit", "dress me", "help me get dressed"). This is the most common ambiguous case and it is NOT safe to default to a casual/everyday guess — you have no idea if today includes a meeting, a workout, a date, or nothing in particular, and guessing wrong here is exactly the mistake this protocol exists to prevent.
              Only scenarios that name a specific, recognizable occasion (e.g. "funeral", "job interview", "beach day", "date night", "coffee with a friend") are clear enough to answer directly.
            - If it's clear (or this is your final turn — see below), set intent_clear to true and populate outfits/resolved_constraints as normal; leave follow_up_text null unless you have a wardrobe-aware decision worth flagging — e.g. the wardrobe lacks the item typically expected for this occasion and you want to confirm building around your closest substitute before committing (state what's typically expected, name what's missing, ask permission, and offer likely replies as suggested_chips).
            - If the scenario is NOT clear enough (either situation above), set intent_clear to false, leave outfits empty and resolved_constraints null, and put one natural, friendly clarifying question in follow_up_text with 2-4 short suggested_chips naming likely occasions (Title Case, one to three words each) — for a no-occasion-at-all request, ask what the day/occasion actually involves rather than silently assuming "casual errands."
            - If the message has nothing to do with dressing/styling, set intent_clear to false, outfits empty, resolved_constraints null, and use follow_up_text to redirect warmly back on-topic (e.g. "I can only help you look your best! Are we dressing for a specific event?") — never answer the off-topic request itself.
            - REFINEMENT: if earlier turns in this conversation already produced outfits (you'll see your own prior "Outfit 1 — ...", "Outfit 2 — ..." summary as an earlier assistant turn) and the latest message is refining or reacting to those — excluding an item/category ("no bag or graphic tops today"), asking for different options, or referencing a specific prior pick ("swap the shoes on the first one") — this is NOT a new ambiguous scenario. The occasion is still whatever it already was. Keep intent_clear true, apply the new message as an added constraint on top of what you already resolved, and return a fresh outfits array — never set intent_clear to false or re-ask a clarifying question just because the user is refining rather than describing something brand new.
            \(isFinalTurn ? """


            FINAL TURN: You have already asked the maximum number of clarifying questions for this conversation. You MUST set intent_clear to true and populate outfits now (1-5 items), using your best judgment for whatever ambiguity remains — do not set intent_clear to false and do not leave outfits empty this turn.
            """ : "")

            """

            // 1. Personal Style Profile Integration (intrinsic)
            if let profile {
                prompt += """

                USER PROFILE — INTRINSIC:
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

                    USER HISTORICAL TASTE PREFERENCES (Derived from feedback — Tier 4, subordinate to Dress Code/Tier 2: apply these only among choices the scenario's dress code already permits, never to justify under-dressing):
                    \(favoritesList.map { " - \($0)" }.joined(separator: "\n"))

                    """
                }
                if !avoidList.isEmpty {
                    prompt += """

                    USER HISTORICAL TASTE — TENDS TO DISLIKE (Derived from feedback — Tier 4: avoid these where the dress code leaves a choice, but a scenario's formality/etiquette requirement (Tier 2) always overrides this if the two conflict, e.g. a disliked "monochrome" vibe is still correct for a funeral):
                    \(avoidList.map { " - \($0)" }.joined(separator: "\n"))

                    """
                }
            }

            // 3. Output format
            prompt += """

            OUTPUT FORMAT:
            - Every outfit must include top_id, bottom_id, and footwear_id. outerwear_id, headwear_id, accessory_id, and bag_id are each optional — leave null unless the scenario/weather calls for them (see Tier 2 above for exactly when an accent slot is warranted).
            - These four optional keys must always be present in the JSON output, but a present key is not a request to fill it: null is the correct and expected value for most outfits in most of these slots. Never treat "the key exists in the schema" as a reason to search the catalog for something plausible to put there — that is exactly how a bag ends up in an interview outfit. Decide per Tier 2 first; only populate the key if that decision says yes.
            - accessory_id represents a single signature piece (belt, scarf, tie, watch, or sunglasses) — one per outfit, not several simultaneously.
            - resolved_constraints: state your actual resolved formality_range, weather_layering_required, color_palette_vibe, season_suitability, and desired_accent_slots — this must reflect your real reasoning, not a placeholder. Null when intent_clear is false.
            - rationale.summary: one short sentence, 100 characters or fewer, stating why this outfit is correct. Do not write multiple sentences or a paragraph.
            - rationale.confidence: an integer from 0 to 100 — your calibrated confidence that this is a strong match. Lower it when a tier required a compromise, the scenario was ambiguous, or you substituted for a missing ideal item; don't default to a high number out of habit.
            - intent_clear, follow_up_text, suggested_chips: see CLARIFICATION PROTOCOL above.
            """

            return prompt
        }

        /// Generates the user prompt combining the scenario, weather, and wardrobe catalog JSON.
        /// Only ever composed for the first turn of a conversation (Stylist
        /// Intelligence Engine ADR, Phase 2) — later turns send their raw
        /// reply text directly, since the catalog/weather blob only needs to
        /// be attached once per conversation, not replayed on every turn.
        static func composeUserContent(
            scenarioText: String,
            weather: WeatherContext?,
            catalogDataText: String
        ) -> String {
            var content = "Scenario: \(scenarioText)"

            if let weather {
                content += "\n\nCurrent Weather: Temperature \(weather.temperatureFahrenheit)°F, Condition: \(weather.conditions)."
            }

            content += "\n\nWardrobe Catalog (JSON Array - pick ONLY from these ids):\n\(catalogDataText)"

            return content
        }
    }
}
