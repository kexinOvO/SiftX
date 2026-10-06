import Foundation
import AppKit
@preconcurrency import SafariServices
import os
import SiftXCore

final class SafariExtensionHandler: SFSafariExtensionHandler {
    private static let logger = Logger(subsystem: SiftXConfiguration.appBundleID, category: "Safari")
    private let badgeState = ToolbarBadgeState<SFSafariWindow>()

    override init() {
        super.init()
        Self.logger.info("Native Safari handler initialized.")
    }

    override func messageReceived(withName messageName: String, from page: SFSafariPage, userInfo: [String: Any]?) {
        if messageName == "siftx.showPopover" {
            Task { @MainActor in await PageContextResolver.shared.showPopover(from: page) }
            return
        }
        guard messageName == "siftx.context", let userInfo,
              let id = userInfo["sessionID"] as? String, UUID(uuidString: id) != nil,
              let text = userInfo["pageURL"] as? String, let url = URL(string: text),
              (try? URLSafety.validate(url)) != nil else { return }
        let context = NativePageContext(sessionID: id, pageURL: url, title: String((userInfo["title"] as? String ?? "").prefix(500)), privateBrowsing: false)
        let requestID = userInfo["requestID"] as? String ?? ""
        Task { @MainActor in
            PageContextResolver.shared.receive(context, page: page, requestID: requestID)
            if requestID.isEmpty { SFSafariApplication.setToolbarItemsNeedUpdate() }
        }
    }

    override func validateToolbarItem(in window: SFSafariWindow, validationHandler: @escaping (Bool, String) -> Void) {
        // Permission checks and page-script replies must not delay Safari's toolbar
        // validation. Returning an empty badge here would hide it on every rescan.
        let badgeState = self.badgeState
        let showsBadge = (try? SharedStore().loadSettings().showsToolbarBadge) ?? true
        let validation = badgeState.beginValidation(for: window, showsBadge: showsBadge)
        validationHandler(true, validation.text)
        Task { @MainActor in
            guard let item = await PageContextResolver.shared.toolbarItem(in: window) else { return }
            // Read after resolving the item, so a rapid preference change uses the latest value.
            let icon = (try? SharedStore().loadSettings().selectedPluginIcon) ?? .currentPNG
            if let name = icon.systemImageName,
               let image = NSImage(systemSymbolName: name, accessibilityDescription: "SiftX")?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) {
                image.isTemplate = true
                item.setImage(image)
            } else {
                // nil restores the original PNG declared in the extension's Info.plist.
                item.setImage(nil)
            }
            guard showsBadge else { return }
            let context = await PageContextResolver.shared.context(in: window)
            let candidates = context.flatMap { try? SharedStore().page(id: $0.sessionID)?.candidates } ?? []
            // A preference can change while page discovery is awaiting its reply.
            let stillShowsBadge = (try? SharedStore().loadSettings().showsToolbarBadge) ?? true
            let count = stillShowsBadge ? candidates.filter { $0.protection == nil }.count : 0
            if badgeState.update(for: window, requestID: validation.requestID, count: count) {
                item.setBadgeText(count > 0 ? String(min(count, 99)) : "")
            }
        }
    }

    override func messageReceivedFromContainingApp(withName messageName: String, userInfo: [String: Any]?) {
        guard messageName == "siftx.toolbarIconChanged" else { return }
        Task { @MainActor in
            SFSafariApplication.setToolbarItemsNeedUpdate()
        }
    }

    override func popoverViewController() -> SFSafariExtensionViewController {
        Self.logger.info("Safari requested the native popover.")
        if Thread.isMainThread { return MainActor.assumeIsolated { SiftXPopoverController.shared } }
        // Construct UI on the main actor even if a Safari XPC lifecycle callback arrives
        // on a background queue. This synchronous SDK method cannot return asynchronously.
        return DispatchQueue.main.sync { MainActor.assumeIsolated { SiftXPopoverController.shared } }
    }

    override func popoverWillShow(in window: SFSafariWindow) {
        Self.logger.info("Native media popover will show.")
        Task { @MainActor in
            SiftXPopoverController.shared.model.begin(window: window)
        }
    }

    override func popoverDidClose(in window: SFSafariWindow) {
        Task { @MainActor in SiftXPopoverController.shared.model.stop() }
    }

    override func page(_ page: SFSafariPage, willNavigateTo url: URL?) {
        Task { @MainActor in
            PageContextResolver.shared.invalidate(page)
            SFSafariApplication.setToolbarItemsNeedUpdate()
        }
    }
}

