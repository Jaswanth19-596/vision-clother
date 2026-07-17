//
//  JobQueueStore.swift
//  Vision_clother
//
//  App-wide background job queue — first piece of app-root-level shared
//  state in this codebase (injected via `.environment()` from
//  `Vision_clotherApp`). Owns the wardrobe-item ingestion pipeline
//  (background isolation -> vision-LLM tagging -> save) and try-on
//  generation as independent, concurrently-running jobs, so neither blocks
//  the user inside a modal sheet. Every job's `Task` is fully independent —
//  starting a second try-on job never cancels a first one, matching the
//  concurrent-generation requirement this store was built for.
//
//  Concurrency note: this store is `@MainActor`, matching
//  `WardrobeRepository`'s existing isolation. "Concurrent jobs" means N
//  independent `Task`s suspended on network/Vision-framework I/O at once —
//  Swift's cooperative MainActor executor guarantees their synchronous
//  segments (every repository write, every `jobs` mutation) never
//  interleave, so no new actor/ModelActor infrastructure is needed.
//

import Foundation
import Observation
import os
import UIKit

/// Correlates an image's bytes across ingestion-pipeline log lines — see
/// `ImageStorage.fingerprint(_:)`, also used to key `SavedCombination`'s
/// cache-matching in `Services/CachedTryOnRenderService.swift`.
private func imageFingerprint(_ data: Data) -> String {
    ImageStorage.fingerprint(data)
}

@Observable
@MainActor
final class JobQueueStore {
    private(set) var jobs: [Job] = []
    var isPanelPresented = false

    private let repository: WardrobeRepository
    private let backgroundIsolationService: BackgroundIsolationService
    private let imagePreprocessingService: BackgroundIsolationService
    private let visionMetadataService: VisionMetadataExtractionService
    private let tryOnService: TryOnRenderService
    private let photoLibrarySaver: PhotoLibrarySaver
    private let notificationService: JobNotificationService

    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    /// Caps in-flight network jobs (upload's Vision-tagging call, try-on's
    /// render call) so a bulk action (e.g. importing 50 photos at once)
    /// can't fire dozens of concurrent requests against the paid
    /// OpenRouter-backed API. Jobs beyond the cap sit in `pendingStarts` and
    /// stay `.queued` until a running job frees a slot.
    private let maxConcurrentJobs = 3
    private var pendingStarts: [(id: UUID, start: () -> Void)] = []

    var activeJobCount: Int {
        jobs.filter { $0.status.isInFlight }.count
    }

    private func scheduleStart(_ jobID: UUID, _ start: @escaping () -> Void) {
        guard runningTasks.count < maxConcurrentJobs else {
            pendingStarts.append((jobID, start))
            return
        }
        start()
    }

    private func startNextPendingIfAny() {
        guard runningTasks.count < maxConcurrentJobs, !pendingStarts.isEmpty else { return }
        let next = pendingStarts.removeFirst()
        next.start()
    }

    init(
        repository: WardrobeRepository,
        backgroundIsolationService: BackgroundIsolationService,
        imagePreprocessingService: BackgroundIsolationService,
        visionMetadataService: VisionMetadataExtractionService,
        tryOnService: TryOnRenderService,
        photoLibrarySaver: PhotoLibrarySaver,
        notificationService: JobNotificationService
    ) {
        self.repository = repository
        self.backgroundIsolationService = backgroundIsolationService
        self.imagePreprocessingService = imagePreprocessingService
        self.visionMetadataService = visionMetadataService
        self.tryOnService = tryOnService
        self.photoLibrarySaver = photoLibrarySaver
        self.notificationService = notificationService
    }

    // MARK: - Upload

    func enqueueUpload(rawImageData: Data, defaultSlot: Slot?) {
        let payload = UploadPayload(rawImageData: rawImageData, defaultSlot: defaultSlot)
        let job = Job(kind: .upload(payload), thumbnail: rawImageData)
        jobs.append(job)
        AppLog.info(.jobQueue, "enqueueUpload: job=\(job.id) defaultSlot=\(defaultSlot?.rawValue ?? "nil") bytes=\(rawImageData.count)")
        Task { await notificationService.requestAuthorizationIfNeeded() }
        scheduleStart(job.id) { [weak self] in self?.startUploadTask(job.id, payload: payload) }
    }

    func retryUpload(_ jobID: Job.ID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              case .upload(let payload) = job.kind else { return }
        AppLog.info(.jobQueue, "retryUpload: job=\(jobID)")
        setStatus(jobID, .queued)
        scheduleStart(jobID) { [weak self] in self?.startUploadTask(jobID, payload: payload) }
    }

