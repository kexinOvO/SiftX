import AppKit
import AVFoundation
import AVKit
import SwiftUI
import WebKit
import SiftXCore

/// 下载前预览：黑色播放面上仅悬浮「返回」和「下载」两个控件，铺满 popover 内容区呈现（仅视频）。
/// 音频不走此预览层，由列表行内的 InlineAudioBadge 直接播放/暂停。
struct MediaPreviewView: View {
    let candidate: MediaCandidate
    var submitted: Bool
    var back: () -> Void
    var download: () -> Void
    @StateObject private var playback = MediaPreviewPlayback()
    @State private var webPreviewID = UUID()

    var body: some View {
        ZStack {
            Color.black
            if candidate.transport == .youtube {
                YouTubePreviewPlayer(candidate: candidate) { message in
                    playback.loading = false
                    playback.error = message
                }
                .id(webPreviewID)
            } else if let player = playback.player, !playback.loading, playback.error == nil {
                // 内容就绪后再挂播放器视图，避免加载阶段悬浮播放控件提前出现在黑面上。
                NativePreviewPlayer(player: player)
            }
            if playback.loading {
                ProgressView("正在加载预览…").tint(.white).foregroundStyle(.white)
                    .padding(16).background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = playback.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.title)
                    Text(error).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("重试") {
                        if candidate.transport == .youtube {
                            playback.loading = true
                            playback.error = nil
                            webPreviewID = UUID()
                        } else {
                            Task { await playback.load(candidate) }
                        }
                    }
                }
                .foregroundStyle(.white).padding(24).frame(maxWidth: 440)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("返回媒体列表").accessibilityLabel("返回媒体列表")
            .keyboardShortcut(.cancelAction)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: download) {
                Image(systemName: submitted ? "checkmark" : "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(submitted)
            .padding(10)
            .help(submitted ? "已加入下载队列" : "下载当前预览的媒体")
            .accessibilityLabel(submitted ? "已加入下载队列" : "下载当前预览的媒体")
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .task(id: candidate.id) {
            if candidate.transport != .youtube { await playback.load(candidate) }
        }
        .task(id: webPreviewID) {
            guard candidate.transport == .youtube else { return }
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            if playback.loading {
                playback.loading = false
                playback.error = "网页播放器加载超时，请重试或在原网页预览。"
            }
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
final class MediaPreviewPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = true
    @Published var error: String?
    @Published var hasAudio: Bool?
    @Published var resolution: String?
    private var proxy: MediaPreviewProxy?
    private var observation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var watchdog: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()

    func load(_ candidate: MediaCandidate) async {
        stop()
        loading = true; error = nil; hasAudio = nil; resolution = nil
        let generation = self.generation
        let proxy = MediaPreviewProxy()
        self.proxy = proxy
        let task = Task { [weak self] in
            do {
                let url = try await proxy.start(candidate: candidate)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { await proxy.stop(); return }
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 3
                let player = AVPlayer(playerItem: item)
                self.player = player
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        if status == .readyToPlay { self.loading = false; self.watchdog?.cancel() }
                        else if status == .failed {
                            self.stop()
                            self.loading = false
                            self.error = "无法播放此媒体。请刷新网页后重试，或在原网页确认内容和声音。"
                        }
                    }
                }
                sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
                    let size = item.presentationSize
                    Task { @MainActor in
                        guard let self, self.generation == generation, size.width > 0, size.height > 0,
                              size.width.isFinite, size.height.isFinite, size.width <= 32_768, size.height <= 32_768 else { return }
                        self.resolution = "\(Int(size.width))×\(Int(size.height))"
                    }
                }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.stop(); self.loading = false
                        self.error = "预览播放中断。请重试，或在原网页继续播放。"
                    }
                }
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.generation == generation, self.loading else { return }
                    self.stop(); self.loading = false
                    self.error = "预览加载超时。请检查网络后重试，或在原网页播放。"
                }
                // Playback only begins after the user's click; menu thumbnails are muted.
                player.play()
                let tracks = try? await asset.loadTracks(withMediaType: .audio)
                let group = try? await asset.loadMediaSelectionGroup(for: .audible)
                guard !Task.isCancelled, self.generation == generation else { return }
                if let tracks { hasAudio = !tracks.isEmpty || group?.options.isEmpty == false }
            } catch is CancellationError {
                await proxy.stop()
            } catch {
                await proxy.stop()
                guard let self, self.generation == generation else { return }
                loading = false; self.error = error.localizedDescription
                watchdog?.cancel()
            }
        }
        preparation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func stop() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        observation?.invalidate(); observation = nil
        sizeObservation?.invalidate(); sizeObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        watchdog?.cancel(); watchdog = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let proxy { Task { await proxy.stop() } }
        proxy = nil
    }
}

private struct NativePreviewPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

private struct YouTubePreviewPlayer: NSViewRepresentable {
    let candidate: MediaCandidate
    var finished: @MainActor (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let canonical = YouTubeURL.canonical(candidate.sourceURL),
           let id = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           let url = URL(string: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0") {
            var request = URLRequest(url: url)
            request.setValue("https://com.siftx.SiftX", forHTTPHeaderField: "Referer")
            view.load(request)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let finished: @MainActor (String?) -> Void
        init(finished: @MainActor @escaping (String?) -> Void) { self.finished = finished }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished(nil) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finished("无法加载网页播放器。请检查网络后在原网页预览。")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finished("网页播放器加载失败，请在原网页预览。")
        }
    }
}
