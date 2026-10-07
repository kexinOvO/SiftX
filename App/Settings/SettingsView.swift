import SwiftUI
import ServiceManagement
import SiftXCore

struct SettingsView: View {
    @EnvironmentObject private var model: ApplicationModel

    var body: some View {
        TabView {
            Form {
                Section("外观") {
                    Picker("显示模式", selection: Binding(get: { model.settings.appearance ?? "system" }, set: { model.settings.appearance = $0 })) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
                Section("启动") {
                    Toggle("登录时启动 SiftX", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { model.setLoginItem($0) }))
                }
                Section("退出") {
                    Picker("退出软件行为", selection: Binding(get: { model.settings.exitBehavior }, set: { model.setExitBehavior($0) })) {
                        Text("关闭软件").tag(AppExitBehavior.closeApp)
                        Text("退出至托盘").tag(AppExitBehavior.menuBar)
                    }
                    .pickerStyle(.menu)
                    Text(model.settings.exitBehavior == .closeApp
                         ? "关闭最后一个窗口时直接退出 SiftX。"
                         : "关闭最后一个窗口后 SiftX 将继续运行，可从菜单栏图标重新打开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("图标") {
                    Toggle("隐藏 Dock 栏图标", isOn: Binding(get: { model.settings.dockIconHidden }, set: { model.setDockIconHidden($0) }))
                    Toggle("隐藏菜单栏图标", isOn: Binding(get: { model.settings.menuBarIconHidden }, set: { model.setMenuBarIconHidden($0) }))
                        .disabled(model.settings.exitBehavior == .menuBar)
                    Text(model.settings.exitBehavior == .menuBar
                         ? "退出至托盘时需要显示菜单栏图标。"
                         : "两个图标不能同时隐藏。隐藏 Dock 图标后，请通过菜单栏图标打开 SiftX。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("通知") {
                    Toggle("下载完成通知", isOn: $model.settings.notifyCompletion)
                    Toggle("下载失败通知", isOn: $model.settings.notifyFailure)
                    Button("允许系统通知") { model.requestNotifications() }
                    Text("通知权限关闭时，下载仍会正常运行。").font(.caption).foregroundStyle(.secondary)
                }
                Section("完成后") { Toggle("自动打开下载文件", isOn: $model.settings.openWhenFinished) }
            }.formStyle(.grouped)
                .tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                Section("保存位置") {
                    HStack {
                        Text("下载目录")
                        Spacer()
                        Text(model.settings.downloadDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "下载文件夹")
                        Button("选择…") { model.chooseFolder() }
                            .accessibilityLabel("选择下载目录")
                    }
                    Text(model.settings.downloadDirectory ?? "默认保存到下载文件夹。选择其他目录后，SiftX 会保存访问授权。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section("下载队列") { Stepper("最大同时下载：\(model.settings.maxConcurrent)", value: $model.settings.maxConcurrent, in: 1...6) }
                Section("同名文件") {
                    Text("自动添加数字：视频.mp4、视频 2.mp4。已有文件始终保留。")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            Form {
                Section("Safari 扩展") {
                    extensionRow("SiftX Safari Extension", identifier: SiftXConfiguration.nativeExtensionID)
                    extensionRow("SiftX Media Probe", identifier: SiftXConfiguration.probeExtensionID)
                    Button("重新检查", systemImage: "arrow.clockwise") { model.refreshExtensionStates() }
                }
                Section("工具栏") {
                    Picker("插件图标", selection: $model.settings.selectedPluginIcon) {
                        ForEach(PluginIcon.allCases, id: \.self) { icon in
                            HStack {
                                if let symbol = icon.systemImageName {
                                    Image(systemName: symbol).accessibilityHidden(true)
                                } else {
                                    Image("ToolbarSymbol").resizable().scaledToFit()
                                        .frame(width: 16, height: 16).accessibilityHidden(true)
                                }
                                Text(icon.title)
                            }.tag(icon)
                        }
                    }.pickerStyle(.menu)
                    Text("选择 Safari 工具栏中 SiftX 按钮的图标。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("显示下载数量红点", isOn: $model.settings.showsToolbarBadge)
                    Text("在 Safari 工具栏图标上显示当前网页可下载的选项数量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("开始下载") {
                    Text("启用两个扩展，并允许它们访问网站。打开网页并播放媒体，然后点击 Safari 工具栏中的 SiftX 图标。")
                    Text("Media Probe 负责发现资源；Safari Extension 提供原生菜单。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("隐私") { Text("SiftX 在本机处理媒体信息，无服务器、分析或追踪服务。").foregroundStyle(.secondary) }
            }.formStyle(.grouped)
                .tabItem { Label("Safari", systemImage: "safari") }
            Form {
                Section("SiftX") {
                    Text("适用于 macOS 的下载工具。")
                }
                Section("免责声明") {
                    Text("该工具仅供学习使用，下载的素材请在24小时内删除，任何个人行为与软件开发者无关。")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Section("使用提示") {
                    Text("请仅下载您拥有版权或已获得授权的素材，并遵守相关法律法规及来源网站的使用条款。")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }.formStyle(.grouped)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }.frame(width: 570, height: 430)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onAppear { model.refreshExtensionStates() }
        .alert("设置未完成", isPresented: Binding(get: { model.settingsError != nil }, set: { if !$0 { model.settingsError = nil } })) {
            Button("好") { model.settingsError = nil }
        } message: { Text(model.settingsError ?? "") }
    }

    private func extensionRow(_ title: String, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(model.extensionStates[identifier] ?? "正在检查…").foregroundStyle(.secondary)
            Button("设置…") { model.openSafariPreferences(identifier) }
                .accessibilityLabel("打开 \(title) 设置")
        }
    }
}
