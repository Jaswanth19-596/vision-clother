//
//  OpenRouterTryOnRenderService.swift
//  Vision_clother
//
//  Virtual try-on pipeline using google/gemini-2.5-flash-image (chat completion)
//  or dedicated Image API models (like bytedance-seed/seedream-4.5) through OpenRouter.
//

import Foundation

protocol TryOnRenderService {
    /// Drives `onUpdate` through the full lifecycle.
    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async
}

enum TryOnStage: Equatable {
    case rendering

    var label: String {
        switch self {
        case .rendering: return "Generating outfit preview…"
        }
    }
}

enum TryOnState: Equatable {
    case idle
    case submitting(stage: TryOnStage)
    case polling(stage: TryOnStage, elapsedSeconds: Double)
    case succeeded(imageURL: URL)
    case failed(TryOnError)
}

enum TryOnError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case network
    case renderFailed(reason: String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenRouter API key configured."
        case .network:
            return "Lost connection while rendering. Try again."
        case .renderFailed(let reason):
            return "Render failed: \(reason)"
        case .timedOut:
            return "That's taking longer than expected. Try again."
        case .cancelled:
            return "Render cancelled."
        }
    }
}

final class OpenRouterTryOnRenderService: TryOnRenderService {
    private let session: URLSession
    private let model: String

    init(session: URLSession = .shared, model: String = ModelConfig.imageToImage) {
        self.session = session
        self.model = model
    }

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        guard let apiKey = APIKeys.openRouter else {
            onUpdate(.failed(.missingAPIKey))
            return
        }

        onUpdate(.submitting(stage: .rendering))

