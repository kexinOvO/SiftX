import AppKit
import Combine
import SwiftUI
@preconcurrency import SafariServices
import SiftXCore

private enum PopoverLayout {
    static let width: CGFloat = 195
    static let previewSize = NSSize(width: 560, height: 440)
}

enum PopoverMediaFilter: String, CaseIterable, Identifiable {
    case all = "全部", video = "视频", audio = "音频"

    var id: String { rawValue }
    var kind: MediaKind? {
        switch self {
        case .all: return nil
        case .video: return .video
        case .audio: return .audio
        }
    }

    var emptyReason: String {
        switch self {
        case .all: return "未发现可下载媒体。请播放网页中的视频或音频后再试。"
        case .video: return "当前网页未发现可下载视频。"
        case .audio: return "当前网页未发现可下载音频。"
        }
    }
}

@MainActor
final class SiftXPopoverController: SFSafariExtensionViewController {
    static let shared = SiftXPopoverController()
    let model = PopoverModel()
    private var listSize = NSSize(width: PopoverLayout.width, height: 140)

    init() {
        super.init(nibName: nil, bundle: nil)
        // Safari reads the size before loading the remotely hosted view.
        preferredContentSize = NSSize(width: PopoverLayout.width, height: 140)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        preferredContentSize = NSSize(width: PopoverLayout.width, height: 140)
    }

    override func loadView() {
        // 93 = 筛选栏 44 + 分隔线 ~1 + 底部操作栏 48
        let initialContentHeight = max(44, listSize.height - 93)
        let host = NSHostingView(rootView: SiftXPopoverView(model: model, initialContentHeight: initialContentHeight) { [weak self] size in
            guard let self else { return }
            if size.width == PopoverLayout.width { listSize = size }
            apply(size: size)
        })
        host.frame = NSRect(origin: .zero, size: preferredContentSize)
        view = host
        preferredContentSize = NSSize(width: PopoverLayout.width, height: 140)
    }

    /// Safari 的 popover 窗口由 Safari 远程托管，preferredContentSize 变更只会瞬时生效
    /// （NSAnimationContext、window.animator() 均被其自身布局覆盖，无法动画），这里直接瞬时切换。
    private func apply(size: NSSize) {
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        view.setFrameSize(size)
    }
}

@MainActor
final class PopoverModel: ObservableObject {
    @Published var candidates: [MediaCandidate] = []
    @Published var mediaFilter: PopoverMediaFilter = .all
    @Published var loading = false
    @Published var error: String?
    @Published var submitted: Set<String> = []
    @Published var previewCandidate: MediaCandidate?
    /// 行内音频试听：点击列表行图标直接播放/暂停，不再打开预览覆盖层。
    let audioPlayback = MediaPreviewPlayback()
    @Published var playingAudioID: String?
    @Published var audioPaused = false
    private var cancellables: Set<AnyCancellable> = []
    private var context: NativePageContext?
    private var window: SFSafariWindow?
    private var polling: Task<Void, Never>?
    private var discoveryStarted = Date()
    private var lifecycleGeneration = 0

