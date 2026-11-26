import AppKit
import Charts
import SwiftUI

/// Which adapter the details window should scroll to (set by a click in the menu).
@MainActor @Observable
final class DetailsFocus {
    static let shared = DetailsFocus()
    var adapter: String?
}

/// Every connection in detail: traffic over the last ten minutes, addresses, ISP, and the apps
/// the engine has on it.
struct DetailsView: View {
    private static var window: NSWindow?

    /// Opens (or brings forward) the details window, scrolled to `focus`. An AppKit window rather
    /// than a SwiftUI Window scene, which would open at launch and quit the app when closed.
    static func show(focus adapter: String?) {
        DetailsFocus.shared.adapter = adapter
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DetailsView()))
            w.title = "Nethance Connections"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 680, height: 860))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var monitor = AdapterMonitor.shared
    private var focus = DetailsFocus.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Astryx.space(4)) {
                    summary
                    if monitor.adapters.isEmpty {
                        Card {
                            Text("No connections found").font(Astryx.Font.body).foregroundStyle(Astryx.Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(Astryx.space(4))
                        }
                    }
                    ForEach(monitor.adapters) { a in
                        AdapterCard(adapter: a, monitor: monitor).id(a.id)
                    }
                }
                .padding(Astryx.space(5))
            }
            .onAppear { scroll(proxy) }
            .onChange(of: focus.adapter) { scroll(proxy) }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Astryx.Color.body)
        .task {
            while !Task.isCancelled {
                monitor.refreshPublicInfo()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = focus.adapter else { return }
        withAnimation { proxy.scrollTo(id, anchor: .top) }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Astryx.space(1)) {
                Text("Connections").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
                Text("\(monitor.adapters.filter(monitor.isOnline).count) online · last 10 minutes")
                    .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            }
            Spacer()
            Rate(symbol: "arrow.down", value: monitor.totalRx, color: Astryx.Color.download, large: true)
            Rate(symbol: "arrow.up", value: monitor.totalTx, color: Astryx.Color.upload, large: true)
        }
    }
}

private struct AdapterCard: View {
    var adapter: Adapter
    var monitor: AdapterMonitor

    var body: some View {
        let online = monitor.isOnline(adapter)
        let pub = monitor.publicInfo[adapter.id]
        Card {
            VStack(alignment: .leading, spacing: Astryx.space(4)) {
                HStack(spacing: Astryx.space(3)) {
                    Image(systemName: adapter.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(online ? Astryx.Color.textPrimary : Astryx.Color.textDisabled)
                        .frame(width: 36, height: 36)
                        .background(Astryx.Color.muted, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Astryx.space(1.5)) {
                            Text(adapter.name).font(Astryx.Font.large).foregroundStyle(Astryx.Color.textPrimary)
                            Text(adapter.id).font(Astryx.Font.code).foregroundStyle(Astryx.Color.textSecondary)
                        }
                        Text(pub.map { "\($0.isp) · \($0.place)" } ?? (online ? "Looking up provider…" : "No internet"))
                            .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Badge(text: online ? "Online" : "Offline", tone: online ? .success : .neutral)
                }
                HStack(spacing: Astryx.space(4)) {
                    Rate(symbol: "arrow.down", value: adapter.rxBytesPerSec, color: Astryx.Color.download)
                    Rate(symbol: "arrow.up", value: adapter.txBytesPerSec, color: Astryx.Color.upload)
                }
                TrafficChart(samples: monitor.history[adapter.id] ?? [])
                Grid(alignment: .leading, horizontalSpacing: Astryx.space(4), verticalSpacing: Astryx.space(2)) {
                    GridRow {
                        Field("Public IP", pub?.ip)
                        Field("Local IP", adapter.ipv4)
                    }
                    GridRow {
                        Field("Provider", pub?.isp)
                        Field("Router", adapter.router ?? monitor.engine?.link(adapter.id).map { _ in "Through the engine" })
                    }
                    GridRow {
                        Field("Location", pub?.place)
                        Field("MAC address", adapter.mac)
                    }
                    GridRow {
                        Field("Since app start", monitor.totals[adapter.id].map {
                            "↓ \(bytesText($0.rx))   ↑ \(bytesText($0.tx))"
                        })
                        Field("Link speed", adapter.linkSpeed > 0 ? "\(adapter.linkSpeed / 1_000_000) Mbit/s" : nil)
                    }
                }
                AppsOnLink(adapter: adapter.id, engine: monitor.engine)
            }
            .padding(Astryx.space(4))
        }
    }
}

/// Download above the line, upload below it, both in Mbit/s on one scale; hover for values.
private struct TrafficChart: View {
    var samples: [Sample]
    @State private var hover: Date?

