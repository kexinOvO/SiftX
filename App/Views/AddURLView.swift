import SwiftUI
import SiftXCore

struct AddURLView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: DownloadManager
    @State private var link = ""
    @State private var title = ""
    @State private var candidates: [MediaCandidate] = []
    @State private var busy = false
    @State private var error: String?
    @State private var analysis: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加媒体链接").font(.title2.bold())
            Text("粘贴 YouTube 视频链接，或可直接访问的视频、音频与媒体播放列表链接。下载后可离线观看学习。")
                .foregroundStyle(.secondary)
            TextField("YouTube 或媒体链接", text: $link).textFieldStyle(.roundedBorder)
                .accessibilityLabel("YouTube 或媒体链接")
                .disabled(busy)
                .onSubmit { analyze() }
            TextField("标题（可选）", text: $title).textFieldStyle(.roundedBorder).disabled(busy)
            if busy { HStack { ProgressView().controlSize(.small); Text("正在读取媒体信息…") } }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            if !candidates.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(candidates.first?.displayTitle ?? "媒体").font(.headline)
                        ForEach(candidates, id: \.id) { candidate in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.quality ?? (candidate.kind == .audio ? "仅音频" : "原始质量"))
                                    if candidate.durationLabel != nil || candidate.encryption != nil {
                                        Text([candidate.durationLabel, candidate.encryption?.rawValue].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(candidate.protection ?? (candidate.kind == .audio ? "音频" : (candidate.hasAudio ? "视频 + 音频" : "视频")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("下载", systemImage: "arrow.down") {
                                    manager.enqueue(candidate: candidate); dismiss()
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel("下载 \(candidate.quality ?? (candidate.kind == .audio ? "音频" : "原始质量"))")
                                    .disabled(candidate.protection != nil)
                            }.padding(.vertical, 4)
                                .accessibilityElement(children: .contain)
                        }
                    }.padding(.horizontal, 12)
                }.frame(height: 180)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { analysis?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("读取媒体", action: analyze).disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
        .onDisappear { analysis?.cancel() }
    }

    private func analyze() {
        guard !busy else { return }
        error = nil; candidates = []
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = "请输入有效的媒体链接。"; return }
        do { try URLSafety.validate(url) } catch { self.error = error.localizedDescription; return }
        if YouTubeURL.isYouTubeHost(url), YouTubeURL.canonical(url) == nil {
            error = "请粘贴单个 YouTube 视频链接（watch、Shorts 或 youtu.be）。"; return
        }
        let classified = URLSafety.classify(url)
        let youtube = YouTubeURL.canonical(url)
        let customTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = MediaCandidate(id: UUID().uuidString, sessionID: "manual", title: customTitle.isEmpty ? (youtube == nil ? url.deletingPathExtension().lastPathComponent : "") : customTitle, pageTitle: customTitle.isEmpty ? (url.host ?? "媒体") : customTitle, pageURL: url, sourceURL: youtube ?? url, kind: classified?.0 ?? .video, transport: youtube == nil ? classified?.1 ?? .direct : .youtube)
        busy = true
        analysis = Task {
            defer { busy = false }
            do {
                let choices = candidate.transport == .youtube
                    ? try await YouTubeDownloader().candidates(for: candidate)
                    : try await MediaAnalyzer().candidates(for: candidate)
                try Task.checkCancellation()
                candidates = choices
            }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
