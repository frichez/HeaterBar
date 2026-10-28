import AppKit
import os

private let storeLog = Logger(subsystem: "local.heaterbar", category: "store")

/// D0310C, the mode chosen in Air+. Each heating mode also sets D0310A to 3
/// (heater); ventilation sets it to 1 (fan only).
enum HeaterMode: Int, CaseIterable {
    case auto = 0
    case high = 65
    case medium = 67
    case low = 66
    case ventilation = -127

    var symbol: String {
        switch self {
        case .auto: return "a.circle"
        case .high: return "thermometer.high"
        case .medium: return "thermometer.medium"
        case .low: return "thermometer.low"
        case .ventilation: return "fan"
        }
    }

    /// What each mode does, after Philips' own explanations in Air+.
    var explanation: String {
        switch self {
        case .auto:
            return "Auto+ (Philips Eco AI): keeps the target temperature by choosing the heating level itself and "
                + "switching on and off as needed. It learns your usage patterns and follows the weather to save energy."
        case .high:
            return "High: heats continuously at 2,000 W. Warms the room fastest."
        case .medium:
            return "Medium: heats continuously at 1,200 W. Balanced warmth for less energy than High."
        case .low:
            return "Low: heats continuously at 800 W. Gentle warmth with the lowest consumption."
        case .ventilation:
            return "Fan: no heating, only a gentle airflow for warm days."
        }
    }

    var label: String {
        switch self {
        case .auto: return "Auto+"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .ventilation: return "Fan"
        }
    }
}

/// What a heater does while nobody is at the Mac.
enum AwayAction: String, CaseIterable {
    case none, lower2, lower4, switchOff

    var label: String {
        switch self {
        case .none: return "Do nothing"
        case .lower2: return "Lower the target by 2°"
        case .lower4: return "Lower the target by 4°"
        case .switchOff: return "Switch off"
        }
    }

    var degrees: Int? {
        switch self {
        case .lower2: return 2
        case .lower4: return 4
        case .none, .switchOff: return nil
        }
    }
}

struct HeaterState: Identifiable, Codable {
    let id: String
    var host: String
    var name: String
    var model: String
    var isOn: Bool?
    var target: Int?
    var roomTemperature: Double?
    var mode: HeaterMode?
    /// Actually producing heat, as opposed to on but idle at its target.
    var isHeating = false
    /// D0313F while heating: the level actually used, which Auto+ chooses itself.
    var runningMode: HeaterMode?
    /// D0320F: the sweep angle, 0 when oscillation is off.
    var isOscillating: Bool?
    /// D03211: minutes until the timer switches the heater off, 0 when unset.
    var timerMinutesLeft: Int?
    /// Whether the model counts the timer down (CX3120). Others (CX5120) only
    /// report the chosen duration and start at one hour.
    var hasTimerCountdown = false
    /// Estimated present draw, from the output level.
    var watts = 0.0
    /// When the shown state was reported, and whether it came from the last
    /// session rather than from the heater since launch.
    var lastSeen: Date?
    var isStale = false
    var problem: String?

    /// Only where to find the heater is remembered; its state is always live.
    private enum CodingKeys: String, CodingKey { case id, host, name, model }
}

/// The heaters and what the panel shows of them. Status keys follow the
/// Philips "D03…" scheme: D03102 power, D0310E target °C, D03224 room °C × 10,
/// D0310C mode, D0310A function (3 heater, 1 fan) and D0310D output level
/// (1–3 heating, 0 idle, 4 fan).
@MainActor
final class HeaterStore: ObservableObject {
    /// Up to 37°, a target the heaters report and Air+ shows.
    static let targetRange = 5...37

    /// Electricity price, euros per kWh.
    static let pricePerKWh = 0.39

    /// Watts drawn at each output level (D0310D): 1–3 heating, 4 fan only.
    /// CX3120: Philips' rated Low 800, Medium 1,200, High 2,000 W (the Air+ app;
    /// a plug meter read 900, 1,100 and 1,900), fan 2 W as measured.
    /// CX5120: two levels, Low 1,200 and High 2,000 W, fan 8 W (Philips' spec
    /// sheet). Its level stays 1 whatever it does, so the running mode
    /// (D0313F) tells which one heats.
    /// Idle and standby read 0 W, below the meter's range. The oscillation
    /// motor adds about 3 W, measured.
    private static let wattsByLevel: [Int: Double] = [1: 800, 2: 1200, 3: 2000, 4: 2]
    private static let oscillationWatts = 3.0

