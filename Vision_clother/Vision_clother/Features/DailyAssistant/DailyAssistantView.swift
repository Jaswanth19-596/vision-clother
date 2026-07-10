//
//  DailyAssistantView.swift
//  Vision_clother
//
//  Tab 1: Daily Assistant / Core Workspace (PRD.md §4).
//

import SwiftUI
import SwiftData

/// One sheet modifier for both the try-on result and the follow-up rating
/// prompt — chaining two separate `.sheet` modifiers on the same view (the
/// prior design) is a known SwiftUI footgun where presenting the second
/// sheet from the first's `onDismiss` can render against stale state. A
/// single `.sheet(item:)` switching over this enum avoids that entirely.
private enum ActiveSheet: Identifiable {
    case tryOn
    case rateOutfit([WardrobeItem])

    var id: String {
        switch self {
        case .tryOn: return "tryOn"
        case .rateOutfit: return "rateOutfit"
        }
    }
}

struct DailyAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: DailyAssistantViewModel?
    @State private var selectedOutfitID: OutfitCombination.ID?
    @State private var activeSheet: ActiveSheet?
    /// Privacy opt-out (PRD §3.8) — backed by the same key
    /// `RecommendationSettings.useAIRecommendations` reads, so toggling here
    /// takes effect on the next `requestOutfitIdeas()` call without any
    /// extra plumbing between the view and the view model.
    @AppStorage("com.visionclother.useAIRecommendations") private var useAIRecommendations = true
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if let viewModel {
                        content(viewModel: viewModel, availableHeight: geometry.size.height)
                    } else {
                        ProgressView()
                    }
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
    private func content(viewModel: DailyAssistantViewModel, availableHeight: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                promptInput(viewModel: viewModel)

                switch viewModel.extractionState {
                case .idle where viewModel.candidates.isEmpty:
                    ContentUnavailableView(
                        "What are you dressing for today?",
                        systemImage: "sparkles",
                        description: Text("Describe the occasion above and tap Get Outfit Ideas.")
                    )
                    .frame(minHeight: 400)

                case .loading:
                    ProgressView("Thinking through your closet…")
                        .frame(minHeight: 400)

                case .failed(let message):
                    VStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await viewModel.requestOutfitIdeas() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 400)

                case .idle:
                    // `TabView(.page)` has no intrinsic height once it's inside a
                    // `ScrollView` (both are scrollable-content containers, so
                    // neither can size to the other) — without an explicit
                    // height it collapses to near-zero and clips every card.
                    // `availableHeight` (the screen's Geometry) minus the
                    // roughly fixed height of the prompt controls above gives
                    // it a sensible size; `OutfitCardView` scrolls internally
                    // as a fallback if a card's content still exceeds it.
                    carousel(viewModel: viewModel, height: max(availableHeight - 260, 420))
                }
            }
            .padding(.top)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            isPromptFocused = false
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tryOn:
                TryOnResultView(
                    state: viewModel.tryOnState,
                    onCancel: {
                        viewModel.cancelTryOn()
                        activeSheet = nil
                    },
                    onRetry: { viewModel.retryTryOn(baseImageData: placeholderBaseImageData) },
                    onSave: { await viewModel.saveCombination() },
                    onDone: {
                        // Item Rating & Preference Learning: if the save
                        // that just finished produced real (non-ghost)
                        // items, hand off straight to the rating sheet —
                        // `onSave` is awaited by `TryOnResultView` before
                        // "Done" is even enabled, so `lastSavedRatableItems`
                        // is guaranteed settled here. Switching the same
                        // `activeSheet` value (rather than chaining a second
                        // `.sheet` modifier's `onDismiss`) avoids the stale
                        // -state footgun that caused the item-rating sheet
                        // to spin forever with nothing loaded.
                        if !viewModel.lastSavedRatableItems.isEmpty {
                            let items = viewModel.lastSavedRatableItems
                            viewModel.clearRatablePrompt()
                            activeSheet = .rateOutfit(items)
                        } else {
                            activeSheet = nil
                        }
                    }
                )
                .presentationDetents([.medium, .large])

            case .rateOutfit(let items):
                RateOutfitView(items: items)
            }
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
            .focused($isPromptFocused)
            .submitLabel(.search)
            .onSubmit {
                isPromptFocused = false
                Task { await viewModel.requestOutfitIdeas() }
            }

            Button("Get Outfit Ideas") {
                isPromptFocused = false
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

    private func carousel(viewModel: DailyAssistantViewModel, height: CGFloat) -> some View {
        VStack {
            TabView(selection: $selectedOutfitID) {
                ForEach(viewModel.candidates) { outfit in
                    OutfitCardView(outfit: outfit)
                        .tag(Optional(outfit.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: height)
            .onAppear { selectedOutfitID = viewModel.candidates.first?.id }

            if let selected = viewModel.candidates.first(where: { $0.id == selectedOutfitID }) {
                Button("How does it look on me?") {
                    viewModel.startTryOn(baseImageData: placeholderBaseImageData, outfit: selected)
                    activeSheet = .tryOn
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
