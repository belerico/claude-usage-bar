// The dropdown panel, styled after Omarchy's agent usage panel, and its settings tab.

import AppKit
import SwiftUI

struct Theme {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    var palette = Palette.presets[0].palette
    var fontFamily = Preferences.systemMono
    var fontSize = 12.0
    var warnAt = 70.0
    var dangerAt = 90.0

    var background: Color { Color(hex: palette.background, fallback: .black) }
    var text: Color { Color(hex: palette.text, fallback: .white) }
    var dim: Color { Color(hex: palette.muted) }
    var bar: Color { Color(hex: palette.bar, fallback: .white) }
    var warning: Color { Color(hex: palette.warning, fallback: .orange) }
    var danger: Color { Color(hex: palette.danger, fallback: .red) }
    var rule: Color { text.opacity(0.10) }
    var track: Color { text.opacity(0.13) }
    var dayBar: Color { bar.opacity(0.72) }
    var modelTrack: Color { text.opacity(0.05) }
    var modelBar: Color { bar.opacity(0.16) }

    var isLight: Bool {
        guard let rgb = Palette.rgb(palette.background) else { return false }
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue > 0.5
    }

    /// `size` is for the default 12 pt setting and scales with the chosen font size.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, family: String? = nil) -> Font {
        let scaled = size * fontSize / 12
        return switch family ?? fontFamily {
        case Preferences.systemMono: .system(size: scaled, weight: weight, design: .monospaced)
        case Preferences.system: .system(size: scaled, weight: weight)
        case let custom: .custom(custom, size: scaled).weight(weight)
        }
    }

    func level(_ percent: Double) -> Color {
        percent >= dangerAt ? danger : percent >= warnAt ? warning : text
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The bordered box used by tabs and every option chip.
private struct Chip: ViewModifier {
    @Environment(\.theme) private var theme
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(selected ? theme.text.opacity(0.10) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.text.opacity(selected ? 0.20 : 0.38)))
            .contentShape(Rectangle())
    }
}

private extension View {
    func chip(selected: Bool) -> some View { modifier(Chip(selected: selected)) }
}

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Preferences

    var body: some View {
        let theme = prefs.theme
        VStack(alignment: .leading, spacing: 16) {
            Header(tab: store.tab, plan: store.tab.agent.flatMap { store.state($0).plan })
            TabBar(selected: $store.tab, showCodex: prefs.showCodex)
            if let agent = store.tab.agent {
                let state = store.state(agent)
                PanelSection("Limits") { LimitsList(state: state) }
                PanelSection("Tokens by day") { DayList(stats: state.stats) }
                PanelSection("Tokens by model", note: prefs.modelWindow.note) { ModelList(stats: state.stats) }
            } else {
                SettingsView(prefs: prefs)
            }
            Footer(store: store)
        }
        .padding(16)
        .frame(width: 360)
        .font(theme.font(12))
        .foregroundStyle(theme.text)
        .background(theme.background)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
    }
}

private struct Header: View {
    @Environment(\.theme) private var theme
    let tab: PanelTab
    let plan: String?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch tab {
                case .claude: Starburst().stroke(Theme.claude, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                case .codex: Image(systemName: "terminal").font(.system(size: 20, weight: .medium))
                case .settings: Image(systemName: "gearshape").font(.system(size: 20, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title).font(theme.font(15, .semibold))
                Text((tab == .settings ? "Claude Usage" : plan ?? " ").uppercased())
                    .font(theme.font(10))
                    .tracking(1.2)
                    .foregroundStyle(theme.dim)
            }
        }
    }
}

/// A sunburst of uneven rays, after the Claude mark.
private struct Starburst: Shape {
    func path(in rect: CGRect) -> Path {
        let lengths: [CGFloat] = [1, 0.74, 0.92, 0.68, 0.98, 0.78, 0.9, 0.7, 1, 0.76, 0.94, 0.72]
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for (index, length) in lengths.enumerated() {
            let angle = Double(index) / Double(lengths.count) * 2 * .pi - .pi / 2 + 0.15
            path.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.16, y: center.y + sin(angle) * radius * 0.16))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * radius * length, y: center.y + sin(angle) * radius * length))
        }
        return path
    }
}

private struct TabBar: View {
    @Environment(\.theme) private var theme
    @Binding var selected: PanelTab
    let showCodex: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PanelTab.allCases.filter { $0 != .settings && ($0 != .codex || showCodex) }) { tab in
                Button { selected = tab } label: {
                    Text(tab.title)
                        .font(theme.font(12, tab == selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .chip(selected: tab == selected)
                }
            }
            Button { selected = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12 * theme.fontSize / 12, weight: selected == .settings ? .semibold : .regular))
                    .frame(width: 22)
                    .chip(selected: selected == .settings)
            }
            .help("Settings")
        }
        .buttonStyle(.plain)
    }
}

