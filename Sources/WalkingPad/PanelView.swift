import SwiftUI

/// The menu bar popup, laid out like a Control Center module.
struct PanelView: View {
    @Bindable var pad: Pad
    var openSettings: () -> Void
    var quit: () -> Void
    var onSize: (CGSize) -> Void

    @State private var sliderValue = 0.0
    @State private var editingSlider = false

    @AppStorage(Settings.Key.maxSpeed) private var maxSpeed = 6.0

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !pad.connected && !pad.error.isEmpty {
                Text(pad.error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pad.connected {
                Button {
                    pad.connect()
                } label: {
                    Label(pad.busy ? "Connecting…" : "Connect", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pad.busy || pad.connection == .bluetoothOff || pad.connection == .unauthorized)
                .help("Connect to your WalkingPad over Bluetooth")
            }

            if pad.connected {
                Divider()
                beltControls
                section("Session") {
                    StatRow(time: pad.status?.time ?? 0, distance: pad.status?.distance ?? 0, steps: pad.status?.steps ?? 0)
                }
            }

            Divider()

            section("Today") {
                StatRow(time: pad.today.time, distance: pad.today.distance, steps: pad.today.steps)
            }

            if !pad.week.isEmpty {
                section("Last 7 Days", trailing: "\(Format.steps(pad.week.reduce(0) { $0 + $1.totals.steps })) steps") {
                    WeekChart(week: pad.week)
                }
            }

            Divider()
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onAppear { sliderValue = pad.displaySpeed }
        .onChange(of: pad.displaySpeed) { _, v in if !editingSlider { sliderValue = v } }
    }

    // MARK: Header

    private var title: String {
        let n = pad.deviceName
        if n.isEmpty { return "WalkingPad" }
        return n.localizedCaseInsensitiveContains("walkingpad") ? n : "WalkingPad \(n)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(pad.running ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                Image(systemName: "figure.walk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pad.running ? .white : .primary)
            }
            .frame(width: 28, height: 28)
            .opacity(pad.connected ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(pad.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            if pad.busy {
                ProgressView().controlSize(.small)
            }

            Toggle("Connected", isOn: Binding(
                get: { pad.connected || pad.busy },
                set: { _ in pad.toggleConnection() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .help(pad.connected ? "Disconnect (frees the pad for the phone app)" : "Connect over Bluetooth")
        }
    }

    // MARK: Belt

    private var beltActive: Bool { pad.running || pad.starting }

    private var beltControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                pad.toggleBelt()
            } label: {
                Label(beltActive ? "Stop Belt" : "Start Belt", systemImage: beltActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(beltActive ? .red : .accentColor)
            .help(beltActive ? "" : "The pad counts down 3 seconds before the belt moves")

            HStack(spacing: 8) {
                Button { pad.slower() } label: {
                    Image(systemName: "tortoise.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!pad.running || pad.displaySpeed <= Settings.minSpeed)
                .help("Slower")

                Slider(value: $sliderValue, in: Settings.minSpeed...maxSpeed) { editing in
                    editingSlider = editing
                    if !editing {
                        let step = Settings.speedStep
                        pad.setSpeed((sliderValue / step).rounded() * step)
                    }
                }
                .controlSize(.small)
                .disabled(!pad.running)

                Button { pad.faster() } label: {
                    Image(systemName: "hare.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!pad.running || pad.displaySpeed >= maxSpeed)
                .help("Faster")

                (Text(Format.speed(sliderValue))
                    .font(.system(size: 13, weight: .semibold))
                 + Text(" km/h").font(.system(size: 11)).foregroundStyle(.secondary))
                    .monospacedDigit()
                    .frame(minWidth: 62, alignment: .trailing)
                    .foregroundStyle(pad.running ? .primary : .secondary)
            }

            Picker("Mode", selection: Binding(
                get: { pad.mode ?? .manual },
                set: { pad.setMode($0) }
            )) {
                ForEach([PadMode.manual, .auto, .standby]) { m in
                    Text(m.label).tag(m).help(m.help)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let trailing { Text(trailing).fontWeight(.regular) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if pad.deviceID != nil && !pad.connected && !pad.busy {
                MenuRow(title: "Forget This WalkingPad") { pad.forget() }
            }
            MenuRow(title: "WalkingPad Settings…", shortcut: "⌘,", action: openSettings)
            MenuRow(title: "Quit WalkingPad", shortcut: "⌘Q", action: quit)
        }
        .padding(.horizontal, -8)
    }
}

// MARK: - Pieces

enum Format {
    static func duration(_ sec: Int) -> String {
        let s = max(0, sec)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    static func km(_ metres: Int) -> String {
        (Double(metres) / 1000).formatted(.number.precision(.fractionLength(2)))
    }

    static func speed(_ kmh: Double) -> String { kmh.formatted(.number.precision(.fractionLength(1))) }

    static func steps(_ n: Int) -> String {
        n >= 10_000 ? (Double(n) / 1000).formatted(.number.precision(.fractionLength(1))) + "k" : n.formatted()
    }
}

/// Three numbers side by side: time, distance, steps.
struct StatRow: View {
    var time: Int
    var distance: Int
    var steps: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Stat(value: Format.duration(time), unit: nil, label: "Time")
            Stat(value: Format.km(distance), unit: "km", label: "Distance")
            Stat(value: steps.formatted(), unit: nil, label: "Steps")
        }
    }

    struct Stat: View {
        var value: String
        var unit: String?
        var label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                (Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                 + Text(unit.map { " \($0)" } ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Seven bars of daily steps, today on the right.
struct WeekChart: View {
    var week: [DayEntry]

    private static let barArea: CGFloat = 48
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()
    private static let tooltipDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        let maxSteps = max(1, week.map(\.totals.steps).max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(week.enumerated()), id: \.element.id) { i, day in
                let isToday = i == week.count - 1
                let steps = day.totals.steps
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isToday ? AnyShapeStyle(Color.accentColor)
                              : steps > 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                        .frame(height: max(3, Self.barArea * CGFloat(steps) / CGFloat(maxSteps)))
                    Text(Self.weekday.string(from: day.date))
                        .font(.system(size: 10, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("\(Self.tooltipDate.string(from: day.date)) · \(steps.formatted()) steps · \(Format.km(day.totals.distance)) km")
            }
        }
        .frame(height: Self.barArea + 18)
        .animation(.smooth, value: week.map(\.totals.steps))
    }
}

/// A full-width row that highlights on hover, like the items at the bottom of
/// Control Center modules and menu bar extras.
struct MenuRow: View {
    var title: String
    var shortcut: String? = nil
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
