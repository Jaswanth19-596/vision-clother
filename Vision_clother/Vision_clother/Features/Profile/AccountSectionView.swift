//
//  AccountSectionView.swift
//  Vision_clother
//
//  Compact account/sign-in section for ProfileView.swift — kept as its own
//  file rather than growing the already-large ProfileView further. Signing
//  in is optional, not a hard gate: `ServiceFactory` already falls back to
//  mocks for every OpenRouter/Pexels-backed service when signed out (see
//  Services/AuthService.swift), so the rest of the app stays interactive.
//

import Combine
import SwiftData
import SwiftUI

@Observable
final class AccountSectionViewModel {
    enum PhoneStep {
        case enterNumber
        case enterCode(verificationID: String)
    }

    var phoneNumber = ""
    var verificationCode = ""
    var phoneStep: PhoneStep = .enterNumber
    var isBusy = false
    var errorMessage: String?
    /// Distinct from `isBusy` (shared across sign-in/phone/sign-out too) —
    /// gates the "Deleting your account…" status label specifically, so it
    /// can't misfire during an unrelated busy sign-in flow.
    private(set) var isDeletingAccount = false
    /// Set by `prepareDebugLogExport()` right before presenting `ShareLink` —
    /// `DebugLogStore` is an actor, so the URL has to be fetched async ahead
    /// of the (synchronous) `ShareLink` init rather than read inline in the view.
    var debugLogURL: URL?

    /// Mirrors of `AuthService.shared`'s `@Published` auth state — added so
    /// `AccountSectionView` (Features/CLAUDE.md: "Views never call Services
    /// directly — always go through a ViewModel") can read auth state here
    /// instead of holding its own `@ObservedObject AuthService.shared`. A
    /// plain computed property forwarding to `AuthService.shared` wouldn't
    /// be reactive under `@Observable` (its tracking only fires on this
    /// class's own stored property writes, not on a Combine `@Published`
    /// read nested inside a computed property), hence the active mirror via
    /// `bindAuthState()`'s Combine subscriptions.
    private(set) var isSignedIn = AuthService.shared.isSignedIn
    private(set) var isAnonymous = AuthService.shared.isAnonymous
    private(set) var uid: String? = AuthService.shared.uid
    private(set) var guestSessionError: String? = AuthService.shared.guestSessionError
    private var authCancellables = Set<AnyCancellable>()

    init() {
        bindAuthState()
    }

    private func bindAuthState() {
        AuthService.shared.$isSignedIn
            .sink { [weak self] in self?.isSignedIn = $0 }
            .store(in: &authCancellables)
        AuthService.shared.$isAnonymous
            .sink { [weak self] in self?.isAnonymous = $0 }
            .store(in: &authCancellables)
        AuthService.shared.$uid
            .sink { [weak self] in self?.uid = $0 }
            .store(in: &authCancellables)
        AuthService.shared.$guestSessionError
            .sink { [weak self] in self?.guestSessionError = $0 }
            .store(in: &authCancellables)
    }

    func signInWithGoogle() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await AuthService.shared.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPhoneCode() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let verificationID = try await AuthService.shared.startPhoneSignIn(phoneNumber: phoneNumber)
            phoneStep = .enterCode(verificationID: verificationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmPhoneCode() async {
        guard case .enterCode(let verificationID) = phoneStep else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await AuthService.shared.confirmPhoneSignIn(verificationID: verificationID, code: verificationCode)
            resetPhoneFlow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetPhoneFlow() {
        phoneNumber = ""
        verificationCode = ""
        phoneStep = .enterNumber
    }

    /// Manual recovery when `AuthService.init()`'s fire-and-forget
    /// `ensureGuestSession()` never established a session (see
    /// `AuthService.guestSessionError`) — every AI feature silently mocks
    /// until this succeeds, so this needs a visible retry, not just a
    /// background relaunch-and-hope.
    func retryGuestSession() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        _ = await AuthService.shared.ensureGuestSession()
    }

    /// Guest-first: sign-out is now "become a fresh guest," not "become
    /// signed-out" — see `Data/WardrobeSyncCoordinator.swift`'s
    /// `performExplicitSignOut` doc comment. Delegates the whole
    /// drain/wipe/sign-out/re-guest sequence there rather than calling
    /// `AuthService.shared.signOut()` directly, since only the coordinator
    /// knows how to do that safely without losing unsynced data.
    func signOut(syncCoordinator: WardrobeSyncCoordinator) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        await syncCoordinator.performExplicitSignOut()
    }

