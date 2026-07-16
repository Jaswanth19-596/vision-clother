//
//  SwipeDiscoveryViewModel.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: loads a deck of licensed stock photos
//  (`Services/StockImageFeedService.swift`) and, on each swipe, embeds the
//  downloaded photo (`Services/ImageEmbeddingService.swift`) and folds it
//  into the persisted visual-taste centroids via
//  `WardrobeRepository.recordSwipe`. Persistence runs in the background so
//  the swipe gesture itself never blocks on network/Vision work — the deck
//  advances immediately, matching every other swipe-card UX.
//

import Foundation
import Observation

/// Deck-load lifecycle — mirrors `RatingSaveState`'s explicit-state-enum
/// convention (Features/CLAUDE.md) rather than a bare `async throws`.
enum SwipeDeckLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Pure translation-to-decision mapping for the card's drag gesture — kept
/// isolated from `SwipeDiscoveryView`'s rendering code so the "past
/// threshold -> liked/disliked" logic is unit-testable without SwiftUI.
enum SwipeGestureResolver {
    /// Horizontal drag distance (points) past which a release commits to a
    /// like/dislike rather than springing back to center.
    static let commitThreshold: CGFloat = 110

    enum Decision: Equatable {
        case like
        case dislike
        case undecided
    }

    static func decision(forHorizontalTranslation translation: CGFloat) -> Decision {
        if translation >= commitThreshold { return .like }
        if translation <= -commitThreshold { return .dislike }
        return .undecided
    }
}

@Observable
@MainActor
final class SwipeDiscoveryViewModel {
    private(set) var deck: [StockPhoto] = []
    private(set) var loadState: SwipeDeckLoadState = .idle
    /// Set when a swipe's background persistence fails — surfaced as a
    /// transient banner, not a blocking error, since the deck has already
    /// advanced past that card by the time this can happen.
    private(set) var lastSwipeError: String?

    /// Gamified calibration meter (`VisualPreferenceState.calibrationProgress`)
    /// for the card screen's progress ring — 0 before the first swipe (no
    /// `VisualPreferenceState` row exists yet), refreshed after every
    /// persisted swipe so the ring animates live as the user swipes.
    private(set) var calibrationProgress: Double = 0
    private(set) var isTrained: Bool = false

    /// Live, per-swipe centroid drift (`VisualClusterUpdater.update`'s return
    /// value, as a fraction — e.g. `0.034` for 3.4%), surfaced as a transient
    /// toast so the user sees the model's math actually move on every swipe,
    /// rather than inferring "it's learning" from `calibrationProgress`'s
    /// swipe-count ring alone. `nil` when the most recent swipe seeded a
    /// fresh centroid instead of nudging one (no drift to report) — those
    /// swipes don't trigger the toast.
    private(set) var lastDriftAmount: Double = 0
    private(set) var showDriftFeedback: Bool = false
    private var driftFeedbackDismissTask: Task<Void, Never>?

    /// Once the deck runs low, top up rather than making the user hit a
    /// hard "no more photos" wall mid-session.
    private let refillThreshold = 5
    private let deckSize = 30

    private let repository: WardrobeRepository
    private let feedService: StockImageFeedService
    private let embeddingService: ImageEmbeddingService
    private let session: URLSession

    init(
        repository: WardrobeRepository,
        feedService: StockImageFeedService,
        embeddingService: ImageEmbeddingService,
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.feedService = feedService
        self.embeddingService = embeddingService
        self.session = session
    }

    var topPhoto: StockPhoto? { deck.first }
    /// A couple of cards deep, for the stacked-card visual — never more than
    /// what's actually in the deck.
    var visibleStack: [StockPhoto] { Array(deck.prefix(3)) }

    func loadDeckIfNeeded() async {
        refreshCalibrationState()
        guard deck.isEmpty, loadState != .loading else { return }
        await loadDeck()
    }

    /// Reads the current `VisualPreferenceState` and republishes its
    /// calibration meter — best-effort, matching this feature's existing
    /// "a taste-profile hiccup shouldn't block the swipe UI" posture
    /// (`persistSwipe`'s `lastSwipeError` handling below).
    private func refreshCalibrationState() {
        guard let state = try? repository.fetchVisualPreferenceState() else { return }
        calibrationProgress = state.calibrationProgress
        isTrained = state.isTrained
    }

    private func loadDeck() async {
        loadState = .loading
        do {
            let photos = try await feedService.fetchDeck(count: deckSize)
            deck.append(contentsOf: photos)
            loadState = .loaded
        } catch {
            loadState = .failed("Couldn't load new photos. Try again.")
        }
    }

    /// Pops the top card immediately (so the deck advances without waiting
    /// on network/Vision work) and persists the swipe in the background.
    func swipe(liked: Bool) {
        guard !deck.isEmpty else { return }
        let photo = deck.removeFirst()
        lastSwipeError = nil

        Task { [weak self] in
            await self?.persistSwipe(photo, liked: liked)
        }

        if deck.count < refillThreshold {
            Task { [weak self] in
                await self?.loadDeck()
            }
        }
    }

    private func persistSwipe(_ photo: StockPhoto, liked: Bool) async {
        do {
            guard let url = URL(string: photo.imageURLString) else {
                throw StockImageFeedError.invalidResponse
            }
            let (data, _) = try await session.data(from: url)
            let embedding = try await embeddingService.embedding(for: data)
            let drift = try repository.recordSwipe(
                sourcePhotoID: photo.id,
                imageURLString: photo.imageURLString,
                liked: liked,
                embedding: embedding
            )
            refreshCalibrationState()
            if let drift {
                presentDriftFeedback(drift / 100.0)
            }
        } catch {
            lastSwipeError = "Couldn't save that swipe — it won't count toward your taste profile."
        }
    }

    /// Shows the live drift toast for ~1.5s, then auto-dismisses — cancels
    /// any still-pending dismiss from a prior swipe first so a fast series of
    /// swipes doesn't fight itself with overlapping auto-hide timers.
    private func presentDriftFeedback(_ amount: Double) {
        driftFeedbackDismissTask?.cancel()
        lastDriftAmount = amount
        showDriftFeedback = true
        driftFeedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.showDriftFeedback = false
        }
    }
}
