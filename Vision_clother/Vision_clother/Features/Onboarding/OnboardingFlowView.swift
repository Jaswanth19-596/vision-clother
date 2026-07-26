//
//  OnboardingFlowView.swift
//  Vision_clother
//
//  First-run guided setup (2026-07-25). Presented full-screen over
//  `RootTabView` by `AppRootView` while the user is not yet set up — i.e. has
//  no base portrait OR an empty closet — and dismissed for good once they
//  finish or skip (`AppStorage("hasCompletedOnboarding")`). A returning,
//  already-set-up user (including one whose wardrobe/portrait restored via
//  Cloud Sync) never sees it, because the presenting gate is keyed on real
//  state, not only the flag (see `AppRootView`).
//
//  Deliberately reuses the real flows rather than duplicating them: the
//  portrait step drives `ProfileViewModel` (same validate→save→derive pipeline
//  as the Profile tab), the closet step presents the real `AddItemView` sheet
//  (same background auto-tag ingestion), and the optional taste step presents
//  `SwipeDiscoveryView`. It only pulls those buried-in-Profile setup steps to
//  the front — it does not reimplement them.
//

import PhotosUI
import SwiftData
import SwiftUI

struct OnboardingFlowView: View {
    /// Called when the user finishes or skips — `AppRootView` persists the
    /// completion flag and dismisses.
    let onComplete: () -> Void

    @Environment(\.modelContext) private var modelContext

    /// Live count of real (non-ghost) wardrobe items — drives the closet
    /// step's "added N" feedback and gates its Continue without any manual
    /// refresh, since photo-add ingestion completes asynchronously in the
    /// background job queue.
    @Query private var allItems: [WardrobeItem]

    @State private var step: Step = .welcome
    @State private var profileViewModel: ProfileViewModel?
    @State private var isCameraPresented = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isAddItemPresented = false
    @State private var isCalibratePresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case welcome, portrait, closet, ready
    }

    private var realItemCount: Int {
        allItems.filter { !$0.isGhostElement }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
                footer
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { onComplete() }
                        .font(.callout)
                }
            }
        }
        .task {
            guard profileViewModel == nil else { return }
            profileViewModel = ProfileViewModel(
                repository: SyncingWardrobeRepository(modelContext: modelContext),
                validationService: ServiceFactory.makePersonPhotoValidationService(),
                profileDerivationService: ServiceFactory.makeUserProfileDerivationService()
            )
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            PortraitCameraCaptureView { data in
                isCameraPresented = false
                guard let data else { return }
                profileViewModel?.savePortrait(data)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isAddItemPresented) {
            AddItemView(defaultSlot: nil)
        }
        .sheet(isPresented: $isCalibratePresented) {
            NavigationStack {
                SwipeDiscoveryView()
                    .navigationTitle("Discover Your Style")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isCalibratePresented = false }
                        }
                    }
            }
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                profileViewModel?.savePortrait(data)
                photoPickerItem = nil
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        Group {
            switch step {
            case .welcome: welcomeStep
            case .portrait: portraitStep
            case .closet: closetStep
            case .ready: readyStep
            }
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var welcomeStep: some View {
        stepScaffold(
            stepIdentity: .welcome,
            icon: "sparkles",
            title: "Welcome to Vision Clother",
            subtitle: "Your AI stylist for the clothes you already own. Two quick steps and you're ready — a photo of you, and a few pieces from your closet."
        ) {
            EmptyView()
        }
    }

    private var portraitStep: some View {
        stepScaffold(
            stepIdentity: .portrait,
            icon: "person.crop.square.badge.camera",
            title: "Add a photo of yourself",
            subtitle: "Used only to render outfits on you when you tap “try it on.” You can retake or swap it anytime in Profile."
        ) {
            VStack(spacing: 12) {
                Group {
                    if profileViewModel?.hasPortrait == true {
                        Label("Photo added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if profileViewModel?.isValidatingPhoto == true {
                        Label("Checking your photo…", systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .vcAnimation(VCMotion.standard, value: profileViewModel?.hasPortrait)
                .vcAnimation(VCMotion.standard, value: profileViewModel?.isValidatingPhoto)

                HStack {
                    Button { isCameraPresented = true } label: {
                        Label(profileViewModel?.hasPortrait == true ? "Retake" : "Take Photo", systemImage: "camera")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button("Use a default silhouette instead") {
                    profileViewModel?.useDefaultBodyPhoto()
                }
                .font(.caption)

                if let error = profileViewModel?.photoUploadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var closetStep: some View {
        stepScaffold(
            stepIdentity: .closet,
            icon: "tshirt",
            title: "Add your clothes",
            subtitle: "Snap or pick a few pieces — we’ll tag each one automatically in the background. The more you add, the better your outfits get."
        ) {
            VStack(spacing: 12) {
                if realItemCount > 0 {
                    Label("\(realItemCount) item\(realItemCount == 1 ? "" : "s") added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                Button { isAddItemPresented = true } label: {
                    Label("Add Clothes", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .vcAnimation(VCMotion.standard, value: realItemCount)
        }
    }

    private var readyStep: some View {
        stepScaffold(
            stepIdentity: .ready,
            icon: "checkmark.seal",
            title: "You’re all set",
            subtitle: "Head to the Daily Assistant and ask for an outfit. Want sharper picks from the start? Take 30 seconds to calibrate your taste — optional."
        ) {
            Button { isCalibratePresented = true } label: {
                Label("Calibrate My Taste", systemImage: "heart.text.square")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - Scaffold + footer

    /// `stepIdentity` isn't read directly — it exists so each call site is
    /// self-documenting about which `Step` it scaffolds. The actual
    /// insertion animation comes from `content`'s `.id(step)`, which gives
    /// this whole `VStack` (and thus every `vcStaggeredEntrance` child below)
    /// a fresh identity on every step change, re-triggering the stagger.
    private func stepScaffold<Extra: View>(
        stepIdentity: Step,
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .vcStaggeredEntrance(index: 0)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .vcStaggeredEntrance(index: 1)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .vcStaggeredEntrance(index: 2)
            extra()
                .padding(.top, 4)
                .vcStaggeredEntrance(index: 3)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 12) {
            stepDots
            Button(primaryButtonTitle) { advance() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isPrimaryDisabled)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .scaleEffect(s == step ? 1.3 : 1.0)
            }
        }
        .vcAnimation(VCMotion.standard, value: step)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .portrait: return "Continue"
        case .closet: return realItemCount > 0 ? "Continue" : "Skip for Now"
        case .ready: return "Start Styling"
        }
    }

    /// The portrait step is the only hard gate — try-on needs a base photo,
    /// and "Use a default silhouette" is always available as an escape hatch,
    /// so this never truly traps the user. The closet step is skippable (the
    /// button relabels to "Skip for Now" when empty).
    private var isPrimaryDisabled: Bool {
        step == .portrait && profileViewModel?.hasPortrait != true
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation(vcMotion(VCMotion.standard, reduceMotion: reduceMotion)) { step = next }
        } else {
            onComplete()
        }
    }
}
