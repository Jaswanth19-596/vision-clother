//
//  JobQueuePanelView.swift
//  Vision_clother
//
//  Dedicated Activity panel — grouped list of every in-flight/completed
//  upload and try-on job, presented once via `.sheet(isPresented:)` at
//  `RootTabView` level (single source of truth, so a notification tap can
//  open it regardless of which tab is active).
//

import SwiftData
import SwiftUI

struct JobQueuePanelView: View {
    @Environment(JobQueueStore.self) private var jobQueueStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var uploadDetailItem: WardrobeItem?
    @State private var activeTryOnJob: Job?

    private var uploadJobs: [Job] {
        jobQueueStore.jobs
            .filter { if case .upload = $0.kind { return true }; return false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var tryOnJobs: [Job] {
        jobQueueStore.jobs
            .filter { if case .tryOn = $0.kind { return true }; return false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jobQueueStore.jobs.isEmpty {
                    ContentUnavailableView(
                        "No Activity Yet",
                        systemImage: "tray",
                        description: Text("Uploads and try-on generations you start will show up here while they process.")
                    )
                } else {
                    List {
                        if !uploadJobs.isEmpty {
                            Section("Uploads") {
                                ForEach(uploadJobs) { job in
                                    JobRow(
                                        job: job,
                                        onTap: { handleTap(job) },
                                        onRetry: { jobQueueStore.retryUpload(job.id) },
                                        onCancel: { jobQueueStore.cancelJob(job.id) }
                                    )
                                }
                            }
                        }
                        if !tryOnJobs.isEmpty {
                            Section("Try-Ons") {
                                ForEach(tryOnJobs) { job in
                                    JobRow(
                                        job: job,
                                        onTap: { handleTap(job) },
                                        onRetry: { jobQueueStore.retryTryOn(job.id) },
                                        onCancel: { jobQueueStore.cancelJob(job.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $uploadDetailItem) { item in
                ItemDetailView(items: [item], selectedItemID: item.id)
            }
            .sheet(item: $activeTryOnJob) { job in
                TryOnResultView(
                    state: job.tryOnResultState ?? .idle,
                    onCancel: { activeTryOnJob = nil },
                    onRetry: {
                        jobQueueStore.retryTryOn(job.id)
                        activeTryOnJob = nil
                    },
                    onSave: { liked in await jobQueueStore.saveCombination(for: job.id, liked: liked) },
                    onDone: { activeTryOnJob = nil }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func handleTap(_ job: Job) {
        switch job.kind {
        case .upload:
            guard case .succeeded = job.status, let itemID = job.resultItemID else { return }
            let repository = SwiftDataWardrobeRepository(modelContext: modelContext)
            uploadDetailItem = (try? repository.fetchInventory())?.first { $0.id == itemID }
        case .tryOn:
            guard job.tryOnResultState != nil else { return }
            activeTryOnJob = job
        }
    }
}

private struct JobRow: View {
    let job: Job
    let onTap: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                thumbnail
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    statusLabel
                }

                Spacer()

                trailingIcon
            }
        }
        .buttonStyle(.plain)
        .disabled(job.status.isInFlight)
        .swipeActions(edge: .trailing) {
            switch job.status {
            case .failed:
                Button("Retry", action: onRetry)
                    .tint(.blue)
            case .queued, .processing:
                Button("Cancel", role: .destructive, action: onCancel)
            case .succeeded:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch job.kind {
        case .upload: return "New item"
        case .tryOn: return "Try-on preview"
        }
    }

    private var statusLabel: some View {
        Group {
            switch job.status {
            case .queued: Text("Queued")
            case .processing(let message): Text(message)
            case .succeeded: Text("Done")
            case .failed(let message): Text(message)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    @ViewBuilder
    private var trailingIcon: some View {
        switch job.status {
        case .queued, .processing:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var fallbackSystemImage: String {
        switch job.kind {
        case .upload: return "tshirt"
        case .tryOn: return "person.crop.rectangle"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailData = job.thumbnail, let uiImage = UIImage(data: thumbnailData) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    Image(systemName: fallbackSystemImage)
                        .foregroundStyle(.secondary)
                }
        }
    }
}
