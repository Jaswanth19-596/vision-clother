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
//  Services/VisionMetadataExtractionService.swift's header for why
//  `minimax/minimax-m3` needs it). `temperature: 0` minimizes
//  run-to-run non-determinism on top of the validator's hard guarantees.
//

import Foundation

protocol OutfitRecommendationService {
    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?
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

    init(session: URLSession = .shared, model: String = "minimax/minimax-m3") {
        self.session = session
        self.model = model
    }

    func recommendOutfits(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?
    ) async throws -> OutfitRecommendationResponse {
        do {
            return try await performRequest(
                prompt: prompt, catalog: catalog, profile: profile, weather: weather, useStructuredOutput: true
            )
        } catch OutfitRecommendationError.emptyChoices, OutfitRecommendationError.decoding {
            do {
                return try await performRequest(
                    prompt: prompt, catalog: catalog, profile: profile, weather: weather, useStructuredOutput: true
                )
            } catch {
                return try await performUnstructuredFallback(
                    prompt: prompt, catalog: catalog, profile: profile, weather: weather
                )
            }
        } catch OutfitRecommendationError.httpStatus(400) {
            // Most likely `response_format: json_schema` itself was rejected
            // by the provider — retrying the same structured request would
            // just 400 again, so switch modes instead of retrying.
            return try await performUnstructuredFallback(
                prompt: prompt, catalog: catalog, profile: profile, weather: weather
            )
        }
    }

    private func performUnstructuredFallback(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?
    ) async throws -> OutfitRecommendationResponse {
        do {
            return try await performRequest(
                prompt: prompt, catalog: catalog, profile: profile, weather: weather, useStructuredOutput: false
            )
        } catch OutfitRecommendationError.emptyChoices, OutfitRecommendationError.decoding {
            return try await performRequest(
                prompt: prompt, catalog: catalog, profile: profile, weather: weather, useStructuredOutput: false
            )
        }
    }

    private func performRequest(
        prompt: String,
        catalog: [CatalogEntry],
        profile: UserStyleProfile?,
        weather: WeatherContext?,
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
        useStructuredOutput: Bool
    ) throws -> Data {
        var userContent = "Scenario: \(prompt)"

        if let weather {
            userContent += "\n\nCurrent weather: \(weather.temperatureFahrenheit)°F, \(weather.conditions)."
        }

        if let profile {
            userContent += """
            \n\nUser style profile: undertone=\(profile.undertone.rawValue), \
            body type=\(profile.bodyType), style keywords=\(profile.styleKeywords.joined(separator: ", ")), \
            recommended colors=\(profile.recommendedColors.joined(separator: ", ")), \
            colors to avoid=\(profile.avoidColors.joined(separator: ", ")).
            """
        }

        let catalogData = try JSONEncoder().encode(catalog)
        let catalogText = String(decoding: catalogData, as: UTF8.self)
        userContent += "\n\nWardrobe catalog (JSON array, choose only from these ids):\n\(catalogText)"

        var systemPrompt = """
        You are a personal stylist choosing outfits for a user from clothes they already own. \
        You will be given a JSON catalog of the user's wardrobe items, each with an "id" — you may \
        only reference items by the exact "id" strings present in that catalog, one id per slot, \
        never inventing an id or reusing one across slots in the same outfit. Every outfit needs a \
        top_id, bottom_id, and footwear_id; outerwear_id is optional (null if not needed).

        Apply color theory when choosing: favor complementary, analogous, or monochrome hue \
        relationships between the top/bottom/outerwear; avoid muddy, high-saturation hue clashes; \
        prefer at most 2-3 color families per outfit, anchored by at least one neutral \
        (colorCategory "neutral" or "monochrome") when available. Respect the formality range implied \
        by the scenario and any provided weather (require outerwear in cold/wet weather when a \
        suitable one exists in the catalog). If a user style profile is given, prefer its \
        recommended colors and avoid its colors to avoid, without ignoring the scenario. \
        Give a short one-sentence "rationale" per outfit explaining the pairing. Return at most 5 \
        outfits, best first.
        """

        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
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

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Matches PRD.md §3.7's response schema.
    private static let outfitRecommendationJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "outfits": [
                "type": "array",
                "maxItems": 5,
                "items": [
                    "type": "object",
                    "properties": [
                        "top_id": ["type": "string"],
                        "bottom_id": ["type": "string"],
                        "footwear_id": ["type": "string"],
                        "outerwear_id": ["type": ["string", "null"]],
                        "rationale": ["type": "string"],
                    ],
                    "required": ["top_id", "bottom_id", "footwear_id", "outerwear_id", "rationale"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["outfits"],
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
        weather: WeatherContext?
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

        return OutfitRecommendationResponse(outfits: [
            RecommendedOutfitWire(
                topID: topID,
                bottomID: bottomID,
                footwearID: footwearID,
                outerwearID: outerwearID,
                rationale: "A balanced, neutral-anchored look for the occasion."
            ),
        ])
    }
}
