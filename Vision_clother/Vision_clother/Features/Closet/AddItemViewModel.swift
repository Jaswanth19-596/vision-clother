//
//  AddItemViewModel.swift
//  Vision_clother
//
//  Drives the "Enter Details Manually" path only — camera/photo-library
//  capture now hands off straight to `Features/JobQueue/JobQueueStore.swift`,
//  which runs background isolation -> vision-LLM tagging -> save without a
//  review step. This view model exists for manual entry, where there is no
//  LLM guess to skip reviewing.
//

import Foundation
import Observation

@Observable
@MainActor
final class AddItemViewModel {
    enum State: Equatable {
        case idle
        case editingMetadata
        case saving
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Flipped once on a successful save — the view observes this to
    /// dismiss itself rather than the view model owning navigation.
    private(set) var didSave = false

    let editor = GarmentAttributesEditorModel()

    private let repository: WardrobeRepository

    init(repository: WardrobeRepository) {
        self.repository = repository
    }

    /// Pre-populates default fields for full manual entry
    func startManualEntry(defaultSlot: Slot) {
        editor.reset(defaultSlot: defaultSlot)
        state = .editingMetadata
    }

    /// Persists the manually entered item. `usageTracker` is the caller's —
    /// this view model has no `UsageTracker` of its own (unlike
    /// `JobQueueStore`, which is a long-lived app-root singleton
    /// constructed with one), so `AddItemView` passes its
    /// `@Environment(UsageTracker.self)` through per call.
    func saveItem(usageTracker: UsageTracker) async {
        AppLog.info(.viewModel, "AddItemViewModel.saveItem: starting")
        state = .saving
        do {
            let item = WardrobeItem.make(from: editor.makeMetadata(), imageAssetName: nil)

            // Guest-first quota plan: client-side pre-check for immediate
            // UX, backstopped server-side by backend/firestore.rules'
            // meta/itemCounts cap. Cap number comes from
            // `usageTracker.itemCap(for:)` — server-resolved, see
            // `Data/UsageTracker.swift`'s doc comment.
            let existingCount = (try? repository.fetchInventory())?.filter { $0.slot == item.slot }.count ?? 0
            guard existingCount < usageTracker.itemCap(for: item.slot) else {
                AppLog.notice(.viewModel, "AddItemViewModel.saveItem: item cap reached for slot=\(item.slot.rawValue)")
                state = .failed("You've reached the item limit for this category. Sign in to add more.")
                return
            }

            try repository.save(item)

            AppLog.info(.viewModel, "AddItemViewModel.saveItem: ok id=\(item.id) slot=\(item.slot.rawValue)")
            state = .idle
            didSave = true
        } catch {
            AppLog.error(.viewModel, "AddItemViewModel.saveItem: failed — \(String(describing: error))")
            state = .failed("Couldn't save that item. Try again.")
        }
    }
}
