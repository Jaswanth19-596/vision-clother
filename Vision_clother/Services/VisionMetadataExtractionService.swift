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

/// Which framing prompt the vision LLM uses for the single-garment call
/// shape. The wire schema (`GarmentMetadata`) is identical regardless.
enum GarmentExtractionFocus {
    /// Ingestion: a single garment whose background was already removed
    /// (`Services/BackgroundIsolationService.swift`). The only case this enum
    /// still has — Swipe-to-Learn taste (a busy, un-isolated scene that may
    /// show a full outfit) now uses the distinct `extractSceneMetadata(imageData:)`
    /// call shape below instead of a second focus case, since its response
    /// shape genuinely differs (an array of garments + an optional
    /// whole-look combination, not one flat `GarmentMetadata`).
    case isolatedGarment
}

protocol VisionMetadataExtractionService {
    func extractMetadata(imageData: Data, focus: GarmentExtractionFocus) async throws -> GarmentMetadata
    /// Swipe-to-Learn taste (Multi-Garment "Discover Your Style"): tags every
    /// distinct visible worn garment in a busy, un-isolated stock/lifestyle
    /// photo (just the one garment if that's all that's shown; the full set —
    /// top/bottom/footwear/outerwear/accessories — if a complete outfit is
    /// shown), plus, only when 2+ garments are detected, a whole-look
    /// color-harmony/style-coherence/formality-consistency assessment. See
    /// `Models/SceneMetadata.swift`.
    func extractSceneMetadata(imageData: Data) async throws -> SceneMetadata
}

extension VisionMetadataExtractionService {
    /// Back-compat convenience — ingestion callers (`JobQueueStore`) tag an
    /// already-isolated garment and never pass a focus.
    func extractMetadata(imageData: Data) async throws -> GarmentMetadata {
        try await extractMetadata(imageData: imageData, focus: .isolatedGarment)
    }
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

/// Thrown from `performSceneRequest` when a structured response decodes
/// `garments.count >= 2` but `combination` came back `nil` anyway — a
/// contract violation the schema's `"required"` clause was supposed to rule
/// out. See the throw site's doc comment for why this is treated as a
/// decode failure rather than accepted at face value.
private struct MissingRequiredCombinationError: Error, CustomStringConvertible {
    let garmentCount: Int
    var description: String {
        "combination missing for a \(garmentCount)-garment scene despite required schema"
    }
}

final class OpenRouterVisionMetadataExtractionService: VisionMetadataExtractionService {
    private let session: URLSession
    private let model: String
    private let endpoint = ProxyConfig.openRouterChatURL

    init(session: URLSession = .shared, model: String = ModelConfig.imageToText) {
        self.session = session
        self.model = model
    }

    func extractMetadata(imageData: Data, focus: GarmentExtractionFocus) async throws -> GarmentMetadata {
        do {
            return try await performRequest(imageData: imageData, focus: focus, useStructuredOutput: true)
        } catch VisionMetadataExtractionError.emptyChoices, VisionMetadataExtractionError.decoding {
            // A second attempt at the identical structured request mostly
            // just reproduces the same deterministic failure — switch modes
            // once instead of paying for a redundant retry (kept this call
            // synchronous/user-facing latency in mind, see StyleCheckView).
            return try await performRequest(imageData: imageData, focus: focus, useStructuredOutput: false)
        } catch VisionMetadataExtractionError.httpStatus(400) {
            // Most likely `response_format: json_schema` itself was rejected
            // by the provider — retrying the same structured request would
            // just 400 again, so switch modes instead of retrying.
            return try await performRequest(imageData: imageData, focus: focus, useStructuredOutput: false)
        }
    }

    /// Same structured→unstructured-fallback shape as `extractMetadata`
    /// above (including the same 400-status special case) — kept as its own
    /// method rather than a third `GarmentExtractionFocus` case since the
    /// response shape genuinely differs (`SceneMetadata`, not `GarmentMetadata`).
    func extractSceneMetadata(imageData: Data) async throws -> SceneMetadata {
        do {
            return try await performSceneRequest(imageData: imageData, useStructuredOutput: true)
        } catch VisionMetadataExtractionError.emptyChoices, VisionMetadataExtractionError.decoding {
            return try await performSceneRequest(imageData: imageData, useStructuredOutput: false)
        } catch VisionMetadataExtractionError.httpStatus(400) {
            return try await performSceneRequest(imageData: imageData, useStructuredOutput: false)
        }
    }

