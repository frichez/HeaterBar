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
    /// The desk thermometer, on the heater of the room this Mac is in
    /// (absent in older files and elsewhere).
    var desk: Double?
    var deskHumidity: Double?

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
                         outdoor: Double?, desk: DeskReading? = nil, for id: String, at now: Date = Date()) -> Bool {
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var list = samples[id] ?? []
        let opened: Bool
        if let last = list.last, last.time == minute {
            // Any heating within the minute counts, so short bursts still show.
            list[list.count - 1] = TemperatureSample(time: minute, room: room, target: target,
                                                     isHeating: last.isHeating || isHeating,
                                                     energyWh: (last.energyWh ?? 0) + energyWh,
                                                     outdoor: outdoor ?? last.outdoor,
                                                     isEco: last.isEco == true || isEco,
                                                     desk: desk?.temperature ?? last.desk,
                                                     deskHumidity: desk?.humidity ?? last.deskHumidity)
            opened = false
        } else {
            list.append(TemperatureSample(time: minute, room: room, target: target, isHeating: isHeating,
                                          energyWh: energyWh, outdoor: outdoor, isEco: isEco,
                                          desk: desk?.temperature, deskHumidity: desk?.humidity))
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

    /// The minute before the one being filled, once a new one has opened.
    func lastFinished(for id: String) -> TemperatureSample? {
        (samples[id] ?? []).dropLast().last
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(samples).write(to: url, options: .atomic)
    }
}

/// Every finished minute, kept for good in ~/Projects/HeaterBar/logs/minutes
/// (one CSV per day, all heaters): the history above keeps only a week, too
/// little to learn from over a winter.
enum MinuteArchive {
    static let columns = ["time", "heater", "room", "target", "heating", "eco", "energy_wh", "outdoor",
                          "desk", "desk_humidity"]

    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/HeaterBar/logs/minutes")

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func append(_ sample: TemperatureSample, heater: String) {
        write([line(sample, heater: heater)], day: sample.time)
    }

    /// Writes the days the archive does not have yet from the history, all
    /// but each heater's last minute, which may still be filling. Run at
    /// launch, it also saved the week before the archive existed.
    static func backfill(_ history: HeaterHistory, names: [String: String]) {
        var days: [String: [(time: Date, line: String)]] = [:]
        for (id, list) in history.samples {
            let heater = names[id] ?? id
            for sample in list.dropLast() {
                days[dayFormat.string(from: sample.time), default: []].append((sample.time, line(sample, heater: heater)))
            }
        }
        for (day, lines) in days where !FileManager.default.fileExists(atPath: url(day).path) {
            let sorted = lines.sorted { $0.time < $1.time }
            write(sorted.map(\.line), day: sorted[0].time)
        }
    }

    private static func url(_ day: String) -> URL { folder.appendingPathComponent(day + ".csv") }

    private static func line(_ sample: TemperatureSample, heater: String) -> String {
        func number(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "" }
        return [timeFormat.string(from: sample.time), heater.replacingOccurrences(of: ",", with: " "),
                number(sample.room, "%.1f"), sample.target.map(String.init) ?? "", sample.isHeating ? "1" : "0",
                sample.isEco == true ? "1" : "0", number(sample.energyWh, "%.1f"), number(sample.outdoor, "%.1f"),
                number(sample.desk, "%.2f"), number(sample.deskHumidity, "%.1f")].joined(separator: ",")
    }

    private static func write(_ lines: [String], day: Date) {
        let url = url(dayFormat.string(from: day))
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? (columns.joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try? handle.close()
    }
}
