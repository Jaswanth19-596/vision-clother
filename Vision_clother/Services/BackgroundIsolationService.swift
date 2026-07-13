//
//  BackgroundIsolationService.swift
//  Vision_clother
//
//  Background Isolation Service (PRD.md §3.1, ingestion stage 1) —
//  CLAUDE.md guardrail #4. On-device only, via Apple's Vision framework
//  (`VNGenerateForegroundInstanceMaskRequest`) — no network call, no LLM.
//  This is a deliberate architectural split from
//  Services/VisionMetadataExtractionService.swift: removing a background is
//  not something a chat-completion vision model can do (it returns text, not
//  edited image bytes), so this step runs entirely offline before the LLM
//  ever sees the photo.
//
//  V1 scope is a single garment per photo (CLAUDE.md guardrail #4) — every
//  detected foreground instance is merged into one mask rather than picking
//  a specific instance index, since multi-garment segmentation is out of
//  scope for now.
//

import CoreImage
import Foundation
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

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read."
        case .noSubjectFound:
            return "Couldn't find a clear garment in that photo. Try a plainer background."
        case .processingFailed:
            return "Something went wrong isolating that item. Try again."
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

// MARK: - Mock for previews/tests — never touches Vision/CoreImage.

struct MockBackgroundIsolationService: BackgroundIsolationService {
    func isolateForeground(from imageData: Data) async throws -> Data {
        imageData
    }
}
