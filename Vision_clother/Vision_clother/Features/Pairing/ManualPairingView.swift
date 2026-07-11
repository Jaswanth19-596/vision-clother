//
//  ManualPairingView.swift
//  Vision_clother
//
//  Sheet content for Manual Outfit Pairing with AI Virtual Try-On. Presented
//  from ClosetView. Three sections: the user's own photo (captured once,
//  reused thereafter), the top/bottom pickers, and the state-driven
//  generation result — mirrors AddItemView's capture-source-picker /
//  progress-state / failed-with-retry shape for consistency with the rest
//  of the ingestion-flavored UI in this app.
//

import PhotosUI
import SwiftData
import SwiftUI

struct ManualPairingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ManualPairingViewModel?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isCameraPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Try On")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = ManualPairingViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                validationService: ServiceFactory.makePersonPhotoValidationService(),
                tryOnService: ServiceFactory.makeTryOnRenderService(),
                photoLibrarySaver: ServiceFactory.makePhotoLibrarySaver(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService()
            )
        }
        .onChange(of: viewModel?.didSaveOutfit) { _, didSave in
            // Rating now happens exclusively from the Combinations tab — a
            // successful save just closes this screen.
            if didSave == true { dismiss() }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            PortraitCameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                viewModel?.savePortrait(data)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(viewModel: ManualPairingViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                portraitSection(viewModel: viewModel)
                itemPicker(title: "Shirt", items: viewModel.availableTops, selected: viewModel.selectedTop) {
                    viewModel.selectTop($0)
                }
                itemPicker(title: "Pants", items: viewModel.availableBottoms, selected: viewModel.selectedBottom) {
                    viewModel.selectBottom($0)
                }
                generationSection(viewModel: viewModel)
            }
            .padding()
        }
    }

    // MARK: - Portrait

    private func portraitSection(viewModel: ManualPairingViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Photo").font(.headline)
            Text("A full-body photo of just you, front-facing, in good light.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    isCameraPresented = true
                } label: {
                    Label(viewModel.hasPortrait ? "Retake Photo" : "Take Photo", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }

            if viewModel.hasPortrait {
                Label("Photo saved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                viewModel.savePortrait(data)
                photoPickerItem = nil
            }
        }
    }

    // MARK: - Item pickers

    private func itemPicker(
        title: String,
        items: [WardrobeItem],
        selected: WardrobeItem?,
        onSelect: @escaping (WardrobeItem) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)

            if items.isEmpty {
                Text("No \(title.lowercased()) in your closet yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items, id: \.id) { item in
                            PairingItemCell(item: item, isSelected: selected?.id == item.id)
                                .onTapGesture { onSelect(item) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Generation

    @ViewBuilder
    private func generationSection(viewModel: ManualPairingViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            Button("Generate Preview") {
                viewModel.generatePreview()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!viewModel.canGeneratePreview)

        case .validatingPhoto:
            progress(viewModel: viewModel, label: "Checking your photo…")

        case .preparingImages:
            progress(viewModel: viewModel, label: "Preparing images…")

        case .generatingPreview(let stage):
            progress(viewModel: viewModel, label: stage.label)

        case .success(let imageURL):
            VStack(spacing: 16) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Label("Couldn't load the preview", systemImage: "photo.badge.exclamationmark")
                    default:
                        ProgressView()
                    }
                }
                .frame(maxHeight: 400)

                Text("Did you like this outfit?").font(.headline)
                HStack {
                    Button {
                        Task { await viewModel.saveOutfit(liked: false) }
                    } label: {
                        Label("Dislike", systemImage: "hand.thumbsdown")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await viewModel.saveOutfit(liked: true) }
                    } label: {
                        Label("Like", systemImage: "hand.thumbsup")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.generatePreview() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func progress(viewModel: ManualPairingViewModel, label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(label)
            Button("Cancel", role: .cancel) { viewModel.cancelGeneration() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
}

private struct PairingItemCell: View {
    let item: WardrobeItem
    let isSelected: Bool

    var body: some View {
        swatch
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
    }

    @ViewBuilder
    private var swatch: some View {
        if let imageAssetName = item.imageAssetName,
           let uiImage = UIImage(contentsOfFile: ImageStorage.url(for: imageAssetName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: item.colorProfile.primaryHex) ?? .gray)
        }
    }
}

/// Thin `UIImagePickerController` wrapper for the user's own photo —
/// deliberately separate from AddItemView's private CameraCaptureView
/// rather than sharing it, since that one is scoped private to that file.
private struct PortraitCameraCaptureView: UIViewControllerRepresentable {
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
    ManualPairingView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self],
            inMemory: true
        )
}
