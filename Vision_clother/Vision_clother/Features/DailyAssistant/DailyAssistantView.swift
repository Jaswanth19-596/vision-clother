//
//  DailyAssistantView.swift
//  Vision_clother
//
//  Tab 1: Daily Assistant / Core Workspace (PRD.md §4).
//
//  Renders `DailyAssistantViewModel.rounds` as a chat timeline — the user's
//  messages, clarifying questions, and outfit results all stay visible as
//  the conversation continues (Stylist Intelligence Engine ADR, Phase 2
//  addendum: Conversational Refinement Loop). Only the latest outfits round
//  renders its carousel expanded by default; earlier rounds collapse to a
//  one-line summary that expands in place on tap.
//

import SwiftUI
import SwiftData

struct DailyAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(JobQueueStore.self) private var jobQueueStore
    @State private var viewModel: DailyAssistantViewModel?
    /// Which historical (non-latest) outfits rounds the user has manually
    /// expanded back open — the latest round is always expanded regardless
    /// of membership here.
    @State private var expandedRoundIDs: Set<UUID> = []
    /// Privacy opt-out (PRD §3.8) — backed by the same key
    /// `RecommendationSettings.useAIRecommendations` reads, so toggling here
    /// takes effect on the next `requestOutfitIdeas()` call without any
    /// extra plumbing between the view and the view model.
    @AppStorage("com.visionclother.useAIRecommendations") private var useAIRecommendations = true
    @FocusState private var isPromptFocused: Bool

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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    JobQueueBadgeButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let viewModel, !viewModel.rounds.isEmpty {
                        Button {
                            viewModel.resetConversation()
                            expandedRoundIDs.removeAll()
                        } label: {
                            Label("New", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = DailyAssistantViewModel(
                repository: SwiftDataWardrobeRepository(modelContext: modelContext),
                jobQueueStore: jobQueueStore,
                intentService: ServiceFactory.makeIntentExtractionService(),
                recommendationService: ServiceFactory.makeOutfitRecommendationService(),
                weatherProvider: ServiceFactory.makeWeatherProvider(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService()
            )
        }
    }

    @ViewBuilder
    private func content(viewModel: DailyAssistantViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if viewModel.rounds.isEmpty, viewModel.extractionState == .idle {
                        ContentUnavailableView(
                            "What are you dressing for today?",
                            systemImage: "sparkles",
                            description: Text("Describe the occasion below and tap Get Outfit Ideas.")
                        )
                        .frame(minHeight: 300)
                    }

                    ForEach(Array(viewModel.rounds.enumerated()), id: \.element.id) { index, round in
                        roundView(round: round, isLatest: index == viewModel.rounds.count - 1, viewModel: viewModel)
                            .id(round.id)
                    }

                    statusView(viewModel: viewModel)
                        .id("status")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { isPromptFocused = false }
            .onChange(of: viewModel.rounds.count) { _, _ in
                withAnimation { proxy.scrollTo("status", anchor: .bottom) }
            }
            .onChange(of: viewModel.extractionState) { _, _ in
                withAnimation { proxy.scrollTo("status", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            promptInput(viewModel: viewModel)
                .background(.bar)
        }
    }

    /// One round of the timeline: the user's message, trailing-aligned,
    /// followed by the assistant's side — either the clarifying
    /// question+chips or the outfit carousel, leading-aligned.
    @ViewBuilder
    private func roundView(
        round: DailyAssistantViewModel.ConversationRound,
        isLatest: Bool,
        viewModel: DailyAssistantViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            userBubble(round.userText)

            switch round.outcome {
            case .clarification(let followUpText, let chips):
                if isLatest, isAwaitingClarification(viewModel) {
                    ClarificationChipsView(
                        followUpText: followUpText,
                        chips: chips,
                        onSelectChip: { chip in
                            isPromptFocused = false
                            Task { await viewModel.continueConversation(with: chip) }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Already answered — shown as a plain, non-interactive
                    // record of what was asked, not a live prompt.
                    Label(followUpText, systemImage: "bubble.left.and.text.bubble.right")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .outfits(let outfits):
                OutfitsRoundView(
                    outfits: outfits,
                    isExpanded: isLatest || expandedRoundIDs.contains(round.id),
                    isLatest: isLatest,
                    onToggleExpanded: {
                        if expandedRoundIDs.contains(round.id) {
                            expandedRoundIDs.remove(round.id)
                        } else {
                            expandedRoundIDs.insert(round.id)
                        }
                    },
                    onStartTryOn: { outfit in
                        viewModel.startTryOn(baseImageData: placeholderBaseImageData, outfit: outfit)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The current in-flight status, trailing the timeline — loading
    /// spinner or a failed-with-Retry row. Idle/awaiting-clarification need
    /// nothing extra here since the latest round already shows it.
    @ViewBuilder
    private func statusView(viewModel: DailyAssistantViewModel) -> some View {
        switch viewModel.extractionState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking through your closet…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.retryLastTurn() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .idle, .awaitingClarification:
            EmptyView()
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
            .onSubmit { submit(viewModel: viewModel) }

            Button(viewModel.rounds.isEmpty ? "Get Outfit Ideas" : "Send") {
                submit(viewModel: viewModel)
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
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Routes the prompt field's submit/button through whichever entry
    /// point matches the current conversation state — starting a fresh
    /// topic when there's no round yet, otherwise continuing the same
    /// conversation (a clarification reply or a post-result refinement read
    /// identically from here). The field is cleared by the ViewModel itself
    /// once it has captured the text (see `requestOutfitIdeas`/
    /// `continueConversation`), not here — clearing `viewModel.prompt`
    /// before the `async` call starts would empty it out from under
    /// `requestOutfitIdeas()`'s own read of `prompt`.
    private func submit(viewModel: DailyAssistantViewModel) {
        guard viewModel.extractionState != .loading,
              !viewModel.prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isPromptFocused = false
        if viewModel.rounds.isEmpty {
            Task { await viewModel.requestOutfitIdeas() }
        } else {
            let text = viewModel.prompt
            Task { await viewModel.continueConversation(with: text) }
        }
    }

    private func isAwaitingClarification(_ viewModel: DailyAssistantViewModel) -> Bool {
        if case .awaitingClarification = viewModel.extractionState { return true }
        return false
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

/// One outfits round's presentation: collapsed to a one-line summary when
/// it's an earlier round the user hasn't re-expanded, otherwise the full
/// paged carousel + try-on action — identical for the live round and any
/// manually re-expanded historical round. Owns its own page-selection/
/// try-on-queued state since each round's carousel is independent.
private struct OutfitsRoundView: View {
    let outfits: [OutfitCombination]
    let isExpanded: Bool
    let isLatest: Bool
    let onToggleExpanded: () -> Void
    let onStartTryOn: (OutfitCombination) -> Void

    @State private var selectedOutfitID: OutfitCombination.ID?
    @State private var justQueuedTryOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isLatest {
                Button(action: onToggleExpanded) {
                    Label(
                        isExpanded ? "Hide these outfits" : "\(outfits.count) outfit idea\(outfits.count == 1 ? "" : "s") — tap to view",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if isExpanded {
                // `OutfitCardView` already scrolls its own content
                // internally, so a moderate fixed height (rather than a
                // GeometryReader-derived one) is sufficient here — this
                // view sits inside the timeline's own ScrollView, not a
                // single full-screen carousel.
                TabView(selection: $selectedOutfitID) {
                    ForEach(outfits) { outfit in
                        OutfitCardView(outfit: outfit)
                            .tag(Optional(outfit.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: 460)
                .onAppear { selectedOutfitID = outfits.first?.id }

                if let selected = outfits.first(where: { $0.id == selectedOutfitID }) {
                    Button {
                        onStartTryOn(selected)
                        justQueuedTryOn = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            justQueuedTryOn = false
                        }
                    } label: {
                        if justQueuedTryOn {
                            Label("Added to queue", systemImage: "checkmark")
                        } else {
                            Text("How does it look on me?")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(justQueuedTryOn)
                }
            }
        }
        .padding()
        .background(isLatest ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    DailyAssistantView()
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
