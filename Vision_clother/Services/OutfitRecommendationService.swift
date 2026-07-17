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
    /// 429 from `backend/functions/src/middleware/quota.ts`'s `"recommendation"`
    /// gate — `limit` is the monthly cap that was hit (20 guest / 100 free).
    case quotaExceeded(limit: Int)
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
        case .quotaExceeded(let limit):
            // The server only 429s once purchased credits are also 0
            // (quota.ts draws down the balance first), so this copy can
            // safely point at buying more.
            return "You've used all \(limit) free recommendations this month and any purchased credits. Buy more in Profile, or wait for the monthly reset."
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
    private let endpoint = ProxyConfig.openRouterRecommendURL

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
        let requestID = AppLog.newRequestID()
        AppLog.info(.recommendation, "[\(requestID)] recommend: POST \(endpoint.path) structured=\(useStructuredOutput) catalogSize=\(catalog.count) turns=\(conversationHistory.count) isFinalTurn=\(isFinalTurn)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] recommend: missing auth header — \(String(describing: error))")
            throw OutfitRecommendationError.missingAPIKey
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
            AppLog.error(.recommendation, "[\(requestID)] recommend: transport error — \(String(describing: error))")
            throw OutfitRecommendationError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 429, let quota = try? JSONDecoder().decode(QuotaExceededResponse.self, from: data) {
                AppLog.notice(.recommendation, "[\(requestID)] recommend: quota exceeded, limit=\(quota.limit)")
                throw OutfitRecommendationError.quotaExceeded(limit: quota.limit)
            }
            AppLog.error(.recommendation, "[\(requestID)] recommend: HTTP \(statusCode)")
            throw OutfitRecommendationError.httpStatus(statusCode)
        }

        let decoded: OpenRouterRecommendationChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterRecommendationChatResponse.self, from: data)
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] recommend: response envelope decode failed — \(String(describing: error))")
            throw OutfitRecommendationError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.recommendation, "[\(requestID)] recommend: empty choices")
            throw OutfitRecommendationError.emptyChoices
        }

        if let usage = decoded.usage {
            let cached = usage.promptTokensDetails?.cachedTokens ?? 0
            AppLog.info(.recommendation, "[\(requestID)] recommend: promptTokens=\(usage.promptTokens ?? -1) cachedTokens=\(cached)")
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let result = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: payload)
            AppLog.info(.recommendation, "[\(requestID)] recommend: ok outfits=\(result.outfits.count) intentClear=\(result.intentClear)")
            return result
        } catch {
            AppLog.error(.recommendation, "[\(requestID)] recommend: OutfitRecommendationResponse decode failed — \(String(describing: error))")
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
        //
        // Turn 0's content and the system prompt are the two large blocks
        // (catalog routinely 75-80KB) that stay byte-identical across every
        // turn of one clarification session, so both get wrapped in
        // `cacheableContent` — an OpenRouter-documented Anthropic-style
        // `cache_control` breakpoint, passed through verbatim by
        // `openrouterChat.ts`. Additive/inert for models that don't support
        // it (extra ignored field, same request otherwise); on models that
        // do, it turns a full-catalog retransmission into a cached-prefix
        // read for every turn after the first. Later turns are short
        // clarification replies, not worth marking.
        let turnMessages: [[String: Any]] = conversationHistory.enumerated().map { index, turn in
            if index == 0 {
                let content = StylistBrain.DynamicPromptComposer.composeUserContent(
                    scenarioText: turn.text,
                    weather: weather,
                    catalogDataText: catalogText
                )
                return ["role": turn.role.rawValue, "content": Self.cacheableContent(content)]
            }
            return ["role": turn.role.rawValue, "content": turn.text]
        }

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Structured-JSON path with a hard 15s client-side timeout
            // (DailyAssistantViewModel's requestTimeoutNanoseconds) — the
            // configured model may support extended "thinking" reasoning,
            // which this call doesn't need and can't afford latency-wise.
            "reasoning": ["enabled": false],
            "messages": [["role": "system", "content": Self.cacheableContent(systemPrompt)]] + turnMessages,
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
            body["messages"] = [["role": "system", "content": Self.cacheableContent(systemPrompt)]] + turnMessages
        }

        Self.logPromptForDebugging(body: body)

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Wraps `text` in OpenRouter's content-array-with-`cache_control`
    /// shape (see `encodeRequestBody`'s doc comment above) instead of a
    /// plain string — the format OpenRouter forwards as an Anthropic
    /// prompt-caching breakpoint on models that support it.
    private static func cacheableContent(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "cache_control": ["type": "ephemeral"]]]
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
                            ],
                            // Multi-Accessory Outfits (Stylist Intelligence
                            // Engine ADR, closed 2026-07-15): worn *alongside*
                            // accessory_id, not instead of it — a second,
                            // more casual accent piece (e.g. a watch or
                            // necklace next to a belt). Empty array (not
                            // null) is the "nothing extra" value, which a
                            // JSON array already expresses natively — no
                            // required-but-nullable hack needed here.
                            "supplementary_accessory_ids": [
                                "type": "array",
                                "items": ["type": "string"],
                                "maxItems": FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories,
                                "description": "0-\(FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories) additional accent items (e.g. a watch, necklace, or scarf) worn together with accessory_id, only for casual/going-out scenarios that call for layered accessorizing. Never duplicate accessory_id or each other. Always an empty array for business, interview, or formal scenarios, and whenever one accessory is already enough.",
                            ],
                        ],
                        uniquingKeysWith: { _, new in new }
                    ),
                    "required": itemIDSchemaProperties.required + ["rationale", "supplementary_accessory_ids"],
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
    /// Observability only (see `encodeRequestBody`'s `cacheableContent`
    /// doc comment) — `prompt_tokens_details.cached_tokens` is OpenRouter's
    /// normalized field for how many prompt tokens were served from cache,
    /// present only on models/providers that actually honored the
    /// `cache_control` breakpoint. Absent entirely on providers that don't
    /// support it, hence fully optional — never assume its presence.
    struct Usage: Decodable {
        struct PromptTokensDetails: Decodable {
            let cachedTokens: Int?
            enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
        }
        let promptTokens: Int?
        let promptTokensDetails: PromptTokensDetails?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

/// `backend/functions/src/middleware/quota.ts`'s 429 body shape:
/// `{ error: "quota_exceeded", limit, period }`.
private struct QuotaExceededResponse: Decodable {
    let limit: Int
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
        // Prospective Purchase Evaluation (2026-07-15): prefer the flagged
        // entry for its own slot over an arbitrary first match, so the
        // keyless Simulator path exercises `mustIncludeItemID` meaningfully
        // instead of always landing on the "no match" state.
        func firstID(for slot: Slot) -> String? {
            let slotEntries = catalog.filter { $0.slot == slot }
            return slotEntries.first { $0.isProspectivePurchase }?.id ?? slotEntries.first?.id
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

/// Routes each call to a real or mock `OutfitRecommendationService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedWardrobeSyncService` (see that type's doc
/// comment in `Services/WardrobeSyncService.swift`) and
/// `AuthGatedVisionMetadataExtractionService`.
@MainActor
final class AuthGatedOutfitRecommendationService: OutfitRecommendationService {
    private lazy var real = OpenRouterOutfitRecommendationService()
    private lazy var mock = MockOutfitRecommendationService()
    private var current: OutfitRecommendationService { AuthService.shared.isSignedIn ? real : mock }

    func recommendOutfits(
        conversationHistory: [ConversationTurn],
        isFinalTurn: Bool,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
        history: FeedbackHistory
    ) async throws -> OutfitRecommendationResponse {
        try await current.recommendOutfits(
            conversationHistory: conversationHistory,
            isFinalTurn: isFinalTurn,
            catalog: catalog,
            profile: profile,
            weather: weather,
            history: history
        )
    }
}