    static func watts(for heater: HeaterState, level: Int?) -> Double {
        guard heater.isOn == true else { return 0 }
        let oscillation = heater.isOscillating == true ? oscillationWatts : 0
        if heater.model.hasPrefix("CX5120") {
            let heating: Double? = switch heater.runningMode {
            case .high: 2000
            case .low, .medium: 1200
            default: nil
            }
            return (heater.isHeating ? heating ?? 8 : 8) + oscillation
        }
        guard let level, let watts = wattsByLevel[level] else { return 0 }
        // After reaching its target the fan runs down through the heating
        // levels for a while with the element already off.
        let fanOnly = level != 4 && !heater.isHeating
        return (fanOnly ? wattsByLevel[4]! : watts) + oscillation
    }

    /// D0313F is the mode actually running: 65–67 while heating, −16 once
    /// Auto+ is idle, 0 for fan only.
    private static let heatingRunModes: Set<Int> = [65, 66, 67]

    @Published private(set) var heaters: [HeaterState] = []
    @Published private(set) var isScanning = false
    @Published private(set) var history = HeaterHistory.load()
    @Published private(set) var ledger = EnergyLedger()
    @Published private(set) var outdoor: OutdoorWeather?
    @Published private(set) var awayActions: [String: AwayAction] = [:]
    @Published private(set) var isAway = false
    /// What to put back when someone returns, per heater: the target and its
    /// setback, or that it was switched off. Saved, so a restart while away
    /// still restores.
    @Published private(set) var awayRestore: [String: [String: Int]] = [:]
    private let presence = PresenceMonitor()
    private static let awayActionsKey = "awayActions"
    private static let awayRestoreKey = "awayRestore"

    private var links: [String: HeaterLink] = [:]
    private var pendingChanges: [String: PendingChange] = [:]
    /// The power each heater was last drawing, and since when: the energy
    /// between two statuses is that power over the time between them.
    private var lastPower: [String: (watts: Double, since: Date)] = [:]
    /// The level in each heater's saved status, for billing it after launch.
    private var cachedLevel: [String: Int] = [:]
    /// Power as the heater last reported it, before any optimistic display.
    private var reportedPower: [String: Bool] = [:]
    /// Counts power commands per heater, so a check knows when it is stale.
    private var powerRequests: [String: Int] = [:]
    private var statusLog = StatusLog()
    private var roomReadings: [String: [(time: Date, value: Double)]] = [:]

    /// What was just asked of a heater: a status push that crosses the command
    /// would otherwise flip the control back for a moment.
    private struct PendingChange {
        var isOn: Bool?
        var target: Int?
        var mode: HeaterMode?
        var isOscillating: Bool?
        var since = Date()
    }

    private static let savedKey = "heaters"
    /// Each heater's last raw status and when it came, so a restart shows the
    /// last known state at once; slow models can take minutes to report.
    private static let lastStatusKey = "lastStatus"
    private var lastStatusSaved: [String: Date] = [:]