        do {
            try Task.checkCancellation()

            let isChatModel = (model == "google/gemini-2.5-flash-image")
            var request: URLRequest

            if isChatModel {
                request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
                
                var contentParts: [[String: Any]] = []

                // 1. Instructions Prompt
                contentParts.append([
                    "type": "text",
                    "text": """
                    Apply the garments from the clothing reference images onto the person in the base portrait image. \
                    Put the top on their upper body, and the bottom on their lower body. Ensure the output is a single \
                    realistic photograph of the person wearing these clothing items, preserving their face, body shape, \
                    and background. Output ONLY the resulting generated image.
                    """
                ])

                // 2. Base Portrait Image
                contentParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/png;base64,\(baseImageData.base64EncodedString())"
                    ]
                ])

                // 3. Ingested Garment Images (Real non-ghost items)
                for item in items {
                    if !item.isGhostElement,
                       let assetName = item.imageAssetName,
                       let garmentData = ImageStorage.loadData(for: assetName) {
                        contentParts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,\(garmentData.base64EncodedString())"
                            ]
                        ])
                    }
                }

                let messages: [[String: Any]] = [
                    [
                        "role": "system",
                        "content": "You are a virtual try-on assistant. Combine the garments in the provided reference images onto the person in the base portrait image, producing a single realistic try-on output image."
                    ],
                    [
                        "role": "user",
                        "content": contentParts
                    ]
                ]

                let body: [String: Any] = [
                    "model": model,
                    "messages": messages,
                    "modalities": ["text", "image"]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } else {
                request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/images")!)

                var inputReferences: [[String: Any]] = []

                // 1. Base Portrait Image — must match ContentPartImage schema
                inputReferences.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/png;base64,\(baseImageData.base64EncodedString())"
                    ]
                ])

                // 2. Ingested Garment Images (Real non-ghost items)
                for item in items {
                    if !item.isGhostElement,
                       let assetName = item.imageAssetName,
                       let garmentData = ImageStorage.loadData(for: assetName) {
                        inputReferences.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,\(garmentData.base64EncodedString())"
                            ]
                        ])
                    }
                }

                let promptText = """
                Full-body fashion photograph. Apply the clothing items from the reference garment images \
                onto the person shown in the portrait reference image. Dress them in the outfit: the top \
                garment on their upper body, and the bottom garment on their lower body. \
                The output must show the COMPLETE person from head to toe — including the full face, \
                full torso, legs, and feet — with the original background preserved. \
                Do NOT crop the image. Do NOT zoom in. Show the full figure in a natural standing pose. \
                Editorial fashion photography style, realistic, high quality.
                """

                let body: [String: Any] = [
                    "model": model,
                    "prompt": promptText,
                    "input_references": inputReferences,
                    "aspect_ratio": "2:3"
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://github.com/Antigravity", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Vision Clother iOS", forHTTPHeaderField: "X-Title")

            let (data, response) = try await session.data(for: request)

            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let errorReason: String
                if let errorObj = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data),
                   let msg = errorObj.error?.message {
                    errorReason = msg
                } else {
                    let httpResponse = response as? HTTPURLResponse
                    let statusCode = httpResponse?.statusCode ?? -1
                    let bodyString = String(data: data, encoding: .utf8) ?? "No error body"
                    errorReason = "HTTP \(statusCode): \(bodyString)"
                }
                throw TryOnError.renderFailed(reason: errorReason)
            }

            let parsedURL: URL?
            if isChatModel {
                parsedURL = parseImageURL(from: data)
            } else {
                parsedURL = parseImageAPIURL(from: data)
            }

            if let resultURL = parsedURL {
                onUpdate(.succeeded(imageURL: resultURL))
            } else {
                let debugString = String(data: data, encoding: .utf8) ?? "Empty response"
                throw TryOnError.renderFailed(reason: "Invalid response format: \(debugString)")
            }

        } catch is CancellationError {
            onUpdate(.failed(.cancelled))
        } catch let error as TryOnError {
            onUpdate(.failed(error))
        } catch {
            onUpdate(.failed(.network))
        }
    }

    internal func parseImageURL(from data: Data) -> URL? {
        guard let response = try? JSONDecoder().decode(OpenRouterResponse.self, from: data) else {
            return nil
        }

        // 1. Extract from message.images
        if let images = response.choices.first?.message.images,
           let firstImage = images.first?.imageUrl.url {
            if let url = handleImageString(firstImage) {
                return url
            }
        }

        // 2. Extract from message.content
        if let content = response.choices.first?.message.content {
            if let url = handleImageString(content) {
                return url
            }
        }

        return nil
    }

    internal func parseImageAPIURL(from data: Data) -> URL? {
        guard let response = try? JSONDecoder().decode(OpenRouterImageResponse.self, from: data),
              let first = response.data?.first else {
            return nil
        }

        if let b64 = first.b64_json {
            let dataString = "data:image/png;base64,\(b64)"
            return handleImageString(dataString)
        }

        if let urlString = first.url {
            return handleImageString(urlString)
        }

        return nil
    }

    internal func handleImageString(_ text: String) -> URL? {
        if text.contains("data:image/") {
            guard let base64Start = text.range(of: "base64,")?.upperBound else {
                return nil
            }
            var base64Str = String(text[base64Start...])
            if let endRange = base64Str.range(of: "\"") {
                base64Str = String(base64Str[..<endRange.lowerBound])
            }
            if let endRange = base64Str.range(of: ")") {
                base64Str = String(base64Str[..<endRange.lowerBound])
            }
            base64Str = base64Str.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let imageData = Data(base64Encoded: base64Str) else {
                return nil
            }

            let tempFilename = "\(UUID().uuidString).png"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
            do {
                try imageData.write(to: tempURL, options: .atomic)
                return tempURL
            } catch {
                print("⚠️ Failed to write temporary try-on image: \(error)")
                return nil
            }
        }

        if text.starts(with: "http") {
            var cleanURL = text
            if let endRange = cleanURL.range(of: "\"") {
                cleanURL = String(cleanURL[..<endRange.lowerBound])
            }
            if let endRange = cleanURL.range(of: ")") {
                cleanURL = String(cleanURL[..<endRange.lowerBound])
            }
            return URL(string: cleanURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}

// MARK: - OpenRouter API Wire Shapes

private struct OpenRouterResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ImageAttachment: Decodable {
                struct ImageURL: Decodable {
                    let url: String
                }
                let imageUrl: ImageURL
                enum CodingKeys: String, CodingKey {
                    case imageUrl = "image_url"
                }
            }
            let content: String?
            let images: [ImageAttachment]?
        }
        let message: Message
    }
    let choices: [Choice]
}

private struct OpenRouterImageResponse: Decodable {
    struct ImageData: Decodable {
        let b64_json: String?
        let url: String?
    }
    let data: [ImageData]?
}

private struct OpenRouterErrorResponse: Decodable {
    struct ErrorDetail: Decodable {
        let message: String?
    }
    let error: ErrorDetail?
}

// MARK: - Mock for previews/tests — never touches the network.

struct MockTryOnRenderService: TryOnRenderService {
    var simulatedStepDelayNanoseconds: UInt64 = 800_000_000
    var resultImageURL = URL(string: "https://example.com/mock-tryon-result.png")!

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        onUpdate(.submitting(stage: .rendering))
        try? await Task.sleep(nanoseconds: simulatedStepDelayNanoseconds)
        onUpdate(.polling(stage: .rendering, elapsedSeconds: 0.8))
        try? await Task.sleep(nanoseconds: simulatedStepDelayNanoseconds)
        onUpdate(.succeeded(imageURL: resultImageURL))
    }
}
