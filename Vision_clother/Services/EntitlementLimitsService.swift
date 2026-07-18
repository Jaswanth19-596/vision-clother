//
//  EntitlementLimitsService.swift
//  Vision_clother
//
//  Calls the one deliberate business-logic exception in the Firebase proxy
//  added for this purpose (`backend/functions/src/routes/entitlementLimits.ts`,
//  alongside accountDelete/iapVerify) — resolving the caller's tier into
//  concrete recommendation/try-on/item-cap numbers server-side, computed
//  from the same `backend/functions/src/entitlementLimits.ts` module
//  `middleware/quota.ts` enforces against. `Data/UsageTracker.swift` is the
//  sole caller — see its doc comment for the fetch cadence.
//

import Foundation

protocol EntitlementLimitsService {
    func fetchLimits() async throws -> EntitlementLimitsResponse
}

enum EntitlementLimitsServiceError: Error, LocalizedError {
    case missingAPIKey
    case network(Error)
    case httpStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Sign in to see your usage limits."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .httpStatus(let code):
            return "Couldn't load usage limits (\(code))."
        case .decoding:
            return "Couldn't read usage limits from the server."
        }
    }
}

final class RemoteEntitlementLimitsService: EntitlementLimitsService {
    private let session: URLSession
    private let endpoint = ProxyConfig.entitlementLimitsURL

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLimits() async throws -> EntitlementLimitsResponse {
        let requestID = AppLog.newRequestID()
        AppLog.info(.network, "[\(requestID)] entitlementLimits: GET \(endpoint.path)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.network, "[\(requestID)] entitlementLimits: missing auth header — \(String(describing: error))")
            throw EntitlementLimitsServiceError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.network, "[\(requestID)] entitlementLimits: transport error — \(String(describing: error))")
            throw EntitlementLimitsServiceError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.network, "[\(requestID)] entitlementLimits: HTTP \(statusCode)")
            throw EntitlementLimitsServiceError.httpStatus(statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(EntitlementLimitsResponse.self, from: data)
            AppLog.info(.network, "[\(requestID)] entitlementLimits: ok tier=\(decoded.tier) recommendationLimit=\(decoded.recommendationLimit) tryOnLimit=\(decoded.tryOnLimit)")
            return decoded
        } catch {
            AppLog.error(.network, "[\(requestID)] entitlementLimits: decode failed — \(String(describing: error))")
            throw EntitlementLimitsServiceError.decoding(error)
        }
    }
}

/// Signed-out/preview fallback — mirrors every other `ServiceFactory`-gated
/// mock. Returns the same conservative numbers `UsageTracker` starts with,
/// so a preview/mock session behaves like a freshly-launched guest.
final class MockEntitlementLimitsService: EntitlementLimitsService {
    func fetchLimits() async throws -> EntitlementLimitsResponse {
        .conservativeDefault
    }
}

/// Routes every call to a real or mock `EntitlementLimitsService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same rationale as `Services/WardrobeSyncService.swift`'s
/// `AuthGatedWardrobeSyncService` doc comment: `Data/UsageTracker.swift`
/// holds this for the app's entire lifetime, constructed once at launch
/// before auth state may have settled, so a construction-time snapshot
/// would risk permanently freezing a signed-out session's mock even after
/// a later sign-in.
final class AuthGatedEntitlementLimitsService: EntitlementLimitsService {
    private lazy var real = RemoteEntitlementLimitsService()
    private lazy var mock = MockEntitlementLimitsService()
    private var current: EntitlementLimitsService { AuthService.shared.isSignedIn ? real : mock }

    func fetchLimits() async throws -> EntitlementLimitsResponse {
        try await current.fetchLimits()
    }
}
