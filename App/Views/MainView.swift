import SwiftUI
import AppKit
import SiftXCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case downloads = "下载管理"
    var id: String { rawValue }
    var symbol: String { "arrow.down.circle" }
}

struct MainView: View {
    @EnvironmentObject private var model: ApplicationModel
    @ObservedObject var manager: DownloadManager
    @State private var section: LibrarySection? = .downloads
    @State private var selected: UUID?
    @State private var search = ""
    @State private var deletion: DownloadRecord?
    @State private var deleteFile = false
    @State private var onboarding = false

    private var visible: [DownloadRecord] {
        manager.records.filter { record in
            search.isEmpty || record.candidate.title.localizedCaseInsensitiveContains(search) || record.candidate.pageTitle.localizedCaseInsensitiveContains(search)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "没有匹配的下载" }
        return "还没有下载任务"
    }

    var body: some View {
        NavigationSplitView {
            List(LibrarySection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Safari 中发现，Mac 上保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Safari 扩展设置", systemImage: "safari") { model.openSafariPreferences() }
                        .buttonStyle(.link)
                }.padding()
            }
        } content: {
            Group {
                if visible.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: section?.symbol ?? "arrow.down.circle", description: Text(search.isEmpty ? "在 Safari 的 SiftX 菜单选择媒体，或添加媒体链接。" : "试试其他标题或网页名称。"))
                } else {
                    List(visible, selection: $selected) { record in
                        DownloadRow(record: record, speed: manager.speeds[record.id] ?? 0)
                            .tag(record.id)
                            .contextMenu { recordActions(record) }
                    }.listStyle(.inset)
                }
            }
            .navigationTitle((section ?? .downloads).rawValue)
            .navigationSplitViewColumnWidth(min: 360, ideal: 450)
            .frame(minWidth: 360)

        } detail: {
            if let record = manager.records.first(where: { $0.id == selected }) {
                DownloadDetail(record: record, manager: manager, delete: { deletion = record })
                    .id(record.id)
            } else {
                ContentUnavailableView("选择一个下载", systemImage: "arrow.down.doc", description: Text("查看进度、文件与来源信息。"))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 560)
        .searchable(text: $search, prompt: "搜索下载")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) { downloadControls }
        }
        .sheet(isPresented: $model.showAddURL) { AddURLView(manager: manager) }
        .sheet(isPresented: $onboarding) { OnboardingView().environmentObject(model) }
        .onAppear { onboarding = !model.settings.onboardingComplete }
        .onChange(of: section) { _, _ in selected = nil }
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
