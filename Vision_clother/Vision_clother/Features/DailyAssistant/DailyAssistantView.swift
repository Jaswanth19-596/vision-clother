//
//  DailyAssistantView.swift
//  Vision_clother
//
//  Tab 1: Daily Assistant / Core Workspace (PRD.md §4).
//

import SwiftUI
import SwiftData

struct DailyAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: DailyAssistantViewModel?
    @State private var selectedOutfitID: OutfitCombination.ID?
    @State private var isTryOnSheetPresented = false
    @State private var isRateOutfitSheetPresented = false
    @State private var ratingSheetItems: [WardrobeItem] = []
    /// Privacy opt-out (PRD §3.8) — backed by the same key
    /// `RecommendationSettings.useAIRecommendations` reads, so toggling here
    /// takes effect on the next `requestOutfitIdeas()` call without any
    /// extra plumbing between the view and the view model.
    @AppStorage("com.visionclother.useAIRecommendations") private var useAIRecommendations = true

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Daily Assistant")
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = DailyAssistantViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                intentService: ServiceFactory.makeIntentExtractionService(),
                tryOnService: ServiceFactory.makeTryOnRenderService(),
                photoLibrarySaver: ServiceFactory.makePhotoLibrarySaver(),
                recommendationService: ServiceFactory.makeOutfitRecommendationService(),
                weatherProvider: ServiceFactory.makeWeatherProvider(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService()
            )
        }
    }

    @ViewBuilder
    private func content(viewModel: DailyAssistantViewModel) -> some View {
        VStack(spacing: 16) {
            promptInput(viewModel: viewModel)

            switch viewModel.extractionState {
            case .idle where viewModel.candidates.isEmpty:
                Spacer()
                ContentUnavailableView(
                    "What are you dressing for today?",
                    systemImage: "sparkles",
                    description: Text("Describe the occasion above and tap Get Outfit Ideas.")
                )
                Spacer()

            case .loading:
                Spacer()
                ProgressView("Thinking through your closet…")
                Spacer()

            case .failed(let message):
                Spacer()
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await viewModel.requestOutfitIdeas() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()

            case .idle:
                carousel(viewModel: viewModel)
            }
        }
        .padding(.top)
        .sheet(isPresented: $isTryOnSheetPresented, onDismiss: {
            // Item Rating & Preference Learning: if the try-on sheet closes
            // after a successful save, prompt to rate the outfit's real
            // items. Capturing into local state (and clearing the view
            // model's copy) means re-opening try-on without a fresh save
            // won't show the prompt again.
            guard !viewModel.lastSavedRatableItems.isEmpty else { return }
            ratingSheetItems = viewModel.lastSavedRatableItems
            viewModel.clearRatablePrompt()
            isRateOutfitSheetPresented = true
        }) {
            TryOnResultView(
                state: viewModel.tryOnState,
                onCancel: {
                    viewModel.cancelTryOn()
                    isTryOnSheetPresented = false
                },
                onRetry: { viewModel.retryTryOn(baseImageData: placeholderBaseImageData) },
                onSave: { Task { await viewModel.saveCombination() } },
                onDone: { isTryOnSheetPresented = false }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isRateOutfitSheetPresented) {
            RateOutfitView(items: ratingSheetItems)
        }
    }

    private func promptInput(viewModel: DailyAssistantViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "What are you dressing for today?",
                text: Binding(get: { viewModel.prompt }, set: { viewModel.prompt = $0 }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)

            Button("Get Outfit Ideas") {
                Task { await viewModel.requestOutfitIdeas() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.extractionState == .loading || viewModel.prompt.trimmingCharacters(in: .whitespaces).isEmpty)

            // Privacy opt-out (PRD §3.8): off sends nothing off-device for
            // recommendations — no wardrobe catalog, no style profile — and
            // uses only the deterministic engine.
            Toggle("AI-personalized recommendations", isOn: $useAIRecommendations)
                .font(.caption)
                .tint(.accentColor)
        }
        .padding(.horizontal)
    }

    private func carousel(viewModel: DailyAssistantViewModel) -> some View {
        VStack {
            TabView(selection: $selectedOutfitID) {
                ForEach(viewModel.candidates) { outfit in
                    OutfitCardView(outfit: outfit)
                        .tag(Optional(outfit.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .onAppear { selectedOutfitID = viewModel.candidates.first?.id }

            if let selected = viewModel.candidates.first(where: { $0.id == selectedOutfitID }) {
                Button("How does it look on me?") {
                    viewModel.startTryOn(baseImageData: placeholderBaseImageData, outfit: selected)
                    isTryOnSheetPresented = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .padding(.bottom)
            }
        }
    }

    /// PRD §3.5's try-on pipeline expects the user's base portrait, now
    /// captured via Manual Outfit Pairing (Services/UserPortraitStorage.swift).
    /// Falls back to an empty placeholder if the user hasn't captured one
    /// yet — the render will simply fail with a network/decoding error in
    /// that case rather than crash.
    private var placeholderBaseImageData: Data {
        UserPortraitStorage.load() ?? Data()
    }
}

#Preview {
    DailyAssistantView()
        .modelContainer(
            for: [WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self],
            inMemory: true
        )
}
