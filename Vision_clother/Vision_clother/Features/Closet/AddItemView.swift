//
//  AddItemView.swift
//  Vision_clother
//
//  Capture entry point for PRD.md §3.1's ingestion pipeline. Presented as a
//  sheet from ClosetView. Camera and multi-select photo-library capture both
//  hand off straight to `Features/JobQueue/JobQueueStore.swift`, which runs
//  background isolation -> vision-LLM tagging -> save in the background —
//  the sheet dismisses immediately, with no review step. "Enter Details
//  Manually" is the only path that still shows a form in-sheet, since
//  there's no LLM guess to review there.
//

import CryptoKit
import os
import PhotosUI
import SwiftData
import SwiftUI

/// Short content fingerprint for correlating an image's bytes across
/// ingestion-pipeline log lines — not a security hash, just enough to tell
/// "same bytes" from "different bytes" when reading logs after the fact.
private func imageFingerprint(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
}

struct AddItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(JobQueueStore.self) private var jobQueueStore

    let defaultSlot: Slot?

    @State private var viewModel: AddItemViewModel?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isCameraPresented = false

    /// Bounds memory and how many tagging calls can be in flight from one
    /// batch selection.
    private let maxSelectionCount = 20

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = AddItemViewModel(repository: SwiftDataWardrobeRepository(modelContext: modelContext))
        }
        .onChange(of: viewModel?.didSave) { _, didSave in
            if didSave == true { dismiss() }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                PerfLog.logger.notice("[ingest] camera capture=\(imageFingerprint(data), privacy: .public) bytes=\(data.count, privacy: .public)")
                jobQueueStore.enqueueUpload(rawImageData: data, defaultSlot: defaultSlot)
                dismiss()
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(viewModel: AddItemViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            captureSourcePicker(viewModel: viewModel)

        case .editingMetadata:
            GarmentAttributesFormView(
                model: viewModel.editor,
                previewImageData: nil,
                saveButtonLabel: "Save to Closet",
                onSave: { Task { await viewModel.saveItem() } }
            )

        case .saving:
            progress("Saving…")

        case .failed(let message):
            VStack(spacing: 16) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                captureSourcePicker(viewModel: viewModel)
            }
            .padding()
        }
    }

    private func progress(_ label: String) -> some View {
        VStack {
            Spacer()
            ProgressView(label)
            Spacer()
        }
    }

    private func captureSourcePicker(viewModel: AddItemViewModel) -> some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Add a garment",
                systemImage: "camera",
                description: Text("Take a photo, or choose one or more from your library. They'll tag and save in the background.")
            )

            Button {
                isCameraPresented = true
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $photoPickerItems, maxSelectionCount: maxSelectionCount, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.startManualEntry(defaultSlot: defaultSlot ?? .top)
            } label: {
                Label("Enter Details Manually", systemImage: "pencil.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onChange(of: photoPickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for pickerItem in newItems {
                    guard let data = try? await pickerItem.loadTransferable(type: Data.self) else { continue }
                    PerfLog.logger.notice("[ingest] picker itemIdentifier=\(pickerItem.itemIdentifier ?? "nil", privacy: .public) raw=\(imageFingerprint(data), privacy: .public) bytes=\(data.count, privacy: .public)")
                    jobQueueStore.enqueueUpload(rawImageData: data, defaultSlot: defaultSlot)
                }
                photoPickerItems = []
                dismiss()
            }
        }
    }
}

/// Thin `UIImagePickerController` wrapper — SwiftUI has no native camera
/// capture view. `onCapture` receives JPEG data on success, `nil` on cancel.
private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    AddItemView(defaultSlot: nil)
        .modelContainer(container)
        .environment(JobQueueStore(
            repository: SwiftDataWardrobeRepository(modelContext: container.mainContext),
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        ))
}
