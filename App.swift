// Menu bar item showing Claude Code and Codex plan usage, like Omarchy's agent usage panel.
// Run the binary with --dump to print what the panel would show and exit.

import AppKit
import Combine
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.belerico.claude-usage", category: "usage")

enum Agent: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"

    var id: Self { self }
}

enum PanelTab: CaseIterable, Identifiable {
    case claude, codex, settings

    var id: Self { self }

    var agent: Agent? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .settings: nil
        }
    }

    var title: String { agent?.rawValue ?? "Settings" }
}

struct AgentState {
    var plan: String?
    var limits: [LimitMeter] = []
    var limitsError: String?
    /// The limits failed because the Claude Code login expired or is missing.
    var needsLogin = false
    var limitsAttemptedAt: Date?
    var stats: TokenStats?
    var updatedAt: Date?
    var loading = false
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var tab: PanelTab = .claude {
        didSet { tab.agent.map { refresh($0) } }
    }
    @Published private(set) var states: [Agent: AgentState] = [:]
    @Published private(set) var loggingIn = false

    private let prefs = Preferences.shared
    private let sources: [Agent: UsageSource] = [.claude: ClaudeSource(), .codex: CodexSource()]
    private let alerts = LimitAlerts()
    private var pollTask: Task<Void, Never>?
    private var login: Process?
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        restartPolling()
        if prefs.alertAt > 0 { alerts.requestPermission() }

        // @Published emits before the new value is stored; hop to the next run loop turn so
        // everything below reads the updated preferences.
        prefs.$refreshMinutes.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restartPolling() }
            .store(in: &subscriptions)
        prefs.$modelWindow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for agent in Agent.allCases where self.states[agent]?.stats != nil { self.refresh(agent) }
            }
            .store(in: &subscriptions)
        prefs.$showCodex.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] show in
                if !show, self?.tab == .codex { self?.tab = .claude }
            }
            .store(in: &subscriptions)
        prefs.$alertAt.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] threshold in
                guard let self, threshold > 0 else { return }
                self.alerts.requestPermission()
                for (agent, state) in self.states {
                    self.alerts.check(agent, meters: state.limits, threshold: threshold)
                }
            }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(.claude) }
        }
        // The panel's window becomes key each time it opens.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let agent = self.tab.agent else { return }
                self.refresh(agent)
            }
        }
    }

    func state(_ agent: Agent) -> AgentState { states[agent] ?? AgentState() }

    func menuBarTitle(format: MenuBarFormat, dangerAt: Int) -> String {
        let limits = state(.claude).limits
        let kinds = switch format {
        case .both: ["session", "weekly_all"]
        case .session: ["session"]
        case .weekly: ["weekly_all"]
        case .icon: [String]()
        }
        let shown = kinds.compactMap { kind in limits.first { $0.id.hasPrefix(kind) } }
        let warning = limits.contains { $0.percent >= Double(dangerAt) } ? " ⚠︎" : ""
        let numbers = shown.map { "\(Int($0.percent.rounded()))%" }.joined(separator: " · ")
        if format == .icon || limits.isEmpty { return "✳︎\(warning)" }
        return "✳︎\(warning) \(numbers)"
    }

    /// Claude is polled for the menu bar title; Codex only refreshes while its tab is shown.
    private func restartPolling() {
        pollTask?.cancel()
        let interval = Duration.seconds(prefs.refreshMinutes * 60)
        pollTask = Task {
            while !Task.isCancelled {
                refresh(.claude)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Rescans the transcripts (cheap: only new bytes are read) and, unless they were asked for
    /// recently, refetches the limits. Anthropic rate-limits the usage endpoint readily.
    func refresh(_ agent: Agent, force: Bool = false) {
        var state = state(agent)
        guard !state.loading, let source = sources[agent] else { return }
        let minimumAge: TimeInterval = force ? 15 : agent == .claude ? 60 : 300
        let fetchLimits = state.limitsAttemptedAt.map { -$0.timeIntervalSinceNow >= minimumAge } ?? true
        let modelWindowDays = prefs.modelWindow.days
        state.loading = true
        states[agent] = state

        Task {
            let stats = await Task.detached(priority: .utility) {
                source.scanStats(modelWindowDays: modelWindowDays)
            }.value
            var state = self.state(agent)
            state.stats = stats
            if fetchLimits {
                state.limitsAttemptedAt = .now
                do {
                    let snapshot = try await source.fetchLimits()
                    state.plan = snapshot.plan ?? state.plan
                    state.limits = snapshot.meters
                    state.limitsError = nil
                    state.needsLogin = false
                    alerts.check(agent, meters: snapshot.meters, threshold: prefs.alertAt)
                    log.notice("\(agent.rawValue, privacy: .public): \(snapshot.meters.map { "\($0.title) \(Int($0.percent))%" }.joined(separator: ", "), privacy: .public)")
                } catch {
                    state.limitsError = error.localizedDescription
                    state.needsLogin = (error as? ClaudeError)?.needsLogin ?? false
                    log.error("\(agent.rawValue, privacy: .public) limits failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            state.updatedAt = .now
            state.loading = false
            states[agent] = state
        }
    }

    /// Runs `claude auth login`, restarting it if one is already waiting for the browser, and
    /// refetches the limits once it exits.
    func logIn() {
        if let login, login.isRunning { login.terminate() }
        do {
            login = try ClaudeLogin.start { [weak self] process in
                let id = ObjectIdentifier(process), status = process.terminationStatus
                Task { @MainActor in
                    guard let self, let login = self.login, ObjectIdentifier(login) == id else { return }
                    log.notice("claude auth login exited with status \(status)")
                    self.login = nil
                    self.loggingIn = false
                    self.states[.claude]?.limitsAttemptedAt = nil
                    self.refresh(.claude)
                }
            }
            loggingIn = true
        } catch {
            states[.claude, default: AgentState()].limitsError = error.localizedDescription
            log.error("claude auth login failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Preferences

    var body: some View {
        Text(store.menuBarTitle(format: prefs.menuBar, dangerAt: prefs.dangerAt))
    }
}

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()
    @ObservedObject private var prefs = Preferences.shared

    init() {
        ClaudeLogin.openURLAsBrowser()
        // Writing to a codex app-server that died must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--dump") { Self.dumpAndExit() }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store, prefs: prefs)
        } label: {
            MenuBarLabel(store: store, prefs: prefs)
        }
        .menuBarExtraStyle(.window)
    }

    private static func dumpAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let sources: [(Agent, UsageSource)] = [(.claude, ClaudeSource()), (.codex, CodexSource())]
            for (agent, source) in sources {
                let start = Date()
                let stats = source.scanStats(modelWindowDays: 30)
                print("== \(agent.rawValue) (scan \(String(format: "%.2f", -start.timeIntervalSinceNow))s)")
                for day in stats.days { print("  \(day.id) \(day.label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(day.tokens)") }
                for model in stats.models { print("  \(model.name): \(model.tokens)") }
                do {
                    let snapshot = try await source.fetchLimits()
                    print("  plan: \(snapshot.plan ?? "-")")
                    for meter in snapshot.meters {
                        print("  \(meter.title): \(meter.percent)% resets \(meter.resetsAt?.formatted() ?? "-")")
                    }
                } catch {
                    print("  limits error: \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