    private func performRequest(imageData: Data, focus: GarmentExtractionFocus, useStructuredOutput: Bool) async throws -> GarmentMetadata {
        let requestID = AppLog.newRequestID()
        AppLog.info(.vision, "[\(requestID)] visionTagging: POST \(endpoint.path) structured=\(useStructuredOutput) imageBytes=\(imageData.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current(requestID: requestID)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging: missing auth header — \(String(describing: error))")
            throw VisionMetadataExtractionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // A few seconds under the backend `proxyApi` function's own 60s
        // timeout (`backend/functions/src/index.ts`, deliberately raised
        // from 15s there after real vision/LLM completions routinely
        // exceeded it) — 20s was tried first and turned out to be shorter
        // than genuinely-in-progress (not stalled) calls sometimes take,
        // producing spurious client-side timeouts. This is a safety net for
        // a truly dead connection, not meant to preempt the backend's own
        // already-tuned cutoff.
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            imageData: imageData,
            focus: focus,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging: transport error — \(String(describing: error))")
            throw VisionMetadataExtractionError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.vision, "[\(requestID)] visionTagging: HTTP \(statusCode)")
            throw VisionMetadataExtractionError.httpStatus(statusCode)
        }

        let decoded: OpenRouterVisionChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterVisionChatResponse.self, from: data)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging: response envelope decode failed — \(String(describing: error))")
            throw VisionMetadataExtractionError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.vision, "[\(requestID)] visionTagging: empty choices")
            throw VisionMetadataExtractionError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let metadata = try JSONDecoder().decode(GarmentMetadata.self, from: payload)
            AppLog.info(.vision, "[\(requestID)] visionTagging: ok slot=\(metadata.slot.rawValue)")
            return metadata
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging: GarmentMetadata decode failed — \(String(describing: error))")
            throw VisionMetadataExtractionError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        imageData: Data,
        focus: GarmentExtractionFocus,
        useStructuredOutput: Bool
    ) throws -> Data {
        let dataURI = "data:image/png;base64,\(imageData.base64EncodedString())"

        var systemPrompt: String
        let userText: String
        switch focus {
        case .isolatedGarment:
            systemPrompt = ModelConfig.Prompts.visionMetadataSystemPrompt
            userText = ModelConfig.Prompts.visionMetadataUserText
        }

        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
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
    /// catalog entry text, see `Domain/WardrobeCatalogBuilder.swift`). Shared
    /// between the single-garment `garmentMetadataJSONSchema` below and the
    /// per-garment array items of `sceneMetadataJSONSchema`, so the ~30-line
    /// field list is defined exactly once.
    private static let garmentObjectSchema: [String: Any] = [
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
            "pattern_scale": ["type": ["string", "null"], "enum": (PatternScale.allCases.map(\.rawValue) as [Any]) + [NSNull()]],
            "texture_finish": ["type": ["string", "null"], "enum": (TextureFinish.allCases.map(\.rawValue) as [Any]) + [NSNull()]],
            "silhouette_cut": ["type": ["string", "null"], "enum": (SilhouetteCut.allCases.map(\.rawValue) as [Any]) + [NSNull()]],
            "neckline_or_rise": ["type": ["string", "null"]],
            "fabric_weight_detail": ["type": ["string", "null"], "enum": (FabricWeightDetail.allCases.map(\.rawValue) as [Any]) + [NSNull()]],
        ],
        "required": [
            "slot", "formality_score", "color_profile", "pattern", "seasonality", "fabric_weight",
            "description", "style_tags", "garment_subtype", "fit", "silhouette", "material", "texture",
            "pattern_scale", "texture_finish", "silhouette_cut", "neckline_or_rise", "fabric_weight_detail",
        ],
        "additionalProperties": false,
    ]

    private static let garmentMetadataJSONSchema: [String: Any] = garmentObjectSchema

    /// Wire schema for `extractSceneMetadata` (`Models/SceneMetadata.swift`):
    /// an array of `garmentObjectSchema` items plus a whole-look `combination`
    /// object. `combination` is deliberately a plain required object here, NOT
    /// a nullable one (`["type", "null"]`) — that pattern is only proven for
    /// scalar fields elsewhere in `garmentObjectSchema` (`fit`/`material`/etc.);
    /// a nullable *object* asks the model/provider to make a structural
    /// applicability decision inside strict JSON-schema mode, which isn't
    /// reliably honored across every vision model reachable via OpenRouter and
    /// was found to make the model default to omitting the object outright
    /// regardless of how many garments were actually visible. The model now
    /// always fills this in with its best-effort whole-look read (see
    /// `sceneMetadataSystemPrompt`); `performSceneRequest` below applies the
    /// real "does this even apply" gate client-side from `garments.count`,
    /// which is a value the app can check deterministically rather than
    /// trusting the model to null a whole object correctly.
    private static let sceneMetadataJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "garments": [
                "type": "array",
                "items": garmentObjectSchema,
            ],
            "combination": CombinationMetadataSchema.objectSchema,
        ],
        "required": ["garments", "combination"],
        "additionalProperties": false,
    ]

    private func performSceneRequest(imageData: Data, useStructuredOutput: Bool) async throws -> SceneMetadata {
        let requestID = AppLog.newRequestID()
        AppLog.info(.vision, "[\(requestID)] visionTagging(scene): POST \(endpoint.path) structured=\(useStructuredOutput) imageBytes=\(imageData.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current(requestID: requestID)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): missing auth header — \(String(describing: error))")
            throw VisionMetadataExtractionError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // A few seconds under the backend `proxyApi` function's own 60s
        // timeout (`backend/functions/src/index.ts`, deliberately raised
        // from 15s there after real vision/LLM completions routinely
        // exceeded it) — 20s was tried first and turned out to be shorter
        // than genuinely-in-progress (not stalled) calls sometimes take,
        // producing spurious client-side timeouts. This is a safety net for
        // a truly dead connection, not meant to preempt the backend's own
        // already-tuned cutoff.
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.encodeSceneRequestBody(
            model: model,
            imageData: imageData,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): transport error — \(String(describing: error))")
            throw VisionMetadataExtractionError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): HTTP \(statusCode)")
            throw VisionMetadataExtractionError.httpStatus(statusCode)
        }

        let decoded: OpenRouterVisionChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterVisionChatResponse.self, from: data)
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): response envelope decode failed — \(String(describing: error))")
            throw VisionMetadataExtractionError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): empty choices")
            throw VisionMetadataExtractionError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            var metadata = try JSONDecoder().decode(SceneMetadata.self, from: payload)
            // `SceneMetadata`'s custom decoder swallows a malformed/missing
            // `combination` to `nil` rather than throwing (it has to stay
            // tolerant so one bad sub-field never discards otherwise-good
            // garment data). That means a `strict` structured response that
            // doesn't actually honor the schema's `"required": [..., "combination"]`
            // — a real risk, since strict-mode compliance varies by
            // provider/model through OpenRouter — decodes "successfully"
            // with `combination == nil`, indistinguishable from the model
            // genuinely detecting <2 garments. On the structured attempt
            // only, treat that as the decode failure it actually is so the
            // existing unstructured-fallback retry below gets a real second
            // try; never on the unstructured attempt itself, so a persistent
            // failure there still returns with garments tagged rather than
            // losing the whole swipe's signal.
            if useStructuredOutput, metadata.garments.count >= 2, metadata.combination == nil {
                throw MissingRequiredCombinationError(garmentCount: metadata.garments.count)
            }
            // The model always returns a `combination` object now (see
            // `sceneMetadataJSONSchema`'s doc comment) — applicability is
            // decided here, deterministically, rather than trusting the model
            // to null the whole object out for a single-garment photo.
            if metadata.garments.count < 2 {
                metadata.combination = nil
            }
            AppLog.info(.vision, "[\(requestID)] visionTagging(scene): ok garments=\(metadata.garments.count) hasCombo=\(metadata.combination != nil)")
            return metadata
        } catch {
            AppLog.error(.vision, "[\(requestID)] visionTagging(scene): SceneMetadata decode failed — \(String(describing: error))")
            throw VisionMetadataExtractionError.decoding(error)
        }
    }

    private static func encodeSceneRequestBody(
        model: String,
        imageData: Data,
        useStructuredOutput: Bool
    ) throws -> Data {
        let dataURI = "data:image/png;base64,\(imageData.base64EncodedString())"
        var systemPrompt = ModelConfig.Prompts.sceneMetadataSystemPrompt
        let userText = ModelConfig.Prompts.sceneMetadataUserText

        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
            ["type": "image_url", "image_url": ["url": dataURI]],
        ]

        var body: [String: Any] = [
            "model": model,
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
                    "name": "SceneMetadata",
                    "strict": true,
                    "schema": sceneMetadataJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: sceneMetadataJSONSchema,
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
        texture: "Smooth",
        patternScale: .solid,
        textureFinish: .matte,
        silhouetteCut: .regular,
        necklineOrRise: "Crew",
        fabricWeightDetail: .lightFlowy
    )

    /// Canned 2-garment + combination response — exercises the full-outfit
    /// path (multiple `SwipeAttributeEvent` rows + one `SwipeCombinationEvent`)
    /// in previews/tests without a network call.
    var sceneResult = SceneMetadata(
        garments: [
            GarmentMetadata(
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
                texture: "Smooth",
                patternScale: .solid,
                textureFinish: .matte,
                silhouetteCut: .regular,
                necklineOrRise: "Crew",
                fabricWeightDetail: .lightFlowy
            ),
            GarmentMetadata(
                slot: .bottom,
                formalityScore: 2.5,
                colorProfile: GarmentMetadata.ColorProfileWire(primaryHex: "#2B2B33", secondaryHex: nil, category: .neutral, undertone: .cool),
                pattern: .solid,
                seasonality: [.springFall, .winter],
                fabricWeight: .medium,
                description: "Slim charcoal chinos.",
                styleTags: ["minimalist", "tailored"],
                garmentSubtype: "Chinos",
                fit: "Slim",
                silhouette: "Straight",
                material: "Cotton",
                texture: "Smooth",
                patternScale: .solid,
                textureFinish: .matte,
                silhouetteCut: .fitted,
                necklineOrRise: "Mid-rise",
                fabricWeightDetail: .mediumStandard
            ),
        ],
        combination: CombinationMetadata(
            colorHarmony: .monochrome,
            styleCoherenceTags: ["minimalist", "tailored"],
            formalityConsistency: .consistent,
            rationale: "Tonal charcoal palette keeps the look cohesive and easy to elevate.",
            paletteArchetype: .monochromatic,
            contrastLevel: .lowTonal,
            colorSandwiching: false,
            colorDistribution: "60_30_10",
            proportionRatio: .halfAndHalf,
            volumeBalance: .allFitted,
            textureContrast: .uniformTexture,
            formalityBridge: .consistent,
            overallAestheticVibe: "Minimalist tonal ease",
            complexityScore: 3
        )
    )

    func extractMetadata(imageData: Data, focus: GarmentExtractionFocus) async throws -> GarmentMetadata {
        result
    }

    func extractSceneMetadata(imageData: Data) async throws -> SceneMetadata {
        sceneResult
    }
}

