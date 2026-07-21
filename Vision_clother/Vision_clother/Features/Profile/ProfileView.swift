//
//  ProfileView.swift
//  Vision_clother
//
//  Tab 3: the user's Profile — account sign-in/out (`AccountCardView`), their
//  own photo (captured here; moved from
//  Features/Pairing/ManualPairingView.swift, which now only reads it), and
//  entry points into the swipe-discovery/style-check tools and the Insights
//  tab. Computed taste/style analytics (color affinity, formality mix, best
//  pairings, activity — PRD.md §4) live in the Insights tab now, not here —
//  this view only links to it, to avoid showing the same derived data twice.
//  See Features/Profile/CLAUDE.md.
//

import PhotosUI
import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    /// Account-switch reactivity: `viewModel` is constructed once for this
    /// tab's lifetime (SwiftUI's plain `TabView` keeps every tab alive), so
    /// nothing else tells it to re-read the portrait after a later account
    /// switch — see `Data/WardrobeSyncCoordinator.swift`'s file header and
    /// `ProfileViewModel.refreshPortrait()`'s doc comment. Reads
    /// `viewModel.uid` (mirrored from `AuthService.shared`) rather than
    /// holding its own `@ObservedObject AuthService.shared` — see
    /// `ProfileViewModel`'s `uid` doc comment.
    @Environment(WardrobeSyncCoordinator.self) private var syncCoordinator
    @Query private var styleProfiles: [UserStyleProfile]

    @State private var viewModel: ProfileViewModel?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isSettingsPresented = false

    /// Single-row profile (PRD §3.8) — `Data/WardrobeRepository.swift`'s
    /// `saveUserProfile` guarantees at most one row exists.
    private var styleProfile: UserStyleProfile? { styleProfiles.first }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("Account Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            let vm = ProfileViewModel(
                repository: SyncingWardrobeRepository(modelContext: modelContext),
                validationService: ServiceFactory.makePersonPhotoValidationService(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService()
            )
            vm.refreshFeedbackHistory()
            viewModel = vm
        }
        .onAppear {
            viewModel?.refreshFeedbackHistory()
            viewModel?.refreshPortrait()
        }
        .onChange(of: viewModel?.uid) { _, _ in
            viewModel?.refreshPortrait()
        }
        .onChange(of: syncCoordinator.photoRefreshTick) { _, _ in
            viewModel?.refreshPortrait()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            PortraitCameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                viewModel?.savePortrait(data)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                List {
                    AccountSectionView()
                }
                .navigationTitle("Account")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { isSettingsPresented = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: ProfileViewModel) -> some View {
        List {
            AccountCardView()
            identitySection(viewModel: viewModel)
            swipeDiscoverySection
            styleCheckSection
            insightsLinkSection
        }
    }

    // MARK: - Identity header

    @ViewBuilder
    private func identitySection(viewModel: ProfileViewModel) -> some View {
        Section {
            VStack(spacing: 16) {
                portraitImage(viewModel: viewModel)

                HStack {
                    Button {
                        isCameraPresented = true
                    } label: {
                        Label(viewModel.hasPortrait ? "Retake Photo" : "Take Photo", systemImage: "camera")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if !viewModel.isUsingDefaultBodyPhoto {
                    Button {
                        viewModel.useDefaultBodyPhoto()
                    } label: {
                        Label("Use Default Image Instead", systemImage: "figure.stand")
                            .font(.caption)
                    }
                }

                if viewModel.isValidatingPhoto {
                    Label("Checking your photo…", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let photoUploadError = viewModel.photoUploadError {
                    Text(photoUploadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                identityFacts(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                viewModel.savePortrait(data)
                photoPickerItem = nil
            }
        }
    }

    @ViewBuilder
    private func portraitImage(viewModel: ProfileViewModel) -> some View {
        Group {
            if let data = viewModel.portraitImageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "person.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 2))
    }

    @ViewBuilder
    private func identityFacts(viewModel: ProfileViewModel) -> some View {
        VStack(spacing: 8) {
            if viewModel.isUsingDefaultBodyPhoto {
                Text("Using the default image — add your own photo to build your personal color and style profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let styleProfile {
                if !styleProfile.styleKeywords.isEmpty {
                    Text(styleProfile.styleKeywords.joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                }
                HStack(spacing: 24) {
                    factPill(label: "Undertone", value: styleProfile.undertone.rawValue.capitalized)
                    factPill(label: "Body Type", value: styleProfile.bodyType)
                }
            } else if !viewModel.hasPortrait {
                Text("Add a photo to build your personal color and style profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch viewModel.derivationState {
            case .deriving:
                Label("Analyzing your style…", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                VStack(spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { viewModel.retryDerivation() }
                        .font(.caption)
                }
            case .idle:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
    }

    private func factPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Discover Your Style (Swipe-to-Learn Visual Taste)

    private var swipeDiscoverySection: some View {
        Section {
            NavigationLink {
                SwipeDiscoveryView()
            } label: {
                Label("Discover Your Style", systemImage: "hand.draw.fill")
            }
        } footer: {
            Text("Swipe through outfit photos — liking and disliking looks helps us fine-tune your recommendations.")
        }
    }

    // MARK: - Test Your Style (manual model-verification tool)

    private var styleCheckSection: some View {
        Section {
            NavigationLink {
                StyleCheckView()
            } label: {
                Label("Test Your Style", systemImage: "checkmark.seal")
            }
        } footer: {
            Text("Upload a photo of any clothing item to see whether it matches what we've learned you like so far.")
        }
    }

    // MARK: - See your taste analytics in Insights

    /// Taste/style analytics (color affinity, formality mix, best pairings,
    /// activity, etc.) moved to the Insights tab — this points there instead
    /// of duplicating that computed data here. See Features/Profile/CLAUDE.md.
    private var insightsLinkSection: some View {
        Section {
            NavigationLink {
                InsightsView()
            } label: {
                Label("View Your Style Insights", systemImage: "chart.bar.xaxis")
            }
        } footer: {
            Text("Your taste breakdown, color affinities, and closet trends live in the Insights tab.")
        }
    }
}

/// Thin `UIImagePickerController` wrapper for the user's own photo — moved
/// here from `Features/Pairing/ManualPairingView.swift`, which now only
/// reads the portrait this screen manages.
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
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self,
        SavedCombination.self, ItemRating.self, UserStyleProfile.self,
        SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    ProfileView()
        .modelContainer(container)
        .environment(WardrobeSyncCoordinator(modelContext: container.mainContext, syncService: MockWardrobeSyncService()))
        .environment(UsageTracker(
            repository: SyncingWardrobeRepository(modelContext: container.mainContext),
            syncService: MockWardrobeSyncService(),
            entitlementLimitsService: MockEntitlementLimitsService()
        ))
}