    init() {
        // audioPlayback 的 @Published 变化转发到 model，驱动列表行刷新（加载圈/暂停图标等）。
        audioPlayback.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    private var matchingCandidates: [MediaCandidate] {
        candidates.filter { mediaFilter.kind == nil || $0.kind == mediaFilter.kind }
    }
    var downloadableCandidates: [MediaCandidate] { matchingCandidates.filter { $0.protection == nil } }
    var showingLoadingState: Bool {
        loading && (candidates.isEmpty || matchingCandidates.contains { $0.protection == "正在分析媒体…" })
    }

    var unavailableReasons: [String] {
        var reasons: [String] = []
        for reason in matchingCandidates.compactMap(\.protection) where reason != "正在分析媒体…" {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        if let error, !reasons.contains(error) { reasons.append(error) }
        if downloadableCandidates.isEmpty && reasons.isEmpty && !showingLoadingState {
            reasons.append(mediaFilter.emptyReason)
        }
        return reasons
    }

    func begin(window: SFSafariWindow) {
        stop()
        self.window = window
        mediaFilter = .all
        // 复用上次的 context/candidates：重开 popover 时内容与高度立刻稳定，
        // 避免「加载态 → 列表」闪变和 preferredContentSize 变更引起的窗口跳变。
        // 换了页面时 updateContext 检测到 sessionID 变化会自动清空重建。
        error = nil
        loading = candidates.isEmpty
        discoveryStarted = Date()
        polling = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                await synchronizeContext()
                if Task.isCancelled { break }
                readPage()
                if candidates.isEmpty { loading = context != nil && error == nil && Date().timeIntervalSince(discoveryStarted) < 3 }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() { lifecycleGeneration += 1; polling?.cancel(); polling = nil; closePreview(); stopAudio() }

    func preview(_ candidate: MediaCandidate) {
        guard candidate.protection == nil else { return }
        if candidate.transport == .bilibili, candidate.kind == .audio {
            NSWorkspace.shared.open(candidate.pageURL)
            return
        }
        if candidate.kind == .audio {
            toggleAudio(candidate)
        } else {
            stopAudio()
            previewCandidate = candidate
        }
    }

    /// 音频行内试听：再次点击同一行 = 播放/暂停切换；点击其他行 = 换曲重载；失败后点击 = 重试。
    private func toggleAudio(_ candidate: MediaCandidate) {
        if playingAudioID == candidate.id, audioPlayback.error == nil {
            if audioPaused {
                audioPlayback.player?.play()
                audioPaused = false
            } else {
                audioPlayback.player?.pause()
                audioPaused = true
            }
        } else {
            audioPaused = false
            playingAudioID = candidate.id
            Task { await audioPlayback.load(candidate) }
        }
    }

    func stopAudio() {
        audioPlayback.stop()
        playingAudioID = nil
        audioPaused = false
    }

    func closePreview() { previewCandidate = nil }

    func refresh() async {
        guard let window else { return }
        loading = true; error = nil
        discoveryStarted = Date()
        let generation = lifecycleGeneration
        let next = await PageContextResolver.shared.context(in: window, refresh: true)
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        updateContext(next)
        readPage()
    }

    private func synchronizeContext() async {
        guard let window else { return }
        let generation = lifecycleGeneration
        let next = await PageContextResolver.shared.context(in: window)
        guard generation == lifecycleGeneration, !Task.isCancelled else { return }
        updateContext(next)
    }

    private func updateContext(_ next: NativePageContext?) {
        if context?.sessionID != next?.sessionID {
            closePreview()
            candidates = []; error = nil; discoveryStarted = Date()
        }
        context = next
        guard let context else {
            loading = false
            error = "无法读取此网页。请允许两个 SiftX 扩展访问当前网站，然后刷新网页。"
            return
        }
        if context.privateBrowsing {
            loading = false
            error = "SiftX 不会保存私人浏览页面的媒体信息。请在普通窗口中打开此网页。"
            return
        }
    }

    private func readPage() {
        guard let context, !context.privateBrowsing else { return }
        do {
            if let page = try SharedStore().page(id: context.sessionID) {
                candidates = page.candidates
                loading = candidates.contains { $0.protection == "正在分析媒体…" }
            } else { candidates = [] }
        } catch { self.error = error.localizedDescription; loading = false }
    }

    func download(_ candidate: MediaCandidate) {
        guard candidate.protection == nil else { return }
        do {
            _ = try SharedStore().enqueue(candidate: candidate)
            submitted.insert(candidate.id)
            openApp()
        } catch { self.error = error.localizedDescription }
    }

    func openApp() {
        guard let url = URL(string: "siftx://downloads") else { return }
        if !NSWorkspace.shared.open(url) { error = "无法打开 SiftX。请手动打开应用。" }
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SiftXPopoverView: View {
    @ObservedObject var model: PopoverModel
    var onSizeChange: @MainActor (NSSize) -> Void
    @State private var contentHeight: CGFloat

    init(model: PopoverModel, initialContentHeight: CGFloat, onSizeChange: @MainActor @escaping (NSSize) -> Void) {
        self.model = model
        self.onSizeChange = onSizeChange
        // 初始高度继承上次的实际值，避免重开首帧按默认值布局造成闪动。
        _contentHeight = State(initialValue: initialContentHeight)
    }

    var body: some View {
        // 预览铺满整个 popover 内容区，不做自身的位移动画：
        // 窗口 frame 动画（见控制器 apply(size:)）是唯一的运动来源，
        // 卡片跟随窗口一起长大/缩回。实测卡片自身的 frame 动画会与
        // 窗口动画互相 retarget，停在中间尺寸永远填不满窗口。
        ZStack {
            mediaList
            if let candidate = model.previewCandidate {
                MediaPreviewView(candidate: candidate, submitted: model.submitted.contains(candidate.id),
                                 back: model.closePreview, download: { model.download(candidate) })
                    .id(candidate.id)
            }
        }
        .onChange(of: model.previewCandidate?.id) {
            onSizeChange(model.previewCandidate == nil ? NSSize(width: PopoverLayout.width, height: contentHeight + 93) : PopoverLayout.previewSize)
        }
    }

    private var mediaList: some View {
        VStack(spacing: 0) {
            GlassMediaFilterPicker(selection: $model.mediaFilter)
                .padding(.horizontal, 12)
                .frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.downloadableCandidates) { candidate in
                        MediaChoiceRow(candidate: candidate, submitted: model.submitted.contains(candidate.id),
                                       audio: candidate.kind == .audio
                                           ? InlineAudioState(
                                               active: model.playingAudioID == candidate.id,
                                               loading: model.playingAudioID == candidate.id
                                                   && model.audioPlayback.loading && model.audioPlayback.error == nil,
                                               failed: model.playingAudioID == candidate.id && model.audioPlayback.error != nil,
                                               paused: model.audioPaused)
                                           : nil,
                                       preview: { model.preview(candidate) }, download: { model.download(candidate) })
                        if candidate.id != model.downloadableCandidates.last?.id { Divider().padding(.leading, candidate.kind == .audio ? 44 : 68) }
                    }
                    if model.showingLoadingState {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在发现网页媒体…").font(.callout).foregroundStyle(.secondary)
                        }.padding(12)
                    }
                    if !model.unavailableReasons.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.unavailableReasons, id: \.self) { reason in
                                Text(reason).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PopoverContentHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .frame(height: contentHeight)
            Divider()
            HStack {
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读取当前网页")
                .accessibilityLabel("刷新媒体列表")
                Spacer()
                Button("在 SiftX 中打开", action: model.openApp).buttonStyle(.borderless)
            }.frame(height: 48).padding(.horizontal, 12)
        }
        .frame(width: PopoverLayout.width)
        .onPreferenceChange(PopoverContentHeightKey.self) { height in
            Task { @MainActor in
                guard model.previewCandidate == nil, height > 0 else { return }
                let next = min(336, max(44, ceil(height)))
                if contentHeight != next { contentHeight = next }
                onSizeChange(NSSize(width: PopoverLayout.width, height: next + 93))
            }
        }
    }
}

/// Liquid Glass 风格的媒体种类筛选控件：毛玻璃胶囊容器 + 可滑动的玻璃透镜选中态。
private struct GlassMediaFilterPicker: View {
    @Binding var selection: PopoverMediaFilter
    @Namespace private var glass

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PopoverMediaFilter.allCases) { filter in
                segment(for: filter)
            }
        }
        .padding(2)
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("筛选媒体种类")
    }

