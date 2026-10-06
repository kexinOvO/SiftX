import AppKit
import SwiftUI
import Combine
import SafariServices
import ServiceManagement
import UserNotifications
import SiftXCore

@MainActor
final class ApplicationModel: ObservableObject {
    let store: SharedStore?
    let downloads: DownloadManager?
    @Published var settings = AppSettings()
    @Published var showAddURL = false
    @Published var startupError: String?
    @Published var extensionStates: [String: String] = [:]
    @Published var settingsError: String?
    private var savedPluginIcon: PluginIcon = .currentPNG
    private var savedToolbarBadgeVisible = true
    private var statusItem: NSStatusItem?
    private var downloadObservation: AnyCancellable?
    weak var mainWindow: NSWindow?
    var openMainWindowAction: (() -> Void)?

    var colorScheme: ColorScheme? {
        switch settings.appearance { case "light": .light; case "dark": .dark; default: nil }
    }

    init() {
        do {
            let database = try SharedStore()
            let loadedSettings = try database.loadSettings()
            store = database
            settings = loadedSettings
            savedPluginIcon = loadedSettings.selectedPluginIcon
            savedToolbarBadgeVisible = loadedSettings.showsToolbarBadge
            downloads = DownloadManager(store: database)
            downloads?.start()
        } catch {
            store = nil
            downloads = nil
            startupError = error.localizedDescription
        }
        refreshExtensionStates()
        applyDockIconPolicy()
        syncMenuBarIcon()
        if let downloads {
            downloadObservation = downloads.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateMenuBarTitle() }
        }
    }

    /// Hides the Dock icon by switching to an accessory app (menu-bar-only style).
    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(settings.dockIconHidden ? .accessory : .regular)
    }

    func setDockIconHidden(_ hidden: Bool) {
        guard !(hidden && settings.menuBarIconHidden) else {
            settingsError = "Dock 图标和菜单栏图标不能同时隐藏，否则无法访问 SiftX。"
            objectWillChange.send()
            return
        }
        settings.dockIconHidden = hidden
        applyDockIconPolicy()
        saveSettings()
    }

    func setMenuBarIconHidden(_ hidden: Bool) {
        guard !(hidden && settings.dockIconHidden) else {
            settingsError = "Dock 图标和菜单栏图标不能同时隐藏，否则无法访问 SiftX。"
            objectWillChange.send()
            return
        }
        settings.menuBarIconHidden = hidden
        syncMenuBarIcon()
        saveSettings()
    }

    func setExitBehavior(_ behavior: AppExitBehavior) {
        settings.exitBehavior = behavior
        if behavior == .menuBar, settings.menuBarIconHidden {
            settings.menuBarIconHidden = false
            syncMenuBarIcon()
        }
        saveSettings()
    }

    /// Creates or removes the menu bar status item according to settings.
    func syncMenuBarIcon() {
        if settings.menuBarIconHidden {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "SiftXMenuBarItem"
            item.menu = buildMenuBar()
            statusItem = item
        }
        updateMenuBarTitle()
        refreshMenuItems()
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        button.image = Self.menuBarIcon()
        let count = downloads?.activeCount ?? 0
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = "SiftX"
        refreshMenuItems()
    }

    /// Black silhouette of the SiftX logo as a template image: macOS renders it
    /// black in light menu bars and inverts it automatically in dark ones.
    private static func menuBarIcon() -> NSImage? {
        guard let icon = NSImage(named: "MenuBarSymbol") else {
            return NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "SiftX")
        }
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    private func refreshMenuItems() {
        guard let downloads, let menu = statusItem?.menu else { return }
        let count = downloads.activeCount
        menu.item(withTag: activeCountTag)?.title = count == 0 ? "当前没有正在下载的任务" : "\(count) 个任务正在下载"
        menu.item(withTag: pauseTag)?.isEnabled = count > 0
        menu.item(withTag: resumeTag)?.isEnabled = downloads.records.contains { $0.status == .paused }
    }

    private func buildMenuBar() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "SiftX", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if downloads != nil {
            let countItem = NSMenuItem(title: "当前没有正在下载的任务", action: nil, keyEquivalent: "")
            countItem.isEnabled = false
            countItem.tag = activeCountTag
            menu.addItem(countItem)
            menu.addItem(.separator())
            let pause = NSMenuItem(title: "暂停全部", action: #selector(pauseAllDownloads), keyEquivalent: "")
            pause.target = self
            pause.tag = pauseTag
            menu.addItem(pause)
            let resume = NSMenuItem(title: "继续全部", action: #selector(resumeAllDownloads), keyEquivalent: "")
            resume.target = self
            resume.tag = resumeTag
            menu.addItem(resume)
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "打开 SiftX", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "退出 SiftX", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private let activeCountTag = 1
    private let pauseTag = 2
    private let resumeTag = 3

    @objc private func pauseAllDownloads() { downloads?.pauseAll() }
    @objc private func resumeAllDownloads() { downloads?.resumeAll() }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowAction {
            openMainWindowAction()
        } else {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    @objc private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func saveSettings() {
        do {
            guard let store else { return }
            try store.saveSettings(settings)
            downloads?.refreshSettings()
            if savedPluginIcon != settings.selectedPluginIcon || savedToolbarBadgeVisible != settings.showsToolbarBadge {
                savedPluginIcon = settings.selectedPluginIcon
                savedToolbarBadgeVisible = settings.showsToolbarBadge
                // When Safari is closed, its next validation reads the saved toolbar preferences.
                let safariRunning = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
                }
                if safariRunning {
                    SiftXRefreshSafariToolbar(SiftXConfiguration.nativeExtensionID) { [weak self] message in
                        if let message {
                            self?.settingsError = "工具栏设置已保存，Safari 暂时未能更新：\(message)"
                        }
                    }
                }
            }
        }
        catch { settingsError = error.localizedDescription }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择下载目录"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                settings.downloadBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                settings.downloadDirectory = url.path
                saveSettings()
            } catch { settingsError = error.localizedDescription }
        }
    }

    func refreshExtensionStates() {
        for identifier in [SiftXConfiguration.nativeExtensionID, SiftXConfiguration.probeExtensionID] {
            SiftXReadSafariState(identifier) { [weak self] known, enabled in
                let text = known ? (enabled ? "已启用" : "未启用") : "等待 Safari 确认"
                Task { @MainActor [weak self] in self?.extensionStates[identifier] = text }
            }
        }
    }

    func openSafariPreferences(_ identifier: String = SiftXConfiguration.nativeExtensionID) {
        SiftXOpenSafariPreferences(identifier) { [weak self] message in
            if let message {
                Task { @MainActor [weak self] in self?.settingsError = "Safari 设置暂时无法打开：\(message)" }
            }
        }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { settingsError = error.localizedDescription }
    }

    func requestNotifications() {
        Task {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { settingsError = error.localizedDescription }
        }
    }
}
