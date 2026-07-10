//
//  FashionKnowledgeConstants.swift
//  Vision_clother
//
//  Single-sourced numeric thresholds for knowledge that has both a *prompt
//  projection* (StylistBrain's system prompt, read by the LLM) and a
//  *deterministic projection* (PairCompatibilityScoring's aesthetic prior,
//  run on-device). Before this file existed, the "how big a formality gap
//  is too big" rule lived only as an unlabeled magic number inside the
//  scoring math, while the prompt described the same rule in prose with no
//  number attached — the two could drift apart silently. Both sides now read
//  the same constant, so a future change to one is a change to both.
//
//  Pure data, no I/O (Domain/CLAUDE.md).
//

import Foundation

enum FashionKnowledgeConstants {
    /// Dress-code / formality-alignment thresholds (Decision Hierarchy Tier 1,
    /// `docs/decisions/stylist-intelligence-engine.md`).
    enum DressCode {
        /// Formality-score delta beyond which two items read as a hard
        /// dress-code mismatch (e.g. a gym tee with dress trousers).
        static let majorFormalityMismatchDelta: Double = 2.0
        /// Softer delta — still noticeable, not disqualifying.
        static let minorFormalityMismatchDelta: Double = 1.0
    }
}
