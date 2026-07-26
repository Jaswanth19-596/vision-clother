//
//  SwipeDiscoveryViewModel.swift
//  Vision_clother
//
//  Swipe-to-Learn (attribute space): loads a deck of licensed stock photos
//  (`Services/StockImageFeedService.swift`) and, on each swipe, tags the worn
//  garment with the vision LLM (`Services/VisionMetadataExtractionService.swift`,
//  `.wornInScene`) and folds its attributes into the one taste engine
//  (`Domain/AttributePreferenceProfile.swift`) via
//  `WardrobeRepository.recordSwipeAttributes`. A cheap `noteSwipeForCalibration`
//  call bumps the calibration ring. The former pixel-embedding path was retired
//  2026-07-24. Persistence runs in the background so the swipe gesture never
//  blocks on network/Vision work — the deck advances immediately.
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

    /// Once the deck runs low, top up rather than making the user hit a
    /// hard "no more photos" wall mid-session.
    private let refillThreshold = 5
    private let deckSize = 30

    private let repository: WardrobeRepository
    private let feedService: StockImageFeedService
    /// Extracts the worn garment's attributes from each swiped photo — the sole
    /// Swipe-to-Learn signal now, feeding `Domain/AttributePreferenceProfile.swift`
    /// (the same engine recommendations, Insights and shopping reason in).
    private let visionService: VisionMetadataExtractionService
    private let session: URLSession

    /// Max edge (points) the swiped photo is downscaled to before the vision
    /// LLM call — attribute extraction is coarse, so a smaller image keeps the
    /// per-swipe token cost down without hurting accuracy.
    private static let taggingMaxDimension: CGFloat = 768

    init(
        repository: WardrobeRepository,
        feedService: StockImageFeedService,
        visionService: VisionMetadataExtractionService,
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.feedService = feedService
        self.visionService = visionService
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
            AppLog.info(.viewModel, "SwipeDiscoveryViewModel.loadDeck: ok fetched=\(photos.count) deckSize=\(deck.count)")
        } catch {
            AppLog.error(.viewModel, "SwipeDiscoveryViewModel.loadDeck: failed — \(String(describing: error))")
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
            // Bump the calibration ring immediately (cheap, no network/Vision).
            try repository.noteSwipeForCalibration()
            refreshCalibrationState()
            AppLog.debug(.viewModel, "SwipeDiscoveryViewModel.persistSwipe: ok photo=\(photo.id) liked=\(liked)")
            // The taste signal itself: tag the worn garment and fold its
            // attributes into the one preference engine. Best-effort — a
            // tagging failure must not undo the swipe the user already saw commit.
            await tagSwipeAttributes(photo, liked: liked, imageData: data)
        } catch {
            AppLog.error(.viewModel, "SwipeDiscoveryViewModel.persistSwipe: failed photo=\(photo.id) — \(String(describing: error))")
            lastSwipeError = "Couldn't save that swipe — it won't count toward your taste profile."
        }
    }

    /// Extracts the worn garment's attributes and folds them into the
    /// attribute-space taste profile. Deduped by stock-photo id so a re-shown
    /// card (deck reshuffle) never pays for a second LLM tagging call. Runs in
    /// the background off the committed gesture, so its latency and any failure
    /// are invisible to the swipe.
    private func tagSwipeAttributes(_ photo: StockPhoto, liked: Bool, imageData: Data) async {
        do {
            if try repository.hasSwipeAttributes(sourcePhotoID: photo.id) {
                AppLog.debug(.viewModel, "SwipeDiscoveryViewModel.tagSwipeAttributes: skip already-tagged photo=\(photo.id)")
                return
            }
            let downscaled = ImageStorage.downscaledPNGForUpload(imageData, maxDimension: Self.taggingMaxDimension)
            let metadata = try await visionService.extractMetadata(imageData: downscaled, focus: .wornInScene)
            try repository.recordSwipeAttributes(
                sourcePhotoID: photo.id,
                imageURLString: photo.imageURLString,
                liked: liked,
                metadata: metadata
            )
            AppLog.debug(.viewModel, "SwipeDiscoveryViewModel.tagSwipeAttributes: ok photo=\(photo.id) liked=\(liked) slot=\(metadata.slot.rawValue)")
        } catch {
            AppLog.error(.viewModel, "SwipeDiscoveryViewModel.tagSwipeAttributes: failed photo=\(photo.id) — \(String(describing: error))")
        }
    }
}
