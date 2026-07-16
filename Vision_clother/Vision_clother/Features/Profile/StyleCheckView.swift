//
//  StyleCheckView.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste, verification tool: pick any clothing photo
//  and see whether the k-means centroids trained by `Features/SwipeDiscovery/`
//  think it matches the user's taste. Entry point is a link from
//  `Features/Profile/ProfileView.swift`, next to "Discover Your Style".
//  Ephemeral — nothing here is persisted (Features/CLAUDE.md: views never
//  touch Services directly, only through `StyleCheckViewModel`).
//

import PhotosUI
import SwiftData
import SwiftUI

struct StyleCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: StyleCheckViewModel?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var previewImageData: Data?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Test Your Style")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            viewModel = StyleCheckViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                embeddingService: ServiceFactory.makeImageEmbeddingService()
            )
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            StyleCheckCameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                submit(data, viewModel: viewModel)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                photoPickerItem = nil
                submit(data, viewModel: viewModel)
            }
        }
    }

    private func submit(_ data: Data, viewModel: StyleCheckViewModel?) {
        guard let viewModel else { return }
        previewImageData = data
        Task { await viewModel.checkPhoto(data) }
    }

    @ViewBuilder
    private func content(viewModel: StyleCheckViewModel) -> some View {
        ScrollView {
            VStack(spacing: VCSpacing.lg) {
                Text("Upload a photo of a clothing item and we'll check it against what your swipes and ratings have taught the model so far.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let previewImageData, let uiImage = UIImage(data: previewImageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(VCRadius.shape(VCRadius.card))
                        .vcShadow()
                }

                switch viewModel.state {
                case .idle:
                    EmptyView()
                case .analyzing:
                    ProgressView("Analyzing…")
                        .padding(.vertical, VCSpacing.md)
                case .result(let result):
                    StyleCheckResultCard(result: result)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                pickerButtons(viewModel: viewModel)
            }
            .padding(VCSpacing.lg)
        }
    }

    private func pickerButtons(viewModel: StyleCheckViewModel) -> some View {
        VStack(spacing: VCSpacing.sm) {
            Button {
                isCameraPresented = true
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())

            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Label(previewImageData == nil ? "Choose from Library" : "Try Another Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

// MARK: - Result card

private struct StyleCheckResultCard: View {
    let result: StyleCheckResult

    private var icon: String {
        switch result.verdict {
        case .matchesStyle: return "heart.fill"
        case .notYourStyle: return "hand.thumbsdown.fill"
        case .mixedSignals: return "questionmark.circle.fill"
        case .notEnoughData: return "hourglass"
        }
    }

    private var tint: Color {
        switch result.verdict {
        case .matchesStyle: return .green
        case .notYourStyle: return .red
        case .mixedSignals: return .secondary
        case .notEnoughData: return .secondary
        }
    }

    private var headline: String {
        switch result.verdict {
        case .matchesStyle: return "Looks like your style"
        case .notYourStyle: return "Not really your style"
        case .mixedSignals: return "Mixed signals"
        case .notEnoughData: return "Not enough data yet"
        }
    }

    private var caption: String {
        switch result.verdict {
        case .matchesStyle: return "This is close to what you've been liking on the swipe deck."
        case .notYourStyle: return "This is closer to what you've been passing on."
        case .mixedSignals: return "No strong pull either way based on what's been learned so far."
        case .notEnoughData: return "Swipe through a few photos in \u{201C}Discover Your Style\u{201D} first, so there's something to compare against."
        }
    }

    var body: some View {
        VStack(spacing: VCSpacing.md) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(tint)

            VStack(spacing: VCSpacing.xs) {
                Text(headline)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let detail = result.detail {
                VStack(spacing: VCSpacing.xs) {
                    numberRow(label: "Match to things you like", value: detail.likedSimilarity)
                    numberRow(label: "Match to things you dislike", value: detail.dislikedSimilarity)
                    Divider()
                    numberRow(label: "Net score", value: detail.bonus)
                }
                .padding(.top, VCSpacing.xs)
            }

            if !result.isTrained {
                Text("Based on early signal — \(Int((result.calibrationProgress * 100).rounded()))% calibrated so far.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(VCSpacing.lg)
        .premiumCard()
    }

    private func numberRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.2f", value))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

/// Thin `UIImagePickerController` wrapper — mirrors `AddItemView`'s and
/// `ProfileView`'s per-screen camera-capture wrappers (this codebase's
/// established pattern; there is no shared camera component).
private struct StyleCheckCameraCaptureView: UIViewControllerRepresentable {
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
    NavigationStack {
        StyleCheckView()
    }
    .modelContainer(
        for: [
            WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self,
            SavedCombination.self, ItemRating.self, UserStyleProfile.self,
            SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
        ],
        inMemory: true
    )
}
