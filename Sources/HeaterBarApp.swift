import AppKit
import SwiftUI

@main
struct HeaterBarApp: App {
    @StateObject private var store = HeaterStore()

    /// Menu bar symbols are drawn as monochrome templates; these keep their
    /// colour so heating (orange) and humid desk air (blue) show at a glance.
    private static let heatingIcon = coloredIcon("heater.vertical.fill", .systemOrange, "Heating")
    private static let humidIcons = [false, true].map {
        coloredIcon($0 ? "heater.vertical.fill" : "heater.vertical", .systemBlue, "Humid air")
    }

    private static func coloredIcon(_ name: String, _ color: NSColor, _ description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }

    var body: some Scene {
        MenuBarExtra {
            HeaterPanel(store: store)
        } label: {
            // Outlined when all are off, filled when one is on, orange when one
            // heats, otherwise blue while the desk air is humid.
            if store.heatersHeating > 0 {
                Image(nsImage: Self.heatingIcon)
            } else if store.isDeskHumid {
                Image(nsImage: Self.humidIcons[store.heatersOn > 0 ? 1 : 0])
            } else {
                Image(systemName: store.heatersOn > 0 ? "heater.vertical.fill" : "heater.vertical")
            }
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
                Spacer()
                Button {
                    let url = StatusLog.fileURL()
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                } label: {
                    Image(systemName: "tablecells")
                }
                .buttonStyle(.borderless)
                .help("Open today's log (CSV) in your spreadsheet app")
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
    /// The day the graph shows: 0 for today, 1 for yesterday, and so on.
    @State private var daysBack = 0
    /// Whether the front's energy line shows the total instead of today;
    /// a click switches, for every card.
    @AppStorage("energyShowsTotal") private var energyShowsTotal = false

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

    private var samples: [TemperatureSample] { store.history.samples[heater.id] ?? [] }

    private var back: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heater.name).font(.system(.body, weight: .semibold))
                Spacer()
                DayPicker(daysBack: $daysBack, samples: samples)
            }
            // The graph takes what the front leaves, so the total and the close
            // button land on the front's last line.
            TemperatureChart(samples: samples, daysBack: daysBack, chartHeight: 130)
            dayEnergyRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same corner as the front's graph button, so one spot flips both ways.
        .overlay(alignment: .bottomTrailing) {
            flipButton("xmark", help: "Back to the controls")
        }
    }

    /// The energy, cost and heating time of the day the graph shows, on the
    /// close button's line.
    private var dayEnergyRow: some View {
        let day = TemperatureChart.day(daysBack)
        let kWh = store.ledger.energy(for: heater.id, on: day.start) / 1000
        let minutes = store.history.heatingMinutes(for: heater.id, in: day)
        let text = String(format: "%@ %.2f kWh · %@", DayPicker.title(daysBack), kWh, HeaterPanel.cost(kWh))
            + (minutes.map { " · " + Self.heatingTime($0) } ?? "")
        return HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(.secondary)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .padding(.trailing, 30)
        .help("Energy, cost and time spent heating that day, estimated from the heating level at Philips' rated power and €\(String(format: "%.2f", HeaterStore.pricePerKWh))/kWh")
    }

    /// "1h20" or "25 min".
    private static func heatingTime(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%dh%02d", minutes / 60, minutes % 60) : "\(minutes) min"
    }

    /// Eco when away: what this heater does while nobody is at the Mac.
    private var ecoMenu: some View {
        // Outside the Mac's room only auto-off: presence says nothing there.
        let followsPresence = store.followsPresence(heater)
        let action = followsPresence ? store.awayActions[heater.id] ?? .none : .none
        let offStep = store.awayOffSteps[heater.id]
        let choices = HeaterStore.awayOffChoices(for: heater)
        let offLabel = choices.first { $0.step == offStep }?.label
        let isEnabled = action != .none || offStep != nil
        return Menu {
            if followsPresence {
                Section("When you leave the Mac") {
                    ForEach(AwayAction.allCases, id: \.self) { choice in
                        Button {
                            store.setAwayAction(choice, for: heater.id)
                        } label: {
                            if choice == action { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                        }
                    }
                }
            }
            if action != .switchOff {
                Section(followsPresence ? "Switch off if away for" : "Switch off after being on for") {
                    ForEach([(label: "Never", step: nil as Int?)] + choices.map { ($0.label, Optional($0.step)) },
                            id: \.label) { choice in
                        Button {
                            store.setAwayOff(step: choice.step, for: heater.id)
                        } label: {
                            if choice.step == offStep { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                        }
                    }
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
        .help(!followsPresence
              ? offLabel.map { "Auto-off: whenever it is switched on, its timer is set to \($0)" }
                  ?? "Auto-off: set its timer whenever it is switched on, so it is never forgotten on"
              : isEnabled
              ? "When you leave the Mac: "
                + [action == .none ? nil : action.label.lowercased(),
                   action == .switchOff ? nil : offLabel.map { "switch off after \($0) away" }]
                    .compactMap { $0 }.joined(separator: ", ")
                + "; put back when you are back"
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
                    HStack(spacing: 5) {
                        Text(heater.name).font(.system(.body, weight: .semibold))
                        signalIcon
                    }
                    HStack(spacing: 4) {
                        if heater.isOn == nil, heater.problem == nil {
                            ProgressView().controlSize(.mini)
                        }
                        Text(subtitle)
                    }
                    .font(.caption)
                    .foregroundStyle(heater.problem == nil && heater.faultCode == 0 ? Color.secondary : Color.red)
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
                // In the room this Mac is in, the desk thermometer is the room
                // temperature that matters; the heater's own sensor, next to the
                // heater, comes small underneath.
                let desk = store.desk(for: heater)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 6) {
                        Text((desk?.temperature ?? heater.roomTemperature).map { String(format: "%.1f°", $0) } ?? "–")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .help(Self.roomHelp(desk))
                        if let hint = Self.humidityHint(desk) {
                            Label(hint.text, systemImage: "humidity.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(hint.color)
                                .help(hint.help)
                        }
                    }
                    Text("Room" + (desk == nil ? "" : heater.roomTemperature.map { String(format: " · heater %.1f°", $0) } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(Self.roomHelp(desk))
                }
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
                        .help("The temperature Auto and Auto+ keep. High, Medium and Low heat continuously instead.")
                }
                .opacity(isOn ? 1 : 0.6)
            }

            HStack(spacing: 4) {
                // The CX5120 has two heat levels, no Medium. Auto or Auto+, as set in Air+.
                ForEach(HeaterMode.allCases.filter { mode in
                    (mode != .medium || !heater.model.hasPrefix("CX5120"))
                        && (!mode.isAutomatic || mode == (heater.autoLearns ? .autoPlus : .auto))
                }, id: \.self) { mode in
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
                // Right above the graph button.
                ecoMenu
            }

            HStack(alignment: .center, spacing: 6) {
                energyRow
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

    /// Wi-Fi bars from the heater's own signal reading, as in the Air+ app.
    @ViewBuilder private var signalIcon: some View {
        if heater.problem != nil {
            Image(systemName: "wifi.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("No answer on the local network")
        } else if let dBm = heater.signal {
            // Bars as Wi-Fi tools usually draw them: −55 dBm or better is full.
            let bars: Double = dBm >= -55 ? 1 : dBm >= -67 ? 0.66 : dBm >= -75 ? 0.33 : 0
            let quality = dBm >= -55 ? "excellent" : dBm >= -67 ? "good" : dBm >= -75 ? "fair" : "weak"
            Image(systemName: "wifi", variableValue: bars)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(bars == 0 ? Color.red : Color.secondary)
                .help("Wi-Fi signal \(dBm) dBm (\(quality))")
        }
    }

    private var subtitle: String {
        if let problem = heater.problem { return problem }
        if heater.faultCode != 0 { return "Fault code \(heater.faultCode)" }
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
            if let auto = heater.mode, auto.isAutomatic, let level = heater.runningMode, !level.isAutomatic {
                state = "Heating (\(auto.label) · \(level.label))"
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
        let text: String
        let help: String
        if energyShowsTotal {
            let kWh = store.energyTotalKWh(for: heater.id)
            let since = store.ledger.firstDay.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            text = String(format: "Total %.2f kWh · %@", kWh, HeaterPanel.cost(kWh))
            help = "Energy and cost since HeaterBar started recording\(since)"
        } else {
            let kWh = store.energyTodayKWh(for: heater.id)
            let minutes = store.history.heatingMinutesToday(for: heater.id)
            text = String(format: "Today %.2f kWh · %@ · %@", kWh, HeaterPanel.cost(kWh), Self.heatingTime(minutes))
            help = "Energy, cost and time spent heating today"
        }
        return Button {
            energyShowsTotal.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(heater.isOn == true && heater.isHeating ? Color.orange : Color.secondary)
                Text(text)
                    .monospacedDigit()
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("\(help), estimated from the heating level at Philips' rated power and €\(String(format: "%.2f", HeaterStore.pricePerKWh))/kWh. Click to switch between today and the total.")
    }

    private var timerMenu: some View {
        let minutes = heater.timerMinutesLeft ?? 0
        // Switching on clears a timer, so one only counts while on.
        let isActive = minutes > 0 && heater.isOn == true
        let choices = HeaterStore.timerChoices.filter { heater.hasTimerCountdown || $0.step > 1 }
        let label = heater.hasTimerCountdown || heater.timerIsCounted
            ? "Off in \(Self.duration(minutes))" : "Timer \(Self.duration(minutes))"
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
        .disabled(heater.timerMinutesLeft == nil || heater.isOn != true)
        .help("Timer: switches the heater off after the chosen time." + (isActive ? " \(label)." : "")
              + (heater.isOn == true ? "" : " Available while the heater is on: switching on clears it."))
    }

    /// Always shown, in colour outside 35–60 %: air too humid in winter means
    /// condensation, and mould, on cold spots such as the window; too dry, eyes
    /// and throat suffer.
    private static func humidityHint(_ desk: DeskReading?) -> (text: String, color: Color, help: String)? {
        guard let desk, let humidity = desk.humidity else { return nil }
        let percent = Int(humidity.rounded())
        if percent > 60 {
            // Magnus formula: below this surface temperature, water condenses.
            let gamma = log(humidity / 100) + 17.62 * desk.temperature / (243.12 + desk.temperature)
            let dewPoint = 243.12 * gamma / (17.62 - gamma)
            return ("\(percent)%", .blue, String(format: "Humid air (%d %%): water condenses on anything colder than %.1f° "
                + "(the dew point), such as the window on a cold night, and mould can follow. 40–50 %% is ideal in winter.\n"
                + "To bring it down: open the window wide (not tilted) for 5–10 minutes, 2–3 times a day, with the "
                + "heater off; keep the bathroom and kitchen doors closed; dry no laundry in the room; keep the "
                + "window's trickle vents open.", percent, dewPoint))
        }
        if percent < 35 {
            return ("\(percent)%", .orange, "Dry air (\(percent) %): below 35 % eyes and throat dry out, and heating dries "
                + "the air further. 40–50 % is ideal.\n"
                + "To raise it: air in short bursts rather than long ones, keep the room a little cooler, or use a "
                + "humidifier if it stays low.")
        }
        return ("\(percent)%", .secondary, "Humidity \(percent) %: comfortable (35–60 %, ideally 40–50 % in winter).")
    }

    private static func roomHelp(_ desk: DeskReading?) -> String {
        guard let desk else { return "Room temperature measured by the heater's own sensor, averaged over the last minute" }
        var text = "Room temperature from the desk thermometer (Bluetooth)"
        if let humidity = desk.humidity { text += String(format: ", humidity %.0f %%", humidity) }
        if let battery = desk.battery { text += ", battery \(battery) %" }
        return text + ". Below, the heater's own sensor, averaged over the last minute."
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
        // The level Auto or Auto+ has chosen for itself, outlined beside the filled mode.
        let isAutoLevel = heater.mode?.isAutomatic == true && isOn && heater.runningMode == mode && !mode.isAutomatic
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
        .help(isAutoLevel ? "The level \(heater.mode?.label ?? "Auto") is using now. \(mode.explanation)" : mode.explanation)
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