struct NativePageContext: Sendable {
    var sessionID: String
    var pageURL: URL
    var title: String
    var privateBrowsing: Bool
}

/// Safari's Objective-C proxies and callbacks are not annotated Sendable in the SDK.
/// The immutable holder transfers a callback result once to the main actor; all subsequent
/// proxy access in this extension stays on the main actor.
private struct SafariCallbackTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Queries the exact SFSafariPage each time. Neither URL equality nor a WebExtension Tab ID
/// is used to determine which page belongs to the native toolbar.
@MainActor
final class PageContextResolver {
    static let shared = PageContextResolver()
    private struct Pending {
        var page: SFSafariPage
        var continuation: CheckedContinuation<NativePageContext?, Never>
    }
    private var pending: [String: Pending] = [:]

    func showPopover(from page: SFSafariPage) async {
        let tab: SafariCallbackTransfer<SFSafariTab> = await withCheckedContinuation { continuation in
            page.getContainingTab { continuation.resume(returning: SafariCallbackTransfer($0)) }
        }
        let window: SafariCallbackTransfer<SFSafariWindow>? = await withCheckedContinuation { continuation in
            tab.value.getContainingWindow { continuation.resume(returning: $0.map(SafariCallbackTransfer.init)) }
        }
        guard let window else { return }
        await toolbarItem(in: window.value)?.showPopover()
    }

    func toolbarItem(in window: SFSafariWindow) async -> SFSafariToolbarItem? {
        let item: SafariCallbackTransfer<SFSafariToolbarItem>? = await withCheckedContinuation { continuation in
            window.getToolbarItem { continuation.resume(returning: $0.map(SafariCallbackTransfer.init)) }
        }
        return item?.value
    }

    func context(in window: SFSafariWindow, refresh: Bool = false) async -> NativePageContext? {
        let transferredTab: SafariCallbackTransfer<SFSafariTab>? = await withCheckedContinuation { continuation in
            window.getActiveTab { continuation.resume(returning: $0.map(SafariCallbackTransfer.init)) }
        }
        guard let tab = transferredTab?.value else { return nil }
        let transferredPage: SafariCallbackTransfer<SFSafariPage>? = await withCheckedContinuation { continuation in
            tab.getActivePage { continuation.resume(returning: $0.map(SafariCallbackTransfer.init)) }
        }
        guard let page = transferredPage?.value else { return nil }
        let privateBrowsing: Bool = await withCheckedContinuation { continuation in
            page.getPropertiesWithCompletionHandler { continuation.resume(returning: $0?.usesPrivateBrowsing ?? false) }
        }
        let result: NativePageContext? = await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            pending[id] = Pending(page: page, continuation: continuation)
            page.dispatchMessageToScript(withName: "siftx.queryContext", userInfo: ["requestID": id])
            if refresh { page.dispatchMessageToScript(withName: "siftx.refresh", userInfo: nil) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                pending.removeValue(forKey: id)?.continuation.resume(returning: nil)
            }
        }
        guard var result else { return nil }
        result.privateBrowsing = privateBrowsing
        return result
    }

    func receive(_ context: NativePageContext, page: SFSafariPage, requestID: String) {
        // Safari may recreate its NSSecureCoding page proxy for the response. The fresh
        // request nonce is delivered only to the queried page's isolated extension world,
        // so it binds the response to the retained page without relying on proxy equality.
        guard let request = pending[requestID] else { return }
        pending.removeValue(forKey: requestID)
        request.continuation.resume(returning: context)
    }

    func invalidate(_ page: SFSafariPage) {
        let ids = pending.filter { $0.value.page.isEqual(page) }.map(\.key)
        for id in ids { pending.removeValue(forKey: id)?.continuation.resume(returning: nil) }
    }
}
