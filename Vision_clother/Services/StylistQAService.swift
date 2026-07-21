//
//  StylistQAService.swift
//  Vision_clother
//
//  Wardrobe/Insights Q&A (2026-07-20). Deliberately a separate service with
//  its own small, focused system prompt — NOT an extension of
//  `Services/OutfitRecommendationService.swift`'s already-large Decision
//  Hierarchy prompt, which stays completely untouched by this feature to
//  avoid diluting a tuned prompt with unrelated content ("lost in the
//  middle"). Reuses `ProxyConfig.openRouterRecommendURL` — the same
//  quota-gated, payload-agnostic proxy route the recommendation call uses
//  (`backend/functions/src/app.ts` gates the *route*, not the body shape) —
//  so a wardrobe/insights question consumes the same monthly
//  "recommendation" quota as an outfit request, with zero backend changes.
//
//  Called by `DailyAssistantViewModel` only when
//  `Domain/QuestionIntentHeuristic.swift` thinks a turn might be a question
//  — never on the ordinary recommendation happy path, so this adds no
//  latency/cost to a normal "dress me for X" request. When
//  `StylistQAResponse.isWardrobeQuestion` comes back false, the caller falls
//  through to the ordinary, unmodified recommendation flow.
//

import Foundation

protocol StylistQAService {
    /// `conversationHistory` is the same running transcript
    /// `Services/OutfitRecommendationService.swift` replays, so a follow-up
    /// like "what about warm colors" can resolve against a prior answer in
    /// the same conversation. `catalogDataText` and `insightsSummaryText`
    /// are attached alongside the LATEST turn on every single call, never
    /// only "once per conversation" the way the recommendation flow treats
    /// its own turn 0 — this service is invoked fresh and independently for
    /// every question, so the model must have the user's real wardrobe/
    /// Insights data directly alongside whatever it's actually answering
    /// right now, not next to some earlier message. Still wrapped as
    /// cacheable content so a byte-identical block across turns in the same
    /// conversation can still hit an OpenRouter/Anthropic prompt cache.
    func answerWardrobeQuestion(
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String
    ) async throws -> StylistQAResponse
}

enum StylistQAError: Error, LocalizedError {
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

final class OpenRouterStylistQAService: StylistQAService {
    private let session: URLSession
    private let model: String
    private let endpoint = ProxyConfig.openRouterRecommendURL

    init(session: URLSession = .shared, model: String = ModelConfig.textToText) {
        self.session = session
        self.model = model
    }

    func answerWardrobeQuestion(
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String
    ) async throws -> StylistQAResponse {
        do {
            return try await PerfLog.time("stylistQA.structuredAttempt") {
                try await performRequest(
                    conversationHistory: conversationHistory,
                    catalogDataText: catalogDataText,
                    insightsSummaryText: insightsSummaryText,
                    useStructuredOutput: true
                )
            }
        } catch StylistQAError.emptyChoices, StylistQAError.decoding, StylistQAError.httpStatus(400) {
            return try await PerfLog.time("stylistQA.unstructuredFallbackAttempt") {
                try await performRequest(
                    conversationHistory: conversationHistory,
                    catalogDataText: catalogDataText,
                    insightsSummaryText: insightsSummaryText,
                    useStructuredOutput: false
                )
            }
        }
    }

    private func performRequest(
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String,
        useStructuredOutput: Bool
    ) async throws -> StylistQAResponse {
        let requestID = AppLog.newRequestID()
        AppLog.info(.recommendation, "[\(requestID)] stylistQA: POST \(endpoint.path) structured=\(useStructuredOutput) turns=\(conversationHistory.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: missing auth header — \(String(describing: error))")
            throw StylistQAError.missingAPIKey
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
            catalogDataText: catalogDataText,
            insightsSummaryText: insightsSummaryText,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: transport error — \(String(describing: error))")
            throw StylistQAError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: HTTP \(statusCode)")
            throw StylistQAError.httpStatus(statusCode)
        }

