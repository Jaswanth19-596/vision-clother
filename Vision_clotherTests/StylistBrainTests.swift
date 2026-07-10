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
        for tier: StylistBrain.DecisionHierarchy in [.dressCode, .weatherContext, .userStyleProfile, .colorHarmony, .fitAndSilhouette] {
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

    @Test func promptStatesTheFashionConstitutionHonestyClause() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("FASHION CONSTITUTION"))
        #expect(prompt.contains("say so"))
    }

    @Test func promptInstructsTheModelToSelfReportResolvedConstraints() {
        let prompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(profile: nil, attributeProfile: nil)
        #expect(prompt.contains("resolved_constraints"))
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
}
