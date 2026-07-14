//
//  OpenRouterIntentExtractionService.swift
//  Vision_clother
//
//  Intent Extraction Layer (PRD.md §2.1, stage 1). This call itself never
//  receives the wardrobe — it only ever sees free text + weather and only
//  ever produces a `StyleConstraints` payload, ideally enforced via
//  OpenRouter's `response_format: json_schema`. Since the 2026-07-10
//  LLM-as-Recommender reversal (CLAUDE.md core invariant,
//  docs/decisions/resolved-v1.md), this service backs the deterministic
//  *fallback* path only — the primary recommendation path is
//  `Services/OutfitRecommendationService.swift`, which does see a bounded
//  wardrobe catalog. Kept as its own narrow call because the fallback engine
//  (`Domain/OutfitRecommendationEngine.swift`) still needs `StyleConstraints`.
//
//  The configured model's (Config/ModelConfig.swift's `textToText`)
//  structured-output support isn't confirmed the way OpenAI's is (CLAUDE.md
//  §5.1), so a `response_format: json_schema` request
//  that gets rejected (HTTP 400) or silently ignored (content doesn't decode)
//  falls back to a plain-prompt request that embeds the schema as
//  instructions and parses the reply leniently (strips markdown fences,
//  extracts the outermost `{...}`). Structured output is still attempted
//  first on every call — the fallback only engages when it's actually needed.
//
//  Swift has no official OpenRouter/OpenAI SDK, so this calls the REST API
//  directly over `URLSession` — no third-party dependency.
//

import Foundation

protocol IntentExtractionService {
    func extractConstraints(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints
}

enum IntentExtractionError: Error, LocalizedError {
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
            return "The styling service didn't return a suggestion."
        case .decoding:
            return "Couldn't understand that — try rephrasing."
        }
    }
}

/// Real network implementation. Retries exactly once, silently, when the
/// response is well-formed HTTP but the *content* is unusable
/// (`.emptyChoices` / `.decoding`) — a one-off provider hiccup shouldn't
/// surface an error the first time. Network/HTTP-status failures are not
/// retried here (more likely a real outage or misconfiguration; an
/// immediate retry just doubles the wait) — the caller's UI is responsible
/// for a manual retry affordance in that case.
final class OpenRouterIntentExtractionService: IntentExtractionService {
    private let session: URLSession
    private let model: String
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared, model: String = ModelConfig.textToText) {
        self.session = session
        self.model = model
    }

    func extractConstraints(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints {
        do {
            return try await PerfLog.time("intentExtraction.structuredAttempt1") {
                try await performRequest(prompt: prompt, weather: weather, useStructuredOutput: true)
            }
        } catch IntentExtractionError.emptyChoices, IntentExtractionError.decoding {
            do {
                return try await PerfLog.time("intentExtraction.structuredAttempt2") {
                    try await performRequest(prompt: prompt, weather: weather, useStructuredOutput: true)
                }
            } catch {
                return try await performUnstructuredFallback(prompt: prompt, weather: weather)
            }
        } catch IntentExtractionError.httpStatus(400) {
            // Most likely `response_format: json_schema` itself was rejected
            // by the provider — retrying the same structured request would
            // just 400 again, so switch modes instead of retrying.
            return try await performUnstructuredFallback(prompt: prompt, weather: weather)
        }
    }

    /// Same request with `response_format` dropped and the schema embedded
    /// as plain-text instructions instead — the one silent content-level
    /// retry still applies here, same as the structured path.
    private func performUnstructuredFallback(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints {
        do {
            return try await PerfLog.time("intentExtraction.unstructuredAttempt1") {
                try await performRequest(prompt: prompt, weather: weather, useStructuredOutput: false)
            }
        } catch IntentExtractionError.emptyChoices, IntentExtractionError.decoding {
            return try await PerfLog.time("intentExtraction.unstructuredAttempt2") {
                try await performRequest(prompt: prompt, weather: weather, useStructuredOutput: false)
            }
        }
    }

    private func performRequest(
        prompt: String,
        weather: WeatherContext?,
        useStructuredOutput: Bool
    ) async throws -> StyleConstraints {
        guard let apiKey = APIKeys.openRouter else {
            throw IntentExtractionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            prompt: prompt,
            weather: weather,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IntentExtractionError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntentExtractionError.httpStatus(statusCode)
        }

        let decoded: OpenRouterChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)
        } catch {
            throw IntentExtractionError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw IntentExtractionError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            return try JSONDecoder().decode(StyleConstraints.self, from: payload)
        } catch {
            throw IntentExtractionError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        prompt: String,
        weather: WeatherContext?,
        useStructuredOutput: Bool
    ) throws -> Data {
        var userContent = prompt
        if let weather {
            userContent += "\n\nCurrent weather: \(weather.temperatureFahrenheit)°F, \(weather.conditions)."
        }

        var systemPrompt = ModelConfig.Prompts.intentExtractionSystemPrompt

        var body: [String: Any] = [
            "model": model,
            // See OutfitRecommendationService.swift's `encodeRequestBody`
            // for why this call disables reasoning.
            "reasoning": ["enabled": false],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]

        if useStructuredOutput {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "StyleConstraints",
                    "strict": true,
                    "schema": styleConstraintsJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: styleConstraintsJSONSchema,
                options: [.sortedKeys]
            )
            let schemaText = String(decoding: schemaData, as: UTF8.self)
            systemPrompt += """
            \n\nRespond with ONLY a single JSON object matching this exact schema — no markdown \
            code fences, no explanation, no text before or after the JSON:
            \(schemaText)
            """
            body["messages"] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ]
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Matches PRD.md §3.3's JSON Schema exactly.
    private static let styleConstraintsJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "formality_range": [
                "type": "array",
                "minItems": 2,
                "maxItems": 2,
                "items": ["type": "number", "minimum": 1.0, "maximum": 5.0],
            ],
            "weather_layering_required": ["type": "boolean"],
            "color_palette_vibe": [
                "type": "array",
                "items": ["type": "string", "enum": ColorVibe.allCases.map(\.rawValue)],
            ],
            "season_suitability": ["type": "string", "enum": Season.allCases.map(\.rawValue)],
            "desired_accent_slots": [
                "type": "array",
                "items": ["type": "string", "enum": Slot.allCases.filter { !$0.isRequired && $0 != .outerwear }.map(\.rawValue)],
            ],
        ],
        "required": ["formality_range", "weather_layering_required", "color_palette_vibe", "season_suitability", "desired_accent_slots"],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockIntentExtractionService: IntentExtractionService {
    var result: StyleConstraints = StyleConstraints(
        formalityRange: FormalityRange(lowerBound: 2.5, upperBound: 3.5),
        weatherLayeringRequired: false,
        colorPaletteVibe: [.neutral, .earthTones],
        seasonSuitability: .springFall
    )

    func extractConstraints(prompt: String, weather: WeatherContext?) async throws -> StyleConstraints {
        result
    }
}