    private func startUploadTask(_ jobID: UUID, payload: UploadPayload) {
        runningTasks[jobID] = runWithBackgroundContinuation { [weak self] in
            await self?.performUpload(jobID: jobID, payload: payload)
        }
    }

    /// Mirrors the pre-job-queue `AddItemViewModel.ingest`/`saveItem`
    /// pipeline (isolate -> tag -> save), writing progress into `Job.status`
    /// instead of view-model state. No fallback to a review form on tagging
    /// failure — the user's recourse is Retry from the queue panel or
    /// manual entry.
    private func performUpload(jobID: UUID, payload: UploadPayload) async {
        setStatus(jobID, .processing("Enhancing photo…"))
        PerfLog.logger.notice("[ingest] job=\(jobID, privacy: .public) raw=\(imageFingerprint(payload.rawImageData), privacy: .public) bytes=\(payload.rawImageData.count, privacy: .public)")

        let workingImageData = await isolateStage1(payload.rawImageData)
        guard !Task.isCancelled else {
            finishJob(jobID, status: .failed("Cancelled"))
            return
        }

        setStatus(jobID, .processing("Isolating garment…"))
        let imageToTag = await isolateStage2(workingImageData)
        guard !Task.isCancelled else {
            finishJob(jobID, status: .failed("Cancelled"))
            return
        }
        PerfLog.logger.notice("[ingest] job=\(jobID, privacy: .public) sentToLLM=\(imageFingerprint(imageToTag), privacy: .public) bytes=\(imageToTag.count, privacy: .public)")

        setStatus(jobID, .processing("Tagging item…"))

        let metadata: GarmentMetadata
        do {
            metadata = try await visionMetadataService.extractMetadata(imageData: imageToTag)
        } catch {
            let message = (error as? VisionMetadataExtractionError)?.errorDescription ?? error.localizedDescription
            AppLog.error(.jobQueue, "performUpload: job=\(jobID) vision tagging failed — \(message)")
            finishJob(jobID, status: .failed(message))
            notificationService.notifyUploadFailed(reason: message)
            return
        }
        guard !Task.isCancelled else {
            finishJob(jobID, status: .failed("Cancelled"))
            return
        }
        PerfLog.logger.notice("[ingest] job=\(jobID, privacy: .public) taggedDescription=\(metadata.description, privacy: .public)")

        setStatus(jobID, .processing("Saving…"))

        // Guest-first quota plan (Domain/EntitlementLimits.swift): same
        // client-side pre-check as AddItemViewModel.saveItem(), backstopped
        // server-side by backend/firestore.rules' meta/itemCounts cap.
        // `WardrobeItem.make` slots the item by `metadata.slot` (the
        // vision-tagged result), not `payload.defaultSlot` (only a tagging
        // hint), so that's what's checked here too.
        let existingCount = (try? repository.fetchInventory())?.filter { $0.slot == metadata.slot }.count ?? 0
        guard existingCount < EntitlementLimits.itemCap(for: metadata.slot, isAnonymous: AuthService.shared.isGuestTier) else {
            let message = "You've reached the item limit for this category. Sign in to add more."
            AppLog.notice(.jobQueue, "performUpload: job=\(jobID) item cap reached for slot=\(metadata.slot.rawValue)")
            finishJob(jobID, status: .failed(message))
            notificationService.notifyUploadFailed(reason: message)
            return
        }

        do {
            let filename = try ImageStorage.save(imageToTag)
            let item = WardrobeItem.make(from: metadata, imageAssetName: filename)
            try repository.save(item)
            finishJob(jobID, status: .succeeded, resultItemID: item.id)
            PerfLog.logger.notice("[ingest] job=\(jobID, privacy: .public) savedItem=\(item.id, privacy: .public) filename=\(filename, privacy: .public)")
            notificationService.notifyUploadSucceeded(itemLabel: item.displayLabel)
        } catch {
            let message = "Couldn't save that item. Try again."
            AppLog.error(.jobQueue, "performUpload: job=\(jobID) save failed — \(String(describing: error))")
            finishJob(jobID, status: .failed(message))
            notificationService.notifyUploadFailed(reason: message)
        }
    }

    // MARK: - Prospective Purchase Evaluation

