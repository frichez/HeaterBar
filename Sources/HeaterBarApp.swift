import AppKit
import SwiftUI

@main
struct HeaterBarApp: App {
    @StateObject private var store = HeaterStore()

    var body: some Scene {
        MenuBarExtra {
            HeaterPanel(store: store)
        } label: {
            Image(systemName: store.heatersHeating > 0 ? "heater.vertical.fill" : "heater.vertical")
        }
        .menuBarExtraStyle(.window)
    }
}

struct HeaterPanel: View {
    @ObservedObject var store: HeaterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Air+").font(.headline)
                Spacer()
                if let outdoor = store.outdoor {
                    Label(String(format: "%.1f° outside", outdoor.temperature), systemImage: outdoor.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Outdoor temperature in \(OutdoorWeather.place), from Open-Meteo")
                }
                if store.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.scan()
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isScanning)
                .help("Search the network and refresh")
            }

            if store.heaters.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary)
                    Text(store.isScanning ? "Looking for heaters…" : "No heaters found on this network")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(store.heaters) { heater in
                    HeaterCard(heater: heater, store: store)
                }
            }

            Divider()
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("Today \(Self.cost(store.energyTodayKWh))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .help(String(format: "%.2f kWh at €%.2f/kWh", store.energyTodayKWh, HeaterStore.pricePerKWh))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        // Solid instead of the menu bar's default translucent material.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear { store.refresh() }
    }

    static func cost(_ kWh: Double) -> String {
        String(format: "€%.2f", kWh * HeaterStore.pricePerKWh)
    }

    private var summary: String {
        let heating = store.heatersHeating
        let idle = store.heatersOn - heating
        guard store.heatersOn > 0 else { return "All off" }
        return [heating > 0 ? "\(heating) heating" : nil, idle > 0 ? "\(idle) idle" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

struct HeaterCard: View {
    let heater: HeaterState
    @ObservedObject var store: HeaterStore

    /// The card turns over to show the temperature graph on its back.
    @State private var isFlipped = false

    private func flip() {
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) { isFlipped.toggle() }
    }

    private enum Activity { case off, idle, fan, heating }

    private var isOn: Bool { heater.isOn == true }

    private var activity: Activity {
        guard isOn else { return .off }
        if heater.isHeating { return .heating }
        return heater.mode == .ventilation ? .fan : .idle
    }

    private var accent: Color { activity == .fan ? .blue : .orange }

    var body: some View {
        front
            .padding(12)
            .opacity(isFlipped ? 0 : 1)
            .allowsHitTesting(!isFlipped)
            .overlay {
                // The back takes the front's size, and is turned so it reads
                // the right way round once the card has flipped.
                back
                    .padding(12)
                    .opacity(isFlipped ? 1 : 0)
                    .allowsHitTesting(isFlipped)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: activity == .heating ? 1.5 : 1)
            )
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .animation(.easeOut(duration: 0.2), value: heater.isOn)
            .animation(.easeOut(duration: 0.2), value: heater.isHeating)
            .animation(.snappy, value: heater.target)
    }

    private var back: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heater.name).font(.system(.body, weight: .semibold))
            TemperatureChart(samples: store.history.samples[heater.id] ?? [], chartHeight: 110)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same corner as the front's graph button, so one spot flips both ways.
        .overlay(alignment: .bottomTrailing) {
            flipButton("xmark", help: "Back to the controls")
        }
    }

    /// Eco when away: what this heater does while nobody is at the Mac.
    private var ecoMenu: some View {
        let action = store.awayActions[heater.id] ?? .none
        let isEnabled = action != .none
        return Menu {
            ForEach(AwayAction.allCases, id: \.self) { choice in
                Button {
                    store.setAwayAction(choice, for: heater.id)
                } label: {
                    if choice == action { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
        } label: {
            Image(systemName: isEnabled ? "leaf.fill" : "leaf")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isEnabled ? Color.green : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isEnabled ? Color.green.opacity(0.15) : Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        // Drawn exactly as labelled, like the graph button beside it; the
        // borderless style resizes the label to its own control size.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isEnabled
              ? "When you leave the Mac: \(action.label.lowercased()), restored when you are back"
              : "Eco when away: save energy while you are not at the Mac")
    }

    private func flipButton(_ symbol: String, help: String) -> some View {
        Button(action: flip) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var front: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    switch activity {
                    case .heating:
                        Circle().fill(Color.orange)
                    case .idle:
                        Circle().strokeBorder(Color.orange, lineWidth: 1.5)
                    case .fan:
                        Circle().fill(Color.blue.opacity(0.2))
                    case .off:
                        Circle().fill(Color.secondary.opacity(0.18))
                    }
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(activity == .heating ? Color.white : activity == .off ? Color.secondary : accent)
                        .symbolEffect(.pulse, isActive: activity == .heating)
                }
                .frame(width: 32, height: 32)
                .help(heater.model)

                VStack(alignment: .leading, spacing: 1) {
                    Text(heater.name).font(.system(.body, weight: .semibold))
                    HStack(spacing: 4) {
                        if heater.isOn == nil, heater.problem == nil {
                            ProgressView().controlSize(.mini)
                        }
                        Text(subtitle)
                    }
                    .font(.caption)
                    .foregroundStyle(heater.problem == nil ? Color.secondary : Color.red)
                }
                Spacer()
                Toggle("Power", isOn: Binding(get: { isOn }, set: { store.setPower($0, for: heater.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.orange)
                    .disabled(heater.isOn == nil)
                    .help("Switch the heater on or off")
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(heater.roomTemperature.map { String(format: "%.1f°", $0) } ?? "–")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Room").font(.caption2).foregroundStyle(.secondary)
                }
                .help("Room temperature measured by the heater's own sensor, averaged over the last minute")
                Spacer()
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        stepButton("minus", step: -1, limit: HeaterStore.targetRange.lowerBound)
                        Text(heater.target.map { "\($0)°" } ?? "–")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .frame(minWidth: 36)
                        stepButton("plus", step: 1, limit: HeaterStore.targetRange.upperBound)
                    }
                    Text("Target").font(.caption2).foregroundStyle(.secondary)
                        .help("The temperature Auto+ keeps. High, Medium and Low heat continuously instead.")
                }
                .opacity(isOn ? 1 : 0.6)
            }

            HStack(spacing: 4) {
                ForEach(HeaterMode.allCases, id: \.self) { mode in
                    modeButton(mode)
                }
            }
            .opacity(isOn ? 1 : 0.6)

            HStack {
                optionButton("Oscillation", symbol: "arrow.left.and.right", isActive: heater.isOscillating,
                             explanation: "Sweeps the airflow from side to side to spread the warmth.") {
                    store.setOscillation($0, for: heater.id)
                }
                .opacity(isOn ? 1 : 0.6)
                timerMenu
                    .opacity(isOn ? 1 : 0.6)
                Spacer()
            }

            HStack(alignment: .center, spacing: 6) {
                energyRow
                if store.followsPresence(heater) {
                    ecoMenu
                }
                flipButton("chart.xyaxis.line", help: "Show the temperature graph")
            }
        }
    }

    private var icon: String {
        switch activity {
        case .heating: return "heater.vertical.fill"
        case .fan: return "fan"
        case .idle, .off: return "heater.vertical"
        }
    }

    private var cardFill: Color {
        switch activity {
        case .heating: return Color.orange.opacity(0.18)
        case .fan: return Color.blue.opacity(0.08)
        case .idle, .off: return Color.primary.opacity(0.05)
        }
    }

    private var cardStroke: Color {
        switch activity {
        case .heating: return Color.orange.opacity(0.6)
        case .idle: return Color.orange.opacity(0.35)
        case .fan: return Color.blue.opacity(0.3)
        case .off: return Color.primary.opacity(0.08)
        }
    }

    private var subtitle: String {
        if let problem = heater.problem { return problem }
        guard heater.isOn != nil else { return "Connecting…" }
        if heater.isStale, let seen = heater.lastSeen {
            return "Last seen \(seen.formatted(date: .omitted, time: .shortened))"
        }
        if store.isEcoActive(heater.id) {
            return isOn ? "Eco (away) · target lowered" : "Eco (away) · switched off"
        }
        let mode = heater.mode.map { " (\($0.label))" } ?? ""
        let state: String
        switch activity {
        case .heating:
            if heater.mode == .auto, let level = heater.runningMode, level != .auto {
                state = "Heating (Auto+ · \(level.label))"
            } else {
                state = "Heating" + mode
            }
        case .fan: state = "Fan only"
        case .off: state = "Off"
        case .idle:
            let reached = heater.roomTemperature.flatMap { room in heater.target.map { room >= Double($0) } } ?? false
            state = reached ? "Idle, target reached" : "Idle" + mode
        }
        return state
    }

    private var energyRow: some View {
        let kWh = store.energyTodayKWh(for: heater.id)
        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(heater.isOn == true && heater.isHeating ? Color.orange : Color.secondary)
            Text(String(format: "Today %.2f kWh · %@", kWh, HeaterPanel.cost(kWh)))
                .monospacedDigit()
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("Energy and cost today, estimated from the heating level at Philips' rated power (Low 800 W, Medium 1,200 W, High 2,000 W) and €\(String(format: "%.2f", HeaterStore.pricePerKWh))/kWh")
    }

    private var timerMenu: some View {
        let minutes = heater.timerMinutesLeft ?? 0
        let isActive = minutes > 0
        let choices = HeaterStore.timerChoices.filter { heater.hasTimerCountdown || $0.step > 1 }
        let label = heater.hasTimerCountdown ? "Off in \(Self.duration(minutes))" : "Timer \(Self.duration(minutes))"
        return Menu {
            ForEach(choices, id: \.step) { choice in
                Button("Off in \(choice.label)") { store.setTimer(step: choice.step, for: heater.id) }
            }
            if isActive {
                Divider()
                Button("Cancel timer") { store.setTimer(step: 0, for: heater.id) }
            }
        } label: {
            Label(isActive ? label : "Timer", systemImage: "timer")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isActive ? Color.orange : Color.secondary)
                .background(Capsule().fill(isActive ? Color.orange.opacity(0.18) : Color.primary.opacity(0.05)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(heater.timerMinutesLeft == nil)
        .help("Timer: switches the heater off after the chosen time." + (isActive ? " \(label)." : ""))
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// A pill that switches an on/off option; disabled until its state is known.
    private func optionButton(_ title: String, symbol: String, isActive state: Bool?, explanation: String,
                              set: @escaping (Bool) -> Void) -> some View {
        let isActive = state ?? false
        return Button {
            set(!isActive)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isActive ? Color.orange : Color.secondary)
                .background(Capsule().fill(isActive ? Color.orange.opacity(0.18) : Color.primary.opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state == nil)
        .help("\(title) (\(isActive ? "on" : "off")): \(explanation)")
    }

    private func modeButton(_ mode: HeaterMode) -> some View {
        let isSelected = heater.mode == mode
        // The level Auto+ has chosen for itself, outlined beside the filled Auto+.
        let isAutoLevel = heater.mode == .auto && isOn && heater.runningMode == mode && mode != .auto
        let tint: Color = mode == .ventilation ? .blue : .orange
        return Button {
            store.setMode(mode, for: heater.id)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.symbol).font(.system(size: 12, weight: .semibold))
                Text(mode.label).font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(isSelected || isAutoLevel ? tint : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 1.5)
                    .opacity(isAutoLevel ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(heater.mode == nil)
        .help(isAutoLevel ? "The level Auto+ is using now. \(mode.explanation)" : mode.explanation)
        .animation(.easeOut(duration: 0.2), value: isAutoLevel)
    }

    private func stepButton(_ symbol: String, step: Int, limit: Int) -> some View {
        Button {
            store.adjustTarget(by: step, for: heater.id)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(heater.target == nil || heater.target == limit)
        .help(step < 0 ? "Lower the target by 1°" : "Raise the target by 1°")
    }
}
