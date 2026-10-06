import Foundation

/// Safari validates on an XPC callback queue and resolves page counts asynchronously.
/// Keep the displayed text across validations and discard superseded page queries.
final class ToolbarBadgeState<Key: Hashable>: @unchecked Sendable {
    private struct Entry {
        var text: String
        var requestID: UUID
        var showsBadge: Bool
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func beginValidation(for key: Key, showsBadge: Bool = true) -> (text: String, requestID: UUID) {
        lock.lock(); defer { lock.unlock() }
        let text = showsBadge ? entries[key]?.text ?? "" : ""
        let requestID = UUID()
        // Bound retained Safari window proxies, including windows that have closed.
        if entries.count >= 64, entries[key] == nil { entries.removeAll() }
        entries[key] = Entry(text: text, requestID: requestID, showsBadge: showsBadge)
        return (text, requestID)
    }

    /// Returns true only when the latest validation changes the visible badge.
    func update(for key: Key, requestID: UUID, count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.requestID == requestID else { return false }
        let text = entry.showsBadge && count > 0 ? String(min(count, 99)) : ""
        guard entry.text != text else { return false }
        entries[key] = Entry(text: text, requestID: requestID, showsBadge: entry.showsBadge)
        return true
    }
}
