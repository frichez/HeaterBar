import Charts
import SwiftUI

/// Room temperature over the chosen range, with the target as a dashed step
/// line and the minutes the heater was heating shaded behind.
struct TemperatureChart: View {
    let samples: [TemperatureSample]
    /// The tallest the plot grows; it shrinks to fit a smaller space.
    var chartHeight: CGFloat = 90

    @AppStorage("chartHours") private var hours = 6
    @State private var selection: Date?

    private var visible: [TemperatureSample] {
        let start = Date().addingTimeInterval(-Double(hours) * 3600)
        return samples.filter { $0.time >= start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Room temperature").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                rangePicker
            }

            if visible.count < 2 {
                Text("Collecting readings, one per minute…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: chartHeight)
            } else {
                chart
                HStack(spacing: 12) {
                    legendItem("Room") {
                        Capsule().fill(Color.primary.opacity(0.85)).frame(width: 12, height: 2)
                    }
                    legendItem("Target") {
                        Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 12, y: 0)) }
                            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 12, height: 1)
                    }
                    legendItem("Heating") {
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.3)).frame(width: 10, height: 8)
                    }
                }
            }
        }
    }

    private var chart: some View {
        Chart {
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
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute())
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
        // Up to chartHeight, shrinking to fit the space it is given.
        .frame(minHeight: 50, maxHeight: chartHeight)
    }

    /// Drawn in SwiftUI: a native segmented control stops taking clicks on the
    /// back of a flipped card, behind its 3D rotations.
    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach([1, 6, 24], id: \.self) { range in
                let isSelected = hours == range
                Button {
                    hours = range
                } label: {
                    Text("\(range)h")
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func legendItem(_ title: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 4) {
            swatch()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func tooltip(for sample: TemperatureSample) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "%.1f°", sample.room)).font(.caption.weight(.semibold)).monospacedDigit()
            Text(sample.time, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
            if sample.isHeating {
                Text("Heating").font(.caption2).foregroundStyle(.secondary)
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

    /// Runs of consecutive heating minutes, each covering its whole last minute.
    private var heatingSpans: [ClosedRange<Date>] {
        var spans: [ClosedRange<Date>] = []
        for sample in visible where sample.isHeating {
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
