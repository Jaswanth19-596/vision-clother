//
//  IntentRoutingService.swift
//  Vision_clother
//
//  Intent routing (2026-07-27): replaces `Domain/QuestionIntentHeuristic.swift`'s
//  on-device keyword/"?" pre-filter with a real LLM classification call, so a
//  question phrased without an interrogative opener ("summarize my style")
//  still gets routed to `Services/StylistQAService.swift` instead of silently
//  falling through to the outfit recommender.
//
//  Deliberately hits `ProxyConfig.openRouterChatURL` — the uncapped route
//  (`backend/functions/src/app.ts`'s `rateLimitOnly` middleware only), never
//  `openRouterRecommendURL` — so this call never debits the metered
//  `RECOMMENDATION` credit (`creditGate.ts`). Both `StylistQAService` and
//  `OutfitRecommendationService` already cost one credit per hit on that
//  route; routing every single Daily Assistant turn through a second metered
//  call here would permanently double the cost of ordinary usage. Same
//  posture as the existing vision-tagging/profile-derivation calls that
//  already use `openRouterChatURL`.
//
//  Sends the full `conversationHistory` (same list `StylistQAService`/
//  `OutfitRecommendationService` replay) but deliberately never the wardrobe
//  catalog, Insights summary, referenced-items block, weather, or style
//  profile — this call only needs to know what kind of turn this is, not the
//  user's actual data, so it stays cheap and fast. `Domain/IntentRouterBrain.swift`
//  holds the prompt.
//
//  Called by `DailyAssistantViewModel.resolveTurn()` on every ordinary
//  free-text turn, before either `resolveWardrobeQuestion` or `resolveOutfits`
//  is attempted.
//

import Foundation

protocol IntentRoutingService {
    func routeIntent(conversationHistory: [ConversationTurn]) async throws -> RoutedIntent
}

enum IntentRoutingError: Error, LocalizedError {
    case missingAPIKey
    case network(Error)
    case httpStatus(Int)
    case emptyChoices
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenRouter API key configured."
        case .network:
            return "Couldn't reach the styling service. Check your connection."
        case .httpStatus(let code):
            return "Styling service returned an error (\(code))."
        case .emptyChoices:
            return "The styling service didn't return an answer."
        case .decoding:
            return "Couldn't understand that — try rephrasing."
        }
    }
}

final class OpenRouterIntentRoutingService: IntentRoutingService {
    private let session: URLSession
    private let model: String
    private let endpoint = ProxyConfig.openRouterChatURL

    init(session: URLSession = .shared, model: String = ModelConfig.textToText) {
        self.session = session
        self.model = model
    }

    func routeIntent(conversationHistory: [ConversationTurn]) async throws -> RoutedIntent {
        do {
            return try await PerfLog.time("intentRouting.structuredAttempt") {
                try await performRequest(conversationHistory: conversationHistory, useStructuredOutput: true)
            }
        } catch IntentRoutingError.emptyChoices, IntentRoutingError.decoding, IntentRoutingError.httpStatus(400) {
            return try await PerfLog.time("intentRouting.unstructuredFallbackAttempt") {
                try await performRequest(conversationHistory: conversationHistory, useStructuredOutput: false)
            }
        }
    }

    private func performRequest(
        conversationHistory: [ConversationTurn],
        useStructuredOutput: Bool
    ) async throws -> RoutedIntent {
        let requestID = AppLog.newRequestID()
        AppLog.info(.recommendation, "[\(requestID)] intentRouting: POST \(endpoint.path) structured=\(useStructuredOutput) turns=\(conversationHistory.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current(requestID: requestID)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: missing auth header — \(String(describing: error))")
            throw IntentRoutingError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            conversationHistory: conversationHistory,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: transport error — \(String(describing: error))")
            throw IntentRoutingError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: HTTP \(statusCode)")
            throw IntentRoutingError.httpStatus(statusCode)
        }

        let decoded: OpenRouterIntentRoutingChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterIntentRoutingChatResponse.self, from: data)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: response envelope decode failed — \(String(describing: error))")
            throw IntentRoutingError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: empty choices")
            throw IntentRoutingError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let result = try JSONDecoder().decode(IntentRoutingResponse.self, from: payload)
            AppLog.info(.recommendation, "[\(requestID)] intentRouting: ok intent=\(result.intent.rawValue)")
            return result.intent
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] intentRouting: IntentRoutingResponse decode failed — \(String(describing: error))")
            throw IntentRoutingError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        conversationHistory: [ConversationTurn],
        useStructuredOutput: Bool
    ) throws -> Data {
        var systemPrompt = IntentRouterBrain.systemPrompt
        let turnMessages: [[String: Any]] = conversationHistory.map { turn in
            ["role": turn.role.rawValue, "content": turn.text]
        }

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "reasoning": ["enabled": false],
            "messages": [["role": "system", "content": systemPrompt]] + turnMessages,
        ]

        if useStructuredOutput {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "IntentRoutingResponse",
                    "strict": true,
                    "schema": intentRoutingJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(withJSONObject: intentRoutingJSONSchema, options: [.sortedKeys])
            let schemaText = String(decoding: schemaData, as: UTF8.self)
            systemPrompt += """
            \n\nRespond with ONLY a single JSON object matching this exact schema — no markdown \
            code fences, no explanation, no text before or after the JSON:
            \(schemaText)
            """
            body["messages"] = [["role": "system", "content": systemPrompt]] + turnMessages
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    private static let intentRoutingJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "intent": [
                "type": "string",
                "enum": ["RECOMMENDATION", "GENERAL_QA"],
                "description": "RECOMMENDATION for a concrete request to be dressed for an occasion (or a refinement of outfits already shown); GENERAL_QA for anything else, including when unsure.",
            ],
        ],
        "required": ["intent"],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterIntentRoutingChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

/// Small inline keyword check so the keyless Simulator path still
/// demonstrates both flows without a real classification call — same
/// conservative "if unsure, GENERAL_QA" default the real prompt uses, and
/// the same style `MockStylistQAService` already uses for its own inline
/// checks. Not a reintroduction of `QuestionIntentHeuristic` as shared
/// Domain API — this logic only exists here, for the offline demo path.
struct MockIntentRoutingService: IntentRoutingService {
    private static let recommendationOpeners: Set<String> = [
        "dress", "wear", "outfit", "style", "put",
    ]

    func routeIntent(conversationHistory: [ConversationTurn]) async throws -> RoutedIntent {
        guard let latest = conversationHistory.last(where: { $0.role == .user })?.text.lowercased() else {
            return .generalQA
        }
        let looksLikeOccasionRequest = latest.contains("wear to") || latest.contains("dress me")
            || latest.contains("outfit for") || Self.recommendationOpeners.contains(where: latest.hasPrefix)
        return looksLikeOccasionRequest ? .recommendation : .generalQA
    }
}

/// Routes each call to a real or mock `IntentRoutingService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedStylistQAService`.
@MainActor
final class AuthGatedIntentRoutingService: IntentRoutingService {
    private lazy var real = OpenRouterIntentRoutingService()
    private lazy var mock = MockIntentRoutingService()
    private var current: IntentRoutingService { AuthService.shared.isSignedIn ? real : mock }

    func routeIntent(conversationHistory: [ConversationTurn]) async throws -> RoutedIntent {
        try await current.routeIntent(conversationHistory: conversationHistory)
    }
}
