import AppKit
import Charts
import SwiftUI

final class ReportWindowController {
    private var window: NSWindow?
    private let usageStore: UsageStore

    init(usageStore: UsageStore) {
        self.usageStore = usageStore
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ReportView(usageStore: usageStore)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Local LLM — Usage Report"
        win.minSize = NSSize(width: 680, height: 560)
        win.center()
        win.contentViewController = hosting
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

struct ReportView: View {
    let usageStore: UsageStore
    @State private var timeframe: ReportTimeframe = .hours24
    @State private var report: UsageReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                if let report {
                    kpiRow(report)
                    tokenTimelineCard(report)
                    parallelSlotsRow(report)
                    HStack(alignment: .top, spacing: 14) {
                        clientChartCard(report)
                        modelChartCard(report)
                    }
                    clientTableCard(report)
                } else {
                    ProgressView("Loading usage report…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { reload() }
        .onChange(of: timeframe) { _, _ in reload() }
    }

    private func reload() {
        report = usageStore.buildReport(timeframe: timeframe)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(timeframe.title) Usage")
                    .font(.title2.weight(.semibold))
                if let report {
                    Text("Updated \(report.generatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Picker("Timeframe", selection: $timeframe) {
                ForEach(ReportTimeframe.allCases) { tf in
                    Text(tf.rawValue).tag(tf)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func kpiRow(_ r: UsageReport) -> some View {
        HStack(spacing: 10) {
            ReportKPI(
                title: "Total Tokens",
                value: formatTokens(r.totalTokens),
                subtitle: "\(formatTokens(r.totalGenTokens)) gen · \(formatTokens(r.totalPromptTokens)) prompt"
            )
            ReportKPI(
                title: "Requests / Tasks",
                value: "\(r.totalRequests)",
                subtitle: "\(formatDuration(r.totalActiveSeconds)) active"
            )
            ReportKPI(
                title: "Avg Gen Speed",
                value: r.avgGenTps > 0 ? String(format: "%.1f t/s", r.avgGenTps) : "—",
                subtitle: "across active slots"
            )
            ReportKPI(
                title: "Parallel Slots",
                value: r.peakParallelSlots > 0 ? "Peak \(r.peakParallelSlots)" : "—",
                subtitle: r.avgParallelSlots > 0
                    ? String(format: "avg %.2f slots active", r.avgParallelSlots)
                    : "no concurrency data"
            )
        }
    }

    private func tokenTimelineCard(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Token Usage Over Time by Client (\(r.timeframe.title))")
                .font(.headline)

            if r.timePoints.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(r.timePoints) { point in
                    BarMark(
                        x: .value("Time", point.timestamp, unit: chartUnit(for: r.timeframe)),
                        y: .value("Tokens", point.totalTokens)
                    )
                    .foregroundStyle(by: .value("Client", point.client))
                }
                .chartXAxis {
                    timeXAxis(for: r.timeframe)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(formatTokens(v))
                            }
                        }
                    }
                }
                .frame(height: 190)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private func parallelSlotsRow(_ r: UsageReport) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parallel Slots Over Time")
                    .font(.headline)

                if r.parallelPoints.isEmpty {
                    emptyChartPlaceholder
                } else {
                    Chart(r.parallelPoints) { point in
                        BarMark(
                            x: .value("Time", point.timestamp, unit: chartUnit(for: r.timeframe)),
                            y: .value("Peak Slots", point.maxParallel)
                        )
                        .foregroundStyle(Color.orange.opacity(0.35))

                        LineMark(
                            x: .value("Time", point.timestamp, unit: chartUnit(for: r.timeframe)),
                            y: .value("Avg Slots", point.avgParallel)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))

                        PointMark(
                            x: .value("Time", point.timestamp, unit: chartUnit(for: r.timeframe)),
                            y: .value("Avg Slots", point.avgParallel)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(24)
                    }
                    .chartXAxis {
                        timeXAxis(for: r.timeframe)
                    }
                    .chartYScale(domain: 0...max(2, r.peakParallelSlots))
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: max(2, r.peakParallelSlots) + 1))
                    }
                    .frame(height: 165)

                    HStack(spacing: 12) {
                        Label("Bar: Peak slots", systemImage: "square.fill")
                            .foregroundColor(.orange.opacity(0.6))
                        Label("Line: Avg active slots", systemImage: "circle.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 10) {
                Text("Concurrency Split")
                    .font(.headline)

                if r.concurrencySlices.isEmpty {
                    emptyChartPlaceholder
                } else {
                    Chart(r.concurrencySlices) { slice in
                        BarMark(
                            x: .value("Share %", slice.ratio * 100),
                            y: .value("Parallel", slice.label)
                        )
                        .foregroundStyle(slice.parallelCount > 1 ? Color.orange.gradient : Color.accentColor.gradient)
                        .annotation(position: .trailing) {
                            Text(String(format: "%.0f%% (%@)", slice.ratio * 100, formatDuration(slice.seconds)))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .chartXScale(domain: 0...115)
                    .frame(height: max(120, CGFloat(r.concurrencySlices.count) * 42))
                }
            }
            .frame(width: 270, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)
        }
    }

    private func clientChartCard(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who Used It (Tokens)")
                .font(.headline)

            if r.clientSummaries.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(r.clientSummaries) { item in
                    BarMark(
                        x: .value("Tokens", item.totalTokens),
                        y: .value("Client", item.client)
                    )
                    .foregroundStyle(by: .value("Client", item.client))
                    .annotation(position: .trailing) {
                        Text(formatTokens(item.totalTokens))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(formatTokens(v))
                            }
                        }
                    }
                }
                .frame(height: max(120, CGFloat(r.clientSummaries.count) * 34))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private func modelChartCard(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models Used (Tokens)")
                .font(.headline)

            if r.modelSummaries.isEmpty {
                emptyChartPlaceholder
            } else {
                Chart(r.modelSummaries) { item in
                    BarMark(
                        x: .value("Tokens", item.totalTokens),
                        y: .value("Model", shortModelName(item.model))
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .annotation(position: .trailing) {
                        Text(formatTokens(item.totalTokens))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(formatTokens(v))
                            }
                        }
                    }
                }
                .frame(height: max(120, CGFloat(r.modelSummaries.count) * 34))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private func clientTableCard(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Client Breakdown")
                .font(.headline)

            if r.clientSummaries.isEmpty {
                Text("No usage recorded in this timeframe yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("Client").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Share").frame(width: 55, alignment: .trailing)
                        Text("Gen").frame(width: 70, alignment: .trailing)
                        Text("Prompt").frame(width: 75, alignment: .trailing)
                        Text("Reqs").frame(width: 45, alignment: .trailing)
                        Text("Time").frame(width: 65, alignment: .trailing)
                        Text("Avg t/s").frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                    Divider()

                    ForEach(r.clientSummaries) { c in
                        HStack {
                            Text(c.client)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.0f%%", c.shareRatio * 100))
                                .frame(width: 55, alignment: .trailing)
                            Text(formatTokens(c.genTokens))
                                .frame(width: 70, alignment: .trailing)
                            Text(formatTokens(c.promptTokens))
                                .frame(width: 75, alignment: .trailing)
                            Text("\(c.requestCount)")
                                .frame(width: 45, alignment: .trailing)
                            Text(formatDuration(c.activeSeconds))
                                .frame(width: 65, alignment: .trailing)
                            Text(c.avgGenTps > 0 ? String(format: "%.1f", c.avgGenTps) : "—")
                                .frame(width: 60, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private var emptyChartPlaceholder: some View {
        Text("No usage recorded yet for this timeframe.")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private func chartUnit(for tf: ReportTimeframe) -> Calendar.Component {
        switch tf {
        case .hour1: return .minute
        case .hours24, .week: return .hour
        case .month: return .day
        }
    }

    @AxisContentBuilder
    private func timeXAxis(for tf: ReportTimeframe) -> some AxisContent {
        switch tf {
        case .hour1:
            AxisMarks(values: .stride(by: .minute, count: 15)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        case .hours24:
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            }
        case .week:
            AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }
}

private struct ReportKPI: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(9)
    }
}

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.2fM", Double(n) / 1_000_000.0)
    } else if n >= 1_000 {
        return String(format: "%.1fk", Double(n) / 1_000.0)
    }
    return "\(n)"
}

private func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    if total >= 3600 {
        return "\(total / 3600)h \((total % 3600) / 60)m"
    } else if total >= 60 {
        return "\(total / 60)m \(total % 60)s"
    }
    return "\(total)s"
}

private func shortModelName(_ name: String) -> String {
    if let slash = name.lastIndex(of: "/") {
        return String(name[name.index(after: slash)...])
    }
    return name
}
