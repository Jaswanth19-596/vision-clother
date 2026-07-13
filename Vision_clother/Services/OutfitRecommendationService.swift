//
//  OutfitRecommendationService.swift
//  Vision_clother
//
//  Primary recommendation call (PRD.md §3.7) — the 2026-07-10
//  LLM-as-Recommender reversal (docs/decisions/resolved-v1.md). Sends the
//  user's free-text prompt, the bounded wardrobe catalog
//  (Domain/WardrobeCatalogBuilder.swift), the derived User Style Profile
//  (PRD §3.8), and current weather to the LLM, which returns outfit picks
//  referencing catalog item IDs. Every returned ID is validated against the
//  catalog by `Domain/OutfitRecommendationValidator.swift` before anything
//  reaches the user — this service's job is only to produce the wire
//  response, not to trust it.
//
//  Same structured-output-with-fallback shape as the other OpenRouter
//  services in this file's directory (see
//  Services/VisionMetadataExtractionService.swift's header for why the
//  configured model needs it). `temperature: 0` minimizes
//  run-to-run non-determinism on top of the validator's hard guarantees.
//

import Foundation

protocol OutfitRecommendationService {
    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse
}

enum OutfitRecommendationError: Error, LocalizedError {
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
            return "The styling service didn't return any outfits."
        case .decoding:
            return "Couldn't understand that — try rephrasing."
        }
    }
}

final class OpenRouterOutfitRecommendationService: OutfitRecommendationService {
    private let session: URLSession
    private let model: String
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared, model: String = ModelConfig.textToText) {
        self.session = session
        self.model = model
    }

    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        do {
            return try await PerfLog.time("recommendation.structuredAttempt") {
                try await performRequest(
                    prompt: prompt, catalog: catalog, profile: profile, weather: weather, history: history, useStructuredOutput: true
                )
            }
        } catch OutfitRecommendationError.emptyChoices, OutfitRecommendationError.decoding, OutfitRecommendationError.httpStatus(400) {
            // Structured output either came back malformed/empty or was
            // rejected outright (most likely `response_format: json_schema`
            // itself isn't supported) — one fallback attempt with the schema
            // embedded in the prompt instead of retrying the same mode twice,
            // which only doubles latency for a failure mode retrying won't fix.
            return try await PerfLog.time("recommendation.unstructuredFallbackAttempt") {
                try await performRequest(
                    prompt: prompt, catalog: catalog, profile: profile, weather: weather, history: history, useStructuredOutput: false
                )
            }
        }
    }

    private func performRequest(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory,
        useStructuredOutput: Bool
    ) async throws -> OutfitRecommendationResponse {
        guard let apiKey = APIKeys.openRouter else {
            throw OutfitRecommendationError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            prompt: prompt,
            catalog: catalog,
            profile: profile,
            weather: weather,
            history: history,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OutfitRecommendationError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OutfitRecommendationError.httpStatus(statusCode)
        }

        let decoded: OpenRouterRecommendationChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterRecommendationChatResponse.self, from: data)
        } catch {
            throw OutfitRecommendationError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw OutfitRecommendationError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            return try JSONDecoder().decode(OutfitRecommendationResponse.self, from: payload)
        } catch {
            throw OutfitRecommendationError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory,
        useStructuredOutput: Bool
    ) throws -> Data {
        let catalogData = try JSONEncoder().encode(catalog)
        let catalogText = String(decoding: catalogData, as: UTF8.self)
        
        let userContent = StylistBrain.DynamicPromptComposer.composeUserContent(
            prompt: prompt,
            weather: weather,
            catalogDataText: catalogText
        )

        var systemPrompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(
            profile: profile,
            attributeProfile: history.attributeProfile
        )

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Structured-JSON path with a hard 15s client-side timeout
            // (DailyAssistantViewModel's requestTimeoutNanoseconds) — the
            // configured model may support extended "thinking" reasoning,
            // which this call doesn't need and can't afford latency-wise.
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
                    "name": "OutfitRecommendationResponse",
                    "strict": true,
                    "schema": outfitRecommendationJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: outfitRecommendationJSONSchema,
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

        Self.logPromptForDebugging(body: body)

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Dumps the exact request body sent to the LLM to the Xcode console —
    /// `print()` rather than `PerfLog`'s `os.Logger` because unified logging
    /// truncates/redacts long string interpolations by default, and the
    /// catalog + system prompt routinely exceed that limit.
    private static func logPromptForDebugging(body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        print("=== [LLM PROMPT] Get Outfit Ideas request ===")
        print(json)
        print("=== [LLM PROMPT] end ===")
    }

    /// Matches PRD.md §3.7's response schema, extended with `resolved_constraints`
    /// (Stylist Intelligence Engine ADR, Decision Hierarchy Tier 1/2 enforcement) —
    /// the same shape `Services/OpenRouterIntentExtractionService.swift` asks the
    /// fallback path for, so the recommendation call self-reports the intent it
    /// resolved without a second LLM round-trip.
    private static let outfitRecommendationJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "outfits": [
                "type": "array",
                // 1, not 3 — the system prompt (StylistBrain.DynamicPromptComposer)
                // explicitly permits returning fewer than 3 when the catalog can't
                // support that many valid, non-duplicate combinations; a stricter
                // floor here would force the model to pad with poor matches to
                // satisfy the schema, contradicting that instruction. Shortfalls
                // below the UX minimum are topped up deterministically by
                // DailyAssistantViewModel, not by coercing the LLM.
                "minItems": 1,
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "properties": [
                        "top_id": ["type": "string"],
                        "bottom_id": ["type": "string"],
                        "footwear_id": ["type": "string"],
                        "outerwear_id": ["type": ["string", "null"]],
                        "rationale": [
                            "type": "object",
                            "properties": [
                                "summary": ["type": "string"],
                                "confidence": ["type": "integer"]
                            ],
                            "required": ["summary", "confidence"],
                            "additionalProperties": false
                        ]
                    ],
                    "required": ["top_id", "bottom_id", "footwear_id", "outerwear_id", "rationale"],
                    "additionalProperties": false,
                ],
            ],
            "resolved_constraints": [
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
                ],
                "required": ["formality_range", "weather_layering_required", "color_palette_vibe", "season_suitability"],
                "additionalProperties": false,
            ],
        ],
        "required": ["outfits", "resolved_constraints"],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterRecommendationChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

