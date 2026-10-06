import SwiftUI
import AppKit
import AVFoundation
import AVKit
import SiftXCore

enum FileActions {
    static func exists(_ record: DownloadRecord, settings: AppSettings) -> Bool {
        (try? DownloadFileLease(record: record, settings: settings).exists) ?? false
    }
    static func reveal(_ record: DownloadRecord, settings: AppSettings) {
        if let lease = try? DownloadFileLease(record: record, settings: settings), lease.exists {
            NSWorkspace.shared.activateFileViewerSelecting([lease.url])
            withExtendedLifetime(lease) {}
        }
    }
    static func open(_ record: DownloadRecord, settings: AppSettings) {
        if let lease = try? DownloadFileLease(record: record, settings: settings), lease.exists {
            NSWorkspace.shared.open(lease.url)
            withExtendedLifetime(lease) {}
        }
    }
    static func copySource(_ record: DownloadRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.candidate.pageURL.absoluteString, forType: .string)
    }
}

struct DownloadDetail: View {
    let record: DownloadRecord
    @ObservedObject var manager: DownloadManager
    let delete: () -> Void

    var body: some View {
        Form {
            if record.status == .completed, record.candidate.kind == .video {
                Section {
                    CompletedMediaPreview(record: record, settings: manager.settings)
                }
            }
            Section {
                Text(record.candidate.title).font(.title3.bold()).textSelection(.enabled)
                LabeledContent("状态", value: record.status.label)
                if let quality = record.candidate.quality { LabeledContent("质量", value: quality) }
                if let duration = record.candidate.durationLabel { LabeledContent("时长", value: duration) }
                if let encryption = record.candidate.encryption { LabeledContent("加密方式", value: encryption.rawValue) }
                if let width = record.candidate.width, let height = record.candidate.height { LabeledContent("分辨率", value: "\(width) × \(height)") }
                LabeledContent("内容", value: record.candidate.kind == .audio ? "仅音频" : (record.candidate.transport != .direct && record.candidate.hasAudio ? "视频 + 音频" : "视频"))
                LabeledContent("已下载", value: ByteCountFormatter.string(fromByteCount: record.bytesReceived, countStyle: .file))
                if let total = record.totalBytes { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) }
                if let total = record.totalBytes, let speed = manager.speeds[record.id], speed > 0, record.status == .downloading {
                    LabeledContent("预计剩余", value: Duration.seconds(Double(max(0, total - record.bytesReceived)) / speed).formatted(.time(pattern: .minuteSecond)))
                }
                if let error = record.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled) }
                controls
            }
            Section("来源") {
                Text(record.candidate.pageTitle).textSelection(.enabled)
                Link(record.candidate.pageURL.host ?? "打开网页", destination: record.candidate.pageURL)
                Button("复制来源链接", systemImage: "link") { FileActions.copySource(record) }
                LabeledContent("添加时间") { Text(record.createdAt, style: .date) }
                if let date = record.completedAt { LabeledContent("完成时间") { Text(date, style: .date) } }
            }
            if let path = record.filePath {
                Section("文件") {
                    Text(URL(fileURLWithPath: path).lastPathComponent).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 3)) { _ in
                        if FileActions.exists(record, settings: manager.settings) {
                            Button("打开文件", systemImage: "play.circle") { FileActions.open(record, settings: manager.settings) }
                            Button("在 Finder 中显示", systemImage: "folder") { FileActions.reveal(record, settings: manager.settings) }
                        } else { Label("文件已移动、删除或需要重新授权", systemImage: "doc.badge.ellipsis").foregroundStyle(.secondary) }
                    }
                }
            }
            Section { Button("删除记录…", role: .destructive, action: delete) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            if record.status == .completed, record.candidate.kind == .audio {
                CompletedMediaPreview(record: record, settings: manager.settings)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
        }
        .navigationTitle("下载详情")
    }

    @ViewBuilder private var controls: some View {
        HStack {
            switch record.status {
            case .queued, .downloading, .processing:
                Button("暂停", systemImage: "pause") { manager.pause(id: record.id) }
                Button("取消", systemImage: "xmark") { manager.cancel(id: record.id) }
            case .paused:
                Button("继续", systemImage: "play") { manager.resume(id: record.id) }
                Button("取消", systemImage: "xmark") { manager.cancel(id: record.id) }
            case .failed, .cancelled:
                Button("重试", systemImage: "arrow.clockwise") { manager.retry(id: record.id) }
            case .completed:
                Button("重新下载", systemImage: "arrow.clockwise") { manager.enqueue(candidate: record.candidate) }
            }
        }
    }
}

private struct CompletedMediaPreview: View {
    let record: DownloadRecord
    let settings: AppSettings
    @StateObject private var playback = CompletedMediaPlayback()

