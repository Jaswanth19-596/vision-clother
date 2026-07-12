//
//  VisionMetadataExtractionService.swift
//  Vision_clother
//
//  Vision-LLM Tag Generation (PRD.md §3.1, ingestion stage 2). Takes an
//  already background-isolated garment photo (see
//  Services/BackgroundIsolationService.swift, which runs first — this
//  service never performs background removal itself, since returning an
//  edited image isn't something a chat-completion vision model can do) and
//  returns only the structural metadata fields defined by PRD §3.1 (as of
//  the 2026-07-10 reversal, this now includes a short `description` and
//  `style_tags` used later as catalog text by the recommendation LLM).
//
//  This is a distinct LLM call from
//  Services/OpenRouterIntentExtractionService.swift and
//  Services/OutfitRecommendationService.swift: it sees exactly one garment
//  photo per call, never the wardrobe collection, and never free-text
//  scenario prompts — all three services share a provider and a resilience
//  pattern, not a code path.
//
//  Same structured-output-with-fallback shape as the intent-extraction
//  service (see that file's header for why the configured model needs it).
//

import Foundation

protocol VisionMetadataExtractionService {
    func extractMetadata(imageData: Data) async throws -> GarmentMetadata
}

enum VisionMetadataExtractionError: Error, LocalizedError {
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
            return "Couldn't reach the tagging service. Check your connection."
        case .httpStatus(let code):
            return "Tagging service returned an error (\(code))."
        case .emptyChoices:
            return "The tagging service didn't return anything."
        case .decoding:
            return "Couldn't read that item — try a clearer photo."
        }
    }
}

final class OpenRouterVisionMetadataExtractionService: VisionMetadataExtractionService {
    private let session: URLSession
    private let model: String
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(session: URLSession = .shared, model: String = ModelConfig.imageToText) {
        self.session = session
        self.model = model
    }

    func extractMetadata(imageData: Data) async throws -> GarmentMetadata {
        do {
            return try await performRequest(imageData: imageData, useStructuredOutput: true)
        } catch VisionMetadataExtractionError.emptyChoices, VisionMetadataExtractionError.decoding {
            do {
                return try await performRequest(imageData: imageData, useStructuredOutput: true)
            } catch {
                return try await performUnstructuredFallback(imageData: imageData)
            }
        } catch VisionMetadataExtractionError.httpStatus(400) {
            // Most likely `response_format: json_schema` itself was rejected
            // by the provider — retrying the same structured request would
            // just 400 again, so switch modes instead of retrying.
            return try await performUnstructuredFallback(imageData: imageData)
        }
    }

    private func performUnstructuredFallback(imageData: Data) async throws -> GarmentMetadata {
        do {
            return try await performRequest(imageData: imageData, useStructuredOutput: false)
        } catch VisionMetadataExtractionError.emptyChoices, VisionMetadataExtractionError.decoding {
            return try await performRequest(imageData: imageData, useStructuredOutput: false)
        }
    }