private struct PanelSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(theme.rule).frame(height: 1)
            HStack {
                Text(title.uppercased())
                Spacer()
                if let note { Text(note.uppercased()) }
            }
            .font(theme.font(10.5, .medium))
            .tracking(1)
            .foregroundStyle(theme.dim)
            content
        }
    }
}

private struct Bar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                if fraction > 0 {
                    Capsule().fill(color)
                        .frame(width: max(height, geometry.size.width * min(fraction, 1)))
                }
            }
        }
        .frame(height: height)
    }
}

private struct LimitsList: View {
    @Environment(\.theme) private var theme
    let state: AgentState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.limits.isEmpty {
                Text(state.limitsError ?? (state.loading ? "Loading…" : "No limits reported."))
                    .font(theme.font(11))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.limits) { LimitRow(meter: $0) }
                if let error = state.limitsError {
                    Text(error)
                        .font(theme.font(10.5))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LimitRow: View {
    @Environment(\.theme) private var theme
    let meter: LimitMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meter.title).font(theme.font(12.5))
                Spacer()
                Text("\(Int(meter.percent.rounded()))%").font(theme.font(11))
            }
            .foregroundStyle(theme.level(meter.percent))
            Bar(fraction: meter.percent / 100,
                color: meter.percent >= theme.warnAt ? theme.level(meter.percent) : theme.bar)
            if let resetsAt = meter.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Resets in \(countdown(to: resetsAt, from: context.date))")
                        .font(theme.font(10.5))
                        .foregroundStyle(theme.dim)
                }
            }
        }
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

private struct DayList: View {
    @Environment(\.theme) private var theme
    let stats: TokenStats?

    var body: some View {
        if let days = stats?.days {
            let peak = max(days.map(\.tokens).max() ?? 0, 1)
            VStack(spacing: 9) {
                ForEach(days) { day in
                    HStack(spacing: 12) {
                        Text(day.label)
                            .foregroundStyle(day.isToday ? theme.text : theme.dim)
                            .frame(width: 46 * theme.fontSize / 12, alignment: .leading)
                        Bar(fraction: Double(day.tokens) / Double(peak), color: theme.dayBar, height: 5)
                        Text(formatTokens(day.tokens)).frame(width: 58 * theme.fontSize / 12, alignment: .trailing)
                    }
                    .font(theme.font(11, day.isToday ? .bold : .regular))
                }
            }
        } else {
            Text("Reading transcripts…").font(theme.font(11)).foregroundStyle(theme.dim)
        }
    }
}

private struct ModelList: View {
    @Environment(\.theme) private var theme
    let stats: TokenStats?

