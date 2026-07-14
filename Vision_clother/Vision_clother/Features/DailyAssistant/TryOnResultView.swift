//
//  TryOnResultView.swift
//  Vision_clother
//
//  Sheet content for "How does it look on me?" (PRD.md §3.5), fully driven
//  by `TryOnState` — see the plan's OpenRouter polling failure-handling decision
//  (Services/OpenRouterTryOnRenderService.swift) for the state machine this
//  visualizes: submitting -> succeeded/failed, with an explicit
//  Cancel during rendering and Retry on failure.
//

import SwiftUI

struct TryOnResultView: View {
    let state: TryOnState
    let onCancel: () -> Void
    let onRetry: () -> Void
    /// `true` for Like, `false` for Dislike — both always save the outfit
    /// (Stylist Intelligence Engine feedback-learning pass), so there's a
    /// durable id for the feedback row to reference regardless of which
    /// button was tapped.
    let onSave: (Bool) async -> Void
    let onDone: () -> Void

    /// Flips to a "Saved" confirmation after tapping Like/Dislike — resets
    /// whenever a fresh render replaces `state`, since `.id(imageURL)` on
    /// the parent sheet isn't guaranteed, so this view model's own state is
    /// the source of truth for "have we saved *this* image".
    @State private var didSave = false
    /// True while `onSave()`'s Task is in flight. "Done" is disabled during
    /// this window so the caller can never read a save's results (e.g. the
    /// rating prompt's item list) before the save has actually finished —
    /// closing this race is what fixed the "Rate this item" infinite
    /// spinner (the save was fire-and-forget before).
    @State private var isSaving = false
    /// Ticks once per completed save — drives the save-confirmation
    /// critical-action haptic.
    @State private var didSaveTick = 0

    var body: some View {
        VStack(spacing: 20) {
            switch state {
            case .idle:
                EmptyView()

            case .submitting(let stage):
                ProgressView(stage.label)
                cancelButton

            case .polling(let stage, let elapsedSeconds):
                ProgressView("\(stage.label) \(Int(elapsedSeconds))s")
                cancelButton

            case .succeeded(let imageURL):
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Label("Couldn't load the image", systemImage: "photo.badge.exclamationmark")
                    default:
                        ProgressView()
                    }
                }
                .frame(maxHeight: 400)
                .clipShape(VCRadius.shape(VCRadius.card))
                .vcShadow()

                if didSave {
                    HStack {
                        Label("Saved", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Done", action: onDone)
                            .buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    Text("Did you like this outfit?").font(.headline)
                    HStack {
                        Button {
                            isSaving = true
                            Task {
                                await onSave(false)
                                didSave = true
                                isSaving = false
                                didSaveTick += 1
                            }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Label("Dislike", systemImage: "hand.thumbsdown")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isSaving)

                        Button {
                            isSaving = true
                            Task {
                                await onSave(true)
                                didSave = true
                                isSaving = false
                                didSaveTick += 1
                            }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Label("Like", systemImage: "hand.thumbsup")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isSaving)
                    }
                    Button("Done", action: onDone)
                        .disabled(isSaving)
                }

            case .failed(let error):
                Label(error.errorDescription ?? "Something went wrong", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding()
        .sensoryFeedback(.success, trigger: didSaveTick)
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel, action: onCancel)
    }
}

#Preview {
    TryOnResultView(
        state: .polling(stage: .rendering, elapsedSeconds: 3),
        onCancel: {},
        onRetry: {},
        onSave: { _ in },
        onDone: {}
    )
}
