import Foundation
import SQLite3

/// A short-lived WAL transaction is the only cross-process shared state. No extension must stay running.
public final class SharedStore: @unchecked Sendable {
    public let directory: URL
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public convenience init() throws {
        let manager = FileManager.default
        guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: SiftXConfiguration.appGroupID) else {
            throw MediaError.storage("SiftX 的共享容器不可用。请使用具有正确 App Group 权限的签名版本。")
        }
        try self.init(directory: container.appendingPathComponent("SiftX", isDirectory: true))
    }
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("Shared.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
            if let database { sqlite3_close(database) }
            database = nil
            throw MediaError.storage(detail)
        }
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try execute("""
            CREATE TABLE IF NOT EXISTS pages(id TEXT PRIMARY KEY, updated REAL NOT NULL, payload BLOB NOT NULL);
            CREATE INDEX IF NOT EXISTS pages_updated ON pages(updated);
            CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, created REAL NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS downloads(id TEXT PRIMARY KEY, created REAL NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
            PRAGMA user_version=1;
            """)
        try prunePages()
    }
    deinit { if let database { sqlite3_close(database) } }

    public func savePage(_ page: PageSession) throws {
        try synchronized {
            var clean = page
            clean.title = String(clean.title.prefix(500))
            clean.candidates = try sanitizedCandidates(page.candidates)
            guard !clean.id.isEmpty, clean.id.utf8.count <= 512 else { throw MediaError.storage("invalid page identity") }
            try URLSafety.validate(clean.pageURL)
            try write("INSERT INTO pages(id,updated,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,payload=excluded.payload WHERE excluded.updated>=pages.updated", values: [.text(clean.id), .number(clean.updatedAt.timeIntervalSince1970), .data(try encoder.encode(clean))])
            try prunePagesLocked()
        }
    }
    /// Atomically merges probe results so simultaneous callbacks cannot drop each other's choices.
    public func mergePage(_ page: PageSession) throws {
        try synchronized {
            try transaction {
                var merged = page
                if let previous = try pageLocked(id: page.id) {
                    merged.candidates = MediaIdentity.deduplicated(page.candidates + previous.candidates)
                    merged.updatedAt = max(previous.updatedAt, page.updatedAt)
                }
                try savePage(merged)
            }
        }
    }
    public func pages() throws -> [PageSession] {
        try synchronized { try read("SELECT payload FROM pages ORDER BY updated DESC LIMIT 200", as: PageSession.self) }
    }
    public func page(id: String) throws -> PageSession? { try synchronized { try pageLocked(id: id) } }
    private func pageLocked(id: String) throws -> PageSession? {
        try read("SELECT payload FROM pages WHERE id=?", values: [.text(id)], as: PageSession.self).first
    }
    public func removePage(id: String) throws {
        try synchronized { try write("DELETE FROM pages WHERE id=?", values: [.text(id)]) }
    }
    public func prunePages() throws { try synchronized { try prunePagesLocked() } }
    private func prunePagesLocked() throws {
        try write("DELETE FROM pages WHERE updated<?", values: [.number(Date().addingTimeInterval(-7_200).timeIntervalSince1970)])
        try execute("DELETE FROM pages WHERE id NOT IN (SELECT id FROM pages ORDER BY updated DESC LIMIT 200)")
    }

    @discardableResult public func enqueue(candidate: MediaCandidate) throws -> UUID {
        try synchronized {
            let clean = try sanitizedCandidate(candidate)
            guard clean.protection == nil else { throw MediaError.protectedMedia }
            let request = DownloadRequest(candidate: clean)
            try transaction {
                let count = try scalar("SELECT COUNT(*) FROM requests")
                guard count < 1_000 else { throw MediaError.storage("下载请求过多，请打开 SiftX 后重试。") }
                try write("INSERT INTO requests(id,created,payload) VALUES(?,?,?)", values: [.text(request.id.uuidString), .number(request.createdAt.timeIntervalSince1970), .data(try encoder.encode(request))])
            }
            return request.id
        }
    }
    public func pendingRequests() throws -> [DownloadRequest] {
        try synchronized { try read("SELECT payload FROM requests ORDER BY created ASC LIMIT 1000", as: DownloadRequest.self) }
    }
    public func ackRequest(id: UUID) throws {
        try synchronized { try write("DELETE FROM requests WHERE id=?", values: [.text(id.uuidString)]) }
    }
    public func loadDownloads() throws -> [DownloadRecord] {
        try synchronized { try read("SELECT payload FROM downloads ORDER BY created DESC", as: DownloadRecord.self) }
    }
    public func saveDownload(_ record: DownloadRecord) throws {
        try synchronized {
            var clean = record
            clean.candidate = try sanitizedCandidate(record.candidate)
            clean.error = clean.error.map { String($0.prefix(2_000)) }
            try write("INSERT INTO downloads(id,created,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [.text(clean.id.uuidString), .number(clean.createdAt.timeIntervalSince1970), .data(try encoder.encode(clean))])
        }
    }
    public func deleteDownload(id: UUID) throws {
        try synchronized { try write("DELETE FROM downloads WHERE id=?", values: [.text(id.uuidString)]) }
    }
    public func loadSettings() throws -> AppSettings {
        try synchronized { try read("SELECT payload FROM settings WHERE id=1", as: AppSettings.self).first ?? AppSettings() }
    }
    public func saveSettings(_ settings: AppSettings) throws {
        try synchronized {
            var bounded = settings
            bounded.maxConcurrent = max(1, min(8, settings.maxConcurrent))
            bounded.collisionPolicy = settings.collisionPolicy == "skip" ? "skip" : "rename"
            try write("INSERT INTO settings(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", values: [.data(try encoder.encode(bounded))])
        }
    }

    private func sanitizedCandidates(_ input: [MediaCandidate]) throws -> [MediaCandidate] {
        try MediaIdentity.deduplicated(input).map { try sanitizedCandidate($0) }
    }
    private func sanitizedCandidate(_ input: MediaCandidate) throws -> MediaCandidate {
        try URLSafety.validate(input.pageURL)
        try URLSafety.validate(input.sourceURL)
        if let audio = input.audioURL { try URLSafety.validate(audio) }
        var result = input
        result.title = String(result.title.prefix(500)); result.pageTitle = String(result.pageTitle.prefix(500))
        result.id = String(result.id.prefix(512)); result.sessionID = String(result.sessionID.prefix(512))
        result.headers = URLSafety.requestHeaders(input.headers)
        if let thumbnail = result.thumbnailURL, (try? URLSafety.validate(thumbnail)) == nil { result.thumbnailURL = nil }
        // Plans are regenerated when a download starts. Thousands of segments never enter durable history.
        result.plan = nil
        return result
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private enum Value { case text(String), number(Double), data(Data) }
    private func prepared(_ sql: String, values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            for (index, value) in values.enumerated() {
                let code: Int32
                switch value {
                case .text(let text): code = sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
                case .number(let number): code = sqlite3_bind_double(statement, Int32(index + 1), number)
                case .data(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(data.count), transient) }
                }
                guard code == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func write(_ sql: String, values: [Value]) throws {
        let statement = try prepared(sql, values: values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func read<T: Decodable>(_ sql: String, values: [Value] = [], as type: T.Type) throws -> [T] {
        let statement = try prepared(sql, values: values); defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length > 0, length <= 2_000_000, let pointer = sqlite3_column_blob(statement, 0) else { throw MediaError.storage("invalid record size") }
            let data = Data(bytes: pointer, count: length)
            output.append(try decoder.decode(type, from: data))
        }
        return output
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepared(sql, values: []); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func failure() -> MediaError { .storage(database.map { String(cString: sqlite3_errmsg($0)) } ?? "closed database") }
}
