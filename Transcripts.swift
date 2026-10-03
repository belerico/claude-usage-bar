// Shared model types and the incremental JSONL transcript scanner.

import Foundation

struct LimitMeter: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

struct LimitsSnapshot {
    var plan: String?
    var meters: [LimitMeter]
}

protocol UsageSource: Sendable {
    func fetchLimits() async throws -> LimitsSnapshot
    /// `modelWindowDays` nil means all history.
    func scanStats(modelWindowDays: Int?) -> TokenStats
}

/// One API response from a transcript, reduced to what the panel shows.
struct TokenRecord: Codable {
    var key: String?
    var model: String
    var day: String
    var tokens: Int
    var output: Int
}

struct TokenStats {
    struct Day: Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let isToday: Bool
    }

    struct Model: Identifiable {
        var id: String { name }
        let name: String
        let tokens: Int
    }

    var days: [Day] = []
    var models: [Model] = []

    /// Tokens of the last 7 local days, and per model over the last `modelWindowDays` (nil: all).
    init(records: [TokenRecord], modelName: (String) -> String, modelWindowDays: Int?, now: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let windowStart = modelWindowDays.map {
            LocalDay.string(calendar.date(byAdding: .day, value: 1 - $0, to: today)!)
        } ?? ""

        var byDay: [String: Int] = [:]
        var byModel: [String: Int] = [:]
        for record in records {
            byDay[record.day, default: 0] += record.tokens
            if record.day >= windowStart {
                byModel[modelName(record.model), default: 0] += record.tokens
            }
        }

        days = (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = LocalDay.string(date)
            return Day(id: key, label: offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)),
                       tokens: byDay[key] ?? 0, isToday: offset == 0)
        }
        models = byModel.map { Model(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    /// Transcripts last modified before this hold nothing the stats show.
    static func scanStart(modelWindowDays: Int?) -> Date {
        guard let days = modelWindowDays else { return .distantPast }
        return Calendar.current.date(byAdding: .day, value: -max(days, 7), to: Calendar.current.startOfDay(for: .now))!
    }
}

/// Local calendar days as "yyyy-MM-dd", the unit transcripts are bucketed by.
enum LocalDay {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let withoutFraction = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func from(timestamp: String?) -> String? {
        guard let timestamp, let date = withFraction.date(from: timestamp) ?? withoutFraction.date(from: timestamp)
        else { return nil }
        return string(date)
    }
}

extension Data {
    func containsBytes(_ needle: [UInt8]) -> Bool {
        withUnsafeBytes { haystack in
            needle.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}

/// Per-file usage records of a tree of JSONL transcripts, persisted between runs. A file whose
/// size and mtime match the index is not reopened; with `appendOnly`, a file that only grew is
/// read from where the last scan stopped, otherwise any change rereads it from the start.
final class TranscriptIndex: @unchecked Sendable {
    typealias Parser = (_ lines: [Data], _ fallbackDay: String, _ records: inout [TokenRecord]) -> Void

    private struct Entry: Codable {
        var size: Int64
        var mtime: Double
        var inode: UInt64
        var offset: Int64
        var records: [TokenRecord]
    }

    private struct Stored: Codable {
        var version: Int
        var zone: String
        var files: [String: Entry]
    }

    private static let version = 1

    private let roots: [URL]
    private let appendOnly: Bool
    private let parse: Parser
    private let cacheURL: URL
    private var files: [String: Entry]?

    init(name: String, roots: [URL], appendOnly: Bool, parse: @escaping Parser) {
        self.roots = roots
        self.appendOnly = appendOnly
        self.parse = parse
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.belerico.claude-usage/\(name)-index.json")
    }

    /// Records of every transcript modified since `since`, one array per file, in path order.
    func scan(modifiedSince since: Date) -> [[TokenRecord]] {
        let previous = files ?? load()
        var current: [String: Entry] = [:]
        var changed = false

        for path in transcriptPaths() {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            let size = Int64(info.st_size)
            let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            let inode = UInt64(info.st_ino)
            guard mtime >= since.timeIntervalSince1970 else { continue }

            if let entry = previous[path], entry.size == size, entry.mtime == mtime {
                current[path] = entry
                continue
            }
            var entry = Entry(size: 0, mtime: 0, inode: inode, offset: 0, records: [])
            if appendOnly, let old = previous[path], old.inode == inode, size > old.size {
                entry = old
            }
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            try? handle.seek(toOffset: UInt64(entry.offset))
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()

            // A trailing line without a newline is still being written; pick it up next time.
            if let end = data.lastIndex(of: 0x0A) {
                let complete = data[..<data.index(after: end)]
                parse(complete.split(separator: 0x0A), LocalDay.string(Date(timeIntervalSince1970: mtime)),
                      &entry.records)
                entry.offset += Int64(complete.count)
            }
            entry.size = size
            entry.mtime = mtime
            entry.inode = inode
            current[path] = entry
            changed = true
        }

        if changed || current.count != previous.count {
            save(current)
        }
        files = current
        return current.keys.sorted().map { current[$0]!.records }
    }

    private func transcriptPaths() -> [String] {
        roots.flatMap { root -> [String] in
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { return [] }
            return enumerator.compactMap { ($0 as? URL)?.pathExtension == "jsonl" ? ($0 as? URL)?.path : nil }
        }
    }

    // Records hold local days, so an index is only valid in the time zone that wrote it.
    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.version, stored.zone == TimeZone.current.identifier
        else { return [:] }
        return stored.files
    }

    private func save(_ files: [String: Entry]) {
        let stored = Stored(version: Self.version, zone: TimeZone.current.identifier, files: files)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

func formatTokens(_ count: Int) -> String {
    let value = Double(count)
    return switch value {
    case 1e9...: String(format: "%.1fB", value / 1e9)
    case 1e6...: String(format: "%.1fM", value / 1e6)
    case 1e3...: String(format: "%.1fK", value / 1e3)
    default: "\(count)"
    }
}