    private var isAudio: Bool { record.candidate.kind == .audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isAudio {
                Label("视频预览", systemImage: "play.rectangle").font(.headline)
            }
            if let error = playback.error {
                VStack(alignment: .leading, spacing: 12) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("重试预览", systemImage: "arrow.clockwise") { playback.load(record, settings: settings) }
                        if playback.fileAvailable {
                            Button("打开文件", systemImage: "arrow.up.forward.app") { FileActions.open(record, settings: settings) }
                        }
                    }
                }
                .padding(.vertical, 12)
            } else if isAudio {
                CompletedAudioControls(playback: playback)
            } else {
                ZStack {
                    Color.black
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if let player = playback.player, !playback.loading {
                                CompletedMediaPlayer(player: player)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if playback.loading {
                        ProgressView("正在加载预览…")
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: identity) { playback.load(record, settings: settings) }
        .onDisappear { playback.stop() }
    }

    private var identity: Identity {
        Identity(id: record.id, path: record.filePath, bookmark: record.fileBookmark,
                 folderBookmark: settings.downloadBookmark, folder: settings.downloadDirectory)
    }

    private struct Identity: Equatable {
        let id: UUID
        let path: String?
        let bookmark: Data?
        let folderBookmark: Data?
        let folder: String?
    }
}

private struct CompletedAudioControls: View {
    @ObservedObject var playback: CompletedMediaPlayback
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playback.togglePlayback) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(playback.loading)
            .help(playback.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(playback.isPlaying ? "暂停音频" : "播放音频")
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : playback.elapsed },
                set: { value in
                    scrubPosition = value
                    if !scrubbing { playback.seek(to: value) }
                }
            ), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                if editing {
                    scrubPosition = playback.elapsed
                    scrubbing = true
                } else {
                    scrubbing = false
                    playback.seek(to: scrubPosition)
                }
            })
            .disabled(playback.loading || playback.duration <= 0)
            .accessibilityLabel("音频播放进度")
            .accessibilityValue(Duration.seconds(playback.elapsed).formatted(.time(pattern: .minuteSecond)))
        }
        .frame(height: 32)
    }
}

/// Keep the completed file's security-scoped access alive for the entire playback session.
@MainActor
private final class CompletedMediaPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published private(set) var fileAvailable = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    private var lease: DownloadFileLease?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var seekGeneration = UUID()
    private var seeking = false
    private var ended = false
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()

    func load(_ record: DownloadRecord, settings: AppSettings) {
        stop()
        loading = true
        error = nil
        fileAvailable = false
        let generation = self.generation
        guard let lease = try? DownloadFileLease(record: record, settings: settings), lease.exists else {
            loading = false
            error = "文件已移动、删除或需要重新授权，请检查下载文件和目录权限。"
            return
        }
        self.lease = lease
        fileAvailable = true
        let item = AVPlayerItem(url: lease.url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        if record.candidate.kind == .audio {
            durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
                let seconds = item.duration.seconds
                Task { @MainActor in
                    guard let self, self.generation == generation, seconds.isFinite, seconds > 0 else { return }
                    self.duration = seconds
                }
            }
            playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.timeControlStatus != .paused
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.isPlaying = playing
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == generation, !self.seeking, !self.ended else { return }
                    let seconds = time.seconds
                    if seconds.isFinite { self.elapsed = min(max(0, seconds), max(self.duration, 0)) }
                }
            }
        }
        if record.candidate.kind == .audio {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == generation, !self.seeking else { return }
                    self.ended = true
                    self.elapsed = self.duration
                    self.isPlaying = false
                }
            }
        }
        // Load the first frame and controls; playback starts only when the user presses Play.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let duration = item.duration.seconds
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch status {
                case .readyToPlay:
                    if duration.isFinite && duration > 0 { self.duration = duration }
                    self.loading = false
                    self.watchdog?.cancel()
                    self.watchdog = nil
                case .failed:
                    self.fail("此文件无法在内置播放器中预览，可尝试打开文件。")
                default: break
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.fail("预览播放中断，请重试或打开文件。")
            }
        }
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.generation == generation, self.loading else { return }
            self.fail("预览加载超时，请重试或打开文件。")
        }
    }

    private func fail(_ message: String) {
        stop()
        loading = false
        error = message
    }

    func togglePlayback() {
        guard let player, !loading else { return }
        if isPlaying { player.pause() }
        else {
            if ended || (duration > 0 && elapsed >= duration) { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player, duration > 0, seconds.isFinite else { return }
        let position = min(max(seconds, 0), duration)
        elapsed = position
        ended = false
        seeking = true
        seekGeneration = UUID()
        let seekGeneration = self.seekGeneration
        let generation = self.generation
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation, self.seekGeneration == seekGeneration else { return }
                self.seeking = false
            }
        }
    }

    func stop() {
        generation = UUID()
        statusObservation?.invalidate(); statusObservation = nil
        durationObservation?.invalidate(); durationObservation = nil
        playbackObservation?.invalidate(); playbackObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        watchdog?.cancel(); watchdog = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        lease = nil
        elapsed = 0
        duration = 0
        isPlaying = false
        seeking = false
        ended = false
    }
}

private struct CompletedMediaPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
