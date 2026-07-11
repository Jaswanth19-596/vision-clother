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

    /// Persists the manually entered item
    func saveItem() async {
        state = .saving
        do {
            let item = WardrobeItem.make(from: editor.makeMetadata(), imageAssetName: nil)
            try repository.save(item)

            state = .idle
            didSave = true
        } catch {
            state = .failed("Couldn't save that item. Try again.")
        }
    }
}
