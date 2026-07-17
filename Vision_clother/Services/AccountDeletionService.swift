//
//  AccountDeletionService.swift
//  Vision_clother
//
//  Calls the one deliberate business-logic exception in the Firebase proxy
//  (`backend/functions/src/routes/accountDelete.ts`) — bulk Firestore
//  subtree delete, Storage prefix wipe, and deleting the Firebase Auth user
//  itself, all requiring Admin SDK privileges this app never holds
//  client-side. `Data/WardrobeSyncCoordinator.swift`'s `deleteAccount()`
//  calls this first and only wipes the local mirror on confirmed server-side
//  success — never the other way around, so a failed server call can't
//  strand local data with no server copy having actually been purged.
//
//  Constructed fresh at the call site (`ServiceFactory.makeAccountDeletionService()`),
//  not held across a long-lived object's lifetime — this is a one-shot,
//  user-triggered action, not a service baked into an app-root object at
//  launch, so it doesn't need the `AuthGated` re-check-per-call wrapper every
//  other proxied service uses to dodge a stale `isSignedIn` snapshot (see
//  `Services/WardrobeSyncService.swift`'s doc comment for that incident).
//

import Foundation

protocol AccountDeletionService {
    /// Deletes the signed-in Firebase account's server-side data (Firestore
    /// subtree + Storage files) and the Auth user itself. Throws on any
    /// failure — the caller must not proceed to wipe local data unless this
    /// returns normally.
    func deleteAccount() async throws
}

enum AccountDeletionError: Error, LocalizedError {
    case missingAPIKey
    case network(Error)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Sign in to delete your account."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .httpStatus(let code):
            return "Couldn't delete your account (\(code)). Try again."
        }
    }
}

final class RemoteAccountDeletionService: AccountDeletionService {
    private let session: URLSession
    private let endpoint = ProxyConfig.accountDeleteURL

    init(session: URLSession = .shared) {
        self.session = session
    }

    func deleteAccount() async throws {
        let requestID = AppLog.newRequestID()
        AppLog.notice(.network, "[\(requestID)] accountDeletion: POST \(endpoint.path)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.network, "[\(requestID)] accountDeletion: missing auth header — \(String(describing: error))")
            throw AccountDeletionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.network, "[\(requestID)] accountDeletion: transport error — \(String(describing: error))")
            throw AccountDeletionError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.network, "[\(requestID)] accountDeletion: HTTP \(statusCode)")
            throw AccountDeletionError.httpStatus(statusCode)
        }

        AppLog.notice(.network, "[\(requestID)] accountDeletion: succeeded")
    }
}

/// Signed-out/preview fallback — mirrors every other `ServiceFactory`-gated
/// mock. Never invoked in practice (the UI only offers deletion while
/// signed in), but keeps previews/tests off the real network.
final class MockAccountDeletionService: AccountDeletionService {
    func deleteAccount() async throws {}
}
