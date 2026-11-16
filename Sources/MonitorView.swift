import AppKit
import Combine
import SwiftUI

final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot = .empty

    let usageStore = UsageStore()
    private let collector = LLMCollector()
    private let queue = DispatchQueue(label: "com.local.llm-monitor.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var isPolling = false

    func start() {
        refreshNow()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        t.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        t.resume()
        timer = t
    }

    func refreshNow() {
        queue.async { [weak self] in
            self?.pollOnce()
        }
    }

    func moveQueueItem(id: String, direction: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.collector.moveQueuedTask(id: id, direction: direction)
            self.pollOnce()
        }
    }

    private func pollOnce() {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        let next = collector.collect()
        usageStore.record(snapshot: next)
        DispatchQueue.main.async {
            self.snapshot = next
        }
    }
}

struct MonitorPopoverView: View {
    @ObservedObject var store: MonitorStore
    var onOpenReport: () -> Void
    var onQuit: () -> Void

    private var snap: MonitorSnapshot { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerView
                modelSection
                summarySection
                slotsSection
                queueSection
                clientsSection
                footerView
            }
            .padding(14)
        }
        .frame(width: 370)
        .frame(maxHeight: 680)
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.accentColor)
                Text("Local LLM Monitor")
                    .font(.headline)
                Text("· \(ComputerInfo.name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(snap.ollamaOnline ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(snap.ollamaOnline ? "Ollama Online" : "Offline")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if let model = snap.models.first {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if !model.parameterSize.isEmpty {
                        Text(model.parameterSize)
                    }
                    if !model.quantization.isEmpty {
                        Text(model.quantization)
                    }
                    Text("VRAM \(model.vramGBString)")
                    if model.contextLength > 0 {
                        Text("ctx \(formatCompact(model.contextLength))")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)
        }
    }

    private var summarySection: some View {
        HStack(spacing: 8) {
            MetricTile(
                title: "Active Sessions",
                value: "\(snap.activeSessionCount) / \(max(snap.slots.count, snap.activeSessionCount))",
                subtitle: "\(snap.connectedClientCount) client\(snap.connectedClientCount == 1 ? "" : "s") connected"
            )

            MetricTile(
                title: "Total Speed",
                value: formattedTotalSpeed,
                subtitle: formattedSpeedSubtitle
            )
        }
    }

    private var formattedTotalSpeed: String {
        if snap.totalGenTps > 0 {
            return String(format: "%.1f t/s", snap.totalGenTps)
        } else if snap.totalPromptTps > 0 {
            return String(format: "%.0f pp/s", snap.totalPromptTps)
        } else {
            return "0.0 t/s"
        }
    }

    private var formattedSpeedSubtitle: String {
        if snap.totalGenTps > 0 && snap.totalPromptTps > 0 {
            return String(format: "gen + %.0f pp/s", snap.totalPromptTps)
        } else if snap.totalGenTps > 0 {
            return "generation"
        } else if snap.totalPromptTps > 0 {
            return "prompt eval"
        } else {
            return "idle"
        }
    }

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions (Slots)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if snap.slots.isEmpty {
                Text("No active runner slots")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(snap.slots) { slot in
                    SlotRow(slot: slot)
                }
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Queue")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(snap.queuedTasks.isEmpty ? "empty" : "\(snap.queuedTasks.count) waiting")
                    .font(.caption2)
                    .foregroundColor(snap.queuedTasks.isEmpty ? .secondary : .orange)
            }

            if !snap.queuedTasks.isEmpty {
                ForEach(Array(snap.queuedTasks.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 8) {
                        Text("#\(item.position)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundColor(.orange)
                            .frame(width: 24, alignment: .leading)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(item.computer) · \(item.program)")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if !item.model.isEmpty {
                                    Text(item.model)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Text("\(Int(item.waitSeconds))s wait")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Button {
                                store.moveQueueItem(id: item.id, direction: "up")
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(idx == 0)

                            Button {
                                store.moveQueueItem(id: item.id, direction: "down")
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(idx == snap.queuedTasks.count - 1)
                        }
                    }
                    .padding(7)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(7)
                }
            }
        }
    }

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clients")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(snap.clients) { client in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(client.isConnected ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 7, height: 7)

                        Text(client.name)
                            .font(.subheadline)
                            .foregroundColor(client.isConnected ? .primary : .secondary)

                        if client.isConnected {
                            Text("· \(client.computer)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if client.isConnected {
                            Text("\(client.connectionCount) conn\(client.connectionCount == 1 ? "" : "s")")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        } else {
                            Text("idle")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }

                    if client.isConnected && !client.activeDetails.isEmpty {
                        ForEach(client.activeDetails, id: \.self) { detail in
                            Text("↳ \(detail)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 15)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footerView: some View {
        HStack(spacing: 10) {
            Text("Updated \(snap.timestamp.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                onOpenReport()
            } label: {
                Label("Report", systemImage: "chart.bar.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)

            Button("Refresh") {
                store.refreshNow()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.top, 2)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }
}

private struct SlotRow: View {
    let slot: SlotInfo

    private var dotColor: Color {
        switch slot.phase {
        case .generating: return .green
        case .promptEval: return .orange
        case .starting: return .yellow
        case .idle: return .gray.opacity(0.4)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text("Slot \(slot.slotId)")
                    .font(.subheadline.weight(.medium))
                if let taskId = slot.taskId, slot.isProcessing {
                    Text("#\(taskId)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if slot.isProcessing {
                    Text(formatElapsed(slot.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                }
                Spacer()
                Text(speedLabel)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(slot.isProcessing ? .primary : .secondary)
            }

            if slot.isProcessing {
                if let owner = slot.owner {
                    Text(owner.displayLabel)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack {
                    Text(slot.phase.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if slot.phase == .promptEval {
                        Text("\(formatCompact(slot.nPromptProcessed)) / \(formatCompact(slot.nPromptTokens)) prompt")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(slot.nDecoded) gen · \(formatCompact(slot.nPromptProcessed + slot.nDecoded))/\(formatCompact(slot.nCtx)) ctx")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: slot.phase == .promptEval ? slot.promptProgress : slot.contextUsageRatio)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(7)
    }

    private var speedLabel: String {
        switch slot.phase {
        case .generating:
            return String(format: "%.1f t/s", slot.genTps)
        case .promptEval:
            return String(format: "%.0f pp/s", slot.promptTps)
        case .starting:
            return "starting…"
        case .idle:
            return "idle"
        }
    }
}

private func formatCompact(_ n: Int) -> String {
    if n >= 1000 {
        return String(format: "%.1fk", Double(n) / 1000.0)
    }
    return "\(n)"
}

private func formatElapsed(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let store = MonitorStore()
    private var reportController: ReportWindowController!
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        reportController = ReportWindowController(usageStore: store.usageStore)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Local LLM")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        let contentView = MonitorPopoverView(
            store: store,
            onOpenReport: { [weak self] in
                self?.panel.orderOut(nil)
                self?.reportController.show()
            },
            onQuit: { [weak self] in
                self?.store.usageStore.flush()
                NSApplication.shared.terminate(nil)
            }
        )

        let hosting = NSHostingController(rootView: contentView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let fxView = NSVisualEffectView()
        fxView.material = .popover
        fxView.state = .active
        fxView.wantsLayer = true
        fxView.layer?.cornerRadius = 12
        fxView.layer?.masksToBounds = true
        fxView.addSubview(hosting.view)

        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: fxView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: fxView.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: fxView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: fxView.trailingAnchor)
        ])

        let size = hosting.sizeThatFits(in: NSSize(width: 370, height: 800))
        let p = PinnedPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.contentView = fxView
        p.delegate = self
        self.panel = p

        cancellable = store.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.updateMenuBarTitle(snap)
            }

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.usageStore.flush()
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            panel.orderOut(nil)
        }
    }

    private func updateMenuBarTitle(_ snap: MonitorSnapshot) {
        guard let button = statusItem.button else { return }
        if !snap.ollamaOnline {
            button.title = " LLM offline"
            return
        }
        let sess = snap.activeSessionCount
        let qSuffix = snap.queuedTasks.isEmpty ? "" : " · \(snap.queuedTasks.count)q"
        if sess == 0 {
            button.title = " 0 sess\(qSuffix)"
        } else if snap.totalGenTps > 0 {
            button.title = String(format: " %d sess%@ · %.1f t/s", sess, qSuffix, snap.totalGenTps)
        } else if snap.totalPromptTps > 0 {
            button.title = String(format: " %d sess%@ · %.0f pp/s", sess, qSuffix, snap.totalPromptTps)
        } else {
            button.title = " \(sess) sess\(qSuffix)"
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        // Size and position once on open; stays pinned until closed and reopened
        let contentSize = panel.contentView?.fittingSize ?? NSSize(width: 370, height: 420)
        let buttonRectInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        var x = buttonRectInScreen.midX - contentSize.width / 2
        let y = buttonRectInScreen.minY - contentSize.height - 6

        if let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - contentSize.width - 8)
        }

        panel.setFrame(NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