    init() {
        ledger = EnergyLedger.load(seed: history)
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode([HeaterState].self, from: data) {
            heaters = saved
        }
        let cached = UserDefaults.standard.dictionary(forKey: Self.lastStatusKey) ?? [:]
        for heater in heaters {
            guard let entry = cached[heater.id] as? [String: Any],
                  let status = entry["status"] as? [String: Any],
                  let seen = entry["seen"] as? Date else { continue }
            apply(status, to: heater.id, seenAt: seen)
        }
        heaters.forEach(connect)
        scan()

        let savedActions = UserDefaults.standard.dictionary(forKey: Self.awayActionsKey) as? [String: String] ?? [:]
        awayActions = savedActions.compactMapValues(AwayAction.init)
        awayRestore = UserDefaults.standard.dictionary(forKey: Self.awayRestoreKey) as? [String: [String: Int]] ?? [:]
        presence.onChange = { [weak self] away in self?.presenceChanged(away) }
        // Heaters still set back from before a restart must come back on return.
        isAway = !awayRestore.isEmpty
        presence.start(away: isAway)
        // Open-Meteo updates every 15 minutes; a failed fetch retries sooner.
        Task { @MainActor in
            while true {
                let weather = await OutdoorWeather.fetch()
                if let weather { outdoor = weather }
                try? await Task.sleep(for: .seconds(weather == nil ? 60 : 900))
            }
        }
        // Steady heating between statuses is billed each minute, for heaters
        // whose state is live; an unreachable one is billed at 0 W.
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(60))
                let now = Date()
                for heater in heaters where lastPower[heater.id] != nil && !heater.isStale {
                    accrue(heater.id, newWatts: heater.watts, at: now)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.links.values.forEach { $0.stop() } }
        }
    }

    var heatersOn: Int { heaters.filter { $0.isOn == true }.count }
    var heatersHeating: Int { heaters.filter { $0.isOn == true && $0.isHeating }.count }

    func energyTodayKWh(for id: String) -> Double { history.energyToday(for: id) / 1000 }
    var energyTodayKWh: Double { heaters.reduce(0) { $0 + energyTodayKWh(for: $1.id) } }
    func energyTotalKWh(for id: String? = nil) -> Double { ledger.energy(for: id) / 1000 }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task { @MainActor in
            let found = await Task.detached { HeaterDiscovery.scan() }.value
            merge(found)
            isScanning = false
        }
    }

    func refresh() {
        links.values.forEach { $0.refresh() }
    }

    /// A heater has been seen to answer "success" to power on and stay off, so
    /// five seconds later the reported power is checked and the command sent
    /// once more if it did not take, unless a newer power command has been
    /// sent since: the check must never undo a later click.
    func setPower(_ isOn: Bool, for id: String, reason: String = "you", isRetry: Bool = false) {
        let request = (powerRequests[id] ?? 0) + 1
        powerRequests[id] = request
        send(["D03102": isOn ? 1 : 0], to: id, reason: isRetry ? reason + ", power check" : reason, isOn: isOn) { [weak self] ok in
            guard ok, !isRetry else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated {
                    guard let self, self.powerRequests[id] == request,
                          let reported = self.reportedPower[id], reported != isOn else { return }
                    storeLog.error("\(id, privacy: .public) still reports power \(reported) after a successful command; sending it again")
                    self.setPower(isOn, for: id, reason: reason, isRetry: true)
                }
            }
        }
    }

    func adjustTarget(by step: Int, for id: String) {
        guard let current = heaters.first(where: { $0.id == id })?.target else { return }
        let next = min(max(current + step, Self.targetRange.lowerBound), Self.targetRange.upperBound)
        guard next != current else { return }
        send(["D0310E": next], to: id, target: next)
    }

    func setMode(_ mode: HeaterMode, for id: String) {
        guard let heater = heaters.first(where: { $0.id == id }), heater.mode != mode else { return }
        let leavingFan = heater.mode == .ventilation && mode != .ventilation && heater.isOn == true
        send(["D0310A": mode == .ventilation ? 1 : 3, "D0310C": mode.rawValue], to: id, mode: mode) { [weak self] ok in
            if ok, leavingFan { self?.rearmHeating(id) }
        }
    }

    /// Coming back from fan-only, a heater can keep its element off and blow
    /// cold air while reporting that it heats; its status cannot tell the two
    /// apart. Switching it off and on again (in the new mode) re-arms it.
    private func rearmHeating(_ id: String) {
        guard let link = links[id] else { return }
        holdPower(on: id)
        link.send(["D03102": 0], reason: "re-arm after fan (off)") { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    self?.holdPower(on: id)
                    link.send(["D03102": 1], reason: "re-arm after fan (on)") { _ in }
                }
            }
        }
    }

    /// Keeps the switch showing on while the heater is briefly cycled.
    private func holdPower(on id: String) {
        var change = pendingChanges[id] ?? PendingChange()
        change.isOn = true
        change.since = Date()
        pendingChanges[id] = change
    }

    func setAwayAction(_ action: AwayAction, for id: String) {
        awayActions[id] = action == .none ? nil : action
        UserDefaults.standard.set(awayActions.mapValues(\.rawValue), forKey: Self.awayActionsKey)
    }

    func isEcoActive(_ id: String) -> Bool { awayRestore[id] != nil }

    /// Heaters in the room where this Mac is: presence at the Mac only says
    /// something about that room, so only they get Eco when away.
    private static let presenceRooms: Set<String> = ["Office"]

    func followsPresence(_ heater: HeaterState) -> Bool { Self.presenceRooms.contains(heater.name) }

    /// Eco when away: on leaving, each heater that is on and has an action gets
    /// its target lowered or is switched off; on return it is put back, unless
    /// someone changed it meanwhile (in Air+, say), which then wins.
    private func presenceChanged(_ away: Bool) {
        isAway = away
        if away {
            for heater in heaters where heater.isOn == true && awayRestore[heater.id] == nil && followsPresence(heater) {
                switch awayActions[heater.id] ?? .none {
                case .none:
                    continue
                case .switchOff:
                    awayRestore[heater.id] = ["power": 1]
                    setPower(false, for: heater.id, reason: "eco: you left the Mac")
                case let action:
                    guard let target = heater.target, let degrees = action.degrees else { continue }
                    let setback = max(Self.targetRange.lowerBound, target - degrees)
                    awayRestore[heater.id] = ["target": target, "setback": setback]
                    send(["D0310E": setback], to: heater.id, reason: "eco: you left the Mac", target: setback)
                }
            }
        } else {
            for (id, restore) in awayRestore {
                guard let heater = heaters.first(where: { $0.id == id }) else { continue }
                if let target = restore["target"], heater.target == restore["setback"] {
                    send(["D0310E": target], to: id, reason: "eco: you are back", target: target)
                } else if restore["power"] == 1, heater.isOn == false {
                    setPower(true, for: id, reason: "eco: you are back")
                }
            }
            awayRestore = [:]
        }
        UserDefaults.standard.set(awayRestore, forKey: Self.awayRestoreKey)
    }

    /// Air+ only switches the sweep on or off; 45° is what it uses for on.
    func setOscillation(_ isOscillating: Bool, for id: String) {
        // The CX5120 ignores 45 and the 17920 it reports while sweeping; the
        // Home Assistant Philips integration (kongo09) sends it 17222.
        let sweep = heaters.first { $0.id == id }?.model.hasPrefix("CX5120") == true ? 17222 : 45
        send(["D0320F": isOscillating ? sweep : 0], to: id, isOscillating: isOscillating)
    }

    /// D03110 steps: 1 is 30 minutes, then n is n − 1 hours (13 is 12 hours).
    static let timerChoices: [(label: String, step: Int)] = [
        ("30 min", 1), ("1 hour", 2), ("2 hours", 3), ("3 hours", 4),
        ("4 hours", 5), ("6 hours", 7), ("8 hours", 9), ("12 hours", 13),
    ]

    func setTimer(step: Int, for id: String) {
        guard let index = heaters.firstIndex(where: { $0.id == id }) else { return }
        heaters[index].timerMinutesLeft = Self.minutes(forTimerStep: step)
        send(["D03110": step], to: id)
    }

    private static func minutes(forTimerStep step: Int) -> Int {
        step <= 0 ? 0 : step == 1 ? 30 : (step - 1) * 60
    }

    private func send(_ values: [String: Any], to id: String, reason: String = "you", isOn: Bool? = nil, target: Int? = nil,
                      mode: HeaterMode? = nil, isOscillating: Bool? = nil,
                      completion: ((Bool) -> Void)? = nil) {
        guard let index = heaters.firstIndex(where: { $0.id == id }), let link = links[id] else { return }
        let before = heaters[index]
        if let isOn { heaters[index].isOn = isOn }
        if let target { heaters[index].target = target }
        if let mode { heaters[index].mode = mode }
        if let isOscillating { heaters[index].isOscillating = isOscillating }
        heaters[index].problem = nil
        var change = pendingChanges[id] ?? PendingChange()
        change.isOn = isOn ?? change.isOn
        change.target = target ?? change.target
        change.mode = mode ?? change.mode
        change.isOscillating = isOscillating ?? change.isOscillating
        change.since = Date()
        pendingChanges[id] = change

        link.send(values, reason: reason) { [weak self] ok in
            MainActor.assumeIsolated {
                completion?(ok)
                guard let self, !ok, let index = self.heaters.firstIndex(where: { $0.id == id }) else { return }
                self.pendingChanges[id] = nil
                if isOn != nil { self.heaters[index].isOn = before.isOn }
                if target != nil { self.heaters[index].target = before.target }
                if mode != nil { self.heaters[index].mode = before.mode }
                if isOscillating != nil { self.heaters[index].isOscillating = before.isOscillating }
                self.heaters[index].problem = "Didn't respond, try again"
            }
        }
    }

    private func connect(_ heater: HeaterState) {
        let link = HeaterLink(host: heater.host, deviceID: heater.id)
        let id = heater.id
        link.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.apply(status, to: id) }
        }
        link.onCommand = { [weak self] description, reason, result in
            MainActor.assumeIsolated {
                guard let self, let name = self.heaters.first(where: { $0.id == id })?.name else { return }
                self.statusLog.recordCommand(description, reason: reason, result: result, heater: name)
            }
        }
        link.onReachable = { [weak self] reachable in
            MainActor.assumeIsolated { self?.reachabilityChanged(reachable, for: id) }
        }
        links[id] = link
        link.seed(target: heater.target, timerMinutesLeft: heater.timerMinutesLeft)
        link.start()
    }

    /// Unplugged at the wall or off Wi-Fi: billing stops (at most the last
    /// minute is billed at the old power, the time it takes to notice). Back,
    /// its state is unknown until it reports, so it is billed nothing until then.
    private func reachabilityChanged(_ reachable: Bool, for id: String) {
        guard let index = heaters.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        if reachable {
            guard heaters[index].problem == Self.unreachableProblem else {
                // First answer after launch. A heater that reports only changes
                // may say nothing for hours, so a recent saved state is taken
                // as current and billed; a restart rarely misses a change.
                if heaters[index].isStale, let seen = heaters[index].lastSeen, now.timeIntervalSince(seen) < 600 {
                    heaters[index].isStale = false
                    heaters[index].watts = Self.watts(for: heaters[index], level: cachedLevel[id])
                    lastPower[id] = (heaters[index].watts, now)
                }
                return
            }
            heaters[index].isStale = true
            heaters[index].problem = nil
        } else {
            accrue(id, newWatts: 0, at: now)
            heaters[index].watts = 0
            // Shown off with the switch disabled, and not counted as on.
            heaters[index].isOn = nil
            heaters[index].isHeating = false
            heaters[index].problem = Self.unreachableProblem
        }
        statusLog.recordEvent(reachable ? "reachable again" : "unreachable: no answer to ping",
                              heater: heaters[index].name, at: now)
    }

    private static let unreachableProblem = "Not connected"

    /// Applies a status: live from the heater, or cached (`seenAt`) at launch,
    /// which shows it as stale and records no history or energy.
    private func apply(_ status: [String: Any], to id: String, seenAt cachedTime: Date? = nil) {
        guard let index = heaters.firstIndex(where: { $0.id == id }) else { return }
        heaters[index].lastSeen = cachedTime ?? Date()
        heaters[index].isStale = cachedTime != nil
        let pending = pendingChanges[id].flatMap { Date().timeIntervalSince($0.since) < 8 ? $0 : nil }
        if pending == nil { pendingChanges[id] = nil }

        if let power = status["D03102"] as? Int {
            let isOn = power != 0
            if cachedTime == nil { reportedPower[id] = isOn }
            if pending?.isOn == nil || pending?.isOn == isOn { heaters[index].isOn = isOn }
        }
        if let target = status["D0310E"] as? Int {
            if pending?.target == nil || pending?.target == target { heaters[index].target = target }
        }
        if let angle = status["D0320F"] as? Int {
            let isOscillating = angle != 0
            if pending?.isOscillating == nil || pending?.isOscillating == isOscillating {
                heaters[index].isOscillating = isOscillating
            }
        }
        heaters[index].hasTimerCountdown = status["D03211"] != nil
        if let minutes = status["D03211"] as? Int {
            heaters[index].timerMinutesLeft = minutes
        } else if let step = status["D03110"] as? Int {
            // Models without a countdown (CX5120) only report the chosen step.
            heaters[index].timerMinutesLeft = Self.minutes(forTimerStep: step)
        }
        if let room = status["D03224"] as? Int {
            let reading = Double(room) / 10
            heaters[index].roomTemperature = cachedTime == nil
                ? smoothedRoom(reading, for: id, shown: heaters[index].roomTemperature)
                : reading
        }
        if let raw = status["D0310C"] as? Int {
            let mode = HeaterMode(rawValue: raw)
            if pending?.mode == nil || pending?.mode == mode { heaters[index].mode = mode }
        }
        if let function = status["D0310A"] as? Int, let level = status["D0310D"] as? Int {
            let running = status["D0313F"] as? Int
            heaters[index].isHeating = function == 3 && (1...3).contains(level)
                && running.map(Self.heatingRunModes.contains) ?? true
            heaters[index].runningMode = heaters[index].isHeating ? running.flatMap(HeaterMode.init) : nil
        }
        if let name = status["D01S03"] as? String, !name.isEmpty { heaters[index].name = name }
        heaters[index].problem = nil

        guard cachedTime == nil else {
            cachedLevel[id] = status["D0310D"] as? Int
            return
        }
        let now = Date()
        saveLastStatus(status, for: id, at: now)
        let watts = Self.watts(for: heaters[index], level: status["D0310D"] as? Int)
        heaters[index].watts = watts
        statusLog.record(status, heater: heaters[index].name, room: heaters[index].roomTemperature, watts: watts,
                         outdoor: outdoor?.temperature, away: isAway, at: now)
        accrue(id, newWatts: watts, at: now)
    }

    /// Bills the power drawn since the last call and records the minute in the
    /// history. Called on each status and once a minute: some models (CX5120)
    /// report only on changes, so an hour of steady heating sends nothing.
    private func accrue(_ id: String, newWatts watts: Double, at now: Date) {
        guard let heater = heaters.first(where: { $0.id == id }) else { return }
        var energyWh = 0.0
        if let last = lastPower[id] {
            // A long gap (sleep, network loss) is not billed at the old power.
            energyWh = last.watts * min(now.timeIntervalSince(last.since), 180) / 3600
        }
        lastPower[id] = (watts, now)
        ledger.add(energyWh, for: id, at: now)
        if let room = heater.roomTemperature,
           history.record(room: room, target: heater.target, isHeating: heater.isOn == true && heater.isHeating,
                          energyWh: energyWh, outdoor: outdoor?.temperature, for: id, at: now) {
            history.save()
            ledger.save()
        }
    }

    /// The sensors flicker by ±0.1° every second or two (the Office pushes each
    /// flicker), so the shown value is the last minute's average, and it only
    /// moves once that average has moved by 0.1° or more.
    private func smoothedRoom(_ reading: Double, for id: String, shown: Double?, now: Date = Date()) -> Double {
        var readings = (roomReadings[id] ?? []).filter { now.timeIntervalSince($0.time) < 60 }
        readings.append((now, reading))
        roomReadings[id] = readings
        let average = readings.map(\.value).reduce(0, +) / Double(readings.count)
        guard let shown, !shown.isNaN else { return (average * 10).rounded() / 10 }
        return abs(average - shown) >= 0.1 ? (average * 10).rounded() / 10 : shown
    }

    /// At most every 30 seconds per heater: the Office reports every few.
    private func saveLastStatus(_ status: [String: Any], for id: String, at now: Date) {
        if let saved = lastStatusSaved[id], now.timeIntervalSince(saved) < 30 { return }
        lastStatusSaved[id] = now
        var cached = UserDefaults.standard.dictionary(forKey: Self.lastStatusKey) ?? [:]
        // Only property-list values can be stored; the status is flat JSON.
        cached[id] = ["status": status.filter { $0.value is String || $0.value is NSNumber }, "seen": now]
        UserDefaults.standard.set(cached, forKey: Self.lastStatusKey)
    }

    private func merge(_ found: [HeaterDiscovery.Device]) {
        for device in found {
            if let index = heaters.firstIndex(where: { $0.id == device.deviceID }) {
                heaters[index].name = device.name
                heaters[index].model = device.model
                if heaters[index].host != device.host {
                    heaters[index].host = device.host
                    links.removeValue(forKey: device.deviceID)?.stop()
                    connect(heaters[index])
                }
            } else {
                let heater = HeaterState(id: device.deviceID, host: device.host, name: device.name, model: device.model)
                heaters.append(heater)
                connect(heater)
            }
        }
        heaters.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        UserDefaults.standard.set(try? JSONEncoder().encode(heaters), forKey: Self.savedKey)
    }
}
