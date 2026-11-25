// What the dashboard's battery and airtime meters open: each as it is now, and as this device heard
// it over the last hour, day or week, drawn as a line that holds each value until the next. The
// node keeps no history, so the line has a gap wherever the device was not connected.

import Charts
import SwiftUI
import TernKit

/// How far back a chart looks.
enum ReadingSpan: CaseIterable, Identifiable, Hashable {
    case hour, sixHours, day, week

    var id: Self { self }

    var ms: Int64 {
        switch self {
        case .hour: 3_600_000
        case .sixHours: 6 * 3_600_000
        case .day: 24 * 3_600_000
        case .week: 7 * 24 * 3_600_000
        }
    }

    var short: String {
        switch self {
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 d"
        }
    }

    var long: String {
        switch self {
        case .hour: "Hour"
        case .sixHours: "6 Hours"
        case .day: "24 Hours"
        case .week: "7 Days"
        }
    }
}

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private func nowMs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

/// How long `seconds` is, said as briefly as is exact: "1 h", "10 min", "36 s".
func periodText(_ seconds: UInt32) -> String {
    if seconds >= 3600 && seconds % 3600 == 0 { return "\(seconds / 3600) h" }
    if seconds >= 60 && seconds % 60 == 0 { return "\(seconds / 60) min" }
    return "\(seconds) s"
}

private func volts(_ v: Double) -> String { String(format: "%.2f V", v) }

private func seconds(_ ms: UInt32) -> String { String(format: "%.1f s", Double(ms) / 1000) }

/// The big figure at the head of a readings screen, on the dashboard's own colours.
private struct ReadingHead: View {
    let value: String
    let line: String?
    let sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.largeTitle.weight(.semibold)).monospacedDigit()
            if let line { Text(line).font(.headline).opacity(0.9) }
            if let sub { Text(sub).font(.footnote).opacity(0.8) }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.heroTop, .heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

/// One point of a drawn line, in the run `run`.
private struct Drawn: Identifiable {
    let id: Int
    let run: Int
    let at: Date
    let value: Double
}

/**
 A line through `points` from `from` to `to`, each value held until the next, broken after an end;
 the area under it shaded. `low` to `high` is its height, and `limit` a dashed line across it.
 */
struct ReadingsChart: View {
    let points: [ChartPoint]
    let from: Int64
    let to: Int64
    let low: Double
    let high: Double
    let color: Color
    var limit: Double?
    let label: (Double) -> String
    let description: String

    /// Each run's points with a step before each change, so a straight line holds each value.
    private var drawn: [Drawn] {
        var out: [Drawn] = []
        for (r, run) in ChartPoint.runs(points, to: to).enumerated() {
            for (i, p) in run.enumerated() {
                if i > 0 { out.append(Drawn(id: out.count, run: r, at: date(p.at), value: run[i - 1].value)) }
                out.append(Drawn(id: out.count, run: r, at: date(p.at), value: p.value))
            }
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(drawn) { d in
                AreaMark(
                    x: .value("Time", d.at), yStart: .value("Floor", low), yEnd: .value("Value", d.value),
                    series: .value("Run", d.run))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", d.at), y: .value("Value", d.value), series: .value("Run", d.run))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .chartXScale(domain: date(from)...date(to))
        .chartYScale(domain: low...high)
        .chartYAxis {
            AxisMarks(position: .leading, values: [low, (low + high) / 2, high]) { v in
                AxisGridLine()
                AxisValueLabel { Text(v.as(Double.self).map(label) ?? "") }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: to - from > 24 * 3_600_000 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute())
            }
        }
        .frame(height: 180)
        .padding(.vertical, 8)
        .accessibilityLabel(description)
    }
}

private struct SpanPicker: View {
    @Binding var span: ReadingSpan

    var body: some View {
        Picker("Span", selection: $span) {
            ForEach(ReadingSpan.allCases) { Text($0.short).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// When the reading at `at` was heard: up to date while the node is connected, or how long ago.
@MainActor
private func heard(_ model: NodeModel, _ at: Int64?, now: Int64) -> String {
    guard let at else { return "Unknown" }
    if model.isReady { return "Up to date" }
    return "\(Words.duration(UInt32(max(0, now - at) / 1000))) ago"
}

/// The node's battery: now, and over time.
struct BatteryView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var span = ReadingSpan.day
    @State private var voltage = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: nowMs(context.date))
        }
        .navigationTitle("Battery")
    }

