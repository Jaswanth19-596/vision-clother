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

    func signOut() {
        errorMessage = nil
        do {
            try AuthService.shared.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AccountSectionView: View {
    @ObservedObject private var authService = AuthService.shared
    @State private var viewModel = AccountSectionViewModel()

    var body: some View {
        Section("Account") {
            if authService.isSignedIn {
                signedInContent
            } else {
                signedOutContent
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        Label("Signed in", systemImage: "checkmark.seal.fill")
        Button("Sign Out", role: .destructive) {
            viewModel.signOut()
        }
    }

    @ViewBuilder
    private var signedOutContent: some View {
        Text("Sign in to unlock AI outfit recommendations, try-on rendering, and style discovery.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            Label("Sign in with Google", systemImage: "person.crop.circle")
        }
        .disabled(viewModel.isBusy)

        phoneSignInContent
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
            .disabled(viewModel.isBusy || viewModel.phoneNumber.isEmpty)
        case .enterCode:
            TextField("Verification code", text: $viewModel.verificationCode)
                .keyboardType(.numberPad)
            Button("Verify") {
                Task { await viewModel.confirmPhoneCode() }
            }
            .disabled(viewModel.isBusy || viewModel.verificationCode.isEmpty)
            Button("Cancel", role: .cancel) {
                viewModel.resetPhoneFlow()
            }
        }
    }
}

#Preview {
    List {
        AccountSectionView()
    }
}
