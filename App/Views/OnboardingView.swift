import SwiftUI
import SiftXCore

struct OnboardingView: View {
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("欢迎使用 SiftX").font(.largeTitle.bold())
                Text("在 Safari 发现媒体，在 Mac 上下载保存。")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Divider()
            extensionRow("SiftX Safari Extension", detail: "Safari 工具栏中的原生媒体菜单", icon: "sidebar.right", identifier: SiftXConfiguration.nativeExtensionID)
            extensionRow("SiftX Media Probe", detail: "自动发现网页视频和音频，需要允许访问网页", icon: "waveform.path", identifier: SiftXConfiguration.probeExtensionID)
            Text("在 Safari → 设置 → 扩展中启用这两个扩展，并允许访问要下载媒体的网站。播放网页中的视频后，点击工具栏中的 SiftX。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("所有媒体信息与下载记录只保存在本机。受保护的媒体无法下载。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查启用状态", systemImage: "arrow.clockwise") { model.refreshExtensionStates() }
                Spacer()
                Button("开始使用") {
                    model.settings.onboardingComplete = true
                    model.saveSettings()
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 560)
    }

    private func extensionRow(_ name: String, detail: String, icon: String, identifier: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Text(model.extensionStates[identifier] ?? "正在检查…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开设置") { model.openSafariPreferences(identifier) }
        }
    }
}