        let decoded: OpenRouterStylistQAChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterStylistQAChatResponse.self, from: data)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: response envelope decode failed — \(String(describing: error))")
            throw StylistQAError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: empty choices")
            throw StylistQAError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let result = try JSONDecoder().decode(StylistQAResponse.self, from: payload)
            AppLog.info(.recommendation, "[\(requestID)] stylistQA: ok isWardrobeQuestion=\(result.isWardrobeQuestion)")
            return result
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] stylistQA: StylistQAResponse decode failed — \(String(describing: error))")
            throw StylistQAError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String,
        useStructuredOutput: Bool
    ) throws -> Data {
        var systemPrompt = StylistQABrain.systemPrompt

        // Attached to the LATEST turn, not index 0 — this call is invoked
        // fresh, independently, on every question (never cached/reused
        // across turns the way `OutfitRecommendationService` treats its own
        // turn 0), so the current wardrobe catalog + Insights summary must
        // sit directly alongside the actual question being answered right
        // now, not next to whatever the conversation's very first message
        // happened to be. Guarantees every QA call has full data access
        // regardless of how many earlier turns (QA or recommend) precede it.
        let lastIndex = conversationHistory.count - 1
        let turnMessages: [[String: Any]] = conversationHistory.enumerated().map { index, turn in
            if index == lastIndex {
                let content = StylistQABrain.composeContent(
                    scenarioText: turn.text,
                    catalogDataText: catalogDataText,
                    insightsSummaryText: insightsSummaryText
                )
                return ["role": turn.role.rawValue, "content": Self.cacheableContent(content)]
            }
            return ["role": turn.role.rawValue, "content": turn.text]
        }

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "reasoning": ["enabled": false],
            "messages": [["role": "system", "content": Self.cacheableContent(systemPrompt)]] + turnMessages,
        ]

        if useStructuredOutput {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "StylistQAResponse",
                    "strict": true,
                    "schema": stylistQAJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(withJSONObject: stylistQAJSONSchema, options: [.sortedKeys])
            let schemaText = String(decoding: schemaData, as: UTF8.self)
            systemPrompt += """
            \n\nRespond with ONLY a single JSON object matching this exact schema — no markdown \
            code fences, no explanation, no text before or after the JSON:
            \(schemaText)
            """
            body["messages"] = [["role": "system", "content": Self.cacheableContent(systemPrompt)]] + turnMessages
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Same OpenRouter/Anthropic-style `cache_control` breakpoint shape as
    /// `OutfitRecommendationService.swift`'s `cacheableContent` — additive/
    /// inert on models that don't support it.
    private static func cacheableContent(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]
    }

    private static let stylistQAJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "is_wardrobe_question": [
                "type": "boolean",
                "description": "True only when this is a genuine question about the user's existing wardrobe or their computed Insights, not a request to be dressed for an occasion.",
            ],
            "answer_text": [
                "type": ["string", "null"],
                "description": "The answer, grounded only in the wardrobe catalog and insights summary given. Null when is_wardrobe_question is false.",
            ],
        ],
        "required": ["is_wardrobe_question", "answer_text"],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterStylistQAChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

/// Keyword-matches a handful of obviously-informational phrasings so the
/// keyless Simulator path still demonstrates the feature; anything else
/// routes to the ordinary recommender, matching the real service's
/// conservative "if unsure, false" instruction.
struct MockStylistQAService: StylistQAService {
    func answerWardrobeQuestion(
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String
    ) async throws -> StylistQAResponse {
        guard let latest = conversationHistory.last(where: { $0.role == .user })?.text.lowercased(),
              latest.contains("how many") || latest.contains("what colors") || latest.contains("style dna") else {
            return StylistQAResponse(isWardrobeQuestion: false, answerText: nil)
        }
        return StylistQAResponse(
            isWardrobeQuestion: true,
            answerText: "Here's what your wardrobe data shows: \(insightsSummaryText.prefix(200))…"
        )
    }
}

/// Routes each call to a real or mock `StylistQAService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedOutfitRecommendationService`.
@MainActor
final class AuthGatedStylistQAService: StylistQAService {
    private lazy var real = OpenRouterStylistQAService()
    private lazy var mock = MockStylistQAService()
    private var current: StylistQAService { AuthService.shared.isSignedIn ? real : mock }

    func answerWardrobeQuestion(
        conversationHistory: [ConversationTurn],
        catalogDataText: String,
        insightsSummaryText: String
    ) async throws -> StylistQAResponse {
        try await current.answerWardrobeQuestion(
            conversationHistory: conversationHistory,
            catalogDataText: catalogDataText,
            insightsSummaryText: insightsSummaryText
        )
    }
}
