//
//  IAPVerificationService.swift
//  Vision_clother
//
//  Client half of the StoreKit purchase-verification handshake
//  (`backend/functions/src/routes/iapVerify.ts`) — posts a StoreKit 2
//  transaction JWS to the proxy, which verifies the signature server-side
//  and credits the purchased balance on the server-only-write
//  `users/{uid}/meta/usage` doc. Modeled on
//  `Services/AccountDeletionService.swift`'s remote/mock split.
//
//  The error taxonomy is the contract `StoreKitPaymentManager` builds its
//  Transaction.finish() decisions on: `network`/`serverUnavailable` are
//  retryable (leave the StoreKit transaction unfinished, StoreKit
//  redelivers it), `rejected` is terminal for this attempt.
//
//  Redaction: the JWS is a signed payload — never log it, only its length.
//

import Foundation

protocol IAPVerificationService {
    /// Submits a transaction JWS for verification and crediting. Returns the
    /// backend's grant outcome; throws `IAPVerificationError` otherwise.
    func verify(jws: String) async throws -> IAPGrantResult
}

/// Wire mirror of `iapVerify.ts`'s success responses.
struct IAPGrantResult: Decodable, Equatable {
    let granted: Bool
    let creditType: String?
    let amount: Int?
    let newBalance: Int?
    let alreadyProcessed: Bool?
    /// `"revoked"` when a refunded transaction was recorded without a grant.
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case granted
        case creditType
        case amount
        case newBalance
        case alreadyProcessed
        case reason
    }
}

/// Wire mirror of the proxy's error bodies (`{"error": "<snake_case_code>"}`).
private struct ProxyErrorResponse: Decodable {
    let error: String

    enum CodingKeys: String, CodingKey {
        case error
    }
}

enum IAPVerificationError: Error, LocalizedError {
    /// No signed-in session to mint a bearer token from.
    case notSignedIn
    /// Transport failure — retryable; do not finish the transaction.
    case network(Error)
    /// 5xx (including the route's fail-closed 503) — retryable; do not
    /// finish the transaction.
    case serverUnavailable(Int)
    /// 4xx with a decoded error code (`invalid_transaction`,
    /// `unknown_product`, `sign_in_required`, `environment_not_supported`,
    /// `invalid_request`) — terminal for this attempt.
    case rejected(code: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to buy credits."
        case .network:
            return "Couldn't reach the server. Your purchase is safe and will be credited automatically once you're back online."
        case .serverUnavailable:
            return "The server is temporarily unavailable. Your purchase is safe and will be credited automatically."
        case .rejected:
            return "This purchase couldn't be verified yet. It will be retried automatically."
        }
    }
}

final class RemoteIAPVerificationService: IAPVerificationService {
    private let session: URLSession
    private let endpoint = ProxyConfig.iapVerifyURL

    init(session: URLSession = .shared) {
        self.session = session
    }

    func verify(jws: String) async throws -> IAPGrantResult {
        let requestID = AppLog.newRequestID()
        AppLog.notice(.payments, "[\(requestID)] iapVerify: POST \(endpoint.path) jwsLength=\(jws.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.payments, "[\(requestID)] iapVerify: missing auth header — \(String(describing: error))")
            throw IAPVerificationError.notSignedIn
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(["jws": jws])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.payments, "[\(requestID)] iapVerify: transport error — \(String(describing: error))")
            throw IAPVerificationError.network(error)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch statusCode {
        case 200...299:
            do {
                let result = try JSONDecoder().decode(IAPGrantResult.self, from: data)
                AppLog.notice(.payments, "[\(requestID)] iapVerify: granted=\(result.granted) alreadyProcessed=\(result.alreadyProcessed ?? false) newBalance=\(result.newBalance.map(String.init) ?? "-")")
                return result
            } catch {
                AppLog.error(.payments, "[\(requestID)] iapVerify: undecodable 2xx body — \(String(describing: error))")
                throw IAPVerificationError.serverUnavailable(statusCode)
            }
        case 400...499:
            let code = (try? JSONDecoder().decode(ProxyErrorResponse.self, from: data))?.error ?? "http_\(statusCode)"
            AppLog.error(.payments, "[\(requestID)] iapVerify: rejected \(statusCode) code=\(code)")
            throw IAPVerificationError.rejected(code: code)
        default:
            AppLog.error(.payments, "[\(requestID)] iapVerify: HTTP \(statusCode)")
            throw IAPVerificationError.serverUnavailable(statusCode)
        }
    }
}

/// Signed-out/preview/test fallback — mirrors `MockAccountDeletionService`.
/// Grants nothing so no preview or unauthenticated state can look like a
/// successful purchase.
final class MockIAPVerificationService: IAPVerificationService {
    func verify(jws: String) async throws -> IAPGrantResult {
        throw IAPVerificationError.notSignedIn
    }
}
