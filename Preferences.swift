// User settings (persisted in UserDefaults), color themes, and limit alerts.

import AppKit
import OSLog
import SwiftUI
import UserNotifications

struct Palette: Codable, Equatable {
    var background: String
    var text: String
    var muted: String
    var bar: String
    var warning: String
    var danger: String

    struct Preset: Identifiable {
        var id: String { name }
        let name: String
        let palette: Palette
    }

    static let presets: [Preset] = [
        Preset(name: "Omarchy", palette: Palette(background: "#2A0F38", text: "#F0E8F5", muted: "#9E8CAD",
                                                 bar: "#F2EDF7", warning: "#FAA640", danger: "#F02654")),
        Preset(name: "Tokyo Night", palette: Palette(background: "#1A1B26", text: "#C0CAF5", muted: "#565F89",
                                                     bar: "#7AA2F7", warning: "#E0AF68", danger: "#F7768E")),
        Preset(name: "Catppuccin", palette: Palette(background: "#1E1E2E", text: "#CDD6F4", muted: "#7F849C",
                                                    bar: "#CBA6F7", warning: "#F9E2AF", danger: "#F38BA8")),
        Preset(name: "Dracula", palette: Palette(background: "#282A36", text: "#F8F8F2", muted: "#6272A4",
                                                 bar: "#BD93F9", warning: "#FFB86C", danger: "#FF5555")),
        Preset(name: "Gruvbox", palette: Palette(background: "#282828", text: "#EBDBB2", muted: "#928374",
                                                 bar: "#B8BB26", warning: "#FABD2F", danger: "#FB4934")),
        Preset(name: "Nord", palette: Palette(background: "#2E3440", text: "#ECEFF4", muted: "#7B88A1",
                                              bar: "#88C0D0", warning: "#EBCB8B", danger: "#BF616A")),
        Preset(name: "Rosé Pine", palette: Palette(background: "#191724", text: "#E0DEF4", muted: "#6E6A86",
                                                   bar: "#EBBCBA", warning: "#F6C177", danger: "#EB6F92")),
        Preset(name: "Latte", palette: Palette(background: "#EFF1F5", text: "#4C4F69", muted: "#8C8FA1",
                                               bar: "#8839EF", warning: "#DF8E1D", danger: "#D20F39")),
    ]

    /// "2a0f38" or "#2A0F38" -> "#2A0F38"; nil unless it is six hex digits.
    static func normalize(_ hex: String) -> String? {
        let digits = hex.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits
    }

    static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalize(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

extension Color {
    init(hex: String, fallback: Color = .gray) {
        if let rgb = Palette.rgb(hex) {
            self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self = fallback
        }
    }
}

enum MenuBarFormat: String, CaseIterable {
    case both, session, weekly, icon

    var label: String {
        switch self {
        case .both: "Both"
        case .session: "Session"
        case .weekly: "Weekly"
        case .icon: "Icon"
        }
    }
}

enum ModelWindow: Int, CaseIterable {
    case week = 7
    case month = 30
    case all = 0

    var days: Int? { self == .all ? nil : rawValue }
    var label: String { self == .all ? "All" : "\(rawValue)d" }
    var note: String { self == .all ? "All history" : "\(rawValue) days" }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    nonisolated static let systemMono = "System Mono"
    nonisolated static let system = "System"

    /// The system fonts plus every installed fixed-pitch family, minus Nerd Font symbol sets.
    static let fontFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.localizedCaseInsensitiveContains("symbols") }
        return [systemMono, system] + families.sorted()
    }()

    private static let defaults = UserDefaults.standard

    @Published var palette: Palette { didSet { Self.save(try? JSONEncoder().encode(palette), "palette") } }
    @Published var fontFamily: String { didSet { Self.save(fontFamily, "fontFamily") } }
    @Published var fontSize: Int { didSet { Self.save(fontSize, "fontSize") } }
    @Published var menuBar: MenuBarFormat { didSet { Self.save(menuBar.rawValue, "menuBar") } }
    @Published var refreshMinutes: Int { didSet { Self.save(refreshMinutes, "refreshMinutes") } }
    @Published var modelWindow: ModelWindow { didSet { Self.save(modelWindow.rawValue, "modelWindow") } }
    @Published var showCodex: Bool { didSet { Self.save(showCodex, "showCodex") } }
    /// Notify when a limit reaches this percentage; 0 turns alerts off.
    @Published var alertAt: Int { didSet { Self.save(alertAt, "alertAt") } }
    @Published var warnAt: Int { didSet { Self.save(warnAt, "warnAt") } }
    @Published var dangerAt: Int { didSet { Self.save(dangerAt, "dangerAt") } }

    private init() {
        let defaults = Self.defaults
        palette = defaults.data(forKey: "palette").flatMap { try? JSONDecoder().decode(Palette.self, from: $0) }
            ?? Palette.presets[0].palette
        fontFamily = defaults.string(forKey: "fontFamily") ?? Self.systemMono
        fontSize = defaults.object(forKey: "fontSize") as? Int ?? 12
        menuBar = defaults.string(forKey: "menuBar").flatMap(MenuBarFormat.init) ?? .both
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Int ?? 5
        modelWindow = (defaults.object(forKey: "modelWindow") as? Int).flatMap(ModelWindow.init) ?? .month
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        alertAt = defaults.object(forKey: "alertAt") as? Int ?? 0
        warnAt = defaults.object(forKey: "warnAt") as? Int ?? 70
        dangerAt = defaults.object(forKey: "dangerAt") as? Int ?? 90
    }

    var theme: Theme {
        Theme(palette: palette, fontFamily: fontFamily, fontSize: Double(fontSize),
              warnAt: Double(warnAt), dangerAt: Double(dangerAt))
    }

    func reset() {
        palette = Palette.presets[0].palette
        fontFamily = Self.systemMono
        fontSize = 12
        menuBar = .both
        refreshMinutes = 5
        modelWindow = .month
        showCodex = true
        alertAt = 0
        warnAt = 70
        dangerAt = 90
    }

    private static func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Feeds the shared macOS color panel into one palette color. The panel outlives the menu bar
/// window (which closes when the panel takes focus), so its target is this app-lifetime object.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var role: WritableKeyPath<Palette, String>?

    func edit(_ role: WritableKeyPath<Palette, String>) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        self.role = role
        if let rgb = Palette.rgb(Preferences.shared.palette[keyPath: role]) {
            panel.color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let role, let color = panel.color.usingColorSpace(.sRGB) else { return }
        Preferences.shared.palette[keyPath: role] = String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

/// Posts a notification once each time a limit crosses `Preferences.alertAt`.
@MainActor
final class LimitAlerts: NSObject, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "com.belerico.claude-usage", category: "alerts")
    private var notified: Set<String> = []

    // UNUserNotificationCenter traps without a bundle, e.g. when the bare binary runs --dump.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            log.notice("Notification permission granted: \(granted), error: \(error?.localizedDescription ?? "none", privacy: .public)")
        }
    }

    func check(_ agent: Agent, meters: [LimitMeter], threshold: Int) {
        guard threshold > 0, let center else { return }
        for meter in meters {
            let key = "\(agent.rawValue)/\(meter.id)/\(threshold)"
            guard meter.percent >= Double(threshold) else {
                notified.remove(key)
                continue
            }
            guard notified.insert(key).inserted else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(agent.rawValue): \(meter.title) at \(Int(meter.percent.rounded()))%"
            if let resetsAt = meter.resetsAt {
                content.body = "Resets \(resetsAt.formatted(.relative(presentation: .named)))."
            }
            content.sound = .default
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    // Show banners even while the panel is open and this app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
