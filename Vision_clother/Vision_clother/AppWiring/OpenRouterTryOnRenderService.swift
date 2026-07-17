//
//  OpenRouterTryOnRenderService.swift
//  Vision_clother
//
//  Virtual try-on pipeline using google/gemini-2.5-flash-image (chat completion)
//  or dedicated Image API models (like bytedance-seed/seedream-4.5) through OpenRouter.
//

import Foundation
import UIKit

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
    /// 429 from `backend/functions/src/middleware/quota.ts`'s `"tryOn"` gate
    /// — the signed-in free-tier monthly cap (10) was hit.
    case quotaExceeded
    /// 403 `sign_in_required` from the same gate — guests have a 0 try-on
    /// cap, so this always means "you're browsing as a guest."
    case signInRequired

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
        case .quotaExceeded:
            return "You've used all your try-ons this month."
        case .signInRequired:
            return "Sign in to try this on."
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
        let requestID = AppLog.newRequestID()
        AppLog.info(.tryOn, "[\(requestID)] renderTryOn: starting, model=\(model) items=\(items.count)")

        let proxyHeaders: [String: String]
        do {
            proxyHeaders = try await ProxyAuthHeaders.current()
        } catch {
            AppLog.error(.tryOn, "[\(requestID)] renderTryOn: missing auth header — \(String(describing: error))")
            onUpdate(.failed(.missingAPIKey))
            return
        }

        onUpdate(.submitting(stage: .rendering))

        // Camera captures (full-resolution portrait JPEGs, and uncompressed
        // RGBA8 PNGs out of background isolation) can be tens of MB — large
        // enough that the base64 upload never finishes inside the request
        // timeout, so the request never actually reaches OpenRouter. Shrink
        // everything to a network-appropriate size right before encoding;
        // the originals on disk are untouched.
        let networkBaseImageData = Self.networkReadyImageData(baseImageData, preservingTransparency: false)
        let networkGarmentData: [Data] = items.compactMap { item in
            guard !item.isGhostElement,
                  let assetName = item.imageAssetName,
                  let garmentData = ImageStorage.loadData(for: assetName) else {
                return nil
            }
            return Self.networkReadyImageData(garmentData, preservingTransparency: true)
        }

        do {
            try Task.checkCancellation()

            let isChatModel = ModelConfig.isChatCompletionImageModel(model)
            var request: URLRequest

            if isChatModel {
                request = URLRequest(url: ProxyConfig.openRouterTryOnURL)

                var contentParts: [[String: Any]] = []

                // 1. Instructions Prompt
                contentParts.append([
                    "type": "text",
                    "text": ModelConfig.Prompts.tryOnChatInstructions
                ])

                // 2. Base Portrait Image
                contentParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/png;base64,\(networkBaseImageData.base64EncodedString())"
                    ]
                ])

                // 3. Ingested Garment Images (Real non-ghost items)
                for garmentData in networkGarmentData {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/png;base64,\(garmentData.base64EncodedString())"
                        ]
                    ])
                }

                let messages: [[String: Any]] = [
                    [
                        "role": "system",
                        "content": ModelConfig.Prompts.tryOnChatSystemMessage
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
                request = URLRequest(url: ProxyConfig.openRouterImagesURL)

                var inputReferences: [[String: Any]] = []

                // 1. Base Portrait Image — must match ContentPartImage schema
                inputReferences.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/png;base64,\(networkBaseImageData.base64EncodedString())"
                    ]
                ])

                // 2. Ingested Garment Images (Real non-ghost items)
                for garmentData in networkGarmentData {
                    inputReferences.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/png;base64,\(garmentData.base64EncodedString())"
                        ]
                    ])
                }

                let promptText = ModelConfig.Prompts.tryOnImagesPrompt

                let body: [String: Any] = [
                    "model": model,
                    "prompt": promptText,
                    "input_references": inputReferences,
                    "aspect_ratio": "2:3"
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            request.httpMethod = "POST"
            // Default 60s is too tight for a multi-image base64 upload plus
            // generation time — bump it so slow uploads surface as a real
            // result instead of a spurious -1001 timeout.
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (field, value) in proxyHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }

            let (data, response) = try await session.data(for: request)

            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let failedStatusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if failedStatusCode == 429 {
                    AppLog.notice(.tryOn, "[\(requestID)] renderTryOn: quota exceeded")
                    throw TryOnError.quotaExceeded
                }
                if failedStatusCode == 403,
                   let proxyError = try? JSONDecoder().decode(ProxyQuotaErrorResponse.self, from: data),
                   proxyError.error == "sign_in_required" {
                    AppLog.notice(.tryOn, "[\(requestID)] renderTryOn: sign-in required")
                    throw TryOnError.signInRequired
                }

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
                AppLog.error(.tryOn, "[\(requestID)] renderTryOn: HTTP \(failedStatusCode) — \(errorReason)")
                throw TryOnError.renderFailed(reason: errorReason)
            }

            let parsedURL: URL?
            if isChatModel {
                parsedURL = parseImageURL(from: data)
            } else {
                parsedURL = parseImageAPIURL(from: data)
            }

            if let resultURL = parsedURL {
                AppLog.info(.tryOn, "[\(requestID)] renderTryOn: ok")
                onUpdate(.succeeded(imageURL: resultURL))
            } else {
                let debugString = String(data: data, encoding: .utf8) ?? "Empty response"
                AppLog.error(.tryOn, "[\(requestID)] renderTryOn: unparseable response — \(debugString.prefix(500))")
                throw TryOnError.renderFailed(reason: "Invalid response format: \(debugString)")
            }

        } catch is CancellationError {
            AppLog.notice(.tryOn, "[\(requestID)] renderTryOn: cancelled")
            onUpdate(.failed(.cancelled))
        } catch let error as TryOnError {
            onUpdate(.failed(error))
        } catch {
            // Surface the real transport error (timed out vs. offline vs.
            // DNS/host failure, etc.) instead of always reporting the same
            // generic message — a large-upload timeout and a truly offline
            // device look identical to the user otherwise.
            AppLog.error(.tryOn, "[\(requestID)] renderTryOn: transport error before a response was received — \(String(describing: error))")
            onUpdate(.failed(.network))
        }
    }

    /// Downscales/re-encodes image bytes before they're base64-encoded into
    /// an OpenRouter request body. Camera captures — full-resolution portrait
    /// JPEGs, and uncompressed RGBA8 PNGs out of background isolation — can
    /// be tens of MB, large enough that the upload never finishes inside the
    /// request timeout, so the request never reaches OpenRouter at all.
    /// Images already at or under `maxDimension` are returned unchanged.
    private static func networkReadyImageData(
        _ data: Data,
        preservingTransparency: Bool,
        maxDimension: CGFloat = 1280
    ) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return data }

        let scale = maxDimension / max(size.width, size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = !preservingTransparency
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        if preservingTransparency {
            return resized.pngData() ?? data
        } else {
            return resized.jpegData(compressionQuality: 0.85) ?? data
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
                AppLog.error(.tryOn, "handleImageString: failed to write temporary try-on image — \(String(describing: error))")
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

/// `backend/functions/src/middleware/quota.ts`'s 403 body shape:
/// `{ error: "sign_in_required" }` — a flat string, not `OpenRouterErrorResponse`'s
/// nested `{ error: { message } }` shape.
private struct ProxyQuotaErrorResponse: Decodable {
    let error: String
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

/// Routes each call to a real or mock `TryOnRenderService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time — same fix as `AuthGatedWardrobeSyncService` (see that type's doc
/// comment in `Services/WardrobeSyncService.swift`) and
/// `AuthGatedVisionMetadataExtractionService`. `ServiceFactory.makeTryOnRenderService`
/// wraps this in `CachedTryOnRenderService`, so the cache still sees a single
/// stable `TryOnRenderService` even though the real/mock choice underneath it
/// can now change between calls.
@MainActor
final class AuthGatedTryOnRenderService: TryOnRenderService {
    private lazy var real = OpenRouterTryOnRenderService()
    private lazy var mock = MockTryOnRenderService()
    private var current: TryOnRenderService { AuthService.shared.isSignedIn ? real : mock }

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        await current.renderTryOn(baseImageData: baseImageData, items: items, onUpdate: onUpdate)
    }
}
