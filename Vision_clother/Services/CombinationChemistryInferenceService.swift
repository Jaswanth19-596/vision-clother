//
//  CombinationChemistryInferenceService.swift
//  Vision_clother
//
//  Swipe + Comment combination feedback (2026-07-27): replaces the manual
//  Level 1/2/3 "Rate this outfit" form (`Features/Rating/RateCombinationView.swift`)
//  with a swipe (love/like/dislike/hate) plus an optional free-text comment.
//  This service turns that sentiment/comment into the same rich
//  `CombinationMetadata` structure the vision LLM infers for stock swipe
//  photos (`Services/VisionMetadataExtractionService.swift`'s
//  `extractSceneMetadata`) — but TEXT-ONLY: the combination's own items are
//  already fully attributed (real hex/pattern/fit/etc. from ingestion), so
//  there's no need to see an image, and doing so would put this call outside
//  the app's core invariant that image-in LLM calls are bounded to ingestion
//  and stock-photo scene tagging.
//
//  Deliberately not a method on `VisionMetadataExtractionService` — that
//  protocol is image-in by definition (`Config/ModelConfig.swift`'s
//  `imageToText`). This is a `textToText` call, alongside
//  `OutfitRecommendationService`/`StylistQAService`/`IntentExtractionService`,
//  and routes through the uncapped `ProxyConfig.openRouterChatURL` (not the
//  metered `openRouterRecommendURL`) — this is a structured tagging/extraction
//  utility, not a recommendation or Q&A answer (`Services/CLAUDE.md`).
//
//  Same structured-output-with-fallback shape as
//  `Services/OpenRouterIntentExtractionService.swift`.
//

import Foundation

/// One garment-specific note the model pulled out of the user's free-text
/// comment. Pure value type — the caller (`RateCombinationViewModel`) turns it
/// into an `ItemNote` row.
///
/// Only *facts about the garment* are extracted, never taste opinions, even
/// though the comment may contain both. A taste claim would have to move the
/// global affinity maps on the strength of an LLM's reading of one sentence,
/// with no confirmation step; the per-slot chips already capture taste
/// deterministically and with the user's own finger on the button. Notes, by
/// contrast, are per-item, visible in Closet, and one tap from being deleted.
struct InferredItemNote: Equatable {
    let itemID: UUID
    let text: String
    let severity: ItemNoteSeverity
    let context: ItemNoteContext
}

/// What one chemistry-inference call returns: the whole-look structure plus
/// any per-garment notes. `itemNotes` is empty for the overwhelming majority
/// of calls (no comment, a purely positive comment, or a comment about the
/// look as a whole).
struct CombinationChemistryResult: Equatable {
    let metadata: CombinationMetadata
    let itemNotes: [InferredItemNote]
}

protocol CombinationChemistryInferenceService {
    /// `items` is the same text-only `CatalogEntry` projection the
    /// recommendation LLM already reads (`Domain/WardrobeCatalogBuilder.swift`)
    /// — no new wire type, no images. `sentiment` is required (the user must
    /// swipe); `comment` is optional free text explaining why.
    func inferChemistry(items: [CatalogEntry], sentiment: SwipeSentiment, comment: String?) async throws -> CombinationChemistryResult
}

enum CombinationChemistryInferenceError: Error, LocalizedError {
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
            return "The styling service didn't return anything."
        case .decoding:
            return "Couldn't read that combination — try again."
        }
    }
}

/// Real network implementation. Same structured-first, one-silent-retry,
/// unstructured-fallback shape as `OpenRouterIntentExtractionService`.
final class OpenRouterCombinationChemistryInferenceService: CombinationChemistryInferenceService {
    private let session: URLSession
    private let model: String
    private let endpoint = ProxyConfig.openRouterChatURL

    init(session: URLSession = .shared, model: String = ModelConfig.textToText) {
        self.session = session
        self.model = model
    }

    func inferChemistry(items: [CatalogEntry], sentiment: SwipeSentiment, comment: String?) async throws -> CombinationChemistryResult {
        do {
            return try await performRequest(items: items, sentiment: sentiment, comment: comment, useStructuredOutput: true)
        } catch CombinationChemistryInferenceError.emptyChoices, CombinationChemistryInferenceError.decoding {
            do {
                return try await performRequest(items: items, sentiment: sentiment, comment: comment, useStructuredOutput: true)
            } catch {
                return try await performRequest(items: items, sentiment: sentiment, comment: comment, useStructuredOutput: false)
            }
        } catch CombinationChemistryInferenceError.httpStatus(400) {
            return try await performRequest(items: items, sentiment: sentiment, comment: comment, useStructuredOutput: false)
        }
    }

