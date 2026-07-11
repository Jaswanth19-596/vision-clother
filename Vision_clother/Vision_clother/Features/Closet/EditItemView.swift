//
//  EditItemView.swift
//  Vision_clother
//
//  Edit-after-save — closes the gap left by skipping the review form on
//  background-queued uploads (`Features/JobQueue/JobQueueStore.swift`). Reuses
//  the same `GarmentAttributesFormView` as manual entry, seeded from the
//  item's current fields via `WardrobeItem.currentMetadataDraft`.
//

import SwiftData
import SwiftUI

struct EditItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let item: WardrobeItem

    @State private var editor = GarmentAttributesEditorModel()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            GarmentAttributesFormView(
                model: editor,
                previewImageData: previewImageData,
                saveButtonLabel: "Save Changes",
                onSave: save
            )
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                editor.load(from: item.currentMetadataDraft)
            }
            .alert("Couldn't save changes", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var previewImageData: Data? {
        guard let imageAssetName = item.imageAssetName else { return nil }
        return ImageStorage.loadData(for: imageAssetName)
    }

    private func save() {
        item.apply(editor.makeMetadata())
        let repository = SwiftDataWardrobeRepository(modelContext: modelContext)
        do {
            try repository.update(item)
            dismiss()
        } catch {
            errorMessage = "Couldn't save that item. Try again."
        }
    }
}

#Preview {
    let item = WardrobeItem(
        slot: .top,
        formalityScore: 2.5,
        colorProfile: ColorProfile(primaryHex: "#3A7CA5", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer, .springFall],
        fabricWeight: .light
    )
    EditItemView(item: item)
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
