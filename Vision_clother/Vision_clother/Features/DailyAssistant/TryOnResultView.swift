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
    let onSave: () -> Void
    let onDone: () -> Void

    /// Flips to a "Saved" confirmation after tapping Save — resets whenever
    /// a fresh render replaces `state`, since `.id(imageURL)` on the parent
    /// sheet isn't guaranteed, so this view model's own state is the source
    /// of truth for "have we saved *this* image".
    @State private var didSave = false

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
                HStack {
                    Button {
                        onSave()
                        didSave = true
                    } label: {
                        Label(didSave ? "Saved" : "Save", systemImage: didSave ? "checkmark" : "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(didSave)

                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                }

            case .failed(let error):
                Label(error.errorDescription ?? "Something went wrong", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
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
        onSave: {},
        onDone: {}
    )
}
