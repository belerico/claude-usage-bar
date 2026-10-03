// Codex: plan limits from the Codex CLI's app-server JSON-RPC (account/rateLimits/read),
// token counts from the local session rollouts in ~/.codex/sessions.

import Foundation

enum CodexError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case noAnswer
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Codex CLI not found."
        case .notLoggedIn: "Not logged in. Run `codex login`."
        case .noAnswer: "Codex app-server did not answer."
        case .rpc(let message): "Codex: \(message)"
        }
    }
}

private struct RPCReply: Decodable {
    struct Failure: Decodable { let message: String? }
    struct Result: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Int?
                let resetsAt: Double?
            }
            let primary: Window?
            let secondary: Window?
            let planType: String?
        }
        let rateLimits: RateLimits?
    }
    let id: Int?
    let result: Result?
    let error: Failure?
}

private struct RolloutLine: Decodable {
    struct Payload: Decodable {
        struct Info: Decodable {
            struct Usage: Decodable, Equatable {
                let inputTokens: Int?
                let cachedInputTokens: Int?
                let cacheWriteInputTokens: Int?
                let outputTokens: Int?
                let reasoningOutputTokens: Int?
                let totalTokens: Int?
            }
            let lastTokenUsage: Usage?
            let totalTokenUsage: Usage?
        }
        let type: String?
        let model: String?
        let modelSlug: String?
        let modelProvider: String?
        let info: Info?
    }
    let timestamp: String?
    let type: String?
    let payload: Payload?
}

final class CodexSource: UsageSource, @unchecked Sendable {
    private static let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")

    // Launched by launchd, the app gets a bare PATH without Homebrew or npm prefixes.
    private static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        return ([ProcessInfo.processInfo.environment["PATH"]].compactMap { $0 } + extra).joined(separator: ":")
    }()

    private let index = TranscriptIndex(name: "codex",
                                        roots: [home.appending(path: "sessions"), home.appending(path: "archived_sessions")],
                                        appendOnly: false, parse: CodexSource.parse)

    func fetchLimits() async throws -> LimitsSnapshot {
        try await Task.detached(priority: .utility) { try Self.readRateLimits() }.value
    }

    func scanStats(modelWindowDays: Int?) -> TokenStats {
        let since = TokenStats.scanStart(modelWindowDays: modelWindowDays)
        return TokenStats(records: index.scan(modifiedSince: since).flatMap { $0 }, modelName: Self.modelName,
                          modelWindowDays: modelWindowDays)
    }

    /// Mirrors Omarchy's collector: count each turn's last_token_usage (cached tokens are part of
    /// input_tokens), skip repeats whose cumulative total did not move, and drop rollouts served
    /// by a provider other than OpenAI, which this subscription does not pay for.
    private static func parse(lines: [Data], fallbackDay: String, records: inout [TokenRecord]) {
        let markers = [#""token_count""#, #""turn_context""#, #""session_meta""#].map { Array($0.utf8) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var totals: [String: Int] = [:]
        var model = "codex"
        var seenMeta = false
        var previousTotal: RolloutLine.Payload.Info.Usage?

        for line in lines where markers.contains(where: line.containsBytes) {
            guard let entry = try? decoder.decode(RolloutLine.self, from: line), let payload = entry.payload
            else { continue }
            switch entry.type {
            case "session_meta":
                // A forked rollout copies its parent's session_meta after its own.
                guard !seenMeta else { continue }
                seenMeta = true
                if let provider = payload.modelProvider, !provider.isEmpty, provider != "openai" {
                    records = []
                    return
                }
            case "turn_context":
                model = payload.model ?? payload.modelSlug ?? model
            default:
                guard payload.type == "token_count", let usage = payload.info?.lastTokenUsage else { continue }
                let cacheRead = usage.cachedInputTokens ?? 0
                let cacheWrite = usage.cacheWriteInputTokens ?? 0
                let input = max(0, (usage.inputTokens ?? 0) - cacheRead - cacheWrite)
                let tokens = input + (usage.outputTokens ?? 0) + cacheRead + cacheWrite
                guard tokens > 0 else { continue }
                if let cumulative = payload.info?.totalTokenUsage {
                    if cumulative == previousTotal { continue }
                    previousTotal = cumulative
                }
                let day = LocalDay.from(timestamp: entry.timestamp) ?? fallbackDay
                totals["\(day)\t\(model)", default: 0] += tokens
            }
        }
        records = totals.map { key, tokens in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return TokenRecord(key: nil, model: parts[1], day: parts[0], tokens: tokens, output: 0)
        }
    }

    /// "gpt-5.6-luna" -> "GPT-5.6 Luna".
    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count > 1, parts[0].lowercased() == "gpt" else { return id }
        return (["GPT-\(parts[1])"] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
    }

    private static func findCodex() -> URL? {
        searchPath.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts `codex app-server`, asks it for the rate limits over JSON-RPC on stdio, and stops it.
    private static func readRateLimits() throws -> LimitsSnapshot {
        guard let codex = findCodex() else { throw CodexError.notInstalled }
        let process = Process()
        process.executableURL = codex
        process.arguments = ["-s", "read-only", "-a", "on-request", "app-server"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath]) { $1 }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Killing the server ends the read loop below with EOF.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "claude-usage", "version": "1"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw CodexError.noAnswer }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let reply = try? JSONDecoder().decode(RPCReply.self, from: line) else { continue }
                switch reply.id {
                case 1:
                    try send(["method": "initialized", "params": [String: Any]()])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])
                case 2:
                    if let message = reply.error?.message {
                        throw message.localizedCaseInsensitiveContains("auth") ? CodexError.notLoggedIn : CodexError.rpc(message)
                    }
                    let limits = reply.result?.rateLimits
                    let meters = [("primary", limits?.primary), ("secondary", limits?.secondary)].compactMap { id, window in
                        window.flatMap { meter(id: id, window: $0) }
                    }
                    return LimitsSnapshot(plan: limits?.planType?.capitalized, meters: meters)
                default:
                    continue
                }
            }
        }
    }

    private static func meter(id: String, window: RPCReply.Result.RateLimits.Window) -> LimitMeter? {
        guard let used = window.usedPercent else { return nil }
        let minutes = window.windowDurationMins ?? 0
        let title = switch minutes {
        case 300: "Session"
        case 10_080: "Weekly"
        case let m where m > 0 && m % 60 == 0: "\(m / 60)h window"
        case let m where m > 0: "\(m)m window"
        default: "Limit"
        }
        return LimitMeter(id: id, title: title, percent: used,
                          resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
    }
}
