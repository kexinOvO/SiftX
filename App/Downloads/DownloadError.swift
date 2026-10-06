import Foundation
import SiftXCore

enum DownloadError: LocalizedError, Sendable {
    case http(Int, retryAfter: TimeInterval?)
    case invalidResponse
    case invalidRange
    case unexpectedContent
    case emptyFile
    case liveStream
    case protectedMedia
    case keyAccess(String)
    case unavailableFolder
    case missingFile
    case fileExists
    case processorUnavailable
    case processingFailed(String)
    case disk(String)

    var errorDescription: String? {
        switch self {
        case .http(403, _): return "服务器拒绝访问或链接已过期（403）。请在 Safari 中重新播放并发现媒体。"
        case .http(404, _): return "媒体已不存在（404）。请在 Safari 中重新发现媒体。"
        case .http(429, _): return "服务器暂时限制下载频率（429）。请稍后重试。"
        case .http(let status, _): return "服务器返回错误（\(status)）。请稍后重试。"
        case .invalidResponse: return "服务器没有返回有效的媒体响应。"
        case .invalidRange: return "服务器无法恢复这次下载。请重试以重新下载。"
        case .unexpectedContent: return "服务器返回网页而非媒体，链接可能已过期或需登录。请在 Safari 中重新播放并发现媒体。"
        case .emptyFile: return "服务器返回了空媒体文件。"
        case .liveStream: return "这是仍在更新的直播。请在直播结束后下载完整媒体。"
        case .protectedMedia: return MediaError.protectedMedia.localizedDescription
        case .keyAccess(let details): return "无法读取 AES-128 密钥：\(details)"
        case .unavailableFolder: return "无法访问下载目录。请在设置中重新选择目录。"
        case .missingFile: return "文件已移动或删除。"
        case .fileExists: return "下载目录中已存在同名文件。请更改重复文件处理设置后重试。"
        case .processorUnavailable: return "找不到本地媒体处理组件。请重新安装完整的 SiftX 应用。"
        case .processingFailed(let details): return "媒体处理失败：\(details)"
        case .disk(let details): return "无法保存媒体：\(details)"
        }
    }

    var retryDelay: TimeInterval? {
        switch self {
        case .http(let code, let requested) where code == 429 || (500...599).contains(code):
            return min(max(requested ?? 1, 1), 30)
        case .invalidRange: return 0
        default: return nil
        }
    }
}

struct TransferProgress: Sendable {
    var bytes: Int64
    var total: Int64?
}

extension Error {
    var downloadDescription: String {
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut:
                return "网络连接中断。已保存下载进度，可以稍后继续。"
            case .noPermissionsToReadFile, .cannotWriteToFile: return "没有文件访问权限。请重新选择下载目录。"
            default: break
            }
        }
        let nsError = self as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: return "磁盘空间不足。请释放空间后继续。"
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "没有文件访问权限。请重新选择下载目录。"
            default: break
            }
        }
        return localizedDescription
    }

    var isTransientDownloadFailure: Bool {
        if let error = self as? DownloadError { return error.retryDelay != nil }
        guard let error = self as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(error.code)
    }
}
