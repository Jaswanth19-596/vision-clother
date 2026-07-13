//
//  ProfileViewModel.swift
//  Vision_clother
//
//  Owns the Profile tab's imperative orchestration — validating, saving,
//  and deriving a style profile from the user's own photo — the piece the
//  old AnalyticsView never needed a ViewModel for (it only ever read
//  @Query/WardrobeRepository, never called a Service). Now that this screen
//  captures the portrait (moved here from Features/Pairing/ManualPairingView.swift),
//  it calls PersonPhotoValidationService + UserProfileDerivationService, so
//  it needs a real ViewModel per Features/CLAUDE.md ("Views never call
//  Services directly — always go through a ViewModel").
//
//  `@Query`-backed data (items, outfitFeedbacks, itemRatings, styleProfiles)
//  stays in ProfileView itself, matching this codebase's existing
//  convention (AnalyticsView/ClosetView) — `@Query` is declarative binding,
//  not a Service call.
//

import Foundation
import Observation

@Observable
@MainActor
final class ProfileViewModel {
    enum DerivationState: Equatable {
        case idle
        case deriving
        case failed(String)
    }

    private(set) var hasPortrait: Bool
    private(set) var portraitImageData: Data?
    private(set) var photoUploadError: String?
    private(set) var isValidatingPhoto = false
    private(set) var derivationState: DerivationState = .idle
    private(set) var feedbackHistory = FeedbackHistory()

    private let repository: WardrobeRepository
    private let validationService: PersonPhotoValidationService
    private let profileDerivationService: UserProfileDerivationService
    private var derivationTask: Task<Void, Never>?

    init(
        repository: WardrobeRepository,
        validationService: PersonPhotoValidationService = MockPersonPhotoValidationService(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService()
    ) {
        self.repository = repository
        self.validationService = validationService
        self.profileDerivationService = profileDerivationService
        self.hasPortrait = UserPortraitStorage.exists
        self.portraitImageData = UserPortraitStorage.load()
    }

    func refreshFeedbackHistory() {
        feedbackHistory = (try? repository.fetchFeedbackHistory()) ?? FeedbackHistory()
    }

    /// Validate-then-save-then-derive, in that order — a profile screen is
    /// the natural place to catch an unusable photo (multiple people, no
    /// full body, poor lighting) immediately, rather than only discovering
    /// it deep in a later try-on generation (as `ManualPairingViewModel.runPipeline`
    /// used to be the only place this ran). That generate-time check stays
    /// in place too, as cheap on-device defense-in-depth.
    func savePortrait(_ data: Data) {
        photoUploadError = nil
        isValidatingPhoto = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.validationService.validate(imageData: data)
            } catch let error as PersonPhotoValidationError {
                self.isValidatingPhoto = false
                self.photoUploadError = error.errorDescription
                return
            } catch {
                self.isValidatingPhoto = false
                self.photoUploadError = "Couldn't check that photo. Try again."
                return
            }

            self.isValidatingPhoto = false
            try? UserPortraitStorage.save(data)
            self.hasPortrait = true
            self.portraitImageData = data
            self.deriveProfile(from: data)
        }
    }

    func retryDerivation() {
        guard let data = portraitImageData ?? UserPortraitStorage.load() else { return }
        deriveProfile(from: data)
    }

    private func deriveProfile(from data: Data) {
        derivationTask?.cancel()
        derivationState = .deriving
        derivationTask = Task { [weak self] in
            guard let self else { return }
            guard let wire = try? await self.profileDerivationService.deriveProfile(portraitData: data) else {
                self.derivationState = .failed("Couldn't build your style profile.")
                return
            }
            try? self.repository.saveUserProfile(wire)
            self.derivationState = .idle
        }
    }
}
