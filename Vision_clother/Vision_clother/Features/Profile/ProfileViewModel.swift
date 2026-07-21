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

import Combine
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

    /// Whether the current base photo is the bundled default image rather
    /// than a real photo of the user — computed from bytes, not a separate
    /// stored flag (see `UserPortraitStorage.isDefaultBodyPhoto`'s doc
    /// comment), so it stays correct across `refreshPortrait()` calls
    /// (account switches, cross-device sync) with no extra state to keep in
    /// sync.
    var isUsingDefaultBodyPhoto: Bool {
        guard let portraitImageData else { return false }
        return UserPortraitStorage.isDefaultBodyPhoto(portraitImageData)
    }

    private let repository: WardrobeRepository
    private let validationService: PersonPhotoValidationService
    private let profileDerivationService: UserProfileDerivationService
    /// Portrait cloud sync (Cloud Sync, docs/decisions/resolved-v1.md) — held
    /// directly rather than routed through `WardrobeRepository`, mirroring
    /// `AccountSectionViewModel`'s existing precedent for a ViewModel calling
    /// a Service straight (Features/CLAUDE.md's "never call Services
    /// directly" applies to Views, not ViewModels). `UserPortraitStorage` has
    /// no SwiftData row to hang a repository method off of.
    private let syncService: WardrobeSyncService
    private var derivationTask: Task<Void, Never>?

    /// Mirror of `AuthService.shared.$uid` — added so `ProfileView`
    /// (Features/CLAUDE.md: "Views never call Services directly — always go
    /// through a ViewModel") can observe account switches here instead of
    /// holding its own `@ObservedObject AuthService.shared`. A plain
    /// computed property forwarding to `AuthService.shared` wouldn't be
    /// reactive under `@Observable` (its tracking only fires on this
    /// class's own stored property writes), hence the active Combine
    /// mirror via `bindAuthState()`.
    private(set) var uid: String? = AuthService.shared.uid
    private var authCancellables = Set<AnyCancellable>()

    init(
        repository: WardrobeRepository,
        validationService: PersonPhotoValidationService = MockPersonPhotoValidationService(),
        profileDerivationService: UserProfileDerivationService = MockUserProfileDerivationService(),
        syncService: WardrobeSyncService = ServiceFactory.makeWardrobeSyncService()
    ) {
        self.repository = repository
        self.validationService = validationService
        self.profileDerivationService = profileDerivationService
        self.syncService = syncService
        self.hasPortrait = UserPortraitStorage.exists
        self.portraitImageData = UserPortraitStorage.load()
        AuthService.shared.$uid
            .sink { [weak self] in self?.uid = $0 }
            .store(in: &authCancellables)
    }

    /// Re-reads local portrait state from disk — called when the signed-in
    /// account changes (`ProfileView`'s `viewModel.uid` observer) or when
    /// `Data/WardrobeSyncCoordinator.swift`'s background prefetch downloads a
    /// portrait for the newly-switched-to account. `init()` only reads this
    /// once, which is stale the moment an account switch happens later in
    /// the same app session (`ProfileView`'s viewModel is constructed once
    /// for the tab's lifetime).
    func refreshPortrait() {
        hasPortrait = UserPortraitStorage.exists
        portraitImageData = UserPortraitStorage.load()
    }

    func refreshFeedbackHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.feedbackHistory = (try? await self.repository.fetchFeedbackHistory()) ?? FeedbackHistory()
        }
    }

    /// Validate-then-save-then-derive, in that order — a profile screen is
    /// the natural place to catch an unusable photo (multiple people, no
    /// full body, poor lighting) immediately, rather than only discovering
    /// it deep in a later try-on generation (as `ManualPairingViewModel.runPipeline`
    /// used to be the only place this ran). That generate-time check stays
    /// in place too, as cheap on-device defense-in-depth.
    func savePortrait(_ data: Data) {
        AppLog.info(.viewModel, "ProfileViewModel.savePortrait: starting, bytes=\(data.count)")
        photoUploadError = nil
        isValidatingPhoto = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.validationService.validate(imageData: data)
            } catch let error as PersonPhotoValidationError {
                AppLog.notice(.viewModel, "ProfileViewModel.savePortrait: validation rejected — \(error.errorDescription ?? "unknown")")
                self.isValidatingPhoto = false
                self.photoUploadError = error.errorDescription
                return
            } catch {
                AppLog.error(.viewModel, "ProfileViewModel.savePortrait: validation failed — \(String(describing: error))")
                self.isValidatingPhoto = false
                self.photoUploadError = "Couldn't check that photo. Try again."
                return
            }

            AppLog.info(.viewModel, "ProfileViewModel.savePortrait: validated ok")
            self.isValidatingPhoto = false
            try? UserPortraitStorage.save(data)
            self.hasPortrait = true
            self.portraitImageData = data
            self.deriveProfile(from: data)
            self.uploadPortraitIfSignedIn(data)
        }
    }

    /// Alternative to `savePortrait` for users who'd rather not upload a
    /// personal photo — applies the bundled `UserPortraitStorage.defaultBodyPhotoData`
    /// as the base try-on photo. Skips both `validationService` (a plastic
    /// mannequin photo has no human pose/joints for Vision to detect — it
    /// would just fail `PersonPhotoValidationService`) and
    /// `profileDerivationService` (there's no real skin tone/body type to
    /// read from it), assigning a neutral `UserStyleProfileWire` instead so
    /// recommendation personalization degrades gracefully rather than
    /// erroring. Still saved/uploaded through the same paths as a real
    /// photo, so Cloud Sync carries the choice to other devices for free.
    func useDefaultBodyPhoto() {
        guard let data = UserPortraitStorage.defaultBodyPhotoData else {
            AppLog.error(.viewModel, "ProfileViewModel.useDefaultBodyPhoto: bundled default image missing")
            photoUploadError = "The default image isn't available."
            return
        }
        AppLog.info(.viewModel, "ProfileViewModel.useDefaultBodyPhoto: applying bundled default")
        photoUploadError = nil
        derivationTask?.cancel()
        try? UserPortraitStorage.save(data)
        hasPortrait = true
        portraitImageData = data
        derivationState = .idle
        let neutralProfile = UserStyleProfileWire(
            skinTone: "Not specified",
            undertone: .neutral,
            bodyType: "Not specified",
            styleKeywords: [],
            recommendedColors: [],
            avoidColors: []
        )
        try? repository.saveUserProfile(neutralProfile)
        uploadPortraitIfSignedIn(data)
    }

    /// Best-effort, not part of the durable `SyncMetadata` outbox — same
    /// posture as `SyncingWardrobeRepository.uploadImageIfNeeded`. A failed
    /// upload just means this device's portrait isn't in Cloud Storage yet;
    /// the next successful save (or a future explicit retry) covers it.
    private func uploadPortraitIfSignedIn(_ data: Data) {
        guard let uid = AuthService.shared.uid else { return }
        let service = syncService
        Task { try? await service.uploadPortrait(data: data, uid: uid) }
    }

    func retryDerivation() {
        guard let data = portraitImageData ?? UserPortraitStorage.load() else { return }
        deriveProfile(from: data)
    }

    private func deriveProfile(from data: Data) {
        AppLog.info(.viewModel, "ProfileViewModel.deriveProfile: starting")
        derivationTask?.cancel()
        derivationState = .deriving
        derivationTask = Task { [weak self] in
            guard let self else { return }
            guard let wire = try? await self.profileDerivationService.deriveProfile(portraitData: data) else {
                AppLog.error(.viewModel, "ProfileViewModel.deriveProfile: failed")
                self.derivationState = .failed("Couldn't build your style profile.")
                return
            }
            try? self.repository.saveUserProfile(wire)
            AppLog.info(.viewModel, "ProfileViewModel.deriveProfile: ok")
            self.derivationState = .idle
        }
    }
}
