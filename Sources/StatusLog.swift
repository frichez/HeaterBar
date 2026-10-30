import Foundation

/// A CSV line each time a heater's state changes, one file per day under
/// ~/Library/Application Support/HeaterBar/logs, kept 30 days: enough to study
/// later how the heaters behave (which levels Auto+ uses, how long it heats).
/// The room temperature rides along on each line but changes alone do not
/// write one; the per-minute history already has it.
struct StatusLog {
    static let columns = [
        "time", "heater", "power", "selected_mode", "running_mode", "level", "function",
        "target", "room", "oscillation", "timer_step", "estimated_watts", "outdoor", "away",
        "desk", "desk_humidity", "event",
    ]
    private static let keys = ["D03102", "D0310C", "D0313F", "D0310D", "D0310A", "D0310E", "D0320F", "D03110"]
    private static let retentionDays = 30

    private var lastLine: [String: [String]] = [:]

    /// Local time, as a spreadsheet reads it.
    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The app's own copy, pruned after 30 days, and a permanent archive in the
    /// project folder for analysis.
    private static let folders: [(url: URL, prunes: Bool)] = {
        let manager = FileManager.default
        return [
            (manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HeaterBar/logs"), true),
            (manager.homeDirectoryForCurrentUser.appendingPathComponent("Projects/HeaterBar/logs"), false),
        ]
    }()

    mutating func record(_ status: [String: Any], heater: String, room: Double?, watts: Double,
                         outdoor: Double?, away: Bool, desk: DeskReading? = nil, at now: Date = Date()) {
        // Presence is part of the state: leaving and returning are worth a line.
        let values = Self.keys.map { status[$0].map { "\($0)" } ?? "" } + [away ? "1" : "0"]
        guard lastLine[heater] != values else { return }
        lastLine[heater] = values
        let time = Self.timeFormat.string(from: now)
        let room = room.map { String(format: "%.1f", $0) } ?? ""
        let outdoor = outdoor.map { String(format: "%.1f", $0) } ?? ""
        let deskTemperature = desk.map { String(format: "%.1f", $0.temperature) } ?? ""
        let deskHumidity = desk?.humidity.map { String(format: "%.0f", $0) } ?? ""
        // Columns: power … target (values 0–5), room, oscillation and timer (6–7),
        // watts, outdoor, away (8), desk, desk humidity.
        let fields = [time, heater.replacingOccurrences(of: ",", with: " ")] + values[0...5] + [room]
            + values[6...7] + [String(Int(watts.rounded())), outdoor, values[8], deskTemperature, deskHumidity, ""]
        Self.append(fields.joined(separator: ","), day: now)
    }

    /// A command HeaterBar sent, on a line of its own with only the event
    /// column filled, e.g. "command D03102=1 (eco: you are back): accepted".
    func recordCommand(_ description: String, reason: String, result: String, heater: String, at now: Date = Date()) {
        recordEvent("command \(description) (\(reason)): \(result)", heater: heater, at: now)
    }

    /// Anything else worth a line of its own, e.g. "unreachable".
    func recordEvent(_ text: String, heater: String, at now: Date = Date()) {
        let event = text.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\"", with: "")
        let fields = [Self.timeFormat.string(from: now), heater.replacingOccurrences(of: ",", with: " ")]
            + Array(repeating: "", count: Self.columns.count - 3) + [event]
        Self.append(fields.joined(separator: ","), day: now)
    }

    private static func append(_ line: String, day: Date) {
        let name = dayFormat.string(from: day) + ".csv"
        let manager = FileManager.default
        for folder in folders {
            let url = folder.url.appendingPathComponent(name)
            upgradeColumns(of: url)
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: folder.url, withIntermediateDirectories: true)
                try? (columns.joined(separator: ",") + "\n").write(to: url, atomically: true, encoding: .utf8)
                if folder.prunes { prune(folder.url) }
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { continue }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    private static var upgraded: Set<URL> = []

    /// A file started before columns were added (desk, desk_humidity on
    /// 2026-10-30) gets them, empty, before its last column (event), so a day
    /// keeps one layout.
    private static func upgradeColumns(of url: URL) {
        guard !upgraded.contains(url) else { return }
        upgraded.insert(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let header = text.split(separator: "\n", maxSplits: 1).first,
              header != columns.joined(separator: ",") else { return }
        let missing = columns.count - header.split(separator: ",", omittingEmptySubsequences: false).count
        guard missing > 0 else { return }
        let lines = text.split(separator: "\n").dropFirst().map { line -> String in
            var fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            fields.insert(contentsOf: Array(repeating: "", count: missing), at: max(0, fields.count - 1))
            return fields.joined(separator: ",")
        }
        try? ([columns.joined(separator: ",")] + lines).joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func prune(_ folder: URL) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "csv" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
