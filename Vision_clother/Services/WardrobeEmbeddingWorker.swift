//
//  WardrobeEmbeddingWorker.swift
//  Vision_clother
//
//  Runs Vision embedding generation off the main actor. Calling
//  `ImageEmbeddingService.embedding(for:)` directly from `@MainActor`-isolated
//  `WardrobeRepository` never actually hops threads — the function has no
//  internal suspension point, so Swift just runs it inline on the caller's
//  executor, blocking the UI. Isolating it to this actor forces the hop, and
//  `withTaskGroup` fans multiple items out across cores instead of awaiting
//  them one-by-one. Only `Sendable` primitives cross this boundary — never a
//  `WardrobeItem` or `ModelContext`.
//

import Foundation

actor WardrobeEmbeddingWorker {
    struct EmbeddingRequest: Sendable {
        let itemID: UUID
        let imageData: Data
        let sourceFingerprint: String
    }

    struct EmbeddingResult: Sendable {
        let itemID: UUID
        let vector: [Float]
        let sourceFingerprint: String
    }

    private let embeddingService: ImageEmbeddingService

    init(embeddingService: ImageEmbeddingService) {
        self.embeddingService = embeddingService
    }

    /// Best-effort per item, same posture as the serial loop this replaces —
    /// one item's Vision failure drops it from the result rather than failing
    /// the whole batch.
    func computeEmbeddings(for requests: [EmbeddingRequest]) async -> [EmbeddingResult] {
        await withTaskGroup(of: EmbeddingResult?.self) { group in
            for request in requests {
                group.addTask {
                    guard let vector = try? await self.embeddingService.embedding(for: request.imageData) else {
                        return nil
                    }
                    return EmbeddingResult(itemID: request.itemID, vector: vector, sourceFingerprint: request.sourceFingerprint)
                }
            }

            var results: [EmbeddingResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }
}