    /// Shares `isolateStage1`/`isolateStage2` with `performUpload` — not
    /// enqueued as a tracked `Job`, and never saves anything. Used by
    /// `DailyAssistantViewModel.checkProspectiveItem()` to tag a photo the
    /// user is only considering buying; the caller decides whether/when to
    /// persist the result (`WardrobeRepository.save`), which this method
    /// never does. Unlike `performUpload`, this one-shot caller has no
    /// job-status updates or cancellation checkpoints to interleave between
    /// stages.
    func isolateAndTag(rawImageData: Data) async throws -> (imageData: Data, metadata: GarmentMetadata) {
        let workingImageData = await isolateStage1(rawImageData)
        let imageToTag = await isolateStage2(workingImageData)
        let metadata = try await visionMetadataService.extractMetadata(imageData: imageToTag)
        return (imageToTag, metadata)
    }

    /// Gemini (via OpenRouter) preprocesses the raw photo — can succeed on
    /// cases on-device Vision alone can't (a worn garment, a background
    /// similar to the item). Falls back to the raw photo on any failure so
    /// stage 2 still runs.
    private func isolateStage1(_ rawImageData: Data) async -> Data {
        (try? await imagePreprocessingService.isolateForeground(from: rawImageData)) ?? rawImageData
    }

    /// On-device Vision produces the final transparent-background cutout
    /// from stage 1's output. Falls back to stage 1's output on failure,
    /// same graceful-degradation philosophy.
    private func isolateStage2(_ workingImageData: Data) async -> Data {
        (try? await backgroundIsolationService.isolateForeground(from: workingImageData)) ?? workingImageData
    }

    // MARK: - Try-on

    func enqueueTryOn(baseImageData: Data, outfit: OutfitCombination) {
        let payload = TryOnPayload(baseImageData: baseImageData, outfit: outfit)
        let job = Job(kind: .tryOn(payload), thumbnail: baseImageData)
        jobs.append(job)
        AppLog.info(.jobQueue, "enqueueTryOn: job=\(job.id) items=\(outfit.items.count)")
        Task { await notificationService.requestAuthorizationIfNeeded() }
        scheduleStart(job.id) { [weak self] in self?.startTryOnTask(job.id, payload: payload) }
    }