    private func performRequest(imageData: Data, useStructuredOutput: Bool) async throws -> GarmentMetadata {
        guard let apiKey = APIKeys.openRouter else {
            throw VisionMetadataExtractionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            imageData: imageData,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VisionMetadataExtractionError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VisionMetadataExtractionError.httpStatus(statusCode)
        }

        let decoded: OpenRouterVisionChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterVisionChatResponse.self, from: data)
        } catch {
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("❌ OpenRouter vision response decoding failed. Raw response: \(rawResponse)")
            }
            throw VisionMetadataExtractionError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw VisionMetadataExtractionError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            return try JSONDecoder().decode(GarmentMetadata.self, from: payload)
        } catch {
            print("❌ Decoding GarmentMetadata failed. Raw content: \(content)")
            throw VisionMetadataExtractionError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        imageData: Data,
        useStructuredOutput: Bool
    ) throws -> Data {
        let dataURI = "data:image/png;base64,\(imageData.base64EncodedString())"

        var systemPrompt = """
        You tag a single garment photo with structural metadata for a wardrobe app. \
        The photo shows exactly one clothing item with its background already removed. \
        You do not know what else the user owns and must never reference other garments \
        — only output the metadata fields defined by the schema, based solely on this photo. \
        For "description", write one concise sentence (140 characters or fewer) describing \
        the garment — this text is later shown to a separate recommendation model that never \
        sees the photo, so make it specific (cut, material, notable detail) rather than generic. \
        For "style_tags", give 2-5 short free-form style descriptors (e.g. "minimalist", \
        "streetwear", "tailored"). For "color_profile.undertone", classify the primary color's \
        undertone as "warm", "cool", or "neutral". \
        For "slot", classify which of these four categories the garment belongs to — use the \
        garment's own cut and construction, not the color or pattern, to decide: \
        "top" = worn on the upper body as a primary layer (t-shirts, shirts, blouses, sweaters, \
        polos, tank tops); \
        "bottom" = worn on the lower body (trousers, pants, jeans, shorts, skirts, chinos, \
        leggings); \
        "footwear" = worn on the feet (sneakers, boots, sandals, heels, loafers, dress shoes); \
        "outerwear" = worn OVER a top as an extra layer, typically with its own front closure \
        (jackets, coats, blazers, cardigans, parkas). \
        Choose exactly one slot; only choose "outerwear" when the item is clearly meant to be \
        layered over other clothing rather than worn as the primary upper-body garment. \
        Identify the following additional attributes: \
        "garment_subtype": the specific item subtype (e.g. "Oxford Shirt", "Linen Camp Collar Shirt", "Chinos", "Jeans", "Sneakers", "Loafers", "Blazer", "Cardigan"); \
        "fit": the apparent fit/cut (e.g. "Slim", "Oversized", "Regular", "Relaxed", "Tailored"); \
        "silhouette": the silhouette shape (e.g. "Straight", "Boxy", "A-line", "Fitted", "Flared"); \
        "material": the apparent primary material (e.g. "Cotton", "Linen", "Denim", "Wool", "Leather", "Silk", "Knit"); \
        "texture": the tactile surface texture (e.g. "Ribbed", "Smooth", "Coarse", "Knit", "Suede", "Waffle").
        """

        let userContent: [[String: Any]] = [
            ["type": "text", "text": "Tag this garment."],
            ["type": "image_url", "image_url": ["url": dataURI]],
        ]

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
                    "name": "GarmentMetadata",
                    "strict": true,
                    "schema": garmentMetadataJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: garmentMetadataJSONSchema,
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

    /// Matches PRD.md §3.1's ingestion metadata table (extended 2026-07-10
    /// with `description`/`style_tags`/`undertone` — the recommendation LLM's
    /// catalog entry text, see `Domain/WardrobeCatalogBuilder.swift`).
    private static let garmentMetadataJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "slot": ["type": "string", "enum": Slot.allCases.map(\.rawValue)],
            "formality_score": ["type": "number", "minimum": 1.0, "maximum": 5.0],
            "color_profile": [
                "type": "object",
                "properties": [
                    "primary_hex": ["type": "string"],
                    "secondary_hex": ["type": ["string", "null"]],
                    "category": ["type": "string", "enum": ColorVibe.allCases.map(\.rawValue)],
                    "undertone": ["type": "string", "enum": Undertone.allCases.map(\.rawValue)],
                ],
                "required": ["primary_hex", "secondary_hex", "category", "undertone"],
                "additionalProperties": false,
            ],
            "pattern": ["type": "string", "enum": GarmentPattern.allCases.map(\.rawValue)],
            "seasonality": [
                "type": "array",
                "items": ["type": "string", "enum": Season.allCases.map(\.rawValue)],
            ],
            "fabric_weight": ["type": "string", "enum": FabricWeight.allCases.map(\.rawValue)],
            "description": ["type": "string"],
            "style_tags": ["type": "array", "items": ["type": "string"]],
            "garment_subtype": ["type": ["string", "null"]],
            "fit": ["type": ["string", "null"]],
            "silhouette": ["type": ["string", "null"]],
            "material": ["type": ["string", "null"]],
            "texture": ["type": ["string", "null"]],
        ],
        "required": [
            "slot", "formality_score", "color_profile", "pattern", "seasonality", "fabric_weight",
            "description", "style_tags", "garment_subtype", "fit", "silhouette", "material", "texture",
        ],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterVisionChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockVisionMetadataExtractionService: VisionMetadataExtractionService {
    var result = GarmentMetadata(
        slot: .top,
        formalityScore: 2.0,
        colorProfile: GarmentMetadata.ColorProfileWire(primaryHex: "#3A3A3A", secondaryHex: nil, category: .neutral, undertone: .neutral),
        pattern: .solid,
        seasonality: [.springFall, .summer],
        fabricWeight: .light,
        description: "Charcoal crewneck tee in a soft cotton blend.",
        styleTags: ["minimalist", "everyday"],
        garmentSubtype: "Tee",
        fit: "Regular",
        silhouette: "Straight",
        material: "Cotton",
        texture: "Smooth"
    )

    func extractMetadata(imageData: Data) async throws -> GarmentMetadata {
        result
    }
}