    /// Permanent account deletion — delegates to
    /// `WardrobeSyncCoordinator.deleteAccount()` (server-side purge via
    /// `Services/AccountDeletionService.swift`, then local wipe + guest
    /// reset), same "not this view model's job to know how" posture as
    /// `signOut(syncCoordinator:)`. `errorMessage` carries the reason on
    /// failure — the account is left untouched (both server and local) if
    /// the server-side purge itself failed.
    func deleteAccount(syncCoordinator: WardrobeSyncCoordinator) async {
        errorMessage = nil
        isBusy = true
        isDeletingAccount = true
        defer {
            isBusy = false
            isDeletingAccount = false
        }
        let succeeded = await syncCoordinator.deleteAccount()
        if !succeeded {
            errorMessage = syncCoordinator.lastSyncError ?? "Couldn't delete your account. Try again."
        }
    }

    /// Refreshes `debugLogURL` right before `ShareLink` is presented —
    /// `DebugLogStore.export()` is async (it's an actor), so this can't just
    /// be a computed property on the view.
    func prepareDebugLogExport() async {
        debugLogURL = await DebugLogStore.shared.export()
    }

    func clearDebugLog() async {
        await DebugLogStore.shared.clear()
        debugLogURL = nil
    }
}

struct AccountSectionView: View {
    @State private var viewModel = AccountSectionViewModel()
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    /// Quota visibility feature (`Data/UsageTracker.swift`) — the shared
    /// live source this section's usage readout now reads from, replacing
    /// its previous own `loadUsage()` fetch so it stays consistent with
    /// every point-of-use quota display elsewhere in the app.
    @Environment(UsageTracker.self) private var usageTracker
    @State private var isPresentingDeleteConfirmation = false
    @State private var isPresentingCreditsStore = false

