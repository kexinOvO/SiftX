import SwiftUI
import AppKit
import SiftXCore

@main
struct SiftXApp: App {
    @NSApplicationDelegateAdaptor(SiftXApplicationDelegate.self) private var appDelegate
    @StateObject private var model = ApplicationModel()

    var body: some Scene {
        WindowGroup("SiftX", id: "main") {
            SiftXMainWindowContent(model: model, appDelegate: appDelegate)
        }
        .defaultSize(width: 1080, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("从链接添加下载…") { model.showAddURL = true }.keyboardShortcut("n")
            }
            CommandGroup(after: .appInfo) {
                Button("Safari 扩展设置…") { model.openSafariPreferences() }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.colorScheme)
                .onAppear { appDelegate.model = model }
        }
    }
}

private struct SiftXMainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: ApplicationModel
    let appDelegate: SiftXApplicationDelegate

    var body: some View {
        Group {
            if let manager = model.downloads {
                MainView(manager: manager).environmentObject(model)
            } else {
                ContentUnavailableView("无法打开本地资料库", systemImage: "externaldrive.badge.exclamationmark", description: Text(model.startupError ?? "请重新启动 SiftX。"))
                    .frame(width: 650, height: 420)
            }
        }
        .onOpenURL { _ in NSApplication.shared.activate(ignoringOtherApps: true) }
        .preferredColorScheme(model.colorScheme)
        .background {
            WindowAccessor { model.mainWindow = $0 }
                .frame(width: 0, height: 0)
        }
        .onAppear {
            appDelegate.model = model
            model.openMainWindowAction = { openWindow(id: "main") }
        }
    }
}

@MainActor
final class SiftXApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        (model?.settings.exitBehavior ?? .closeApp) == .closeApp
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }
}

@MainActor
private struct WindowAccessor: NSViewRepresentable {
    var onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {
        view.onWindowChange = onWindowChange
    }
}

@MainActor
private final class WindowAccessorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
