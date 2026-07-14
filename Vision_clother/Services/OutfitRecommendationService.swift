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
    /// `conversationHistory` is the full clarification-loop transcript so
    /// far (Stylist Intelligence Engine ADR, Phase 2) — index 0 is always
    /// the user's initial scenario; replayed in full every call since
    /// OpenRouter is stateless. `isFinalTurn` instructs the model it must
    /// decide now regardless of remaining ambiguity (the clarification
    /// turn cap has been reached).
    func recommendOutfits(
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
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
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        do {
            return try await PerfLog.time("recommendation.structuredAttempt") {
                try await performRequest(
                    conversationHistory: conversationHistory, isFinalTurn: isFinalTurn,
                    catalog: catalog, profile: profile, weather: weather, history: history, useStructuredOutput: true
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
                    conversationHistory: conversationHistory, isFinalTurn: isFinalTurn,
                    catalog: catalog, profile: profile, weather: weather, history: history, useStructuredOutput: false
                )
            }
        }
    }

    private func performRequest(
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
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
            conversationHistory: conversationHistory,
            isFinalTurn: isFinalTurn,
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
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory,
        useStructuredOutput: Bool
    ) throws -> Data {
        let catalogData = try JSONEncoder().encode(catalog)
        let catalogText = String(decoding: catalogData, as: UTF8.self)

        var systemPrompt = StylistBrain.DynamicPromptComposer.composeSystemPrompt(
            profile: profile,
            attributeProfile: history.attributeProfile,
            isFinalTurn: isFinalTurn
        )

        // Replays the full clarification-loop transcript every call —
        // OpenRouter is stateless, there's no server-side thread to resume
        // (Stylist Intelligence Engine ADR, Phase 2). Only turn 0 (always
        // the user's initial scenario) carries the weather/catalog blob;
        // every later turn's text is sent verbatim with its own role.
        let turnMessages: [[String: String]] = conversationHistory.enumerated().map { index, turn in
            let content: String
            if index == 0 {
                content = StylistBrain.DynamicPromptComposer.composeUserContent(
                    scenarioText: turn.text,
                    weather: weather,
                    catalogDataText: catalogText
                )
            } else {
                content = turn.text
            }
            return ["role": turn.role.rawValue, "content": content]
        }

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Structured-JSON path with a hard 15s client-side timeout
            // (DailyAssistantViewModel's requestTimeoutNanoseconds) — the
            // configured model may support extended "thinking" reasoning,
            // which this call doesn't need and can't afford latency-wise.
            "reasoning": ["enabled": false],
            "messages": [["role": "system", "content": systemPrompt]] + turnMessages,
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
            body["messages"] = [["role": "system", "content": systemPrompt]] + turnMessages
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
                // 0, not 1 or 3 — the system prompt (StylistBrain.DynamicPromptComposer)
                // explicitly permits returning fewer than 3 when the catalog can't
                // support that many valid, non-duplicate combinations, AND permits
                // zero on a clarification/redirect turn (Stylist Intelligence Engine
                // ADR, Phase 2 — Clarification Protocol) — see intent_clear below. A
                // stricter floor here would force the model to pad with poor matches
                // to satisfy the schema, contradicting both instructions. Shortfalls
                // below the UX minimum are topped up deterministically by
                // DailyAssistantViewModel, not by coercing the LLM.
                "minItems": 0,
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "properties": itemIDSchemaProperties.properties.merging(
                        [
                            "rationale": [
                                "type": "object",
                                "properties": [
                                    "summary": ["type": "string"],
                                    "confidence": ["type": "integer", "minimum": 0, "maximum": 100]
                                ],
                                "required": ["summary", "confidence"],
                                "additionalProperties": false
                            ]
                        ],
                        uniquingKeysWith: { _, new in new }
                    ),
                    "required": itemIDSchemaProperties.required + ["rationale"],
                    "additionalProperties": false,
                ],
            ],
            "resolved_constraints": [
                "type": ["object", "null"],
                "description": "Populate only when intent_clear is true and you're returning real recommendations this turn — set null while intent_clear is false (a clarification or redirect turn), since nothing has been resolved yet.",
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
            ],
            "intent_clear": [
                "type": "boolean",
                "description": "True once the occasion is clear enough to output real recommendations this turn (or this is the forced final turn — see FINAL TURN in the system prompt). False when you need to ask a clarifying question or redirect an off-topic message.",
            ],
            "follow_up_text": [
                "type": ["string", "null"],
                "description": "A clarifying question, an off-topic redirect, or a wardrobe-aware decision note alongside real recommendations. Null only when intent_clear is true and there's nothing to say beyond the outfits themselves.",
            ],
            "suggested_chips": [
                "type": "array",
                "items": ["type": "string"],
                "maxItems": 4,
                "description": "2-4 short, Title Case quick-reply suggestions (e.g. \"Job Interview\") for follow_up_text. Empty array when there's nothing to suggest.",
            ],
        ],
        "required": ["outfits", "resolved_constraints", "intent_clear", "follow_up_text", "suggested_chips"],
        "additionalProperties": false,
    ]

    /// Per-slot `{slot}_id` JSON Schema properties, shared by the per-outfit
    /// item schema above — required-but-nullable for optional slots (the
    /// same pattern `outerwear_id` originally used by hand), plain required
    /// string for top/bottom/footwear. Adding a future `Slot` case needs no
    /// change here.
    private static var itemIDSchemaProperties: (properties: [String: Any], required: [String]) {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for slot in Slot.allCases {
            properties[slot.wireKey] = schemaProperty(for: slot)
            required.append(slot.wireKey)
        }
        return (properties, required)
    }

    /// `strict: true` (see `outfitRecommendationJSONSchema` above) requires
    /// every property to appear in `required`, even the four accent/layer
    /// slots that are semantically optional — strict JSON Schema mode has no
    /// concept of "required key, optional value." Left unaddressed, this
    /// reads to a smaller model as "these keys must be filled," biasing it
    /// toward stuffing a plausible-looking item into every accent slot
    /// instead of returning `null` (observed failure: a bag forced into an
    /// interview outfit just because `bag_id` is a required key with a
    /// formality-matching item sitting in the catalog). Each optional slot's
    /// `description` explicitly separates "the key must be present" from
    /// "the value should usually be null," reinforcing the same instruction
    /// `StylistBrain`'s prompt gives in prose — this is the schema-level
    /// backstop for it.
    private static func schemaProperty(for slot: Slot) -> [String: Any] {
        guard !slot.isRequired else { return ["type": "string"] }

        let omissionNote = "This key must always be present in your JSON output, but that does not mean it should be filled — set it to null whenever the slot doesn't apply. Do not search the catalog for a plausible item just because the key exists."
        let guidance: String
        switch slot {
        case .outerwear:
            guidance = "Only set when the scenario/weather genuinely calls for a layer (cold, rain, or a formal blazer/jacket). \(omissionNote)"
        case .headwear:
            guidance = "Only set for outdoor, sunny, or casual scenarios where headwear is typical. Null for indoor, formal, or business/interview scenarios. \(omissionNote)"
        case .accessory:
            guidance = "A single signature accessory piece, only when it genuinely enhances the outfit. \(omissionNote)"
        case .bag:
            guidance = "CRITICAL: only set when carrying a bag is typical for the scenario (errands, commute, travel) and a formality-appropriate option exists in the catalog. For interviews, formal business, or black-tie scenarios this must be null unless a structured/formal bag (e.g. a briefcase) is present in the catalog. \(omissionNote)"
        case .top, .bottom, .footwear:
            preconditionFailure("unreachable — isRequired slots return above before this switch")
        }
        return ["type": ["string", "null"], "description": guidance]
    }
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
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
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

        var itemIDsBySlot: [Slot: String] = [.top: topID, .bottom: bottomID, .footwear: footwearID]
        if weather != nil, let outerwearID = firstID(for: .outerwear) {
            itemIDsBySlot[.outerwear] = outerwearID
        }

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
                    itemIDsBySlot: itemIDsBySlot,
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
