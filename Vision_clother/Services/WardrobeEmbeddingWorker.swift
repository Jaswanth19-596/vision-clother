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

    struct FingerprintRequest: Sendable {
        let itemID: UUID
        let filename: String
    }

    struct FingerprintResult: Sendable {
        let itemID: UUID
        let imageData: Data
        let fingerprint: String
    }

    private let embeddingService: ImageEmbeddingService

    init(embeddingService: ImageEmbeddingService) {
        self.embeddingService = embeddingService
    }

    /// Off-main-actor disk read + content hash — same fan-out-across-cores
    /// posture as `computeEmbeddings`, used by `WardrobeRepository.fetchFeedbackHistory()`
    /// only for items whose embedding-cache validity can't be resolved from
    /// an already-persisted `WardrobeItem.imageFingerprint` (a pre-existing
    /// row saved before that field existed, or a genuine cache miss) — the
    /// steady-state case skips this entirely via a pure in-memory compare.
    /// Best-effort per item: a missing/unreadable file just drops that item,
    /// same posture as `computeEmbeddings`.
    func computeFingerprints(for requests: [FingerprintRequest]) async -> [FingerprintResult] {
        await withTaskGroup(of: FingerprintResult?.self) { group in
            for request in requests {
                group.addTask {
                    guard let data = ImageStorage.loadData(for: request.filename) else { return nil }
                    return FingerprintResult(itemID: request.itemID, imageData: data, fingerprint: ImageStorage.fingerprint(data))
                }
            }

            var results: [FingerprintResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
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
