//
//  BackgroundIsolationService.swift
//  Vision_clother
//
//  Background Isolation Service (PRD.md §3.1, ingestion stage 1) —
//  CLAUDE.md guardrail #4. Two implementations behind one protocol, run in a
//  fixed sequence for every upload (`JobQueueStore.performUpload`):
//  `OpenRouterBackgroundIsolationService` sends the raw photo to a Gemini
//  image model (via OpenRouter) with a flatlay-styling prompt first, since
//  it can succeed on cases the on-device path can't (a person wearing the
//  garment in frame, or a background visually similar to the item).
//  `VisionBackgroundIsolationService` then runs entirely on-device via
//  Apple's Vision framework (`VNGenerateForegroundInstanceMaskRequest`) on
//  Gemini's output to produce the final transparent-background cutout. Both
//  stages degrade gracefully on failure — see `JobQueueStore.performUpload`.
//
//  V1 scope is a single garment per photo (CLAUDE.md guardrail #4) — every
//  detected foreground instance is merged into one mask rather than picking
//  a specific instance index, since multi-garment segmentation is out of
//  scope for now.
//

import CoreImage
import Foundation
import UIKit
import Vision

protocol BackgroundIsolationService {
    /// Returns PNG-encoded image data of just the foreground garment,
    /// cropped to its extent, background dropped.
    func isolateForeground(from imageData: Data) async throws -> Data
}

enum BackgroundIsolationError: Error, LocalizedError {
    case invalidImage
    case noSubjectFound
    case processingFailed(Error)
    case missingAPIKey
    case requestFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read."
        case .noSubjectFound:
            return "Couldn't find a clear garment in that photo. Try a plainer background."
        case .processingFailed:
            return "Something went wrong isolating that item. Try again."
        case .missingAPIKey:
            return "No OpenRouter API key configured."
        case .requestFailed(let reason):
            return "AI background removal failed: \(reason)"
        }
    }
}

final class VisionBackgroundIsolationService: BackgroundIsolationService {
    private let context = CIContext()

    func isolateForeground(from imageData: Data) async throws -> Data {
        guard let sourceImage = CIImage(data: imageData) else {
            throw BackgroundIsolationError.invalidImage
        }

        // `CIImage(data:)` never rotates pixels for EXIF orientation — it only
        // exposes the tag via `.properties`. Bake it in now so the mask request,
        // and the PNG we persist (which has no orientation tag of its own),
        // are both in upright, display-correct pixel space.
        let orientation = (sourceImage.properties[kCGImagePropertyOrientation as String] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init)
            ?? .up
        let inputImage = sourceImage.oriented(orientation)

        let handler = VNImageRequestHandler(ciImage: inputImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            throw BackgroundIsolationError.processingFailed(error)
        }

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw BackgroundIsolationError.noSubjectFound
        }

        do {
            let maskedPixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let maskedImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
            guard
                let cgImage = context.createCGImage(maskedImage, from: maskedImage.extent),
                let pngData = context.pngRepresentation(
                    of: CIImage(cgImage: cgImage),
                    format: .RGBA8,
                    colorSpace: maskedImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
                )
            else {
                throw BackgroundIsolationError.processingFailed(
                    NSError(domain: "BackgroundIsolationService", code: -1, userInfo: nil)
                )
            }
            return pngData
        } catch let error as BackgroundIsolationError {
            throw error
        } catch {
            throw BackgroundIsolationError.processingFailed(error)
        }
    }
}

// MARK: - AI-assisted background removal via OpenRouter (Seedream)

/// Mandatory preprocessing stage that runs before `VisionBackgroundIsolationService`
/// for every upload (`JobQueueStore.performUpload`) — sends the raw upload photo to
/// a Gemini image model (via OpenRouter) with a flatlay-styling prompt, asking for a
/// 1:1, 4K, fully isolated product photo back. Costs money and needs network, but it
/// can succeed on cases Vision's foreground-instance mask alone can't handle (a person
/// wearing the garment in frame, or a background that's visually similar to the item)
/// — its output then still goes through on-device Vision for the final cutout. If this
/// stage fails (missing key, network error, bad response), `JobQueueStore` falls back
/// to running Vision directly on the raw photo.
final class OpenRouterBackgroundIsolationService: BackgroundIsolationService {
    private let session: URLSession
    private let model: String

    init(session: URLSession = .shared, model: String = ModelConfig.imageEdit) {
        self.session = session
        self.model = model
    }

    func isolateForeground(from imageData: Data) async throws -> Data {
        guard let apiKey = APIKeys.openRouter else {
            throw BackgroundIsolationError.missingAPIKey
        }

        // Same rationale as OpenRouterTryOnRenderService.networkReadyImageData
        // — raw camera captures can be tens of MB, and the model regenerates
        // a fresh image at 4K regardless of input resolution, so there's no
        // quality reason to upload full-res bytes.
        let networkImageData = Self.networkReadyImageData(imageData, maxDimension: 1280)

        // Same split as OpenRouterTryOnRenderService: Google's Gemini image
        // models are chat-completion models on OpenRouter, not dedicated
        // Images API models like Seedream — sending Gemini a Seedream-shaped
        // `/images` request fails outright.
        let isChatModel = ModelConfig.isChatCompletionImageModel(model)
        var request: URLRequest

        if isChatModel {
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)

            let messages: [[String: Any]] = [
                [
                    "role": "system",
                    "content": ModelConfig.Prompts.backgroundIsolationChatSystemMessage
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": ModelConfig.Prompts.backgroundIsolationFlatlayPrompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(networkImageData.base64EncodedString())"
                            ]
                        ]
                    ]
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

