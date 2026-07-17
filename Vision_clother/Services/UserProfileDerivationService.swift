//
//  UserProfileDerivationService.swift
//  Vision_clother
//
//  User Style Profile derivation (PRD.md §3.8) — the 2026-07-10
//  LLM-as-Recommender reversal (docs/decisions/resolved-v1.md). Takes the
//  user's existing onboarding portrait (Services/UserPortraitStorage.swift)
//  and returns a personal-color/style profile that the recommendation call
//  (Services/OutfitRecommendationService.swift) uses to personalize picks.
//
//  This is the *only* recommendation-adjacent call that sends an image, and
//  it runs once per derivation (triggered on portrait save, or lazily
//  backfilled), never per recommendation request — see
//  `Data/WardrobeRepository.swift`'s `saveUserProfile` for the persistence
//  side.
//
//  Same structured-output-with-fallback shape as
//  Services/VisionMetadataExtractionService.swift (see that file's header
//  for why the configured model needs it) — a distinct call because it tags
//  a person, not a garment, and produces `UserStyleProfileWire`, not
//  `GarmentMetadata`.
//

import Foundation

protocol UserProfileDerivationService {
    func deriveProfile(portraitData: Data) async throws -> UserStyleProfileWire
}

enum UserProfileDerivationError: Error, LocalizedError {
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
            return "The styling service didn't return a profile."
        case .decoding:
            return "Couldn't read that photo — try a clearer one."
        }
    }
}

final class OpenRouterUserProfileDerivationService: UserProfileDerivationService {
    private let session: URLSession
    private let model: String
    private let endpoint = ProxyConfig.openRouterChatURL

    init(session: URLSession = .shared, model: String = ModelConfig.imageToText) {
        self.session = session
        self.model = model
    }

    func deriveProfile(portraitData: Data) async throws -> UserStyleProfileWire {
        do {
            return try await PerfLog.time("profile.structuredAttempt") {
                try await performRequest(portraitData: portraitData, useStructuredOutput: true)
            }
        } catch UserProfileDerivationError.emptyChoices, UserProfileDerivationError.decoding, UserProfileDerivationError.httpStatus(400) {
            // Structured output either came back malformed/empty or was
            // rejected outright (most likely `response_format: json_schema`
            // itself isn't supported) — one fallback attempt with the schema
            // embedded in the prompt instead of retrying the same mode twice,
            // which only doubles latency for a failure mode retrying won't fix.
            return try await PerfLog.time("profile.unstructuredFallbackAttempt") {
                try await performRequest(portraitData: portraitData, useStructuredOutput: false)
            }
        }
    }

    private func performRequest(portraitData: Data, useStructuredOutput: Bool) async throws -> UserStyleProfileWire {
        let requestID = AppLog.newRequestID()
        AppLog.info(.network, "[\(requestID)] profileDerivation: POST \(endpoint.path) structured=\(useStructuredOutput) imageBytes=\(portraitData.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.network, "[\(requestID)] profileDerivation: missing auth header — \(String(describing: error))")
            throw UserProfileDerivationError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in proxyHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try Self.encodeRequestBody(
            model: model,
            portraitData: portraitData,
            useStructuredOutput: useStructuredOutput
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.error(.network, "[\(requestID)] profileDerivation: transport error — \(String(describing: error))")
            throw UserProfileDerivationError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error(.network, "[\(requestID)] profileDerivation: HTTP \(statusCode)")
            throw UserProfileDerivationError.httpStatus(statusCode)
        }

        let decoded: OpenRouterProfileChatResponse
        do {
            decoded = try JSONDecoder().decode(OpenRouterProfileChatResponse.self, from: data)
        } catch {
            AppLog.error(.network, "[\(requestID)] profileDerivation: response envelope decode failed — \(String(describing: error))")
            throw UserProfileDerivationError.decoding(error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            AppLog.error(.network, "[\(requestID)] profileDerivation: empty choices")
            throw UserProfileDerivationError.emptyChoices
        }

        let payload = useStructuredOutput ? Data(content.utf8) : OpenRouterResponseParsing.extractJSONObject(from: content)
        do {
            let profile = try JSONDecoder().decode(UserStyleProfileWire.self, from: payload)
            AppLog.info(.network, "[\(requestID)] profileDerivation: ok")
            return profile
        } catch {
            AppLog.error(.network, "[\(requestID)] profileDerivation: UserStyleProfileWire decode failed — \(String(describing: error))")
            throw UserProfileDerivationError.decoding(error)
        }
    }

    private static func encodeRequestBody(
        model: String,
        portraitData: Data,
        useStructuredOutput: Bool
    ) throws -> Data {
        let dataURI = "data:image/jpeg;base64,\(portraitData.base64EncodedString())"

        var systemPrompt = ModelConfig.Prompts.userProfileDerivationSystemPrompt

        let userContent: [[String: Any]] = [
            ["type": "text", "text": ModelConfig.Prompts.userProfileDerivationUserText],
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
                    "name": "UserStyleProfile",
                    "strict": true,
                    "schema": userStyleProfileJSONSchema,
                ],
            ]
        } else {
            let schemaData = try JSONSerialization.data(
                withJSONObject: userStyleProfileJSONSchema,
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

    /// Matches PRD.md §3.8's User Style Profile table.
    private static let userStyleProfileJSONSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "skin_tone": ["type": "string"],
            "undertone": ["type": "string", "enum": Undertone.allCases.map(\.rawValue)],
            "body_type": ["type": "string"],
            "style_keywords": ["type": "array", "items": ["type": "string"]],
            "recommended_colors": ["type": "array", "items": ["type": "string"]],
            "avoid_colors": ["type": "array", "items": ["type": "string"]],
        ],
        "required": [
            "skin_tone", "undertone", "body_type", "style_keywords", "recommended_colors", "avoid_colors",
        ],
        "additionalProperties": false,
    ]
}

// MARK: - OpenAI-compatible chat completions response shape

private struct OpenRouterProfileChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockUserProfileDerivationService: UserProfileDerivationService {
    var result = UserStyleProfileWire(
        skinTone: "medium, warm olive",
        undertone: .warm,
        bodyType: "athletic build",
        styleKeywords: ["classic", "minimalist"],
        recommendedColors: ["#8A5A44", "#3A7CA5", "#F5F5F0"],
        avoidColors: ["#B983FF"]
    )

    func deriveProfile(portraitData: Data) async throws -> UserStyleProfileWire {
        result
    }
}

/// Routes each call to a real or mock `UserProfileDerivationService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedWardrobeSyncService` (see that type's doc
/// comment in `Services/WardrobeSyncService.swift`) and
/// `AuthGatedVisionMetadataExtractionService`.
@MainActor
final class AuthGatedUserProfileDerivationService: UserProfileDerivationService {
    private lazy var real = OpenRouterUserProfileDerivationService()
    private lazy var mock = MockUserProfileDerivationService()
    private var current: UserProfileDerivationService { AuthService.shared.isSignedIn ? real : mock }

    func deriveProfile(portraitData: Data) async throws -> UserStyleProfileWire {
        try await current.deriveProfile(portraitData: portraitData)
    }
}