/// Reads the *actual* catalog it's given and returns valid picks referencing
/// real IDs from it — so the keyless Simulator path (no API key) still
/// exercises the full validator pipeline with genuinely valid recommendations,
/// not a fixed canned UUID that would always fail validation.
struct MockOutfitRecommendationService: OutfitRecommendationService {
    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        func firstID(for slot: Slot) -> String? {
            catalog.first { $0.slot == slot }?.id
        }

        guard let topID = firstID(for: .top),
              let bottomID = firstID(for: .bottom),
              let footwearID = firstID(for: .footwear) else {
            return OutfitRecommendationResponse(outfits: [])
        }

        let outerwearID: String? = weather != nil ? firstID(for: .outerwear) : nil

        // Best-effort resolved constraints from the same inputs a real model
        // call would reason over — wide-open formality band (the mock has no
        // real scenario understanding), layering keyed off actual weather.
        let resolvedConstraints = StyleConstraints(
            formalityRange: FormalityRange(lowerBound: 1.0, upperBound: 5.0),
            weatherLayeringRequired: (weather?.temperatureFahrenheit ?? 70) < 50,
            colorPaletteVibe: [.neutral],
            seasonSuitability: .springFall
        )

        return OutfitRecommendationResponse(
            outfits: [
                RecommendedOutfitWire(
                    topID: topID,
                    bottomID: bottomID,
                    footwearID: footwearID,
                    outerwearID: outerwearID,
                    rationale: StructuredRationaleWire(
                        summary: "A balanced, neutral-anchored look for the occasion.",
                        confidence: 95
                    )
                ),
            ],
            resolvedConstraints: resolvedConstraints
        )
    }
}
