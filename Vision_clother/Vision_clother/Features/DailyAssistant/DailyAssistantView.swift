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
import PhotosUI

struct DailyAssistantView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(JobQueueStore.self) private var jobQueueStore
    /// Quota visibility feature (`Data/UsageTracker.swift`) — live
    /// recommendation/combination captions + proactive disable, see
    /// `promptInput`/`prospectivePurchaseInput`/`roundView`.
    @Environment(UsageTracker.self) private var usageTracker
    /// Account-switch reactivity: `viewModel` is constructed once for this
    /// tab's lifetime (SwiftUI's plain `TabView` keeps every tab alive), so
    /// without this the chat timeline from the previous account would just
    /// keep showing after switching — see
    /// `Data/WardrobeSyncCoordinator.swift`'s file header. Reads
    /// `viewModel.uid`/`.isAnonymous` (mirrored from `AuthService.shared`)
    /// rather than holding its own `@ObservedObject AuthService.shared` —
    /// see `DailyAssistantViewModel.bindAuthState()`'s doc comment.
    @State private var viewModel: DailyAssistantViewModel?
    /// Which historical (non-latest) outfits rounds the user has manually
    /// expanded back open — the latest round is always expanded regardless
    /// of membership here.
    @State private var expandedRoundIDs: Set<UUID> = []
    @FocusState private var isPromptFocused: Bool
    /// Ticks once per submit tap — drives the send/get-outfit-ideas
    /// critical-action haptic without firing on unrelated state changes.
    @State private var sendTick = 0
    /// Shown instead of enqueuing a try-on when no base portrait has been
    /// captured yet — without this, `placeholderBaseImageData` falls back to
    /// empty `Data()` and the render request fails downstream with an opaque
    /// "Invalid image data-url" error from the render API.
    @State private var isMissingPortraitAlertPresented = false
    /// Guest-first quota plan: try-on requires a linked account
    /// (`backend/functions/src/middleware/quota.ts`'s `tryOn` cap is 0 for
    /// guests) — this pre-flight guard avoids a round trip to the proxy just
    /// to get the same 403 back. Checked before the portrait check below so
    /// a guest sees "sign in" rather than "add a photo" first.
    @State private var isGuestTryOnAlertPresented = false

    // Prospective Purchase Evaluation (2026-07-15) — "Buying something new?"
    // photo attach state, live only while `viewModel.isProspectivePurchaseMode`
    // is on and no photo has been attached yet.
    @State private var isProspectiveCameraPresented = false
    @State private var prospectivePhotoPickerItem: PhotosPickerItem?

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
                repository: SyncingWardrobeRepository(modelContext: modelContext),
                jobQueueStore: jobQueueStore,
                recommendationService: ServiceFactory.makeOutfitRecommendationService(),
                weatherProvider: ServiceFactory.makeWeatherProvider(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService(),
                usageTracker: usageTracker
            )
        }
        .onChange(of: viewModel?.uid) { _, _ in
            viewModel?.resetConversation()
            expandedRoundIDs.removeAll()
        }
        .alert("Add a photo first", isPresented: $isMissingPortraitAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Add a photo of yourself on your Profile tab to try on outfits.")
        }
        .alert("Sign in to try this on", isPresented: $isGuestTryOnAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try-on rendering needs a linked account. Sign in on your Profile tab — your closet comes with you.")
        }
        .fullScreenCover(isPresented: $isProspectiveCameraPresented) {
            CameraCaptureView { data in
                isProspectiveCameraPresented = false
                guard let data else { return }
                viewModel?.attachedProspectiveImageData = data
            }
            .ignoresSafeArea()
        }
        .onChange(of: prospectivePhotoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    viewModel?.attachedProspectiveImageData = data
                }
                prospectivePhotoPickerItem = nil
            }
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
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.bottom, 8, for: .scrollContent)
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
                    assistantRow {
                        ClarificationChipsView(
                            followUpText: followUpText,
                            chips: chips,
                            onSelectChip: { chip in
                                isPromptFocused = false
                                Task { await viewModel.continueConversation(with: chip) }
                            }
                        )
                    }
                } else {
                    // Already answered — shown as a plain, non-interactive
                    // record of what was asked, not a live prompt.
                    assistantRow {
                        Label(followUpText, systemImage: "bubble.left.and.text.bubble.right")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .premiumCard()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

            case .outfits(let outfits):
                assistantRow {
                    OutfitsRoundView(
                        outfits: outfits,
                        isExpanded: isLatest || expandedRoundIDs.contains(round.id),
                        isLatest: isLatest,
                        isAnonymous: viewModel.isAnonymous,
                        combinationsRemaining: usageTracker.combinationsRemaining,
                        onToggleExpanded: {
                            if expandedRoundIDs.contains(round.id) {
                                expandedRoundIDs.remove(round.id)
                            } else {
                                expandedRoundIDs.insert(round.id)
                            }
                        },
                        onStartTryOn: { outfit in
                            guard !viewModel.isAnonymous else {
                                isGuestTryOnAlertPresented = true
                                return
                            }
                            guard UserPortraitStorage.exists else {
                                isMissingPortraitAlertPresented = true
                                return
                            }
                            viewModel.startTryOn(baseImageData: placeholderBaseImageData, outfit: outfit)
                        }
                    )
                }

            case .purchaseCheck(let item, let outfits, let note):
                assistantRow {
                    PurchaseCheckRoundView(
                        item: item,
                        outfits: outfits,
                        note: note,
                        isExpanded: isLatest || expandedRoundIDs.contains(round.id),
                        isLatest: isLatest,
                        isAnonymous: viewModel.isAnonymous,
                        combinationsRemaining: usageTracker.combinationsRemaining,
                        onToggleExpanded: {
                            if expandedRoundIDs.contains(round.id) {
                                expandedRoundIDs.remove(round.id)
                            } else {
                                expandedRoundIDs.insert(round.id)
                            }
                        },
                        onStartTryOn: { outfit in
                            guard !viewModel.isAnonymous else {
                                isGuestTryOnAlertPresented = true
                                return
                            }
                            guard UserPortraitStorage.exists else {
                                isMissingPortraitAlertPresented = true
                                return
                            }
                            viewModel.startTryOn(baseImageData: placeholderBaseImageData, outfit: outfit)
                        },
                        onAddToCloset: { viewModel.addProspectiveItemToCloset(item) },
                        onDiscard: { viewModel.discardProspectiveItem(item) }
                    )
                }
            }
        }
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor, in: VCRadius.shape(VCRadius.card))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Leading circular glyph + assistant-side content, giving the
    /// assistant a distinct visual identity from the accent-filled user
    /// bubble rather than an anonymous card floating in the timeline.
    private func assistantRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: VCSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(VCAccentColor.brand)
                .frame(width: 28, height: 28)
                .background(.thinMaterial, in: Circle())

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .idle, .awaitingClarification:
            EmptyView()
        }
    }

    private func promptInput(viewModel: DailyAssistantViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Buying something new?",
                    isOn: Binding(
                        get: { viewModel.isProspectivePurchaseMode },
                        set: { newValue in
                            viewModel.isProspectivePurchaseMode = newValue
                            if !newValue { viewModel.attachedProspectiveImageData = nil }
                        }
                    )
                )
                .font(.subheadline)
                .disabled(viewModel.extractionState == .loading)

                if viewModel.isProspectivePurchaseMode {
                    prospectivePurchaseInput(viewModel: viewModel)
                } else {
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

                    recommendationQuotaCaption

                    Button(viewModel.rounds.isEmpty ? "Get Outfit Ideas" : "Send") {
                        submit(viewModel: viewModel)
                        sendTick += 1
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(
                        viewModel.extractionState == .loading
                        || viewModel.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                        || usageTracker.recommendationsRemaining <= 0
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
    }

    /// Replaces the free-text prompt entirely while "Buying something new?"
    /// is on — Prospective Purchase Evaluation is a fixed, no-scenario-text
    /// evaluation (see `DailyAssistantViewModel.checkProspectiveItem`), so
    /// the only input this needs is the photo itself.
    @ViewBuilder
    private func prospectivePurchaseInput(viewModel: DailyAssistantViewModel) -> some View {
        if let imageData = viewModel.attachedProspectiveImageData, let uiImage = UIImage(data: imageData) {
            HStack(spacing: 12) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(VCRadius.shape(VCRadius.swatch))

                Button("Choose a different photo") {
                    viewModel.attachedProspectiveImageData = nil
                }
                .font(.footnote)
                .buttonStyle(SecondaryButtonStyle())

                Spacer()
            }

            recommendationQuotaCaption

            Button("Check This Item") {
                Task { await viewModel.checkProspectiveItem() }
                sendTick += 1
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(viewModel.extractionState == .loading || usageTracker.recommendationsRemaining <= 0)
        } else {
            HStack(spacing: 12) {
                Button {
                    isProspectiveCameraPresented = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                PhotosPicker(selection: $prospectivePhotoPickerItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
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

    /// Quota visibility feature — shown above both the free-text and
    /// prospective-purchase submit buttons, which both spend one
    /// `recommendationCount` unit per call (`DailyAssistantViewModel`'s
    /// `resolveOutfits`/`resolveProspectivePurchase`).
    @ViewBuilder
    private var recommendationQuotaCaption: some View {
        if usageTracker.recommendationsRemaining <= 0 {
            Text(usageTracker.isAnonymousQuota
                 ? "You've used all your recommendations this month. Sign in for more."
                 : "You've used all your recommendations this month. Resets next month.")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("\(usageTracker.recommendationsRemaining) recommendation\(usageTracker.recommendationsRemaining == 1 ? "" : "s") left this month")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One outfits round's presentation: collapsed to a one-line summary when
/// it's an earlier round the user hasn't re-expanded, otherwise the full
/// paged carousel + try-on action — identical for the live round and any
/// manually re-expanded historical round. Owns its own page-selection/
/// try-on-queued state since each round's carousel is independent.
///
/// ⚠️ Carousel implementation note:
/// Uses `ScrollView(.horizontal)` + `scrollTargetBehavior(.viewAligned)`
/// instead of `TabView(.page)`. A paged `TabView` nested inside a vertical
/// `ScrollView` causes UIKit gesture-recogniser conflicts — the outer scroll
/// wins horizontal drags, making the carousel unswipeable, and any
/// DragGesture workaround then blocks vertical scrolling. Two orthogonal
/// `ScrollView`s negotiate gestures automatically at the UIKit level.
private struct OutfitsRoundView: View {
    let outfits: [OutfitCombination]
    let isExpanded: Bool
    let isLatest: Bool
    let isAnonymous: Bool
    let combinationsRemaining: Int
    let onToggleExpanded: () -> Void
    let onStartTryOn: (OutfitCombination) -> Void

    @State private var selectedOutfitID: OutfitCombination.ID?
    /// Permanently tracks which outfits in this round have been queued for
    /// try-on. Once an outfit is queued the button stays locked — there is
    /// no timer reset. Swiping to a different outfit shows a fresh button
    /// for that outfit if it hasn't been queued yet.
    @State private var queuedOutfitIDs: Set<OutfitCombination.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isLatest {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        onToggleExpanded()
                    }
                }) {
                    Label(
                        isExpanded ? "Hide these outfits" : "\(outfits.count) outfit idea\(outfits.count == 1 ? "" : "s") — tap to view",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if isExpanded {
                VStack(spacing: 8) {
                    // Horizontal paging carousel.
                    // `ScrollView(.horizontal)` + `scrollTargetBehavior(.viewAligned)`
                    // correctly shares gestures with the outer vertical ScrollView:
                    // horizontal drags go to this carousel, vertical drags pass
                    // through to the parent — no workarounds required.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(outfits) { outfit in
                                OutfitCardView(outfit: outfit)
                                    .containerRelativeFrame(.horizontal)
                                    .id(outfit.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.never)
                    .frame(height: 460)
                    .onScrollTargetVisibilityChange(idType: OutfitCombination.ID.self) { visible in
                        selectedOutfitID = visible.first ?? outfits.first?.id
                    }
                    .onAppear { selectedOutfitID = outfits.first?.id }

                    // Manual page-dot indicator (replaces TabView's built-in dots).
                    if outfits.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(outfits) { outfit in
                                Circle()
                                    .fill(outfit.id == selectedOutfitID
                                          ? Color.accentColor
                                          : Color.secondary.opacity(0.35))
                                    .frame(
                                        width: outfit.id == selectedOutfitID ? 8 : 6,
                                        height: outfit.id == selectedOutfitID ? 8 : 6
                                    )
                                    .animation(.spring(response: 0.25, dampingFraction: 0.7),
                                               value: selectedOutfitID)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let selected = outfits.first(where: { $0.id == selectedOutfitID }) {
                    TryOnActionButton(
                        isQueued: queuedOutfitIDs.contains(selected.id),
                        isAnonymous: isAnonymous,
                        combinationsRemaining: combinationsRemaining,
                        elevated: true
                    ) {
                        onStartTryOn(selected)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            queuedOutfitIDs.insert(selected.id)
                        }
                    }
                }
            }
        }
        .premiumCard(material: isLatest ? .thinMaterial : .ultraThinMaterial, shadow: nil)
    }
}

/// Prospective Purchase Evaluation (2026-07-15): renders the result of
/// `DailyAssistantViewModel.checkProspectiveItem()` — either the "doesn't
/// pair well" verdict (`outfits.isEmpty`) or a carousel of outfits built
/// around `item`, always followed by Add to Closet / Not Buying This
/// actions scoped to that exact item. A self-contained sibling of
/// `OutfitsRoundView` rather than a parameterized variant of it — the two
/// diverge enough (verdict state, per-item actions) that sharing would mean
/// threading optional callbacks through a view with its own well-established
/// contract, for a feature this bounded in scope.
private struct PurchaseCheckRoundView: View {
    let item: WardrobeItem
    let outfits: [OutfitCombination]
    let note: String?
    let isExpanded: Bool
    let isLatest: Bool
    let isAnonymous: Bool
    let combinationsRemaining: Int
    let onToggleExpanded: () -> Void
    let onStartTryOn: (OutfitCombination) -> Void
    let onAddToCloset: () -> Bool
    let onDiscard: () -> Void

    @State private var selectedOutfitID: OutfitCombination.ID?
    @State private var queuedOutfitIDs: Set<OutfitCombination.ID> = []
    @State private var isAdded = false
    @State private var isDiscarded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isLatest {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        onToggleExpanded()
                    }
                }) {
                    Label(
                        isExpanded ? "Hide" : summaryText,
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if isExpanded {
                if outfits.isEmpty {
                    noMatchContent
                } else {
                    matchedContent
                }

                if !isDiscarded {
                    actionRow
                } else {
                    Label("Discarded", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .premiumCard(material: isLatest ? .thinMaterial : .ultraThinMaterial, shadow: nil)
    }

    private var summaryText: String {
        outfits.isEmpty ? "Doesn't pair well — tap to view" : "Pairs with \(outfits.count) outfit\(outfits.count == 1 ? "" : "s") — tap to view"
    }

    private var noMatchContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This doesn't pair well with your current wardrobe", systemImage: "xmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var matchedContent: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(outfits) { outfit in
                        OutfitCardView(outfit: outfit, prospectiveItemID: item.id)
                            .containerRelativeFrame(.horizontal)
                            .id(outfit.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .frame(height: 460)
            .onScrollTargetVisibilityChange(idType: OutfitCombination.ID.self) { visible in
                selectedOutfitID = visible.first ?? outfits.first?.id
            }
            .onAppear { selectedOutfitID = outfits.first?.id }

            if outfits.count > 1 {
                HStack(spacing: 6) {
                    ForEach(outfits) { outfit in
                        Circle()
                            .fill(outfit.id == selectedOutfitID ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: outfit.id == selectedOutfitID ? 8 : 6, height: outfit.id == selectedOutfitID ? 8 : 6)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selectedOutfitID)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let selected = outfits.first(where: { $0.id == selectedOutfitID }) {
                TryOnActionButton(
                    isQueued: queuedOutfitIDs.contains(selected.id),
                    isAnonymous: isAnonymous,
                    combinationsRemaining: combinationsRemaining,
                    elevated: false
                ) {
                    onStartTryOn(selected)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        queuedOutfitIDs.insert(selected.id)
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { isAdded = onAddToCloset() }
            } label: {
                if isAdded {
                    Label("Added to Closet", systemImage: "checkmark")
                } else {
                    Label("Add to Closet", systemImage: "plus")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isAdded)

            Button("Not Buying This") {
                onDiscard()
                withAnimation { isDiscarded = true }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isAdded)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shared "How does it look on me?" try-on trigger for both
/// `OutfitsRoundView` and `PurchaseCheckRoundView` — quota visibility
/// feature: "combinations" is the user-facing term for a try-on render
/// (`Data/UsageTracker.swift`'s doc comment). Once queued the button stays
/// permanently locked (matches the pre-existing per-outfit queue-lock
/// behavior); otherwise it reflects whichever of "blocked" states applies —
/// guest (0 cap) takes priority over an exhausted free-tier cap, matching
/// `onStartTryOn`'s own guest-alert-first ordering at the call site.
private struct TryOnActionButton: View {
    let isQueued: Bool
    let isAnonymous: Bool
    let combinationsRemaining: Int
    /// `OutfitsRoundView`'s live/expanded card gets a drop shadow;
    /// `PurchaseCheckRoundView`'s does not — matches the pre-existing
    /// per-caller styling this button replaces.
    let elevated: Bool
    let action: () -> Void

    private var isBlocked: Bool { isAnonymous || combinationsRemaining <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                if isQueued {
                    Label("Added to queue", systemImage: "checkmark")
                } else if isAnonymous {
                    Text("Sign in to try this on")
                } else if combinationsRemaining <= 0 {
                    Text("Combination limit reached")
                } else {
                    Text("How does it look on me?")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .modifier(ConditionalElevatedShadow(isElevated: elevated))
            .disabled(isQueued || isBlocked)
            .animation(.easeInOut(duration: 0.2), value: isQueued)

            if !isQueued && !isBlocked {
                Text("\(combinationsRemaining) combination\(combinationsRemaining == 1 ? "" : "s") left this month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConditionalElevatedShadow: ViewModifier {
    let isElevated: Bool

    func body(content: Content) -> some View {
        if isElevated {
            content.vcShadow(VCShadow.elevated)
        } else {
            content
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self,
        SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let previewRepository = SyncingWardrobeRepository(modelContext: container.mainContext)
    DailyAssistantView()
        .modelContainer(container)
        .environment(JobQueueStore(
            repository: previewRepository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService(),
            usageTracker: UsageTracker(repository: previewRepository, syncService: MockWardrobeSyncService())
        ))
        .environment(UsageTracker(repository: previewRepository, syncService: MockWardrobeSyncService()))
}
