import Foundation

/// Energy used per heater per day, kept for good (unlike the week-long
/// history) so the panel can show any day and the total since HeaterBar started.
struct EnergyLedger {
    /// Watt-hours by local day ("2026-10-28"), then by heater id.
    private(set) var days: [String: [String: Double]] = [:]

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeaterBar/energy.json")
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The saved ledger, or on first use one started from what the history
    /// still holds, so the day it is introduced is not lost.
    static func load(seed history: HeaterHistory) -> EnergyLedger {
        var ledger = EnergyLedger()
        if let data = try? Data(contentsOf: fileURL),
           let days = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            ledger.days = days
        } else {
            for (id, samples) in history.samples {
                for sample in samples { ledger.add(sample.energyWh ?? 0, for: id, at: sample.time) }
            }
            ledger.save()
        }
        return ledger
    }

    mutating func add(_ energyWh: Double, for id: String, at time: Date) {
        guard energyWh > 0 else { return }
        days[Self.dayFormat.string(from: time), default: [:]][id, default: 0] += energyWh
    }

    /// Watt-hours for one heater, or all when `id` is nil, over the days whose
    /// key starts with `prefix` ("2026-10" for a month, "" for everything).
    func energy(for id: String? = nil, prefix: String = "") -> Double {
        days.filter { $0.key.hasPrefix(prefix) }.values.reduce(0) { total, heaters in
            total + (id.map { heaters[$0] ?? 0 } ?? heaters.values.reduce(0, +))
        }
    }

    /// Watt-hours on the local day that contains `date`.
    func energy(for id: String? = nil, on date: Date) -> Double {
        energy(for: id, prefix: Self.dayFormat.string(from: date))
    }

    /// The first day recorded, for "since …".
    var firstDay: Date? { days.keys.min().flatMap(Self.dayFormat.date) }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(days).write(to: url, options: .atomic)
    }
}
