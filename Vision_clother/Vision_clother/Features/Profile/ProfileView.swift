//
//  ProfileView.swift
//  Vision_clother
//
//  Tab 3: the user's Profile — their own photo (captured here; moved from
//  Features/Pairing/ManualPairingView.swift, which now only reads it) and
//  the taste/style analytics learned from their feedback (PRD.md §4).
//  Backed by real SwiftData feedback queries from day one — persistence is
//  already in place per CLAUDE.md guardrail #3.
//
//  Preference math is unchanged from the original Style Analytics tab: this
//  is a presentation-layer redesign over the same deterministic
//  `FeedbackHistory`/`AttributePreferenceProfile` data
//  (Domain/AttributePreferenceProfile.swift, Domain/TasteSynthesis.swift) —
//  no ML, no new scoring formula.
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
    @Query private var items: [WardrobeItem]
    /// Full-history by necessity — `.count`, `mostActiveWeekdayLabel`, and
    /// `daysSinceLastRating` below are all all-time aggregates derived from
    /// this one array (weekday-mode in particular needs every row's date;
    /// SwiftData has no server-side `GROUP BY`), so there's no cheaper query
    /// shape that still answers them correctly. Bounded in practice by
    /// real-world rating cadence (at most a few outfits/day), unlike
    /// higher-volume tables (`SwipeEvent`, `RecommendationImpressionEvent`).
    @Query private var outfitFeedbacks: [OutfitFeedback]
    /// Existence-only — every other read of item ratings in this view goes
    /// through `viewModel.feedbackHistory` (already 180-day-windowed by
    /// `WardrobeRepository.fetchFeedbackHistory()`), so this only needs to
    /// answer "has the user ever rated an item," not materialize the table.
    @Query(Self.itemRatingExistenceDescriptor) private var itemRatingExistenceCheck: [ItemRating]
    @Query private var styleProfiles: [UserStyleProfile]

    private static var itemRatingExistenceDescriptor: FetchDescriptor<ItemRating> {
        var descriptor = FetchDescriptor<ItemRating>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// Segments offered by the "Colors You Wear Well" picker — matches the
    /// requested Tops/Bottoms/Shoes mockup; outerwear and the newer
    /// headwear/accessory/bag accent slots are a much smaller slice of most
    /// closets and are omitted to keep the picker to three segments.
    private static let colorAffinitySlots: [Slot] = [.top, .bottom, .footwear]
    @State private var selectedColorSlot: Slot = .top

    @State private var viewModel: ProfileViewModel?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isSettingsPresented = false

    /// Single-row profile (PRD §3.8) — `Data/WardrobeRepository.swift`'s
    /// `saveUserProfile` guarantees at most one row exists.
    private var styleProfile: UserStyleProfile? { styleProfiles.first }

    private var itemsByID: [UUID: WardrobeItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    private var tasteSignals: [TasteSignal] {
        guard let viewModel else { return [] }
        return TasteSynthesis.rank(from: viewModel.feedbackHistory.attributeProfile)
    }

    private func formalityBandLabel(_ band: Int) -> String {
        switch band {
        case ..<2: return "Casual"
        case 2...3: return "Smart-Casual"
        default: return "Formal"
        }
    }

    private func slotLabel(_ slot: Slot) -> String {
        switch slot {
        case .top: return "Tops"
        case .bottom: return "Bottoms"
        case .footwear: return "Shoes"
        case .outerwear: return "Outerwear"
        case .headwear: return "Headwear"
        case .accessory: return "Accessories"
        case .bag: return "Bags"
        }
    }

    private func vibeLabel(_ vibe: ColorVibe) -> String {
        vibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Plain-language tier for a raw affinity score — used in place of a bare
    /// percentage so "Colors You Wear Well" reads as a ranking, not a stat.
    private func affinityQualifier(_ affinity: Double) -> String {
        switch affinity {
        case 0.65...: return "Strongly preferred"
        case 0.5..<0.65: return "Preferred"
        case 0.35..<0.5: return "Occasional"
        default: return "Rarely worn"
        }
    }

    /// Plain-language read on a pairing's confidence — used in place of a
    /// bare percentage in "Best Pairings" so a single try-once pairing
    /// doesn't read as an equally strong "100%" alongside a repeated one.
    private func pairingNarrative(score: Double, count: Int) -> String {
        switch (score, count) {
        case let (s, c) where c >= 3 && s >= 0.7:
            return "A reliable favorite — you keep coming back to this pairing."
        case let (s, _) where s >= 0.7:
            return "Off to a strong start."
        case let (s, _) where s <= 0.3:
            return "Hasn't landed well so far."
        default:
            return "A pairing you've tried a few times."
        }
    }

    /// Per-slot color affinity ranking (e.g. "which colors do I like in
    /// tops") for the "Colors You Wear Well" chart — only attributes with
    /// real data are shown.
    private func colorAffinityEntries(for slot: Slot, viewModel: ProfileViewModel) -> [(label: String, affinity: Double)] {
        (viewModel.feedbackHistory.attributeProfile.colorVibeAffinityBySlot[slot] ?? [:])
            .sorted { $0.value > $1.value }
            .map { (vibeLabel($0.key), $0.value) }
    }

    /// Highest-ranking individual item pairs (PRD §4, Tab 3). Reads the same
    /// decay-weighted `feedbackHistory.pairFeedback`
    /// `Domain/OutfitRecommendationEngine.swift` scores against, run through
    /// the identical `PairCompatibilityScoring.pairCompatibilityScore`
    /// Bayesian shrinkage.
    private func topPairs(viewModel: ProfileViewModel) -> [(itemA: WardrobeItem, itemB: WardrobeItem, score: Double, count: Int, recentlyDisliked: Bool)] {
        let feedbackHistory = viewModel.feedbackHistory
        return feedbackHistory.pairFeedback.compactMap { key, value in
            guard let itemA = itemsByID[key.a], let itemB = itemsByID[key.b] else { return nil }
            let prior = PairCompatibilityScoring.aestheticPrior(itemA, itemB)
            let score = PairCompatibilityScoring.pairCompatibilityScore(
                aestheticPrior: prior, feedbackSum: value.likes, evaluationCount: value.total
            )
            let recentlyDisliked = feedbackHistory.outfitNegativeSignalByItemSet.contains { itemSet, negativity in
                negativity > 0 && itemSet.contains(itemA.id) && itemSet.contains(itemB.id)
            }
            return (itemA, itemB, score, Int(value.total.rounded()), recentlyDisliked)
        }
        .sorted { $0.score > $1.score }
    }

    /// Total closet formality balance (PRD §4, Tab 3).
    private var formalityBuckets: [(label: String, count: Int)] {
        let buckets: [(label: String, range: ClosedRange<Double>)] = [
            ("Casual", 1.0...2.0),
            ("Smart-Casual", 2.0...3.5),
            ("Formal", 3.5...5.0),
        ]
        return buckets.map { bucket in
            (bucket.label, items.filter { bucket.range.contains($0.formalityScore) }.count)
        }
    }

    /// Combines the closet-inventory mix (`formalityBuckets`) with what the
    /// user actually rates well (`formalityAffinity`) into one sentence, so
    /// "what you own" and "what you rate well" read as a single comparison
    /// instead of two unrelated numbers sitting next to each other.
    private func formalityNarrative(viewModel: ProfileViewModel) -> String {
        let buckets = formalityBuckets
        guard let dominant = buckets.max(by: { $0.count < $1.count }), dominant.count > 0 else {
            return "Add a few items to see your closet's formality mix."
        }
        var sentence = "Your closet leans \(dominant.label.lowercased()) — \(dominant.count) of \(items.count) pieces."
        if
            let (band, affinity) = viewModel.feedbackHistory.attributeProfile.formalityAffinity.max(by: { $0.value < $1.value }),
            affinity >= TasteSynthesis.confidenceThreshold
        {
            let preferredLabel = formalityBandLabel(band)
            if preferredLabel == dominant.label {
                sentence += " That matches what you rate highest, too."
            } else {
                sentence += " But you actually rate \(preferredLabel.lowercased()) pieces highest — worth adding more of those."
            }
        }
        return sentence
    }

    /// Weekday the user most often rates outfits on, for the "Style
    /// Activity" narrative — `nil` with no feedback yet.
    private func mostActiveWeekdayLabel(from feedbacks: [OutfitFeedback]) -> String? {
        guard !feedbacks.isEmpty else { return nil }
        let calendar = Calendar.current
        let counts = Dictionary(grouping: feedbacks) { calendar.component(.weekday, from: $0.recordedAt) }
            .mapValues(\.count)
        guard let (weekday, _) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return DateFormatter().weekdaySymbols[weekday - 1]
    }

    /// Days since the most recent rated outfit, for the "Style Activity"
    /// narrative — `nil` with no feedback yet.
    private func daysSinceLastRating(from feedbacks: [OutfitFeedback]) -> Int? {
        guard let mostRecent = feedbacks.map(\.recordedAt).max() else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: mostRecent),
            to: calendar.startOfDay(for: .now)
        ).day
    }

    /// Plain-language copy for one synthesized taste signal — kept in the
    /// Features layer since Domain/TasteSynthesis.swift stays string/UI-free.
    private func copy(for signal: TasteSignal) -> (icon: String, text: String) {
        switch signal {
        case .colorInSlot(let slot, let vibe, _):
            return ("paintpalette.fill", "You gravitate toward \(vibeLabel(vibe)) for \(slotLabel(slot).lowercased()).")
        case .formalitySweetSpot(let band, _):
            return ("theatermasks.fill", "\(formalityBandLabel(band)) is your sweet spot.")
        case .pattern(let pattern, _):
            return ("square.grid.2x2.fill", "\(pattern.rawValue.capitalized) patterns tend to work for you.")
        case .silhouette(let tag, _):
            return ("figure.stand", "\(tag.capitalized) silhouettes are a strong fit for your style.")
        case .fabricWeight(let weight, _):
            return ("thermometer.medium", "\(weight.rawValue.capitalized) fabrics suit the way you dress.")
        case .avoidedColor(let vibe, _):
            return ("eye.slash.fill", "You tend to steer clear of \(vibeLabel(vibe)).")
        }
    }

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
            identitySection(viewModel: viewModel)
            swipeDiscoverySection
            styleCheckSection
            tasteInWordsSection(viewModel: viewModel)
            colorAffinitySection(viewModel: viewModel)
            formalitySection(viewModel: viewModel)
            bestPairingsSection(viewModel: viewModel)
            styleActivitySection
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
            if let styleProfile {
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

    // MARK: - Your Taste, In Words

    @ViewBuilder
    private func tasteInWordsSection(viewModel: ProfileViewModel) -> some View {
        Section("Your Taste, In Words") {
            if tasteSignals.isEmpty {
                Text("Rate a few outfits to see your taste profile here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tasteSignals.enumerated()), id: \.offset) { _, signal in
                    let entry = copy(for: signal)
                    Label(entry.text, systemImage: entry.icon)
                }
            }
        }
    }

    // MARK: - Colors You Wear Well

    @ViewBuilder
    private func colorAffinitySection(viewModel: ProfileViewModel) -> some View {
        Section("Colors You Wear Well") {
            if itemRatingExistenceCheck.isEmpty {
                Text("No item ratings yet — rate items to see which colors you favor per category.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Slot", selection: $selectedColorSlot) {
                    ForEach(Self.colorAffinitySlots) { slot in
                        Text(slotLabel(slot)).tag(slot)
                    }
                }
                .pickerStyle(.segmented)

                let entries = colorAffinityEntries(for: selectedColorSlot, viewModel: viewModel)
                if entries.isEmpty {
                    Text("No \(slotLabel(selectedColorSlot).lowercased()) ratings yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(4), id: \.label) { entry in
                        HStack {
                            Text(entry.label)
                            Spacer()
                            Text(affinityQualifier(entry.affinity))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formality Comfort Zone

    @ViewBuilder
    private func formalitySection(viewModel: ProfileViewModel) -> some View {
        Section("Formality Comfort Zone") {
            if items.isEmpty {
                Text("No items in your closet yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text(formalityNarrative(viewModel: viewModel))
                    .fixedSize(horizontal: false, vertical: true)

                let buckets = formalityBuckets
                let total = max(items.count, 1)
                HStack(spacing: 2) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                        if bucket.count > 0 {
                            Capsule()
                                .fill(ProfileChartPalette.categorical[index % ProfileChartPalette.categorical.count])
                                .frame(width: CGFloat(bucket.count) / CGFloat(total) * 240, height: 8)
                        }
                    }
                }

                HStack(spacing: 16) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(ProfileChartPalette.categorical[index % ProfileChartPalette.categorical.count])
                                .frame(width: 8, height: 8)
                            Text("\(bucket.label) (\(bucket.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Best Pairings

    @ViewBuilder
    private func bestPairingsSection(viewModel: ProfileViewModel) -> some View {
        Section("Best Pairings") {
            let pairs = topPairs(viewModel: viewModel)
            if pairs.isEmpty {
                Text("No pair feedback yet — like or dislike outfit pairings from Daily Assistant to see your best combinations here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(pairs.prefix(5).enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(pair.itemA.displayLabel) + \(pair.itemB.displayLabel)")
                            .font(.subheadline.weight(.semibold))
                        Text(pairingNarrative(score: pair.score, count: pair.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(ProfileChartPalette.barFill)
                            .frame(width: max(20, CGFloat(pair.score) * 200), height: 5)
                        if pair.recentlyDisliked {
                            Text("Recently disliked in an outfit")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Style Activity

    private var styleActivitySection: some View {
        Section("Style Activity") {
            if outfitFeedbacks.isEmpty {
                Text("Rate a few outfits to see your activity here.")
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "\(outfitFeedbacks.count) outfit\(outfitFeedbacks.count == 1 ? "" : "s") rated so far.",
                    systemImage: "checkmark.seal.fill"
                )
                if let weekday = mostActiveWeekdayLabel(from: outfitFeedbacks) {
                    Label("You rate outfits most often on \(weekday)s.", systemImage: "calendar")
                }
                if let days = daysSinceLastRating(from: outfitFeedbacks) {
                    Label(
                        days <= 0 ? "You rated an outfit today." : "Last rated \(days) day\(days == 1 ? "" : "s") ago.",
                        systemImage: "clock"
                    )
                }
            }
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
            syncService: MockWardrobeSyncService()
        ))
}
