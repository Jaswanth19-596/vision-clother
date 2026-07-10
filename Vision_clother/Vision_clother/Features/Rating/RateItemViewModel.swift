//
//  RateItemViewModel.swift
//  Vision_clother
//
//  Item Rating & Preference Learning: collects a multi-question rating for
//  one garment — Level 1 (fit, comfort, confidence, wear-again) plus Level 2
//  Fashion Evaluation (versatility, predicted wear frequency, style
//  identity, quality perception — Stylist Intelligence Engine Phase 1
//  addendum, item granularity) — and persists it via
//  `WardrobeRepository.recordItemRating`. Mirrors `AddItemViewModel`'s
//  save-state shape (Features/CLAUDE.md: explicit state enums, not bare
//  `async throws`).
//

import Foundation
import Observation

/// Save/submit lifecycle shared by every rating flow — `RateItemViewModel`
/// (one garment) and `RateCombinationViewModel` (a whole saved outfit,
/// `Features/Rating/RateCombinationViewModel.swift`).
enum RatingSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

/// Shared question-set contract so `RateItemQuestionsView` (below) can render
/// the same Level 1 + Level 2 item rating form for either a single garment
/// or a whole combination without duplicating the form's view code.
@MainActor
protocol RatingQuestionsViewModel: AnyObject, Observable {
    var fit: FitRating { get set }
    var comfort: Int { get set }
    var confidence: Int { get set }
    var wearAgain: Bool { get set }
    var versatility: Int { get set }
    var frequency: Int { get set }
    var styleIdentity: Int { get set }
    var qualityPerception: Int { get set }
    var state: RatingSaveState { get }
    func submit() async
}

@Observable
@MainActor
final class RateItemViewModel: RatingQuestionsViewModel {
    let item: WardrobeItem

    var fit: FitRating = .justRight
    var comfort: Int = 3
    var confidence: Int = 3
    var wearAgain: Bool = true
    var versatility: Int = 3
    var frequency: Int = 3
    var styleIdentity: Int = 3
    var qualityPerception: Int = 3

    private(set) var state: RatingSaveState = .idle

    private let repository: WardrobeRepository

    init(item: WardrobeItem, repository: WardrobeRepository) {
        self.item = item
        self.repository = repository
    }

    func submit() async {
        state = .saving
        do {
            try repository.recordItemRating(
                itemID: item.id,
                fit: fit,
                comfort: comfort,
                confidence: confidence,
                wearAgain: wearAgain,
                versatility: versatility,
                frequency: frequency,
                styleIdentity: styleIdentity,
                qualityPerception: qualityPerception
            )
            state = .saved
        } catch {
            state = .failed("Couldn't save that rating. Try again.")
        }
    }
}