    var body: some View {
        Section("Account") {
            if viewModel.isSignedIn && !viewModel.isAnonymous {
                linkedContent
            } else if viewModel.isSignedIn {
                guestContent
            } else {
                noSessionContent
            }

            usageContent

            if syncCoordinator.isSyncingAccountSwitch {
                Label("Syncing your closet…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, options: .repeating)
            }

            if viewModel.isDeletingAccount {
                Label("Deleting your account…", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let syncError = syncCoordinator.lastSyncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry Sync") {
                    Task { await syncCoordinator.retrySync() }
                }
                .disabled(syncCoordinator.isSyncingAccountSwitch)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            debugLogContent

            // Host modifiers on a single invisible leaf cell to prevent duplication by List
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
                .task(id: viewModel.uid) {
                    await usageTracker.refreshUsage()
                    usageTracker.refreshItemCounts()
                }
                .task {
                    await viewModel.prepareDebugLogExport()
                }
                .alert("Delete Account?", isPresented: $isPresentingDeleteConfirmation) {
                    Button("Delete Everything", role: .destructive) {
                        Task { await viewModel.deleteAccount(syncCoordinator: syncCoordinator) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes your cloud data — wardrobe catalog, saved combinations, ratings, style history, and any purchased credits — on this device and every synced device. This can't be undone.")
                }
                .sheet(isPresented: $isPresentingCreditsStore) {
                    CreditsStoreView()
                }
        }
    }

    /// Lets the user hand over a bug report — every layer's `AppLog` calls
    /// (see `Diagnostics/AppLog.swift`) mirror to this same file, so this is
    /// the one place to grab everything without a Mac/Xcode session.
    @ViewBuilder
    private var debugLogContent: some View {
        if let debugLogURL = viewModel.debugLogURL {
            ShareLink("Share Debug Log", item: debugLogURL)
        }
        Button("Clear Debug Log", role: .destructive) {
            Task { await viewModel.clearDebugLog() }
        }
    }

    @ViewBuilder
    private var linkedContent: some View {
        Label("Signed in", systemImage: "checkmark.seal.fill")
        // Linked accounts only — purchases hang off the Firebase uid, and a
        // guest uid is disposable (see `CreditsStoreView`'s doc comment).
        Button {
            isPresentingCreditsStore = true
        } label: {
            Label("Buy Credits", systemImage: "plus.circle")
        }
        .disabled(syncCoordinator.isSyncingAccountSwitch)
        Button("Sign Out", role: .destructive) {
            Task { await viewModel.signOut(syncCoordinator: syncCoordinator) }
        }
        .disabled(syncCoordinator.isSyncingAccountSwitch)
        Button("Delete Account", role: .destructive) {
            isPresentingDeleteConfirmation = true
        }
        .disabled(viewModel.isBusy || syncCoordinator.isSyncingAccountSwitch)
    }

    /// No Firebase session at all — distinct from `guestContent`'s "browsing
    /// as a guest" (that implies a working anonymous session): this is what
    /// shows when `AuthService.init()`'s fire-and-forget guest sign-in never
    /// completed, so every AI feature is silently mocked
    /// (`Services/ServiceFactory.swift` gates on `isSignedIn`). Previously
    /// this state fell through to `linkedContent`'s "Signed in" + a Sign Out
    /// button that did nothing (`isAnonymous` reads `false` with no
    /// `currentUser` at all, same as a real signed-in account) — this is the
    /// fix for that.
    @ViewBuilder
    private var noSessionContent: some View {
        Text("Couldn't start a session — AI styling features are unavailable until this succeeds.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let guestSessionError = viewModel.guestSessionError {
            Text(guestSessionError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button {
            Task { await viewModel.retryGuestSession() }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isBusy)

        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            Label("Sign in with Google", systemImage: "person.crop.circle")
        }
        .disabled(viewModel.isBusy)

        phoneSignInContent
    }

    /// Guest (unlinked anonymous session): Google/phone sign-in now
    /// transparently *link* this session (`AuthService.signInOrLink`)
    /// rather than replacing it, so the copy here promises "save," not
    /// "unlock" — AI recommendations already work as a guest.
    @ViewBuilder
    private var guestContent: some View {
        Text("Browsing as a guest. Sign in to save your closet across devices, unlock try-on rendering, and buy credits.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            Label("Sign in with Google", systemImage: "person.crop.circle")
        }
        .disabled(viewModel.isBusy || syncCoordinator.isSyncingAccountSwitch)

        phoneSignInContent

        // Guests still have real synced Firestore/Storage data under their
        // anonymous uid (guest-first: `AuthService`'s `isSignedIn` is true
        // for guests too) — offered here too, not just `linkedContent`, so a
        // guest who never links can still purge it rather than it sitting
        // orphaned in the cloud indefinitely.
        Button("Delete My Data", role: .destructive) {
            isPresentingDeleteConfirmation = true
        }
        .disabled(viewModel.isBusy || syncCoordinator.isSyncingAccountSwitch)
    }

    /// Quota summary this billing period — item counts are always shown
    /// (local-only, `Data/UsageTracker.swift.refreshItemCounts()`);
    /// recommendation/combination counts are server-authoritative
    /// (`users/{uid}/meta/usage`, written by
    /// `backend/functions/src/middleware/quota.ts`) and stay hidden until
    /// a first request has actually been made this period (`usage == nil`),
    /// rather than showing a misleading "0/20" before any real server round
    /// trip has happened. "Combinations" is the user-facing term for what
    /// the server tracks as `tryOnCount` — see `UsageTracker`'s doc comment.
    @ViewBuilder
    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(usageTracker.coreItemCount)/\(usageTracker.coreItemCap) core items \u{00B7} \(usageTracker.accessoryItemCount)/\(usageTracker.accessoryItemCap) accessories")
            if usageTracker.usage != nil {
                // "+N purchased" = the lifetime StoreKit credit balance
                // (never expires, spent only after the month's free tier) —
                // hidden at 0 so the pre-IAP readout is unchanged.
                Text("\(usageTracker.recommendationsUsed)/\(usageTracker.recommendationLimit) recommendations this month"
                     + (usageTracker.purchasedRecommendationsRemaining > 0 ? " · +\(usageTracker.purchasedRecommendationsRemaining) purchased" : ""))
                Text("\(usageTracker.combinationsUsed)/\(usageTracker.combinationLimit) combinations this month"
                     + (usageTracker.purchasedCombinationsRemaining > 0 ? " · +\(usageTracker.purchasedCombinationsRemaining) purchased" : ""))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var phoneSignInContent: some View {
        switch viewModel.phoneStep {
        case .enterNumber:
            TextField("Phone number (e.g. +14155551234)", text: $viewModel.phoneNumber)
                .keyboardType(.phonePad)
            Button("Send Code") {
                Task { await viewModel.sendPhoneCode() }
            }
            .disabled(viewModel.isBusy || viewModel.phoneNumber.isEmpty || syncCoordinator.isSyncingAccountSwitch)
        case .enterCode:
            TextField("Verification code", text: $viewModel.verificationCode)
                .keyboardType(.numberPad)
            Button("Verify") {
                Task { await viewModel.confirmPhoneCode() }
            }
            .disabled(viewModel.isBusy || viewModel.verificationCode.isEmpty || syncCoordinator.isSyncingAccountSwitch)
            Button("Cancel", role: .cancel) {
                viewModel.resetPhoneFlow()
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    List {
        AccountSectionView()
    }
    .modelContainer(container)
    .environment(WardrobeSyncCoordinator(modelContext: container.mainContext, syncService: MockWardrobeSyncService()))
    .environment(UsageTracker(
        repository: SyncingWardrobeRepository(modelContext: container.mainContext),
        syncService: MockWardrobeSyncService()
    ))
    // Mock-backed so opening the Buy Credits sheet in a preview never hits
    // the real proxy — same posture as every other preview environment here.
    .environment(StoreKitPaymentManager(
        verificationService: { MockIAPVerificationService() },
        onCreditsGranted: {}
    ))
}
