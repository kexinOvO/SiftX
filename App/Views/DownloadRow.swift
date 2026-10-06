import SwiftUI
import SiftXCore

struct DownloadRow: View {
    let record: DownloadRecord
    let speed: Double
    private var working: Bool { [.downloading, .queued, .processing, .paused].contains(record.status) }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.candidate.kind == .audio ? "waveform" : "film")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30).padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.candidate.title).font(.headline).lineLimit(2)
                Text([record.candidate.quality, record.candidate.sourceURL.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if working {
                    if let total = record.totalBytes, total > 0 {
                        ProgressView(value: min(Double(record.bytesReceived) / Double(total), 1))
                    } else if record.status == .downloading || record.status == .processing {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Label(record.status.label, systemImage: record.status == .failed ? "exclamationmark.circle" : (record.status == .completed ? "checkmark.circle" : "arrow.down"))
                        .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: record.bytesReceived, countStyle: .file))
                    if speed > 0, record.status == .downloading {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/秒")
                    }
                }.font(.caption).monospacedDigit()
            }
        }.padding(.vertical, 8)
    }
}
