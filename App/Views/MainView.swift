import SwiftUI
import AppKit
import SiftXCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case downloads = "全部下载"
    case downloading = "正在下载"
    case completed = "已完成"
    case failed = "失败"
    case video = "视频"
    case audio = "音频"
    case other = "其他"

    static let downloadSections: [Self] = [.downloads, .downloading, .completed, .failed]
    static let mediaSections: [Self] = [.video, .audio, .other]

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .downloading: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .video: "play.circle"
        case .audio: "waveform.circle"
        case .other: "document.circle"
        }
    }

    func includes(_ record: DownloadRecord) -> Bool {
        switch self {
        case .downloads: true
        case .downloading: record.status == .downloading || record.status == .processing
        case .completed: record.status == .completed
        case .failed: record.status == .failed
        case .video: record.candidate.kind == .video
        case .audio: record.candidate.kind == .audio
        case .other: ![MediaKind.video, .audio].contains(record.candidate.kind)
        }
    }

    var emptyTitle: String {
        switch self {
        case .downloads: "还没有下载任务"
        case .downloading: "没有正在下载的任务"
        case .completed: "还没有已完成的下载"
        case .failed: "没有失败的下载"
        case .video: "还没有视频下载"
        case .audio: "还没有音频下载"
        case .other: "还没有其他下载"
        }
    }

    var emptyDescription: String {
        switch self {
        case .downloads, .video, .audio:
            "在 Safari 的 SiftX 菜单选择媒体，或添加媒体链接。"
        case .downloading:
            "下载和文件整理中的任务会显示在这里。"
        case .completed:
            "已完成的下载会显示在这里。"
        case .failed:
            "下载失败的任务会显示在这里，可重试或删除。"
        case .other:
            "其他媒体类型的下载会显示在这里。"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: ApplicationModel
    @ObservedObject var manager: DownloadManager
    @State private var section: LibrarySection? = .downloads
    @State private var downloadPath: [UUID] = []
    @State private var search = ""
    @State private var deletion: DownloadRecord?
    @State private var deleteFile = false
    @State private var onboarding = false

    private var selectedSection: LibrarySection { section ?? .downloads }

    private var visible: [DownloadRecord] {
        manager.records.filter { record in
            selectedSection.includes(record) && (search.isEmpty || record.candidate.title.localizedCaseInsensitiveContains(search) || record.candidate.pageTitle.localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "没有匹配的下载" }
        return selectedSection.emptyTitle
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("下载管理") {
                    sidebarItems(LibrarySection.downloadSections)
                }
                Section("媒体类型") {
                    sidebarItems(LibrarySection.mediaSections)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Safari 中发现，Mac 上保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Safari 扩展设置", systemImage: "safari") { model.openSafariPreferences() }
                        .buttonStyle(.link)
                }.padding()
            }
        } detail: {
            NavigationStack(path: $downloadPath) {
                Group {
                    if visible.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: selectedSection.symbol, description: Text(search.isEmpty ? selectedSection.emptyDescription : "试试其他标题或网页名称。"))
                    } else {
                        List(visible) { record in
                            NavigationLink(value: record.id) {
                                DownloadRow(record: record, speed: manager.speeds[record.id] ?? 0, settings: manager.settings)
                            }
                            .contextMenu { recordActions(record) }
                        }.listStyle(.inset)
                    }
                }
                .navigationTitle(selectedSection.rawValue)
                .navigationDestination(for: UUID.self) { id in
                    if let record = manager.records.first(where: { $0.id == id }) {
                        DownloadDetail(record: record, manager: manager, delete: { deletion = record })
                            .id(record.id)
                    }
                }
            }
            .frame(minWidth: 360)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 400)
        .searchable(text: $search, prompt: "搜索下载")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) { downloadControls }
        }
        .sheet(isPresented: $model.showAddURL) { AddURLView(manager: manager) }
        .sheet(isPresented: $onboarding) { OnboardingView().environmentObject(model) }
        .onAppear { onboarding = !model.settings.onboardingComplete }
        .onChange(of: section) { _, _ in downloadPath.removeAll() }
        .onChange(of: manager.records.map(\.id)) { _, ids in
            if downloadPath.contains(where: { !ids.contains($0) }) {
                downloadPath.removeAll()
            }
        }
        .alert("删除下载", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil; deleteFile = false } })) {
            if deletion?.filePath != nil { Toggle("同时删除下载文件", isOn: $deleteFile) }
            Button("取消", role: .cancel) { deletion = nil }
            Button("删除", role: .destructive) {
                if let record = deletion { manager.remove(id: record.id, deleteFile: deleteFile) }
                deletion = nil; deleteFile = false
            }
        } message: { Text(deleteFile ? "文件将从磁盘删除。" : "删除下载记录。") }
        .alert("操作未完成", isPresented: Binding(get: { manager.lastError != nil }, set: { if !$0 { manager.lastError = nil } })) {
            Button("好") { manager.lastError = nil }
        } message: { Text(manager.lastError ?? "") }
    }

    @ViewBuilder private func sidebarItems(_ items: [LibrarySection]) -> some View {
        ForEach(items) { item in
            Button {
                section = item
                downloadPath.removeAll()
            } label: {
                Label {
                    Text(item.rawValue)
                } icon: {
                    Image(systemName: item.symbol)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .badge(item == .downloading ? manager.activeCount : 0)
            .accessibilityLabel(item.rawValue)
            .accessibilityValue(item == .downloading ? "\(manager.activeCount) 个任务" : "")
            .tag(item)
        }
    }

    @ViewBuilder private var downloadControls: some View {
        Button { model.showAddURL = true } label: { Label("添加媒体链接", systemImage: "plus") }
            .help("添加媒体链接（⌘N）")
        Menu {
            Button("暂停全部", systemImage: "pause") { manager.pauseAll() }
            Button("继续全部", systemImage: "play") { manager.resumeAll() }
            Divider()
            Button("清除已完成任务") { manager.clearCompleted() }
        } label: { Label("下载操作", systemImage: "ellipsis.circle") }
    }

    @ViewBuilder private func recordActions(_ record: DownloadRecord) -> some View {
        switch record.status {
        case .queued, .downloading, .processing:
            Button("暂停", systemImage: "pause") { manager.pause(id: record.id) }
            Button("取消下载", systemImage: "xmark") { manager.cancel(id: record.id) }
        case .paused:
            Button("继续下载", systemImage: "play") { manager.resume(id: record.id) }
            Button("取消下载", systemImage: "xmark") { manager.cancel(id: record.id) }
        case .failed, .cancelled:
            Button("重试", systemImage: "arrow.clockwise") { manager.retry(id: record.id) }
        case .completed:
            Button("在 Finder 中显示", systemImage: "folder") { FileActions.reveal(record, settings: manager.settings) }.disabled(!FileActions.exists(record, settings: manager.settings))
            Button("重新下载", systemImage: "arrow.clockwise") { manager.enqueue(candidate: record.candidate) }
        }
        Divider()
        Button("复制来源链接", systemImage: "link") { FileActions.copySource(record) }
        Button("删除记录…", systemImage: "trash", role: .destructive) { deletion = record }
    }
}

extension DownloadStatus {
    var label: String {
        switch self {
        case .queued: "等待下载"; case .downloading: "正在下载"; case .paused: "已暂停"; case .processing: "正在整理媒体"; case .completed: "已完成"; case .failed: "下载失败"; case .cancelled: "已取消"
        }
    }
}
