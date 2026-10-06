import Foundation
import Combine
import AppKit
import UserNotifications
import OSLog
import SiftXCore

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var speeds: [UUID: Double] = [:]
    @Published var lastError: String?
    @Published private(set) var settings = AppSettings()

    private let store: SharedStore
    private let engine: DownloadEngine
    private let stagingRoot: URL
    private let logger = Logger(subsystem: "com.siftx.SiftX", category: "Download")
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var polling: Task<Void, Never>?
    private var samples: [UUID: (bytes: Int64, time: TimeInterval)] = [:]
    private var persistedAt: [UUID: TimeInterval] = [:]
    private var generations: [UUID: UUID] = [:]
    private var removing: Set<UUID> = []
    private var started = false

    init(store: SharedStore) {
        self.store = store
        stagingRoot = store.directory.appendingPathComponent("Transfers", isDirectory: true)
        engine = DownloadEngine(stagingRoot: stagingRoot)
        do {
            settings = try store.loadSettings()
            records = try store.loadDownloads().sorted { $0.createdAt > $1.createdAt }
            for index in records.indices where records[index].status == .downloading || records[index].status == .processing {
                records[index].status = .paused
                records[index].error = nil
                try store.saveDownload(records[index])
            }
            // A process can exit between saving completion/removing a record
            // and discarding its disk chunks. Reclaim those orphaned folders.
            let retained = Set(records.filter { $0.status != .completed && $0.status != .cancelled }.map(\.id))
            if let folders = try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
                for folder in folders {
                    guard let id = UUID(uuidString: folder.lastPathComponent), !retained.contains(id),
                          (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        } catch { lastError = error.downloadDescription }
    }

    var activeCount: Int { records.filter { $0.status == .downloading || $0.status == .processing }.count }
    var queuedCount: Int { records.filter { $0.status == .queued }.count }

    func start() {
        guard !started else { return }
        started = true
        refreshSettings()
        drainRequests()
        pump()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.drainRequests()
                do { try await Task.sleep(nanoseconds: 800_000_000) }
                catch { break }
            }
        }
        if settings.notifyCompletion || settings.notifyFailure {
            Task {
                let center = UNUserNotificationCenter.current()
                let authorization = await center.notificationSettings()
                if authorization.authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                }
            }
        }
    }

    func shutdown() async {
        started = false
        polling?.cancel()
        polling = nil
        pauseAll()
        let tasks = Array(workers.values)
        for task in tasks { await task.value }
    }

    @discardableResult
    func enqueue(candidate: MediaCandidate) -> UUID {
        let record = DownloadRecord(candidate: candidate)
        do {
            try store.saveDownload(record)
            records.insert(record, at: 0)
            pump()
        } catch { lastError = error.downloadDescription }
        return record.id
    }

    func pause(id: UUID) {
        guard let record = record(id), [.queued, .downloading, .processing].contains(record.status) else { return }
        update(id: id) { $0.status = .paused; $0.error = nil }
        workers[id]?.cancel()
        speeds[id] = nil
        samples[id] = nil
    }

    func resume(id: UUID) {
        guard let record = record(id), record.status == .paused else { return }
        update(id: id) { $0.status = .queued; $0.error = nil }
        pump()
    }

    func cancel(id: UUID) {
        guard let record = record(id), [.queued, .downloading, .processing, .paused].contains(record.status) else { return }
        update(id: id) { $0.status = .cancelled; $0.error = nil }
        speeds[id] = nil
        samples[id] = nil
        if let task = workers[id] { task.cancel() }
        else { DownloadFiles.discardStaging(id: id, root: stagingRoot) }
        pump()
    }

    func retry(id: UUID) {
        guard let record = record(id) else { return }
        if record.status == .completed {
            enqueue(candidate: record.candidate)
            return
        }
        guard [.failed, .cancelled, .paused].contains(record.status) else { return }
        update(id: id) { $0.status = .queued; $0.error = nil; $0.completedAt = nil }
        pump()
    }

    func remove(id: UUID, deleteFile: Bool = false) {
        guard let record = record(id) else { return }
        do {
            if deleteFile, record.filePath != nil || record.fileBookmark != nil {
                let lease = try DownloadFileLease(record: record, settings: settings)
                try lease.deleteIfPresent()
                withExtendedLifetime(lease) {}
            }
            try store.deleteDownload(id: id)
            records.removeAll { $0.id == id }
            speeds[id] = nil
            samples[id] = nil
            if let task = workers[id] { removing.insert(id); task.cancel() }
            else { DownloadFiles.discardStaging(id: id, root: stagingRoot) }
        } catch { lastError = error.downloadDescription }
        pump()
    }

    func pauseAll() {
        for id in records.filter({ [.queued, .downloading, .processing].contains($0.status) }).map(\.id) { pause(id: id) }
    }

    func resumeAll() {
        for id in records.filter({ $0.status == .paused }).map(\.id) { resume(id: id) }
    }

    func clearCompleted() {
        for id in records.filter({ $0.status == .completed }).map(\.id) { remove(id: id) }
    }

    func refreshSettings() {
        do { settings = try store.loadSettings(); pump() }
        catch { lastError = error.downloadDescription }
    }

    private func drainRequests() {
        do {
            for request in try store.pendingRequests() {
                // Save the durable task before acknowledging its handoff. A crash
                // between these writes is harmless because request IDs are stable.
                if !records.contains(where: { $0.id == request.id }) {
                    let record = DownloadRecord(id: request.id, candidate: request.candidate, createdAt: request.createdAt)
                    try store.saveDownload(record)
                    records.insert(record, at: 0)
                }
                try store.ackRequest(id: request.id)
            }
            pump()
        } catch { lastError = error.downloadDescription }
    }

    private func pump() {
        guard started else { return }
        let limit = min(max(settings.maxConcurrent, 1), 8)
        let slots = max(0, limit - workers.count)
        let ready = records.reversed().filter { $0.status == .queued && workers[$0.id] == nil }.prefix(slots)
        for record in ready {
            update(id: record.id) { $0.status = .downloading; $0.error = nil }
            workers[record.id] = Task { [weak self] in
                guard let self else { return }
                await self.run(id: record.id, candidate: record.candidate)
            }
        }
    }

    private func run(id: UUID, candidate: MediaCandidate) async {
        let generation = UUID()
        generations[id] = generation
        defer {
            workers[id] = nil
            speeds[id] = nil
            samples[id] = nil
            persistedAt[id] = nil
            generations[id] = nil
            if removing.remove(id) != nil || record(id)?.status == .cancelled { DownloadFiles.discardStaging(id: id, root: stagingRoot) }
            pump()
        }
        do {
            let settings = self.settings
            let folder = try DownloadFolder(settings: settings)
            let artifact = try await engine.run(candidate: candidate, id: id) { [weak self] update in
                Task { @MainActor in self?.received(id: id, generation: generation, progress: update) }
            } processing: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generations[id] == generation, self.record(id)?.status == .downloading else { return }
                    self.update(id: id) { $0.status = .processing }
                    self.speeds[id] = nil
                }
            }
            try Task.checkCancellation()
            guard record(id) != nil else { throw CancellationError() }
            update(id: id) { $0.status = .processing }
            let commitTask = Task.detached(priority: .utility) {
                try DownloadFiles.commit(staged: artifact.file, candidate: candidate, fileExtension: artifact.fileExtension,
                                         folder: folder.url, collisionPolicy: settings.collisionPolicy)
            }
            let destination = try await withTaskCancellationHandler { try await commitTask.value } onCancel: { commitTask.cancel() }
            let bookmark = DownloadFileLease.bookmark(for: destination)
            withExtendedLifetime(folder) {}
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            update(id: id) {
                $0.status = .completed
                $0.filePath = destination.path
                $0.fileBookmark = bookmark
                $0.completedAt = Date()
                $0.bytesReceived = size ?? $0.bytesReceived
                $0.totalBytes = size ?? $0.totalBytes
                $0.error = nil
            }
            DownloadFiles.discardStaging(id: id, root: stagingRoot)
            logger.info("Download completed")
            if settings.notifyCompletion { notify(id: id, title: "下载完成", body: destination.lastPathComponent) }
            if settings.openWhenFinished { NSWorkspace.shared.open(destination) }
        } catch {
            guard let record = record(id) else { return }
            if error is CancellationError || Task.isCancelled {
                // Pause/cancel/resume owns its requested state. A rapid Resume
                // is queued while the old worker flushes and closes its file.
                if record.status == .downloading || record.status == .processing {
                    update(id: id) { $0.status = .paused; $0.error = nil }
                } else { persist(id: id) }
            } else {
                let message = error.downloadDescription
                update(id: id) { $0.status = .failed; $0.error = message }
                logger.error("Download failed: \(message, privacy: .private)")
                if settings.notifyFailure { notify(id: id, title: "下载失败", body: candidate.title + "\n" + message) }
            }
        }
    }

    private func received(id: UUID, generation: UUID, progress: TransferProgress) {
        guard generations[id] == generation, let index = records.firstIndex(where: { $0.id == id }), records[index].status == .downloading else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if let sample = samples[id], now - sample.time >= 0.2, progress.bytes >= sample.bytes {
            let measured = Double(progress.bytes - sample.bytes) / (now - sample.time)
            speeds[id] = (speeds[id] ?? measured) * 0.55 + measured * 0.45
            samples[id] = (progress.bytes, now)
        } else if samples[id] == nil || progress.bytes < (samples[id]?.bytes ?? 0) {
            samples[id] = (progress.bytes, now)
        }
        records[index].bytesReceived = progress.bytes
        records[index].totalBytes = progress.total
        if now - (persistedAt[id] ?? 0) >= 1.5 {
            persistedAt[id] = now
            persist(id: id)
        }
    }

    private func record(_ id: UUID) -> DownloadRecord? { records.first { $0.id == id } }

    private func update(id: UUID, change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        persist(id: id)
    }

    private func persist(id: UUID) {
        guard let record = record(id) else { return }
        do { try store.saveDownload(record) }
        catch { lastError = error.downloadDescription }
    }

    private func notify(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(500))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "download-\(id.uuidString)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