    private func segment(for filter: PopoverMediaFilter) -> some View {
        let isSelected = selection == filter
        return Button {
            guard !isSelected else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selection = filter
            }
        } label: {
            // 粗细无法插值动画，用两层文字交叉淡入淡出实现平滑过渡
            ZStack {
                Text(filter.rawValue)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .opacity(isSelected ? 0 : 1)
                Text(filter.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Capsule())
                .background {
                    if isSelected {
                        GlassLens()
                            .matchedGeometryEffect(id: "lens", in: glass)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 选中项的玻璃透镜：白渐变镜面 + 彩虹折射描边 + 顶部高光 + 柔和投影。
private struct GlassLens: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let faceGradient = LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.30), Color.white.opacity(0.12)]
                : [Color.white.opacity(0.95), Color.white.opacity(0.62)],
            startPoint: .top, endPoint: .bottom
        )
        return Capsule()
            .fill(faceGradient)
            .overlay {
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.28 : 0.85), .clear], startPoint: .top, endPoint: .center))
                    .padding(0.5)
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0.9), lineWidth: 0.5)
                    .padding(0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 3, y: 1.5)
    }
}

/// 音频行内试听状态（仅对音频行传入）。
struct InlineAudioState {
    var active: Bool    // 该行是当前加载/播放中的音频
    var loading: Bool   // 正在加载流
    var failed: Bool    // 上次播放失败
    var paused: Bool    // 已加载且处于暂停
}

