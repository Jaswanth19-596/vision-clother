//
//  AddItemView.swift
//  Vision_clother
//
//  Capture entry point for PRD.md §3.1's ingestion pipeline. Presented as a
//  sheet from ClosetView. Two capture sources (camera, photo library) feed
//  the same AddItemViewModel.ingest(rawImageData:) pipeline; V1 scope is one
//  garment per photo (CLAUDE.md guardrail #4).
//

import PhotosUI
import SwiftData
import SwiftUI

struct AddItemView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let defaultSlot: Slot?

    @State private var viewModel: AddItemViewModel?
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
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = AddItemViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                backgroundIsolationService: ServiceFactory.makeBackgroundIsolationService(),
                visionMetadataService: ServiceFactory.makeVisionMetadataExtractionService()
            )
        }
        .onChange(of: viewModel?.didSave) { _, didSave in
            if didSave == true { dismiss() }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                Task { await viewModel?.ingest(rawImageData: data) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(viewModel: AddItemViewModel) -> some View {
        switch viewModel.state {
        case .idle:
            captureSourcePicker(viewModel: viewModel)

        case .isolatingBackground:
            progress("Isolating garment…")

        case .taggingMetadata:
            progress("Tagging item…")

        case .editingMetadata:
            editForm(viewModel: viewModel)

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

    @ViewBuilder
    private func editForm(viewModel: AddItemViewModel) -> some View {
        Form {
            Section("Garment Preview") {
                HStack {
                    Spacer()
                    if let isolated = viewModel.isolatedImageData, let uiImage = UIImage(data: isolated) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: viewModel.primaryHex) ?? .gray)
                            .frame(width: 80, height: 80)
                            .overlay {
                                Image(systemName: "tshirt.fill")
                                    .foregroundStyle(.white)
                                    .font(.title2)
                            }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Attributes") {
                Picker("Category", selection: Bindable(viewModel).slot) {
                    ForEach(Slot.allCases) { slot in
                        Text(slot.rawValue.capitalized).tag(slot)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Formality Score")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.formalityScore))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Bindable(viewModel).formalityScore, in: 1.0...5.0, step: 0.5)
                    HStack {
                        Text("Casual (1.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Business (3.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Formal (5.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ColorPicker("Garment Color", selection: Binding(
                    get: { Color(hex: viewModel.primaryHex) ?? .white },
                    set: { newColor in
                        if let hex = newColor.toHex() {
                            viewModel.primaryHex = hex
                        }
                    }
                ))

                Picker("Color Vibe", selection: Bindable(viewModel).colorCategory) {
                    ForEach(ColorVibe.allCases, id: \.self) { vibe in
                        Text(vibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag(vibe)
                    }
                }

                Picker("Undertone", selection: Bindable(viewModel).undertone) {
                    Text("Unknown").tag(Undertone?.none)
                    ForEach(Undertone.allCases, id: \.self) { tone in
                        Text(tone.rawValue.capitalized).tag(Undertone?.some(tone))
                    }
                }

                Picker("Pattern", selection: Bindable(viewModel).pattern) {
                    ForEach(GarmentPattern.allCases, id: \.self) { pat in
                        Text(pat.rawValue.capitalized).tag(pat)
                    }
                }

                Picker("Fabric Weight", selection: Bindable(viewModel).fabricWeight) {
                    ForEach(FabricWeight.allCases, id: \.self) { weight in
                        Text(weight.rawValue.capitalized).tag(weight)
                    }
                }
            }

            Section("Fit & Material") {
                TextField("Garment Subtype (e.g. Oxford Shirt)", text: Bindable(viewModel).garmentSubtype)
                TextField("Fit (e.g. Oversized, Slim, Regular)", text: Bindable(viewModel).fit)
                TextField("Silhouette (e.g. Straight, Boxy, Fitted)", text: Bindable(viewModel).silhouette)
                TextField("Material (e.g. Linen, Cotton, Denim)", text: Bindable(viewModel).material)
                TextField("Texture (e.g. Ribbed, Knit, Smooth)", text: Bindable(viewModel).texture)
            }

            Section("Description") {
                TextField("e.g. Charcoal crewneck tee in a soft cotton blend", text: Bindable(viewModel).itemDescription, axis: .vertical)
                    .lineLimit(2...4)
                if !viewModel.styleTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(viewModel.styleTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
            }

            Section("Seasonality") {
                ForEach(Season.allCases, id: \.self) { season in
                    Toggle(season.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(
                        get: { viewModel.seasonality.contains(season) },
                        set: { isSelected in
                            if isSelected {
                                if !viewModel.seasonality.contains(season) {
                                    viewModel.seasonality.append(season)
                                }
                            } else {
                                viewModel.seasonality.removeAll { $0 == season }
                            }
                        }
                    ))
                }
            }

            Button {
                Task {
                    await viewModel.saveItem()
                }
            } label: {
                Text("Save to Closet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
        }
    }

    private func captureSourcePicker(viewModel: AddItemViewModel) -> some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Add a garment",
                systemImage: "camera",
                description: Text("Take a photo or choose one from your library. One item per photo.")
            )

            Button {
                isCameraPresented = true
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $photoPickerItem, matching: .images) {
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
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                await viewModel.ingest(rawImageData: data)
                photoPickerItem = nil
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
    AddItemView(defaultSlot: nil)
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, ItemRating.self],
            inMemory: true
        )
}
