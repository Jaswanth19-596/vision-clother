//
//  ImageEmbeddingServiceTests.swift
//  Vision_clotherTests
//
//  Covers `Services/ImageEmbeddingService.swift`. `MockImageEmbeddingService`
//  is exercised for the plumbing (protocol conformance, error propagation) —
//  everything view models/repositories actually depend on. A real-Vision
//  smoke test on `VisionFeaturePrintEmbeddingService` covers the on-device
//  extraction path against a tiny generated image, without depending on any
//  bundled test-fixture asset.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Vision_clother

struct ImageEmbeddingServiceTests {

    @Test func mockReturnsItsConfiguredVector() async throws {
        let service = MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        let vector = try await service.embedding(for: Data())
        #expect(vector == [1, 0, 0])
    }

    @Test func mockThrowsItsConfiguredError() async {
        let service = MockImageEmbeddingService(errorToThrow: .invalidImage)
        await #expect(throws: ImageEmbeddingError.self) {
            try await service.embedding(for: Data())
        }
    }

    @Test func realServiceThrowsInvalidImageForUnreadableBytes() async {
        let service = VisionFeaturePrintEmbeddingService()
        await #expect(throws: ImageEmbeddingError.self) {
            try await service.embedding(for: Data([0x00, 0x01, 0x02]))
        }
    }

    @Test func realServiceProducesAnL2NormalizedEmbeddingForARealImage() async throws {
        guard let imageData = Self.makeSolidColorPNG(width: 32, height: 32) else {
            Issue.record("Failed to generate a test PNG")
            return
        }

        let service = VisionFeaturePrintEmbeddingService()
        let vector = try await service.embedding(for: imageData)

        #expect(!vector.isEmpty)
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 0.01)
    }

    /// Generates a minimal solid-color PNG in-memory — no bundled test
    /// fixture asset needed for the real-Vision smoke test above.
    private static func makeSolidColorPNG(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(red: 0.6, green: 0.2, blue: 0.2, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else { return nil }
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