/// 列表行内的音频试听控件：悬停显示播放按钮，播放中显示暂停，失败显示警告。
private struct InlineAudioBadge: View {
    var state: InlineAudioState?
    @State private var hovering = false

    private var showingControl: Bool {
        guard let state else { return false }
        return state.failed || hovering || (state.active && !state.loading && !state.paused)
    }

    var body: some View {
        ZStack {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let state {
                if state.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if state.loading {
                    ProgressView().controlSize(.mini)
                } else if showingControl {
                    Image(systemName: state.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.accentColor.opacity(0.85), in: Circle())
                }
            }
        }
        .frame(width: 24)
        .padding(.top, 3)
        .onHover { hovering = $0 }
    }
}

private struct DownloadButtonAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.1, *) {
            content.buttonStyle(.glass(.clear))
        } else if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct MediaChoiceRow: View {
    let candidate: MediaCandidate
    var submitted: Bool
    var audio: InlineAudioState?
    var preview: () -> Void
    var download: () -> Void

    private var audioHelp: String {
        if candidate.transport == .bilibili, candidate.kind == .audio { return "在原网页试听" }
        guard let audio else { return "点击试听" }
        if audio.failed { return "播放失败，点击重试" }
        if audio.loading { return "正在加载音频…" }
        return audio.paused ? "继续播放" : "暂停"
    }

    private var detail: String {
        var parts: [String] = []
        parts.append(candidate.formatName)
        if let duration = candidate.durationLabel { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
    private var heading: String {
        if let width = candidate.width, let height = candidate.height { return "\(width)×\(height)" }
        return candidate.quality ?? (candidate.kind == .audio ? "音频" : "视频")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: preview) {
                if candidate.kind == .audio {
                    InlineAudioBadge(state: audio)
                } else {
                    MediaThumbnailView(candidate: candidate)
                        .frame(width: 48, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .buttonStyle(.borderless)
            .help(audioHelp)
            .accessibilityLabel(candidate.kind == .audio ? audioHelp + "：" + candidate.displayTitle : "预览\(heading)视频")
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            Button(action: download) {
                Image(systemName: submitted ? "checkmark" : "arrow.down")
                    .font(.title3)
                    .fontWeight(submitted ? .regular : .bold)
                    // 抵消外层按钮缩放，使箭头最终为原尺寸的 0.7 倍。
                    .scaleEffect((submitted ? 1.0 : 0.7) / 1.2)
            }
                .modifier(DownloadButtonAppearance())
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .scaleEffect(1.2)
                .disabled(submitted)
                .help(submitted ? "已加入下载队列" : "下载此媒体")
                .accessibilityLabel(submitted ? "已加入下载队列" : "下载\(heading)")
        }.padding(.horizontal, 12).padding(.vertical, 13)
    }
}