    var body: some View {
        let now = samples.last?.time ?? Date()
        Chart {
            ForEach(samples, id: \.time) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Mbit/s", mbit(s.rx)), series: .value("Direction", "Download"))
                    .foregroundStyle(by: .value("Direction", "Download"))
                AreaMark(x: .value("Time", s.time), y: .value("Mbit/s", -mbit(s.tx)), series: .value("Direction", "Upload"))
                    .foregroundStyle(by: .value("Direction", "Upload"))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(Astryx.Color.border).lineStyle(StrokeStyle(lineWidth: 1))
            if let s = nearest(hover) {
                RuleMark(x: .value("Time", s.time))
                    .foregroundStyle(Astryx.Color.textSecondary.opacity(0.5))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(s)
                    }
            }
        }
        .chartForegroundStyleScale(["Download": Astryx.Color.download, "Upload": Astryx.Color.upload])
        .chartLegend(position: .top, alignment: .leading, spacing: Astryx.space(2))
        .chartXScale(domain: now.addingTimeInterval(-Double(AdapterMonitor.historyLength))...now)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                AxisGridLine().foregroundStyle(Astryx.Color.border)
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Astryx.Color.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Astryx.Color.border)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(shortMbit(abs(d))).foregroundStyle(Astryx.Color.textSecondary) }
                }
            }
        }
        .chartXSelection(value: $hover)
        .frame(height: 150)
        .overlay {
            if samples.count < 2 {
                Text("Collecting…").font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            }
        }
    }

    private func nearest(_ t: Date?) -> Sample? {
        guard let t else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }
    }

    private func tooltip(_ s: Sample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.time.formatted(date: .omitted, time: .standard)).foregroundStyle(Astryx.Color.textSecondary)
            Text("↓ \(speedText(s.rx))   ↑ \(speedText(s.tx))").foregroundStyle(Astryx.Color.textPrimary)
        }
        .font(Astryx.Font.supporting).monospacedDigit()
        .padding(.horizontal, Astryx.space(2)).padding(.vertical, Astryx.space(1))
        .background(Astryx.Color.card, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
        .overlay(RoundedRectangle(cornerRadius: Astryx.Radius.inner).strokeBorder(Astryx.Color.border))
    }
}

/// The apps the engine has open connections for on this adapter, busiest first.
private struct AppsOnLink: View {
    var adapter: String
    var engine: EngineStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(2)) {
            Text("APPS ON THIS CONNECTION").font(Astryx.Font.h6).tracking(0.6).foregroundStyle(Astryx.Color.textSecondary)
            if let engine {
                let apps = engine.apps.filter { $0.adapter == adapter }.sorted { $0.flows > $1.flows }
                if apps.isEmpty {
                    note("None right now")
                } else {
                    let icons = runningIcons()
                    ForEach(apps.prefix(8), id: \.app) { f in
                        HStack(spacing: Astryx.space(2)) {
                            Group {
                                if let icon = icons[f.app] ?? installedIcon(f.app) { Image(nsImage: icon).resizable() }
                                else { Image(systemName: "terminal").foregroundStyle(Astryx.Color.iconSecondary) }
                            }
                            .frame(width: 18, height: 18)
                            Text(f.app.isEmpty ? "Unknown app" : f.app).font(Astryx.Font.body).foregroundStyle(Astryx.Color.textPrimary)
                            Spacer()
                            Text("\(f.flows) open").font(Astryx.Font.supporting).monospacedDigit().foregroundStyle(Astryx.Color.textSecondary)
                        }
                    }
                }
            } else {
                note("Turn Nethance on to see which apps use this connection")
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
    }

    /// Apps whose network work runs in a helper or daemon are often not "running" as such.
    private func installedIcon(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "\(home)/Applications"].map { "\($0)/\(name).app" }
            .first(where: FileManager.default.fileExists(atPath:))
            .map(NSWorkspace.shared.icon(forFile:))
    }

    private func runningIcons() -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL, let icon = app.icon else { continue }
            out[appName(forPath: url.path)] = out[appName(forPath: url.path)] ?? icon
        }
        return out
    }
}

private struct Field: View {
    var label: String
    var value: String?
    init(_ label: String, _ value: String?) { self.label = label; self.value = value }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            Text(value ?? "—").font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                .textSelection(.enabled).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A live rate with its series colour as a small mark (text stays in text colours).
private struct Rate: View {
    var symbol: String
    var value: Double
    var color: SwiftUI.Color
    var large = false

    var body: some View {
        HStack(spacing: Astryx.space(1)) {
            Image(systemName: symbol).font(.system(size: large ? 13 : 11, weight: .bold)).foregroundStyle(color)
            Text(speedText(value)).font(large ? Astryx.Font.large : Astryx.Font.label).monospacedDigit()
                .foregroundStyle(Astryx.Color.textPrimary)
        }
    }
}

private func mbit(_ bytesPerSec: Double) -> Double { bytesPerSec * 8 / 1_000_000 }

private func shortMbit(_ v: Double) -> String {
    v == 0 ? "0" : v < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
}

func bytesText(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