    /// Enqueues a fresh, independent job with the same inputs rather than
    /// mutating the failed job in place — keeps the "each request is
    /// independent" model consistent with `cancelJob`.
    func retryTryOn(_ jobID: Job.ID) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              case .tryOn(let payload) = job.kind else { return }
        enqueueTryOn(baseImageData: payload.baseImageData, outfit: payload.outfit)
    }

    private func startTryOnTask(_ jobID: UUID, payload: TryOnPayload) {
        runningTasks[jobID] = runWithBackgroundContinuation { [weak self, tryOnService] in
            guard let self else { return }
            await tryOnService.renderTryOn(baseImageData: payload.baseImageData, items: payload.outfit.items) { state in
                Task { @MainActor in
                    self.handleTryOnUpdate(jobID: jobID, state: state)
                }
            }
        }
    }

    private func handleTryOnUpdate(jobID: UUID, state: TryOnState) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch state {
        case .idle:
            break
        case .submitting(let stage):
            jobs[index].status = .processing(stage.label)
        case .polling(let stage, _):
            jobs[index].status = .processing(stage.label)
        case .succeeded:
            AppLog.info(.jobQueue, "handleTryOnUpdate: job=\(jobID) succeeded")
            jobs[index].tryOnResultState = state
            jobs[index].status = .succeeded
            jobs[index].completedAt = .now
            runningTasks[jobID] = nil
            notificationService.notifyTryOnSucceeded()
            startNextPendingIfAny()
        case .failed(let error):
            AppLog.error(.jobQueue, "handleTryOnUpdate: job=\(jobID) failed — \(String(describing: error))")
            jobs[index].tryOnResultState = state
            jobs[index].status = .failed(error.errorDescription ?? "Something went wrong")
            jobs[index].completedAt = .now
            runningTasks[jobID] = nil
            if error != .cancelled {
                notificationService.notifyTryOnFailed(reason: error.errorDescription ?? "Something went wrong")
            }
            startNextPendingIfAny()
        }
    }

    /// Persists a job's succeeded render via `ImageStorage` +
    /// `SavedCombination`, mirrored to the Photos library — same shape as
    /// the pre-job-queue `DailyAssistantViewModel.saveCombination()`. Called
    /// from `TryOnResultView`'s Like/Dislike buttons when the user reopens a
    /// completed job from the queue panel. Both always save — `liked`
    /// reflects the user's choice for the outfit-level and pair-level
    /// feedback rows, matching `ManualPairingViewModel.saveOutfit(liked:)`.
    /// Pair feedback is recorded for every pairwise combination in the
    /// outfit (not just top+bottom), since a Daily Assistant outfit can have
    /// 3-4 real items and `outfitScore` already reads every pair.
    func saveCombination(for jobID: Job.ID, liked: Bool) async {
        guard let job = jobs.first(where: { $0.id == jobID }),
              case .tryOn(let payload) = job.kind,
              case .succeeded(let imageURL) = job.tryOnResultState,
              let imageData = try? Data(contentsOf: imageURL) else {
            AppLog.error(.jobQueue, "saveCombination: job=\(jobID) has no succeeded try-on result to save")
            return
        }
        AppLog.info(.jobQueue, "saveCombination: job=\(jobID) liked=\(liked)")

        let outfit = payload.outfit
        if let assetName = try? ImageStorage.save(imageData) {
            // Generated up front so the outfit-level feedback event below
            // can reference the same durable id the Combinations tab reads —
            // mirrors ManualPairingViewModel.saveOutfit(liked:).
            let combinationID = UUID()
            let combination = SavedCombination(
                id: combinationID,
                imageAssetName: assetName,
                itemIDsBySlot: outfit.itemsBySlot.mapValues(\.id),
                labelsBySlot: outfit.itemsBySlot.mapValues(\.displayLabel),
                origin: "assistant",
                basePortraitFingerprint: ImageStorage.fingerprint(payload.baseImageData),
                supplementaryAccessoryItemIDs: outfit.supplementaryAccessories.map(\.id),
                supplementaryAccessoryLabels: outfit.supplementaryAccessories.map(\.displayLabel)
            )
            try? repository.saveCombination(combination)
            try? repository.recordOutfitFeedback(outfitID: combinationID, likedOverall: liked)
            for (itemA, itemB) in PairCompatibilityScoring.pairwiseCombinations(outfit.items) {
                try? repository.recordPairFeedback(itemAID: itemA.id, itemBID: itemB.id, likedTogether: liked)
            }
        }
        try? await photoLibrarySaver.save(imageData: imageData)
    }

    // MARK: - Shared job control

    /// No server-side cancel call needed for try-on — the render either
    /// finishes or the `Task` cancellation check inside
    /// `OpenRouterTryOnRenderService` short-circuits it. For uploads, this
    /// stops the pipeline at its next cancellation checkpoint.
    func cancelJob(_ jobID: Job.ID) {
        AppLog.notice(.jobQueue, "cancelJob: job=\(jobID)")
        pendingStarts.removeAll { $0.id == jobID }
        runningTasks[jobID]?.cancel()
        runningTasks[jobID] = nil
        finishJob(jobID, status: .failed("Cancelled"))
    }

    private func setStatus(_ jobID: UUID, _ status: Job.Status) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = status
    }

    private func finishJob(_ jobID: UUID, status: Job.Status, resultItemID: UUID? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = status
        jobs[index].completedAt = .now
        if let resultItemID {
            jobs[index].resultItemID = resultItemID
        }
        runningTasks[jobID] = nil
        startNextPendingIfAny()
    }

    /// Buys a job a grace window to finish if the user briefly leaves the
    /// app entirely (switches apps/locks phone) rather than just navigating
    /// between in-app tabs, which needs no special handling since the
    /// process stays foregrounded. Not a guarantee for a long render
    /// backgrounded early — true guaranteed completion would need
    /// `BGProcessingTask`, out of scope here.
    private func runWithBackgroundContinuation(_ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let box = BackgroundTaskBox()
        let task = Task {
            await operation()
            box.endIfNeeded()
        }
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: "VisionClotherJob") {
            // Expiration fired before `operation()` finished (e.g. a stuck
            // network call) — cancel it so it doesn't run unbounded, and end
            // the assertion exactly once.
            task.cancel()
            box.endIfNeeded()
        }
        return task
    }
}

/// Reference-type holder so the expiration handler and the post-`await`
/// cleanup both read/write the same `identifier` without the "mutated after
/// capture by Sendable closure" diagnostic a plain captured `var` triggers.
/// `endIfNeeded()` is idempotent so the two call sites (expiration handler,
/// post-`await` cleanup) racing never double-`endBackgroundTask` the same
/// identifier.
private final class BackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func endIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, identifier != .invalid else { return }
        ended = true
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
