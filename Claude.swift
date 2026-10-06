// Claude Code: plan limits from Anthropic's OAuth usage endpoint (with the Claude Code login
// token), token counts from the local transcripts in ~/.claude/projects.

import Foundation

private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

enum ClaudeError: LocalizedError {
    case notInstalled
    case noCredentials
    case tokenExpired
    case rateLimited
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Claude Code CLI not found."
        case .noCredentials: "No Claude Code login found. Run `claude` and log in."
        case .tokenExpired: "Login token expired. Open Claude Code to refresh it."
        case .rateLimited: "Rate limited by the usage API. Retrying later."
        case .http(let code): "Usage API returned HTTP \(code)."
        }
    }

    /// Errors that `claude auth login` fixes.
    var needsLogin: Bool {
        switch self {
        case .noCredentials, .tokenExpired: true
        default: false
        }
    }
}

private struct Credentials {
    let accessToken: String
    let expiresAt: Date?
    let plan: String?
}

private struct CredentialsFile: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
        let subscriptionType: String?
        let rateLimitTier: String?
    }
    let claudeAiOauth: OAuth
}

/// Claude Code's global config (~/.claude.json), which keeps the account after the token expires.
private struct GlobalConfig: Decodable {
    struct Account: Decodable { let emailAddress: String? }
    let oauthAccount: Account?
}

/// Chrome's "Local State": the profile directories and the Google account each is signed in to.
private struct ChromeLocalState: Decodable {
    struct Profiles: Decodable {
        struct Info: Decodable {
            let userName: String?
            enum CodingKeys: String, CodingKey { case userName = "user_name" }
        }
        let infoCache: [String: Info]
        enum CodingKeys: String, CodingKey { case infoCache = "info_cache" }
    }
    let profile: Profiles
}

private struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let displayName: String? }
            let model: Model?
        }
        let kind: String
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [Limit]?
}

private struct TranscriptLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?
        }
        let id: String?
        let model: String?
        let role: String?
        let usage: Usage?
    }
    let type: String?
    let timestamp: String?
    let uuid: String?
    let message: Message?
}

final class ClaudeSource: UsageSource, @unchecked Sendable {
    private static let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    private let index = TranscriptIndex(name: "claude", roots: [configDir.appending(path: "projects")],
                                        appendOnly: true, parse: ClaudeSource.parse)

    func fetchLimits() async throws -> LimitsSnapshot {
        let credentials = try Self.readCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt < .now { throw ClaudeError.tokenExpired }

        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw ClaudeError.tokenExpired
        case 429: throw ClaudeError.rateLimited
        case let code: throw ClaudeError.http(code)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage = try decoder.decode(UsageResponse.self, from: data)
        return LimitsSnapshot(plan: credentials.plan, meters: Self.meters(from: usage))
    }

    /// One API message can appear on several lines and, in resumed sessions, in several files:
    /// the record with the highest output count wins, as in Omarchy's collector.
    func scanStats(modelWindowDays: Int?) -> TokenStats {
        let since = TokenStats.scanStart(modelWindowDays: modelWindowDays)
        var unique: [String: TokenRecord] = [:]
        for records in index.scan(modifiedSince: since) {
            for record in records {
                let key = record.key ?? ""
                if let held = unique[key], record.output < held.output { continue }
                unique[key] = record
            }
        }
        return TokenStats(records: Array(unique.values), modelName: Self.modelName, modelWindowDays: modelWindowDays)
    }

