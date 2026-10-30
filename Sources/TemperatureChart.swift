import Charts
import SwiftUI

/// Room temperature over one day, midnight to midnight (to now for today),
/// with the target as a dashed step line, and shaded behind it the minutes
/// the heater was heating (orange) or held back by Eco when away (green). `DayPicker` chooses the day.
struct TemperatureChart: View {
    let samples: [TemperatureSample]
    /// 0 for today, 1 for yesterday, and so on.
    let daysBack: Int
    /// The tallest the plot grows; it shrinks to fit a smaller space.
    var chartHeight: CGFloat = 90

    @State private var selection: Date?

    private var day: DateInterval { Self.day(daysBack) }

    static func day(_ daysBack: Int) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: Date()))!
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private var visible: [TemperatureSample] {
        let day = day
        return samples.filter { $0.time >= day.start && $0.time < day.end }
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visible.count < 2 {
                Text(daysBack == 0 ? "Collecting readings, one per minute…" : "No readings that day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: chartHeight)
            } else {
                chart
                HStack(spacing: 12) {
                    legendItem("Temperature") {
                        Capsule().fill(Color.primary.opacity(0.85)).frame(width: 12, height: 2)
                    }
                    legendItem("Target") {
                        Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 12, y: 0)) }
                            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 12, height: 1)
                    }
                    legendItem("Heating", help: durationHelp("Heating", minutes: visible.filter(\.isHeating).count)) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.3)).frame(width: 10, height: 8)
                    }
                    if !ecoSpans.isEmpty {
                        legendItem("Eco", help: durationHelp("Eco", minutes: visible.filter { $0.isEco == true }.count)
                                   + ": target lowered or heater switched off while you were away") {
                            RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.3)).frame(width: 10, height: 8)
                        }
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(ecoSpans, id: \.lowerBound) { span in
                RectangleMark(xStart: .value("From", span.lowerBound), xEnd: .value("To", span.upperBound))
                    .foregroundStyle(Color.green.opacity(0.15))
            }
            ForEach(heatingSpans, id: \.lowerBound) { span in
                RectangleMark(xStart: .value("From", span.lowerBound), xEnd: .value("To", span.upperBound))
                    .foregroundStyle(Color.orange.opacity(0.15))
            }
            ForEach(visible.filter { $0.target != nil }) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Target", Double(sample.target ?? 0)),
                         series: .value("Series", "Target"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(visible) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Room", sample.room),
                         series: .value("Series", "Room"))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let selected = selectedSample {
                RuleMark(x: .value("Selected", selected.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(for: selected)
                    }
                PointMark(x: .value("Time", selected.time), y: .value("Room", selected.room))
                    .symbolSize(50)
                    .foregroundStyle(Color.primary)
            }
        }
        .chartYScale(domain: yDomain)
        // Past days span midnight to midnight, so they compare at a glance.
        .chartXScale(domain: day.start...(daysBack == 0 ? max(Date(), day.start.addingTimeInterval(3600)) : day.end))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let degrees = value.as(Double.self) { Text("\(degrees, specifier: "%.0f")°") }
                }
            }
        }
        .chartXSelection(value: $selection)
        .onChange(of: daysBack) { selection = nil }
        // Up to chartHeight, shrinking to fit the space it is given.
        .frame(minHeight: 50, maxHeight: chartHeight)
    }

    private func legendItem(_ title: String, help: String? = nil, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 4) {
            swatch()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
        }
        .contentShape(Rectangle())
        .help(help ?? "")
    }

    /// E.g. "Heating 3h 12m today", from the day's one-per-minute readings.
    private func durationHelp(_ title: String, minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        let duration = hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        return "\(title) \(duration) " + (daysBack == 0 ? "today" : "that day")
    }

    private func tooltip(for sample: TemperatureSample) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "%.1f°", sample.room)).font(.caption.weight(.semibold)).monospacedDigit()
            Text(sample.time, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
            if sample.isHeating {
                Text("Heating").font(.caption2).foregroundStyle(.secondary)
            }
            if sample.isEco == true {
                Text("Eco").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }

    private var selectedSample: TemperatureSample? {
        guard let selection else { return nil }
        return visible.min { abs($0.time.timeIntervalSince(selection)) < abs($1.time.timeIntervalSince(selection)) }
    }

    private var heatingSpans: [ClosedRange<Date>] { spans { $0.isHeating } }
    private var ecoSpans: [ClosedRange<Date>] { spans { $0.isEco == true } }

    /// Runs of consecutive matching minutes, each covering its whole last minute.
    private func spans(where matches: (TemperatureSample) -> Bool) -> [ClosedRange<Date>] {
        var spans: [ClosedRange<Date>] = []
        for sample in visible where matches(sample) {
            let end = sample.time.addingTimeInterval(60)
            if let open = spans.last, sample.time <= open.upperBound {
                spans[spans.count - 1] = open.lowerBound...end
            } else {
                spans.append(sample.time...end)
            }
        }
        return spans
    }

    private var yDomain: ClosedRange<Double> {
        let values = visible.map(\.room) + visible.compactMap { $0.target.map(Double.init) }
        guard let low = values.min(), let high = values.max() else { return 15...25 }
        return (low - 0.5).rounded(.down)...(high + 0.5).rounded(.up)
    }
}

/// ‹ Today › on the back of a card, where the front has its power switch.
struct DayPicker: View {
    @Binding var daysBack: Int
    let samples: [TemperatureSample]

    /// How many days back the oldest reading is.
    private var oldestDaysBack: Int {
        guard let first = samples.first?.time else { return 0 }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                       to: calendar.startOfDay(for: Date())).day ?? 0
    }

    /// Drawn in SwiftUI: native controls stop taking clicks on the back of a
    /// flipped card, behind its 3D rotations.
    var body: some View {
        HStack(spacing: 2) {
            dayArrow("chevron.left", enabled: daysBack < oldestDaysBack) { daysBack += 1 }
            Text(dayTitle)
                .font(.system(size: 10, weight: .medium))
                .frame(minWidth: 64)
            dayArrow("chevron.right", enabled: daysBack > 0) { daysBack -= 1 }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var dayTitle: String { Self.title(daysBack) }

    static func title(_ daysBack: Int) -> String {
        switch daysBack {
        case 0: "Today"
        case 1: "Yesterday"
        default: TemperatureChart.day(daysBack).start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    private func dayArrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