    private func content(now: Int64) -> some View {
        let p = model.records.power
        let readings = model.readings.power
        // Charge where the node estimates it; its voltage where it only measures that.
        let hasPercent = p.map { $0.percent <= 100 } ?? readings.contains { $0.knownPercent != nil }
        let hasVolts = (p?.millivolts ?? 0) > 0 || readings.contains { $0.millivolts > 0 }
        let showVolts = voltage || !hasPercent
        let source: String? = p.map { $0.flags & 1 != 0 ? "Charging" : $0.flags & 2 != 0 ? "On external power" : "On battery" }
        let from = now - span.ms
        let points = ChartPoint.inSpan(readings.compactMap { r in
            let v = showVolts ? (r.millivolts > 0 ? Double(r.millivolts) / 1000 : nil) : r.knownPercent.map(Double.init)
            return v.map { ChartPoint(at: r.at, value: $0, end: r.end) }
        }, from: from)
        let values = points.map(\.value)
        let shown: (Double) -> String = { showVolts ? volts($0) : "\(Int($0.rounded()))%" }

        return Form {
            Section {
                ReadingHead(
                    value: p.map { $0.percent <= 100 ? "\($0.percent)%" : $0.millivolts > 0 ? volts(Double($0.millivolts) / 1000) : "Unknown" } ?? "Unknown",
                    line: source,
                    sub: p.flatMap { $0.percent <= 100 && $0.millivolts > 0 ? volts(Double($0.millivolts) / 1000) : nil })
            }
            Section {
                SpanPicker(span: $span)
                if hasPercent && hasVolts {
                    Picker("Show", selection: $voltage) {
                        Text("Charge").tag(false)
                        Text("Voltage").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if points.isEmpty {
                    Text("Nothing heard from your node in this time. The app keeps what your node tells it while they're connected.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    // Volts: a little room either side of what was heard. Charge: the whole of 0 to 100.
                    let pad = max(0.05, ((values.max() ?? 0) - (values.min() ?? 0)) * 0.15)
                    ReadingsChart(
                        points: points, from: from, to: now,
                        low: showVolts ? (values.min() ?? 0) - pad : 0, high: showVolts ? (values.max() ?? 0) + pad : 100,
                        color: !showVolts && (values.last ?? 100) < 20 ? .warn : .good,
                        label: shown,
                        description: "Your node's battery over the last \(span.long.lowercased())")
                }
            } header: {
                Text(showVolts ? "Voltage" : "Charge")
            }
            if let lo = values.min(), let hi = values.max(), let first = values.first, let last = values.last {
                Section("Over the Last \(span.long)") {
                    LabeledContent("Lowest", value: shown(lo))
                    LabeledContent("Highest", value: shown(hi))
                    LabeledContent("Change", value: (last > first ? "+" : last < first ? "−" : "") + shown(abs(last - first)))
                }
            }
            Section {
                LabeledContent("Charge", value: p.flatMap { $0.percent <= 100 ? "\($0.percent)%" : nil } ?? "Unknown")
                LabeledContent("Voltage", value: p.flatMap { $0.millivolts > 0 ? volts(Double($0.millivolts) / 1000) : nil } ?? "Unknown")
                LabeledContent("Power", value: source ?? "Unknown")
                LabeledContent("Last Heard", value: heard(model, readings.last?.at, now: now))
            } header: {
                Text("Now")
            } footer: {
                Text("Your node tells the app its battery when it changes. The app keeps what it hears while connected, "
                    + "for a week, on this device only: a gap in the line is a time it wasn't connected.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The node's airtime: how much of the region's limit it has used, now and over time.
struct AirtimeView: View {
    @EnvironmentObject private var model: NodeModel
    @State private var span = ReadingSpan.day

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: nowMs(context.date))
        }
        .navigationTitle("Airtime")
    }

    private func content(now: Int64) -> some View {
        let a = model.records.airtime
        let from = now - span.ms
        let points = ChartPoint.inSpan(
            model.readings.airtime.compactMap { r in r.fraction.map { ChartPoint(at: r.at, value: $0 * 100, end: r.end) } }, from: from)
        let peak = points.map(\.value).max()

        return Form {
            Section {
                ReadingHead(
                    value: a.map { $0.period == 0 ? "No limit" : "\(min(100, Int($0.used) * 100 / Int(max($0.allowed, 1))))%" } ?? "Unknown",
                    line: a.map { $0.period == 0 ? "This region has no limit" : "\(seconds($0.used)) of \(seconds($0.allowed)) used, every \(periodText($0.period))" },
                    sub: a.flatMap { $0.wait > 0 ? "Next send in about \(seconds($0.wait))" : nil })
            }
            if a?.period != 0 {
                Section("Used of the Limit") {
                    SpanPicker(span: $span)
                    if points.isEmpty {
                        Text("Nothing heard from your node in this time. The app keeps what your node tells it while they're connected.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ReadingsChart(
                            points: points, from: from, to: now, low: 0, high: 100,
                            color: (peak ?? 0) >= 90 ? .warn : .accentColor, limit: 100,
                            label: { "\(Int($0.rounded()))%" },
                            description: "How much of its airtime limit your node used over the last \(span.long.lowercased())")
                    }
                }
                if let peak {
                    Section("Over the Last \(span.long)") {
                        LabeledContent("Highest", value: "\(Int(peak.rounded()))%")
                        let waits = model.readings.waits(since: from)
                        LabeledContent("Times It Had to Wait", value: waits == 0 ? "None" : "\(waits)")
                    }
                }
            }
            Section {
                if let a, a.period != 0 {
                    LabeledContent("Allowed", value: "\(seconds(a.allowed)) every \(periodText(a.period))")
                    LabeledContent("Used", value: seconds(a.used))
                    LabeledContent("Next Send") {
                        Text(a.wait > 0 ? "In about \(seconds(a.wait))" : "Now").foregroundStyle(a.wait > 0 ? Color.warn : .secondary)
                    }
                }
                LabeledContent("Last Heard", value: heard(model, model.readings.airtime.last?.at, now: now))
            } header: {
                Text("Now")
            } footer: {
                Text("The radio rules in your node's region limit how long it may spend sending in each period. Airtime is how "
                    + "much of that it has used in the period just gone: when it runs out, messages wait until some frees up. "
                    + "The app keeps what your node tells it while connected, for a week, on this device only: a gap in the "
                    + "line is a time it wasn't connected.")
            }
        }
        .formStyle(.grouped)
    }
}
