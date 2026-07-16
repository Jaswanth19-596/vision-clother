//
//  StylistBrainTests.swift
//  Vision_clotherTests
//
//  Covers Domain/StylistBrain.swift's prompt composition: the Decision
//  Hierarchy's tier/enforcement metadata, symmetric (positive + negative)
//  taste injection, and the cross-projection consistency between the
//  formality-mismatch prose and `Domain/FashionKnowledgeConstants.swift` —
//  the anti-drift check described in the Stylist Intelligence Engine ADR.
//

import Foundation
import Testing
@testable import Vision_clother

struct StylistBrainTests {

    @Test func hardConstraintsTierIsAlwaysEnforcedByRejection() {
        #expect(StylistBrain.DecisionHierarchy.hardConstraints.enforcement == .reject)
    }

    @Test func aestheticTrendTierIsGuidanceOnlyAndRanksLast() {
        #expect(StylistBrain.DecisionHierarchy.aestheticTrend.enforcement == .guide)
        #expect(StylistBrain.DecisionHierarchy.aestheticTrend.rawValue == StylistBrain.DecisionHierarchy.allCases.count)
    }

    @Test func middleTiersArePenalizedNotRejected() {
        for tier: StylistBrain.DecisionHierarchy in [.dressCode, .weatherContext, .userStyleProfile, .visualCohesion] {
            #expect(tier.enforcement == .penalize)
        }
    }

    // MARK: - Cross-projection consistency (prompt prose vs. deterministic scoring)

    @Test func dressCodeProseCitesTheSameThresholdsPairCompatibilityScoringEnforces() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        let majorText = FashionKnowledgeConstants.DressCode.majorFormalityMismatchDelta.formatted()
        let minorText = FashionKnowledgeConstants.DressCode.minorFormalityMismatchDelta.formatted()

        #expect(prompt.contains(majorText))
        #expect(prompt.contains(minorText))
    }

    @Test func promptStatesTheNonNegotiableRulesHonestyClause() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("NON-NEGOTIABLE RULES"))
        #expect(prompt.contains("say so"))
    }

    @Test func promptInstructsTheModelToSelfReportResolvedConstraints() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("resolved_constraints"))
    }

    @Test func promptStatesTheDiversityObjective() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("Diversity:"))
    }

    @Test func promptGivesConfidenceCalibrationGuidance() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("rationale.confidence"))
        #expect(prompt.contains("calibrated confidence"))
    }

    // MARK: - Symmetric taste injection

    @Test func noTasteBlocksWhenEveryAffinityIsNeutral() {
        // Sparse/no ratings -> every affinity defaults to 0.5 -> neither the
        // "prioritize" nor the "avoid" block should render.
        let profile = AttributePreferenceProfile()
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: profile)

        #expect(!prompt.contains("USER HISTORICAL TASTE PREFERENCES"))
        #expect(!prompt.contains("TENDS TO DISLIKE"))
    }

    @Test func highAffinityRendersThePrioritizeBlock() {
        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity[.vibrant] = 0.9
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: profile)

        #expect(prompt.contains("USER HISTORICAL TASTE PREFERENCES"))
        #expect(prompt.contains("vibrant"))
        #expect(!prompt.contains("TENDS TO DISLIKE"))
    }

    @Test func lowAffinityRendersTheAvoidBlockSymmetrically() {
        // Before the symmetric-injection fix, negative affinities (< 0.4)
        // were computed by AttributePreferenceProfile but never surfaced to
        // the LLM at all — only the local re-ranker saw them.
        var profile = AttributePreferenceProfile()
        profile.patternAffinity[.plaid] = 0.1
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: profile)

        #expect(prompt.contains("TENDS TO DISLIKE"))
        #expect(prompt.contains("plaid"))
    }

    @Test func bothBlocksCanRenderTogether() {
        var profile = AttributePreferenceProfile()
        profile.colorVibeAffinity[.neutral] = 0.85
        profile.formalityAffinity[2] = 0.05
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: profile)

        #expect(prompt.contains("USER HISTORICAL TASTE PREFERENCES"))
        #expect(prompt.contains("TENDS TO DISLIKE"))
    }

    // MARK: - Clarification Loop (Stylist Intelligence Engine ADR, Phase 2)

    @Test func promptDescribesTheClarificationProtocol() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)

        #expect(prompt.contains("CLARIFICATION PROTOCOL"))
        #expect(prompt.contains("Occasion is the only thing you may ask about"))
        #expect(prompt.contains("intent_clear"))
        #expect(prompt.contains("suggested_chips"))
        #expect(prompt.contains("follow_up_text"))
    }

    @Test func defaultTurnDoesNotForceADecision() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(!prompt.contains("FINAL TURN"))
    }

    @Test func promptForcesADecisionOnTheFinalTurn() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil, isFinalTurn: true)

        #expect(prompt.contains("FINAL TURN"))
        #expect(prompt.contains("MUST set intent_clear to true"))
    }

    // MARK: - Conversational Refinement Loop (Stylist Intelligence Engine ADR, Phase 2 addendum)

    @Test func promptDistinguishesRefinementFromANewAmbiguousScenario() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)

        #expect(prompt.contains("REFINEMENT"))
        #expect(prompt.contains("NOT a new ambiguous scenario"))
    }

    // MARK: - Prompt-compliance strengthening (2026-07-14: live testing showed
    // a real model treating "what should I wear today?" as clear enough to
    // answer directly, and repeating the same top across multiple outfits —
    // both are LLM judgment gaps to close in prose, not code bugs, per the
    // project's LLM-as-Recommender invariant).

    @Test func clarificationProtocolCallsOutAGenericNoOccasionRequestAsAmbiguous() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)

        #expect(prompt.contains("what should I wear today?"))
        #expect(prompt.contains("No occasion is named at all"))
    }

    @Test func diversityRuleForbidsReusingAPrimaryGarmentAcrossOutfits() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)

        #expect(prompt.contains("no single top_id, bottom_id, footwear_id, or outerwear_id may appear in more than one outfit"))
    }

    // MARK: - Prospective Purchase Evaluation (2026-07-15)

    @Test func promptDescribesProspectivePurchaseEvaluation() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)

        #expect(prompt.contains("PROSPECTIVE PURCHASE EVALUATION"))
        #expect(prompt.contains("is_prospective_purchase"))
        #expect(prompt.contains("even zero"))
    }
}
