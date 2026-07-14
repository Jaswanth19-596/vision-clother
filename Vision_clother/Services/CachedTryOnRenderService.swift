//
//  CachedTryOnRenderService.swift
//  Vision_clother
//
//  Decorates a real/mock `TryOnRenderService` so a try-on request for an
//  item set that already has a saved, still-on-disk render — generated
//  against the same base portrait — reuses that image instead of paying for
//  a fresh AI generation. Wired in once at `ServiceFactory.makeTryOnRenderService`
//  so both Manual Pairing and Daily Assistant's job queue benefit without
//  either call site changing.
//

import Foundation

@MainActor
final class CachedTryOnRenderService: TryOnRenderService {
    private let repository: WardrobeRepository
    private let underlying: TryOnRenderService

    init(repository: WardrobeRepository, underlying: TryOnRenderService) {
        self.repository = repository
        self.underlying = underlying
    }

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        let itemIDs = Set(items.map(\.id))
        let portraitFingerprint = ImageStorage.fingerprint(baseImageData)

        if let cached = (try? repository.fetchSavedCombinations())?.first(where: { combination in
            combination.basePortraitFingerprint == portraitFingerprint
                && Set(combination.itemIDsBySlot.values) == itemIDs
        }), ImageStorage.loadData(for: cached.imageAssetName) != nil {
            onUpdate(.succeeded(imageURL: ImageStorage.url(for: cached.imageAssetName)))
            return
        }

        await underlying.renderTryOn(baseImageData: baseImageData, items: items, onUpdate: onUpdate)
    }
}