    var body: some View {
        let models = Array((stats?.models ?? []).prefix(5))
        if models.isEmpty {
            Text(stats == nil ? "Reading transcripts…" : "No usage recorded.")
                .font(theme.font(11))
                .foregroundStyle(theme.dim)
        } else {
            let peak = max(models[0].tokens, 1)
            VStack(spacing: 6) {
                ForEach(models) { model in
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(theme.modelTrack)
                            Rectangle().fill(theme.modelBar)
                                .frame(width: geometry.size.width * Double(model.tokens) / Double(peak))
                            HStack {
                                Text(model.name)
                                Spacer()
                                Text(formatTokens(model.tokens)).foregroundStyle(theme.dim)
                            }
                            .padding(.horizontal, 9)
                        }
                    }
                    .frame(height: 26 * theme.fontSize / 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
        }
    }
}

private struct Footer: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(theme.rule).frame(height: 1)
            HStack(spacing: 14) {
                if let agent = store.tab.agent {
                    let state = store.state(agent)
                    if let updatedAt = state.updatedAt {
                        Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                    Button { store.refresh(agent, force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh now")
                    .keyboardShortcut("r")
                    .disabled(state.loading)
                    if agent == .claude {
                        Button("Usage") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                    }
                } else {
                    Text("Changes apply immediately")
                    Spacer()
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .font(theme.font(10.5))
            .foregroundStyle(theme.dim)
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var prefs: Preferences

    private let twoColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelSection("Theme") {
                    LazyVGrid(columns: twoColumns, spacing: 8) {
                        ForEach(Palette.presets) { preset in
                            PresetChip(preset: preset, selected: prefs.palette == preset.palette) {
                                prefs.palette = preset.palette
                            }
                        }
                    }
                }
                PanelSection("Colors", note: "click a swatch to pick") {
                    VStack(spacing: 7) {
                        ColorRow(label: "Background", role: \.background, prefs: prefs)
                        ColorRow(label: "Text", role: \.text, prefs: prefs)
                        ColorRow(label: "Muted", role: \.muted, prefs: prefs)
                        ColorRow(label: "Bars", role: \.bar, prefs: prefs)
                        ColorRow(label: "Warning", role: \.warning, prefs: prefs)
                        ColorRow(label: "Danger", role: \.danger, prefs: prefs)
                    }
                }
                PanelSection("Font") {
                    LazyVGrid(columns: twoColumns, spacing: 8) {
                        ForEach(Preferences.fontFamilies, id: \.self) { family in
                            Button { prefs.fontFamily = family } label: {
                                Text(family)
                                    .font(theme.font(11, family == prefs.fontFamily ? .semibold : .regular, family: family))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .chip(selected: family == prefs.fontFamily)
                            }
                        }
                    }
                    SettingRow("Size") {
                        NumberStepper(value: $prefs.fontSize, range: 10...16, step: 1, suffix: " pt")
                    }
                }
                PanelSection("Menu bar") {
                    Chips(options: MenuBarFormat.allCases, selection: $prefs.menuBar, label: \.label)
                }
                PanelSection("Data") {
                    SettingRow("Refresh") {
                        Chips(options: [1, 2, 5, 10, 15], selection: $prefs.refreshMinutes) { "\($0)m" }
                    }
                    SettingRow("Models") {
                        Chips(options: ModelWindow.allCases, selection: $prefs.modelWindow, label: \.label)
                    }
                    SettingRow("Codex tab") {
                        Chips(options: [true, false], selection: $prefs.showCodex) { $0 ? "Show" : "Hide" }
                    }
                }
                PanelSection("Alerts") {
                    SettingRow("Notify at") {
                        Chips(options: [0, 75, 90, 100], selection: $prefs.alertAt) { $0 == 0 ? "Off" : "\($0)%" }
                    }
                    SettingRow("Warn at") {
                        NumberStepper(value: $prefs.warnAt, range: 50...95, step: 5, suffix: "%")
                    }
                    SettingRow("Danger at") {
                        NumberStepper(value: $prefs.dangerAt, range: 55...100, step: 5, suffix: "%")
                    }
                }
                Button { prefs.reset() } label: {
                    Text("Reset to defaults").frame(maxWidth: .infinity).chip(selected: false)
                }
            }
            .buttonStyle(.plain)
            .font(theme.font(11))
        }
        .scrollIndicators(.never)
        .frame(height: 440)
    }
}

private struct SettingRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(theme.dim)
                .frame(width: 80 * theme.fontSize / 12, alignment: .leading)
            content
        }
    }
}

private struct Chips<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(theme.font(10.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? theme.text : theme.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .chip(selected: selected)
                }
            }
        }
    }
}

private struct NumberStepper: View {
    @Environment(\.theme) private var theme
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String

    var body: some View {
        HStack(spacing: 6) {
            Button { value = max(range.lowerBound, value - step) } label: {
                Image(systemName: "minus").frame(width: 14).chip(selected: false)
            }
            .disabled(value <= range.lowerBound)
            Text("\(value)\(suffix)").frame(maxWidth: .infinity)
            Button { value = min(range.upperBound, value + step) } label: {
                Image(systemName: "plus").frame(width: 14).chip(selected: false)
            }
            .disabled(value >= range.upperBound)
        }
    }
}

/// A theme preview: the preset's own background and text, with its bar and alert colors.
private struct PresetChip: View {
    @Environment(\.theme) private var theme
    let preset: Palette.Preset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(preset.name).lineLimit(1)
                Spacer(minLength: 4)
                ForEach([preset.palette.bar, preset.palette.warning, preset.palette.danger], id: \.self) {
                    Circle().fill(Color(hex: $0)).frame(width: 7, height: 7)
                }
            }
            .font(theme.font(10.5, selected ? .semibold : .regular))
            .foregroundStyle(Color(hex: preset.palette.text))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color(hex: preset.palette.background))
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(selected ? theme.text : theme.text.opacity(0.25), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
    }
}

private struct ColorRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let role: WritableKeyPath<Palette, String>
    @ObservedObject var prefs: Preferences
    @State private var text = ""

    var body: some View {
        SettingRow(label) {
            Button { ColorPanelBridge.shared.edit(role) } label: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: prefs.palette[keyPath: role]))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.text.opacity(0.35)))
                    .frame(width: 34, height: 18)
            }
            .help("Open the color picker")
            TextField("#RRGGBB", text: $text)
                .textFieldStyle(.plain)
                .font(theme.font(11))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Palette.normalize(text) == nil ? theme.danger : theme.text.opacity(0.2)))
                .onChange(of: text) { _, typed in
                    if let hex = Palette.normalize(typed), hex != prefs.palette[keyPath: role] {
                        prefs.palette[keyPath: role] = hex
                    }
                }
        }
        .onAppear { text = prefs.palette[keyPath: role] }
        .onChange(of: prefs.palette[keyPath: role]) { _, hex in
            if Palette.normalize(text) != hex { text = hex }
        }
    }
}
