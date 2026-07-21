//
//  AccountCardView.swift
//  Vision_clother
//
//  The Profile tab's sign-in/sign-out surface — split out of
//  AccountSectionView.swift (formerly the *only* place sign-in/out lived,
//  buried behind the gear-icon Settings sheet) so account status is visible
//  directly in the main Profile list, first section. AccountSectionView
//  keeps the rest of "Settings" (credits, usage, sync status, debug log,
//  delete account) behind the gear icon — see Features/Profile/CLAUDE.md.
//

import SwiftUI
import SwiftData
import Combine

@Observable
final class AccountCardViewModel {
    enum PhoneStep {
        case enterNumber
        case enterCode(verificationID: String)
    }

    var phoneNumber = ""
    var verificationCode = ""
    var phoneStep: PhoneStep = .enterNumber
    var isBusy = false
    var errorMessage: String?

    /// Mirrors of `AuthService.shared`'s `@Published` auth state — see
    /// `AccountSectionViewModel`'s identical doc comment for why a plain
    /// computed forwarding property wouldn't be `@Observable`-reactive here.
    private(set) var isSignedIn = AuthService.shared.isSignedIn
    private(set) var isAnonymous = AuthService.shared.isAnonymous
    private(set) var uid: String? = AuthService.shared.uid
    private(set) var guestSessionError: String? = AuthService.shared.guestSessionError
    private(set) var displayLabel: String? = AuthService.shared.displayLabel
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
        AuthService.shared.$displayLabel
            .sink { [weak self] in self?.displayLabel = $0 }
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
    /// `ensureGuestSession()` never established a session — see
    /// `AccountSectionViewModel`'s identical doc comment.
    func retryGuestSession() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        _ = await AuthService.shared.ensureGuestSession()
    }

    /// Guest-first: sign-out is "become a fresh guest," not "become
    /// signed-out" — delegates to `WardrobeSyncCoordinator` for the safe
    /// drain/wipe/sign-out/re-guest sequence. See
    /// `AccountSectionViewModel.signOut(syncCoordinator:)`'s identical doc
    /// comment.
    func signOut(syncCoordinator: WardrobeSyncCoordinator) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        await syncCoordinator.performExplicitSignOut()
    }
}

struct AccountCardView: View {
    @State private var viewModel = AccountCardViewModel()
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    @State private var isPhoneSignInExpanded = false

    var body: some View {
        Section {
            if viewModel.isSignedIn && !viewModel.isAnonymous {
                linkedContent
            } else if viewModel.isSignedIn {
                guestContent
            } else {
                noSessionContent
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private var linkedContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed in")
                    .font(.subheadline.weight(.semibold))
                if let displayLabel = viewModel.displayLabel {
                    Text(displayLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)

        Button("Sign Out", role: .destructive) {
            Task { await viewModel.signOut(syncCoordinator: syncCoordinator) }
        }
        .disabled(viewModel.isBusy || syncCoordinator.isSyncingAccountSwitch)
    }

    /// Guest (unlinked anonymous session): Google/phone sign-in *link* this
    /// session rather than replacing it, so the copy promises "save," not
    /// "unlock" — AI recommendations already work as a guest.
    @ViewBuilder
    private var guestContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Browsing as a Guest")
                    .font(.subheadline.weight(.semibold))
                Text("Sign in to save your closet across devices, unlock try-on rendering, and buy credits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)

        signInActions
    }

    /// No Firebase session at all — `AuthService.init()`'s fire-and-forget
    /// guest sign-in never completed, so every AI feature is silently
    /// mocked. See `AccountSectionViewModel.noSessionContent`'s identical
    /// doc comment for the guest-vs-no-session distinction.
    @ViewBuilder
    private var noSessionContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't start a session")
                    .font(.subheadline.weight(.semibold))
                Text("AI styling features are unavailable until this succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let guestSessionError = viewModel.guestSessionError {
                    Text(guestSessionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)

        Button {
            Task { await viewModel.retryGuestSession() }
        } label: {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isBusy)

        signInActions
    }

    @ViewBuilder
    private var signInActions: some View {
        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            Label("Sign in with Google", systemImage: "person.crop.circle")
        }
        .disabled(viewModel.isBusy || syncCoordinator.isSyncingAccountSwitch)

        DisclosureGroup("Sign in with phone number instead", isExpanded: $isPhoneSignInExpanded) {
            phoneSignInContent
        }
        .font(.footnote)
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
    List {
        AccountCardView()
    }
    .environment(WardrobeSyncCoordinator(
        modelContext: try! ModelContainer(
            for: WardrobeItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ).mainContext,
        syncService: MockWardrobeSyncService()
    ))
}
