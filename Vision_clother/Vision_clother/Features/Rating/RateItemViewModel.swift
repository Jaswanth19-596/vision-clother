//
//  RateItemViewModel.swift
//  Vision_clother
//
//  Item Rating & Preference Learning: collects a multi-question rating for
//  one garment — Fit, Comfort, Color, Pattern, Formality Fit, Style Identity,
//  Wear Again, each mapped to a specific attribute affinity in
//  Domain/AttributePreferenceProfile.swift rather than one blended score
//  (see docs/decisions/stylist-intelligence-engine.md) — and persists it via
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
    var colorLike: Int { get set }
    var patternLike: Int { get set }
    var formalityFit: Int { get set }
    var styleIdentity: Int { get set }
    var wearAgain: Bool { get set }
    var state: RatingSaveState { get }
    func submit() async
}

@Observable
@MainActor
final class RateItemViewModel: RatingQuestionsViewModel {
    let item: WardrobeItem

    var fit: FitRating = .justRight
    var comfort: Int = 3
    var colorLike: Int = 3
    /// Bound by the Pattern question's `StarRatingRow` when shown; ignored
    /// (submitted as `nil`) for solid-pattern items, which never show that
    /// section — see `submit()`.
    var patternLike: Int = 3
    var formalityFit: Int = 3
    var styleIdentity: Int = 3
    var wearAgain: Bool = true

    private(set) var state: RatingSaveState = .idle

    private let repository: WardrobeRepository

    init(item: WardrobeItem, repository: WardrobeRepository) {
        self.item = item
        self.repository = repository
    }

    func submit() async {
        AppLog.info(.viewModel, "RateItemViewModel.submit: itemID=\(item.id)")
        state = .saving
        do {
            try repository.recordItemRating(
                itemID: item.id,
                fit: fit,
                comfort: comfort,
                colorLike: colorLike,
                patternLike: item.pattern == .solid ? nil : patternLike,
                formalityFit: formalityFit,
                styleIdentity: styleIdentity,
                wearAgain: wearAgain
            )
            state = .saved
        } catch {
            AppLog.error(.viewModel, "RateItemViewModel.submit: failed itemID=\(item.id) — \(String(describing: error))")
            state = .failed("Couldn't save that rating. Try again.")
        }
    }
}
