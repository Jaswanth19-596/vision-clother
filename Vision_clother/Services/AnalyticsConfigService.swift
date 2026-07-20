//
//  AnalyticsConfigService.swift
//  Vision_clother
//
//  Calls the fourth deliberate business-logic exception in the Firebase proxy
//  (`backend/functions/src/routes/analyticsConfig.ts`, alongside
//  accountDelete/iapVerify/entitlementLimits) — resolving Analytics &
//  Insights confidence/unlock thresholds server-side from
//  `backend/functions/src/analyticsConfig.ts`, so `Domain/AnalyticsConfidence.swift`
//  and the Insights feature never hardcode their own copy. Mirrors
//  `Services/EntitlementLimitsService.swift` exactly.
//

import Foundation

protocol AnalyticsConfigService {
    func fetchConfig() async throws -> AnalyticsConfigResponse
}

enum AnalyticsConfigServiceError: Error, LocalizedError {
    case missingAPIKey
    case network(Error)
    case httpStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Sign in to see your Insights."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .httpStatus(let code):
            return "Couldn't load Insights settings (\(code))."
        case .decoding:
            return "Couldn't read Insights settings from the server."
        }
    }
}

final class RemoteAnalyticsConfigService: AnalyticsConfigService {
    private let session: URLSession
    private let endpoint = ProxyConfig.analyticsConfigURL

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchConfig() async throws -> AnalyticsConfigResponse {
        let requestID = AppLog.newRequestID()
        AppLog.info(.network, "[\(requestID)] analyticsConfig: GET \(endpoint.path)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.network, "[\(requestID)] analyticsConfig: missing auth header — \(String(describing: error))")
            throw AnalyticsConfigServiceError.missingAPIKey
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
            AppLog.error(.network, "[\(requestID)] analyticsConfig: transport error — \(String(describing: error))")
            throw AnalyticsConfigServiceError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.network, "[\(requestID)] analyticsConfig: HTTP \(statusCode)")
            throw AnalyticsConfigServiceError.httpStatus(statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(AnalyticsConfigResponse.self, from: data)
            AppLog.info(.network, "[\(requestID)] analyticsConfig: ok styleDNAMinRatings=\(decoded.styleDNAMinRatings)")
            return decoded
        } catch {
            AppLog.error(.network, "[\(requestID)] analyticsConfig: decode failed — \(String(describing: error))")
            throw AnalyticsConfigServiceError.decoding(error)
        }
    }
}

/// Signed-out/preview fallback — mirrors every other `ServiceFactory`-gated
/// mock. Returns the same conservative numbers a preview/mock session starts
/// with.
final class MockAnalyticsConfigService: AnalyticsConfigService {
    func fetchConfig() async throws -> AnalyticsConfigResponse {
        .conservativeDefault
    }
}

/// Routes every call to a real or mock `AnalyticsConfigService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same rationale as `Services/EntitlementLimitsService.swift`'s
/// `AuthGatedEntitlementLimitsService` doc comment.
final class AuthGatedAnalyticsConfigService: AnalyticsConfigService {
    private lazy var real = RemoteAnalyticsConfigService()
    private lazy var mock = MockAnalyticsConfigService()
    private var current: AnalyticsConfigService { AuthService.shared.isSignedIn ? real : mock }

    func fetchConfig() async throws -> AnalyticsConfigResponse {
        try await current.fetchConfig()
    }
}