/// Routes each call to a real or mock `VisionMetadataExtractionService` based
/// on `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedWardrobeSyncService` (see that type's doc
/// comment in `Services/WardrobeSyncService.swift`). `ServiceFactory` used to
/// snapshot `isSignedIn` once and bake the choice into a `let`
/// `JobQueueStore` held for its entire lifetime: a cold launch before
/// `AuthService.ensureGuestSession()` finished (or before a real sign-in
/// took effect) permanently froze uploads on
/// `MockVisionMetadataExtractionService`'s fixed placeholder description,
/// silently mistagging every garment for the rest of the process's life
/// even after sign-in completed.
@MainActor
final class AuthGatedVisionMetadataExtractionService: VisionMetadataExtractionService {
    private lazy var real = OpenRouterVisionMetadataExtractionService()
    private lazy var mock = MockVisionMetadataExtractionService()
    private var current: VisionMetadataExtractionService { AuthService.shared.isSignedIn ? real : mock }

    func extractMetadata(imageData: Data, focus: GarmentExtractionFocus) async throws -> GarmentMetadata {
        try await current.extractMetadata(imageData: imageData, focus: focus)
    }

    func extractSceneMetadata(imageData: Data) async throws -> SceneMetadata {
        try await current.extractSceneMetadata(imageData: imageData)
    }
}
