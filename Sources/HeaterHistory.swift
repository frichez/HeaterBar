import Foundation

struct TemperatureSample: Codable, Identifiable {
    var time: Date
    var room: Double
    var target: Int?
    var isHeating: Bool
    /// Estimated energy used during this minute (absent in older files).
    var energyWh: Double?
    /// Outdoor temperature at the time, for analysis (absent in older files).
    var outdoor: Double?
    /// Whether Eco when away had lowered the target or switched the heater
    /// off (absent in older files).
    var isEco: Bool?

    var id: Date { time }
}

/// One room-temperature reading per heater per minute, kept a week and saved
/// so the graph survives restarts and can show the days before. The heaters only report the present, so the
/// history starts when HeaterBar does.
struct HeaterHistory {
    static let retention: TimeInterval = 7 * 24 * 3600

    private(set) var samples: [String: [TemperatureSample]] = [:]

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeaterBar/history.json")
    }

    static func load() -> HeaterHistory {
        var history = HeaterHistory()
        if let data = try? Data(contentsOf: fileURL),
           let samples = try? JSONDecoder().decode([String: [TemperatureSample]].self, from: data) {
            history.samples = samples
        }
        return history
    }

    /// Folds a reading into the current minute's sample. Returns true when it
    /// opened a new minute, which is when the history is worth saving.
    mutating func record(room: Double, target: Int?, isHeating: Bool, isEco: Bool, energyWh: Double,
                         outdoor: Double?, for id: String, at now: Date = Date()) -> Bool {
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var list = samples[id] ?? []
        let opened: Bool
        if let last = list.last, last.time == minute {
            // Any heating within the minute counts, so short bursts still show.
            list[list.count - 1] = TemperatureSample(time: minute, room: room, target: target,
                                                     isHeating: last.isHeating || isHeating,
                                                     energyWh: (last.energyWh ?? 0) + energyWh,
                                                     outdoor: outdoor ?? last.outdoor,
                                                     isEco: last.isEco == true || isEco)
            opened = false
        } else {
            list.append(TemperatureSample(time: minute, room: room, target: target, isHeating: isHeating,
                                          energyWh: energyWh, outdoor: outdoor, isEco: isEco))
            opened = true
        }
        list.removeAll { now.timeIntervalSince($0.time) > Self.retention }
        samples[id] = list
        return opened
    }

    /// Energy used since local midnight, in watt-hours.
    func energyToday(for id: String, now: Date = Date()) -> Double {
        let midnight = Calendar.current.startOfDay(for: now)
        return (samples[id] ?? []).filter { $0.time >= midnight }.reduce(0) { $0 + ($1.energyWh ?? 0) }
    }

    /// Minutes spent heating since local midnight.
    func heatingMinutesToday(for id: String, now: Date = Date()) -> Int {
        heatingMinutes(for: id, in: DateInterval(start: Calendar.current.startOfDay(for: now), end: now)) ?? 0
    }

    /// Minutes spent heating within `interval`; nil when no reading that old
    /// is kept any more.
    func heatingMinutes(for id: String, in interval: DateInterval) -> Int? {
        let list = samples[id] ?? []
        guard let first = list.first, first.time < interval.end else { return nil }
        return list.filter { interval.contains($0.time) && $0.isHeating }.count
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(samples).write(to: url, options: .atomic)
    }
}