    /// Streamed responses repeat a message id on several lines; the first carries a placeholder
    /// output count, so keep each message's line with the highest one.
    private static func parse(lines: [Data], fallbackDay: String, records: inout [TokenRecord]) {
        let needle = Array(#""usage":"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var positions = [String: Int](records.enumerated().map { ($1.key ?? "", $0) }, uniquingKeysWith: { $1 })

        for line in lines where line.containsBytes(needle) {
            guard let entry = try? decoder.decode(TranscriptLine.self, from: line),
                  let message = entry.message,
                  entry.type == "assistant" || message.role == "assistant",
                  let usage = message.usage,
                  let key = message.id ?? entry.uuid
            else { continue }
            let output = usage.outputTokens ?? 0
            let tokens = (usage.inputTokens ?? 0) + output + (usage.cacheReadInputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
            guard tokens > 0 else { continue }

            let record = TokenRecord(key: key, model: message.model ?? "claude",
                                     day: LocalDay.from(timestamp: entry.timestamp) ?? fallbackDay,
                                     tokens: tokens, output: output)
            if let held = positions[key] {
                if output >= records[held].output { records[held] = record }
            } else {
                positions[key] = records.count
                records.append(record)
            }
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5".
    static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
            .filter { $0 != "claude" && !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first(where: { $0.first?.isLetter == true }) else { return id }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    private static func meters(from usage: UsageResponse) -> [LimitMeter] {
        if let limits = usage.limits, !limits.isEmpty {
            return limits.enumerated().map { index, limit in
                let title = switch limit.kind {
                case "session": "Session"
                case "weekly_all": "Weekly"
                case "weekly_scoped": "\(limit.scope?.model?.displayName ?? "Scoped") Weekly"
                default: limit.kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                return LimitMeter(id: "\(limit.kind)-\(index)", title: title, percent: limit.percent ?? 0,
                                  resetsAt: parseDate(limit.resetsAt))
            }
        }
        // Older response shape without the `limits` array.
        return [("session", "Session", usage.fiveHour), ("weekly_all", "Weekly", usage.sevenDay)]
            .compactMap { id, title, window in
                window?.utilization.map { LimitMeter(id: id, title: title, percent: $0, resetsAt: parseDate(window?.resetsAt)) }
            }
    }

    /// The API returns microsecond fractions ("2026-10-03T10:50:00.384527+00:00"), which
    /// the ISO 8601 parsers reject, so drop the fraction first.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return try? Date(string.replacing(#/\.\d+/#, with: ""), strategy: .iso8601)
    }

    /// Shells out to /usr/bin/security: Claude Code stores the item with that tool, so reading it
    /// this way does not trigger a Keychain prompt every time this app is rebuilt.
    private static func readCredentials() throws -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var keychain: Data?
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            keychain = process.terminationStatus == 0 ? data : nil
        }

        guard let data = keychain ?? (try? Data(contentsOf: configDir.appending(path: ".credentials.json"))),
              let oauth = try? JSONDecoder().decode(CredentialsFile.self, from: data).claudeAiOauth
        else { throw ClaudeError.noCredentials }

        var plan = oauth.subscriptionType?.capitalized
        if let tier = oauth.rateLimitTier, let multiplier = tier.firstMatch(of: #/(\d+x)$/#)?.1 {
            plan = [plan, String(multiplier)].compactMap { $0 }.joined(separator: " ")
        }
        return Credentials(accessToken: oauth.accessToken,
                           expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                           plan: plan)
    }
}

/// `claude auth login` opens the sign-in page with $BROWSER and waits for the page's localhost
/// callback. When a Chrome profile is signed in to the Claude account's email, $BROWSER is this
/// app's own binary, and `openURLAsBrowser` opens the page in that profile.
enum ClaudeLogin {
    private static let profileKey = "CLAUDE_USAGE_CHROME_PROFILE"

    /// Starts the login; `onExit` runs on a background thread when it finishes, fails or is
    /// abandoned for 10 minutes.
    static func start(onExit: @escaping @Sendable (Process) -> Void) throws -> Process {
        guard let claude = CommandLineTool.find("claude") else { throw ClaudeError.notInstalled }
        var environment = ProcessInfo.processInfo.environment.merging(["PATH": CommandLineTool.searchPath]) { $1 }
        let email = accountEmail()
        if let email, let profile = chromeProfile(signedInAs: email), let binary = Bundle.main.executablePath {
            environment["BROWSER"] = binary
            environment[profileKey] = profile
        }

        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.environment = environment
        // Without a terminal the "paste code" prompt reads EOF and the login waits for the callback.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = onExit
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
            if process.isRunning { process.terminate() }
        }
        return process
    }

    /// Run by `claude auth login` as $BROWSER with the sign-in URL: opens it in the Chrome profile
    /// and exits. `open -n` hands the URL to the running Chrome, or starts Chrome in that profile.
    static func openURLAsBrowser() {
        let arguments = CommandLine.arguments
        guard let profile = ProcessInfo.processInfo.environment[profileKey], arguments.count == 2,
              let url = URL(string: arguments[1]), ["http", "https"].contains(url.scheme)
        else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-b", "com.google.Chrome", "--args", "--profile-directory=\(profile)", url.absoluteString]
        guard (try? open.run()) != nil else { exit(1) }
        open.waitUntilExit()
        exit(open.terminationStatus)
    }

    private static func accountEmail() -> String? {
        let file = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: file.appending(path: ".claude.json")) else { return nil }
        return (try? JSONDecoder().decode(GlobalConfig.self, from: data))?.oauthAccount?.emailAddress
    }

    /// The profile directory ("Profile 9") whose Google account is `email`.
    private static func chromeProfile(signedInAs email: String) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(ChromeLocalState.self, from: data)
        else { return nil }
        return state.profile.infoCache
            .first { $0.value.userName?.caseInsensitiveCompare(email) == .orderedSame }?.key
    }
}
