//
//  ImageEmbeddingService.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: turns raw image bytes into a fixed-length,
//  L2-normalized embedding vector — the shared representation
//  `Domain/VisualPreferenceProfile.swift`'s k-means clustering and cosine
//  scoring operate on. Runs entirely on-device via Apple's Vision framework
//  (CLAUDE.md guardrail #4's on-device philosophy) — no bundled CoreML model,
//  no network call, same posture as `Services/PersonPhotoValidationService.swift`.
//
//  `VNGenerateImageFeaturePrintRequest` is Vision's general-purpose visual
//  similarity embedding — chosen over `VNFeaturePrintObservation.computeDistance`
//  because online k-means needs raw per-dimension access to the vector, not
//  just a pairwise distance. Swappable behind this protocol so a real CoreML
//  CLIP encoder can replace it later if quality is insufficient (deferred,
//  see the swipe-deck plan).
//

import CoreImage
import Foundation
import Vision

/// `Sendable`: both conformers are stateless, and `WardrobeEmbeddingWorker`
/// (`Services/WardrobeEmbeddingWorker.swift`) captures an instance across an
/// actor boundary to run embedding work off the main actor.
protocol ImageEmbeddingService: Sendable {
    /// Returns an L2-normalized embedding vector for the given image bytes.
    /// Throws `ImageEmbeddingError` if the image can't be read or Vision
    /// can't produce a feature print for it.
    func embedding(for imageData: Data) async throws -> [Float]
}

enum ImageEmbeddingError: Error, LocalizedError {
    case invalidImage
    case processingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "That photo couldn't be read."
        case .processingFailed:
            return "Something went wrong analyzing that photo."
        }
    }
}

final class VisionFeaturePrintEmbeddingService: ImageEmbeddingService, @unchecked Sendable {
    func embedding(for imageData: Data) async throws -> [Float] {
        guard let ciImage = CIImage(data: imageData) else {
            throw ImageEmbeddingError.invalidImage
        }

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()

        do {
            try handler.perform([request])
        } catch {
            throw ImageEmbeddingError.processingFailed(error)
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw ImageEmbeddingError.processingFailed(
                NSError(domain: "ImageEmbeddingService", code: -1, userInfo: nil)
            )
        }

        let raw = Self.rawFloats(from: observation)
        return VisualClusterUpdater.l2Normalized(raw)
    }

    /// Extracts the underlying per-dimension floats from a feature print's
    /// opaque `.data` blob — `elementType` is `.float` or `.double` depending
    /// on device/OS, and this reads either into a `[Float]` so downstream
    /// k-means math (`Domain/VisualPreferenceProfile.swift`) has one uniform
    /// representation to work with.
    static func rawFloats(from observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        var floats = [Float](repeating: 0, count: count)

        observation.data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            switch observation.elementType {
            case .float:
                let buffer = rawBuffer.bindMemory(to: Float.self)
                for i in 0..<count { floats[i] = buffer[i] }
            case .double:
                let buffer = rawBuffer.bindMemory(to: Double.self)
                for i in 0..<count { floats[i] = Float(buffer[i]) }
            default:
                break
            }
        }

        return floats
    }
}

// MARK: - Mock for previews/tests — never touches Vision/CoreImage.

struct MockImageEmbeddingService: ImageEmbeddingService {
    var vectorToReturn: [Float] = [1, 0, 0, 0]
    var errorToThrow: ImageEmbeddingError?

    func embedding(for imageData: Data) async throws -> [Float] {
        if let errorToThrow {
            throw errorToThrow
        }
        return vectorToReturn
    }
}