    private func performRequest(
        items: [CatalogEntry],
        sentiment: SwipeSentiment,
        comment: String?,
        useStructuredOutput: Bool
    ) async throws -> CombinationChemistryResult {
        let requestID = AppLog.newRequestID()
        AppLog.info(.network, "[\(requestID)] combinationChemistry: POST \(endpoint.path) structured=\(useStructuredOutput) items=\(items.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current(requestID: requestID)
        } catch {
            AppLog.error(.network, "[\(requestID)] combinationChemistry: missing auth header — \(String(describing: error))")
            throw CombinationChemistryInferenceError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            items: items,
            sentiment: sentiment,
            comment: comment,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.network, "[\(requestID)] combinationChemistry: transport error — \(String(describing: error))")
            throw CombinationChemistryInferenceError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.network, "[\(requestID)] combinationChemistry: HTTP \(statusCode)")
            throw CombinationChemistryInferenceError.httpStatus(statusCode)
        }

        let decoded: OpenRouterChatResponseEnvelope
        do {
            decoded = try JSONDecoder().decode(OpenRouterChatResponseEnvelope.self, from: data)
        } catch {
            AppLog.error(.network, "[\(requestID)] combinationChemistry: response envelope decode failed — \(String(describing: error))")
            throw CombinationChemistryInferenceError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.network, "[\(requestID)] combinationChemistry: empty choices")
            throw CombinationChemistryInferenceError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let wire = try JSONDecoder().decode(ChemistryWithItemNotesWire.self, from: payload)
            let validIDs = Set(items.map(\.id))
            // An id the model invented, or one that isn't in the combination
            // it was shown, is dropped rather than trusted — the whole point
            // of a note is that it belongs to a specific real garment.
            let notes: [InferredItemNote] = wire.itemNotes.compactMap { note in
                guard validIDs.contains(note.itemID), let uuid = UUID(uuidString: note.itemID) else {
                    AppLog.error(.network, "[\(requestID)] combinationChemistry: dropped item note for unknown id=\(note.itemID)")
                    return nil
                }
                let text = ItemNote.normalizedText(note.text)
                guard !text.isEmpty else { return nil }
                return InferredItemNote(
                    itemID: uuid,
                    text: text,
                    severity: ItemNoteSeverity(rawValue: note.severity) ?? .conditional,
                    context: ItemNoteContext(rawValue: note.context) ?? .none
                )
            }
            AppLog.info(.network, "[\(requestID)] combinationChemistry: ok itemNotes=\(notes.count)")
            return CombinationChemistryResult(metadata: wire.chemistry, itemNotes: notes)
        } catch {
            AppLog.error(.network, "[\(requestID)] combinationChemistry: decode failed — \(String(describing: error))")
            throw CombinationChemistryInferenceError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        items: [CatalogEntry],
        sentiment: SwipeSentiment,
        comment: String?,
        useStructuredOutput: Bool
    ) throws -> Data {
        let itemsData = try JSONEncoder().encode(items)
        let itemsText = String(decoding: itemsData, as: UTF8.self)

        var userContent = """
        The user swiped "\(sentiment.rawValue)" on this specific combination of garments they already own (no photo — reason only from the listed attributes). \
        Garments in this combination:
        \(itemsText)
        """
        if let comment, !comment.isEmpty {
            userContent += "\n\nThe user's own comment on why: \"\(comment)\""
        }

        var systemPrompt = ModelConfig.Prompts.combinationChemistryInferenceSystemPrompt

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
                    "name": "CombinationChemistryWithItemNotes",
                    "strict": true,
                    "schema": CombinationMetadataSchema.chemistryWithItemNotesSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: CombinationMetadataSchema.chemistryWithItemNotesSchema,
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

// MARK: - Wire shape

/// Mirrors `CombinationMetadataSchema.chemistryWithItemNotesSchema`. Explicit
/// `CodingKeys` per `Models/CLAUDE.md` — no global snake-case strategy.
private struct ChemistryWithItemNotesWire: Decodable {
    struct ItemNoteWire: Decodable {
        let itemID: String
        let text: String
        let severity: String
        let context: String

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case text
            case severity
            case context
        }
    }

    let chemistry: CombinationMetadata
    let itemNotes: [ItemNoteWire]

    enum CodingKeys: String, CodingKey {
        case chemistry
        case itemNotes = "item_notes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chemistry = try container.decode(CombinationMetadata.self, forKey: .chemistry)
        // Tolerated as absent, not just empty: a model that drops the key
        // entirely on the unstructured fallback path should still yield usable
        // chemistry rather than failing the whole decode over the optional half.
        itemNotes = try container.decodeIfPresent([ItemNoteWire].self, forKey: .itemNotes) ?? []
    }
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterChatResponseEnvelope: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockCombinationChemistryInferenceService: CombinationChemistryInferenceService {
    var metadata = CombinationMetadata(
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
    var itemNotes: [InferredItemNote] = []

    func inferChemistry(items: [CatalogEntry], sentiment: SwipeSentiment, comment: String?) async throws -> CombinationChemistryResult {
        CombinationChemistryResult(metadata: metadata, itemNotes: itemNotes)
    }
}

/// Routes each call to a real or mock service based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction time
/// — same fix as `AuthGatedIntentExtractionService`/`AuthGatedVisionMetadataExtractionService`.
@MainActor
final class AuthGatedCombinationChemistryInferenceService: CombinationChemistryInferenceService {
    private lazy var real = OpenRouterCombinationChemistryInferenceService()
    private lazy var mock = MockCombinationChemistryInferenceService()
    private var current: CombinationChemistryInferenceService { AuthService.shared.isSignedIn ? real : mock }

    func inferChemistry(items: [CatalogEntry], sentiment: SwipeSentiment, comment: String?) async throws -> CombinationChemistryResult {
        try await current.inferChemistry(items: items, sentiment: sentiment, comment: comment)
    }
}
