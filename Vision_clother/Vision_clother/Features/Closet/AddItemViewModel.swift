//
//  AddItemViewModel.swift
//  Vision_clother
//
//  Drives the ingestion pipeline (PRD.md §3.1): capture -> on-device
//  background isolation (Services/BackgroundIsolationService.swift) ->
//  vision-LLM metadata tagging (Services/VisionMetadataExtractionService.swift)
//  -> persist as a `WardrobeItem`. V1 scope is one garment per photo
//  (CLAUDE.md guardrail #4).
//

import Foundation
import Observation

@Observable
@MainActor
final class AddItemViewModel {
    enum State: Equatable {
        case idle
        case isolatingBackground
        case taggingMetadata
        case editingMetadata
        case saving
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Flipped once on a successful save — the view observes this to
    /// dismiss itself rather than the view model owning navigation.
    private(set) var didSave = false

    // Editable fields for the review/manual form
    var slot: Slot = .top
    var formalityScore: Double = 3.0
    var primaryHex: String = "#FFFFFF"
    var secondaryHex: String? = nil
    var colorCategory: ColorVibe = .neutral
    var undertone: Undertone? = nil
    var pattern: GarmentPattern = .solid
    var seasonality: [Season] = [.summer, .springFall, .winter]
    var fabricWeight: FabricWeight = .medium
    /// One concise sentence describing the garment — becomes the catalog
    /// entry text `Domain/WardrobeCatalogBuilder.swift` sends to the
    /// recommendation LLM (PRD §3.7). Empty for fully manual entries with no
    /// vision-tagging pass.
    var itemDescription: String = ""
    var styleTags: [String] = []

    private(set) var isolatedImageData: Data? = nil

    private let repository: WardrobeRepository
    private let backgroundIsolationService: BackgroundIsolationService
    private let visionMetadataService: VisionMetadataExtractionService

    init(
        repository: WardrobeRepository,
        backgroundIsolationService: BackgroundIsolationService = MockBackgroundIsolationService(),
        visionMetadataService: VisionMetadataExtractionService = MockVisionMetadataExtractionService()
    ) {
        self.repository = repository
        self.backgroundIsolationService = backgroundIsolationService
        self.visionMetadataService = visionMetadataService
    }

    /// Runs the capture -> isolate -> tag pipeline, transitioning to `.editingMetadata`
    /// on success or failure so the user can review/edit/enter manual values.
    func ingest(rawImageData: Data) async {
        state = .isolatingBackground
        let imageToTag: Data
        do {
            let isolated = try await backgroundIsolationService.isolateForeground(from: rawImageData)
            self.isolatedImageData = isolated
            imageToTag = isolated
        } catch {
            print("Background isolation failed: \(error). Falling back to raw image for LLM tagging.")
            self.isolatedImageData = rawImageData
            imageToTag = rawImageData
        }

        state = .taggingMetadata
        do {
            let metadata = try await visionMetadataService.extractMetadata(imageData: imageToTag)

            self.slot = metadata.slot
            self.formalityScore = metadata.formalityScore
            self.primaryHex = metadata.colorProfile.primaryHex
            self.secondaryHex = metadata.colorProfile.secondaryHex
            self.colorCategory = metadata.colorProfile.category
            self.undertone = metadata.colorProfile.undertone
            self.pattern = metadata.pattern
            self.seasonality = metadata.seasonality
            self.fabricWeight = metadata.fabricWeight
            self.itemDescription = metadata.description
            self.styleTags = metadata.styleTags

            state = .editingMetadata
        } catch {
            if let tagError = error as? VisionMetadataExtractionError {
                state = .failed(tagError.errorDescription ?? "Couldn't tag that item.")
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Pre-populates default fields for full manual entry
    func startManualEntry(defaultSlot: Slot) {
        self.slot = defaultSlot
        self.formalityScore = 3.0
        self.primaryHex = "#FFFFFF"
        self.secondaryHex = nil
        self.colorCategory = .neutral
        self.undertone = nil
        self.pattern = .solid
        self.seasonality = [.summer, .springFall, .winter]
        self.fabricWeight = .medium
        self.itemDescription = ""
        self.styleTags = []
        self.isolatedImageData = nil

        state = .editingMetadata
    }

    /// Persists the reviewed or manually entered item
    func saveItem() async {
        state = .saving
        do {
            var filename: String? = nil
            if let isolatedImageData {
                filename = try ImageStorage.save(isolatedImageData)
            }

            let item = WardrobeItem(
                slot: slot,
                formalityScore: formalityScore,
                colorProfile: ColorProfile(
                    primaryHex: primaryHex,
                    secondaryHex: secondaryHex,
                    category: colorCategory,
                    undertone: undertone
                ),
                pattern: pattern,
                seasonality: seasonality,
                fabricWeight: fabricWeight,
                imageAssetName: filename,
                itemDescription: itemDescription.isEmpty ? nil : itemDescription,
                styleTags: styleTags
            )
            try repository.save(item)

            state = .idle
            didSave = true
        } catch {
            state = .failed("Couldn't save that item. Try again.")
        }
    }
}