            let body: [String: Any] = [
                "model": model,
                "prompt": ModelConfig.Prompts.backgroundIsolationFlatlayPrompt,
                "input_references": [
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(networkImageData.base64EncodedString())"
                        ]
                    ]
                ],
                "aspect_ratio": "1:1",
                "resolution": "4K"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        request.httpMethod = "POST"
        // A full 4K generation runs longer than the try-on service's
        // body-photo-sized renders — give it more headroom than that
        // service's 120s.
        request.timeoutInterval = 150
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/Antigravity", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Vision Clother iOS", forHTTPHeaderField: "X-Title")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackgroundIsolationError.processingFailed(error)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let reason: String
            if let errorObj = try? JSONDecoder().decode(OpenRouterImageErrorResponse.self, from: data),
               let msg = errorObj.error?.message {
                reason = msg
            } else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyString = String(data: data, encoding: .utf8) ?? "No error body"
                reason = "HTTP \(statusCode): \(bodyString)"
            }
            throw BackgroundIsolationError.requestFailed(reason: reason)
        }

        if isChatModel {
            return try Self.extractImageData(fromChatCompletion: data)
        }
        return try await Self.extractImageData(from: data, session: session)
    }

    /// Decodes `{ data: [{ b64_json, url }] }` — same shape as
    /// OpenRouterTryOnRenderService's images-endpoint response, but this
    /// service must hand back raw `Data` (for immediate `ImageStorage.save`)
    /// rather than a `URL` for `AsyncImage` display, so a hosted `url`
    /// result is downloaded rather than just returned.
    private static func extractImageData(from responseBody: Data, session: URLSession) async throws -> Data {
        guard let decoded = try? JSONDecoder().decode(OpenRouterImagesResponse.self, from: responseBody),
              let first = decoded.data?.first else {
            let debugString = String(data: responseBody, encoding: .utf8) ?? "Empty response"
            throw BackgroundIsolationError.requestFailed(reason: "Invalid response format: \(debugString)")
        }

        if let b64 = first.b64_json, let imageData = Data(base64Encoded: b64) {
            return imageData
        }

        if let urlString = first.url, let url = URL(string: urlString) {
            do {
                let (imageData, _) = try await session.data(from: url)
                return imageData
            } catch {
                throw BackgroundIsolationError.processingFailed(error)
            }
        }

        throw BackgroundIsolationError.requestFailed(reason: "No image in response")
    }

    /// Decodes the chat-completions response shape Gemini image models
    /// return — `choices[0].message.images[].image_url.url` as a data: URI,
    /// or (less commonly) embedded directly in `message.content` — same
    /// shape `OpenRouterTryOnRenderService.parseImageURL` handles, but this
    /// service hands back raw `Data` for `ImageStorage.save` rather than a
    /// file `URL` for `AsyncImage` display.
    private static func extractImageData(fromChatCompletion responseBody: Data) throws -> Data {
        guard let decoded = try? JSONDecoder().decode(OpenRouterChatCompletionResponse.self, from: responseBody) else {
            let debugString = String(data: responseBody, encoding: .utf8) ?? "Empty response"
            throw BackgroundIsolationError.requestFailed(reason: "Invalid response format: \(debugString)")
        }

        let candidate = decoded.choices.first?.message.images?.first?.imageUrl.url
            ?? decoded.choices.first?.message.content

        if let candidate, let imageData = Self.decodeDataURI(candidate) {
            return imageData
        }

        let debugString = String(data: responseBody, encoding: .utf8) ?? "Empty response"
        throw BackgroundIsolationError.requestFailed(reason: "Invalid response format: \(debugString)")
    }

    private static func decodeDataURI(_ text: String) -> Data? {
        guard let base64Start = text.range(of: "base64,")?.upperBound else { return nil }
        var base64Str = String(text[base64Start...])
        if let endRange = base64Str.range(of: "\"") {
            base64Str = String(base64Str[..<endRange.lowerBound])
        }
        base64Str = base64Str.trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: base64Str)
    }

    /// Downscales/re-encodes image bytes before they're base64-encoded into
    /// the request body — mirrors
    /// `OpenRouterTryOnRenderService.networkReadyImageData`. Images already
    /// at or under `maxDimension` are returned unchanged.
    private static func networkReadyImageData(_ data: Data, maxDimension: CGFloat) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return data }

        let scale = maxDimension / max(size.width, size.height)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.85) ?? data
    }
}

// MARK: - OpenRouter Images API wire shapes

private struct OpenRouterImagesResponse: Decodable {
    struct ImageData: Decodable {
        let b64_json: String?
        let url: String?
    }
    let data: [ImageData]?
}

private struct OpenRouterImageErrorResponse: Decodable {
    struct ErrorDetail: Decodable {
        let message: String?
    }
    let error: ErrorDetail?
}

/// Chat-completions response shape for Gemini image models — mirrors
/// `OpenRouterTryOnRenderService`'s private `OpenRouterResponse`.
private struct OpenRouterChatCompletionResponse: Decodable {
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

// MARK: - Mock for previews/tests — never touches Vision/CoreImage.

struct MockBackgroundIsolationService: BackgroundIsolationService {
    func isolateForeground(from imageData: Data) async throws -> Data {
        imageData
    }
}
