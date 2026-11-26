import ServiceManagement
import UniformTypeIdentifiers
import AppKit
import Charts
import SwiftUI

/// What the details window shows: the overview, or one adapter (by BSD name).
@MainActor @Observable
final class DetailsFocus {
    static let shared = DetailsFocus()
    static let overview = "overview"
    static let routes = "routes" // the app routes page
    static let settings = "settings"
    static let latency = "latency"
    var selection: String = overview
}

/// The details window: a sidebar of connections, and for the selection its last ten minutes of
/// traffic, addresses and interface; the overview adds every app's connections across links.
struct DetailsView: View {
    private static var window: NSWindow?

    /// Opens (or brings forward) the window on `adapter` (nil: the overview). An AppKit window
    /// rather than a SwiftUI Window scene, which would open at launch and quit the app when closed.
    static func show(focus adapter: String?) {
        DetailsFocus.shared.selection = adapter ?? DetailsFocus.overview
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DetailsView()))
            w.title = "Netfuse"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 940, height: 680))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var monitor = AdapterMonitor.shared
    @Bindable private var focus = DetailsFocus.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $focus.selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(DetailsFocus.overview)
                Label("App routes", systemImage: "arrow.triangle.branch").tag(DetailsFocus.routes)
                Label("Latency test", systemImage: "stopwatch").tag(DetailsFocus.latency)
                Label("Settings", systemImage: "gearshape").tag(DetailsFocus.settings)
                Section("Connections") {
                    ForEach(monitor.adapters) { a in
                        SidebarRow(adapter: a, online: monitor.isOnline(a)).tag(a.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            ScrollView {
                Group {
                    if focus.selection == DetailsFocus.latency {
                        LatencyPage(monitor: monitor)
                    } else if focus.selection == DetailsFocus.settings {
                        SettingsPage()
                    } else if focus.selection == DetailsFocus.routes {
                        AppRoutesPage(monitor: monitor)
                    } else if let a = monitor.adapters.first(where: { $0.id == focus.selection }) {
                        AdapterPage(adapter: a, monitor: monitor)
                    } else {
                        OverviewPage(monitor: monitor)
                    }
                }
                .padding(Astryx.space(6))
                .frame(maxWidth: 900, alignment: .leading)
            }
            .background(Astryx.Color.body)
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            while !Task.isCancelled {
                monitor.refreshPublicInfo()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

private struct SidebarRow: View {
    var adapter: Adapter
    var online: Bool

    var body: some View {
        HStack(spacing: Astryx.space(2)) {
            Image(systemName: adapter.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(adapter.name).lineLimit(1)
                Text("↓ \(speedText(adapter.rxBytesPerSec))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(online ? Astryx.Color.success : Astryx.Color.textDisabled).frame(width: 7, height: 7)
        }
    }
}

// MARK: settings

private struct SettingsPage: View {
    private var rules = RuleStore.shared
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @AppStorage("alertDrops") private var alertDrops = true

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(5)) {
            Text("Settings").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
            TitledCard("VPN") {
                VStack(alignment: .leading, spacing: Astryx.space(2)) {
                    Picker("When a VPN connects", selection: Binding(get: { rules.keepWithVPN }, set: rules.setKeepWithVPN)) {
                        Text("Pause Netfuse").tag(false)
                        Text("Keep combining").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    Text((rules.keepWithVPN
                         ? "Traffic is combined across your connections and does not go through the VPN."
                         : "All traffic goes through the VPN. Netfuse resumes when it disconnects. Recommended.")
                         + " Apps you send through the VPN in App routes keep Netfuse running beside it.")
                        .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                }
                .padding(Astryx.space(4))
            }
            TitledCard("General") {
                VStack(alignment: .leading, spacing: Astryx.space(2)) {
                    Toggle("Open Netfuse at login", isOn: Binding(get: { atLogin }, set: setLogin))
                    Toggle("Alert when a connection drops or comes back", isOn: $alertDrops)
                    if let error {
                        Text(error).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
                    }
                }
                .padding(Astryx.space(4))
            }
            TitledCard("Network") {
                HStack(spacing: Astryx.space(2)) {
                    Button("Flush DNS cache") {
                        run { try EngineSwitch.asAdmin(["/bin/sh", "-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"],
                                                       prompt: "Netfuse will clear the DNS cache.") }
                    }
                    .help("Forgets cached website addresses. Helps when a site moved or will not load.")
                    Button("Network Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                    }
                    Spacer()
                }
                .buttonStyle(AstryxButtonStyle())
                .padding(Astryx.space(4))
            }
            TitledCard("Help") {
                HStack(spacing: Astryx.space(2)) {
                    Button("Report an issue…") { NSWorkspace.shared.open(Self.repo.appending(path: "issues/new")) }
                    Button("Project on GitHub") { NSWorkspace.shared.open(Self.repo) }
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                }
                .buttonStyle(AstryxButtonStyle())
                .padding(Astryx.space(4))
            }
            TitledCard("Remove") {
                HStack(spacing: Astryx.space(2)) {
                    Text("Stops Netfuse and removes its routing engine from this Mac. Your app routes are kept.")
                        .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                    Spacer()
                    Button("Uninstall engine…") { run(EngineSwitch.uninstall) }
                }
                .buttonStyle(AstryxButtonStyle())
                .padding(Astryx.space(4))
            }
            if let error {
                Text(error).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
            }
        }
    }

    static let repo = URL(string: "https://github.com/masiur/netfuse")!

    private func run(_ f: () throws -> Void) {
        do { try f(); error = nil } catch let e as EngineSwitch.Failure { error = e.message } catch { self.error = error.localizedDescription }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: app routes

/// Every open app (and any added by hand) with the connection it may use. Moved here from the
/// menu, which stays small.
private struct AppRoutesPage: View {
    var monitor: AdapterMonitor
    private var rules = RuleStore.shared
    @State private var extra: [URL] = []
    @State private var apps: [AppEntry] = []

    init(monitor: AdapterMonitor) { self.monitor = monitor }

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(5)) {
            HStack(alignment: .center) {
                PageHeader(symbol: "arrow.triangle.branch", title: "App routes",
                           subtitle: "Choose which connection each app may use, including your VPN. Others combine all.",
                           rx: monitor.totalRx, tx: monitor.totalTx)
            }
            TitledCard("Apps") {
                if apps.isEmpty {
                    Text("No apps open").font(Astryx.Font.body).foregroundStyle(Astryx.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Astryx.space(4))
                }
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    if i > 0 { Divider().overlay(Astryx.Color.border) }
                    AppRow(app: app, policy: rules.policy(for: app.name), adapters: monitor.adapters,
                           live: monitor.engine?.flows(for: app.name) ?? []) {
                        rules.set($0, for: app.name)
                        reload()
                    }
                }
            }
            HStack {
                Button("Add app…", action: add).buttonStyle(AstryxButtonStyle())
                if let err = rules.lastError {
                    Text(err).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func reload() { apps = listApps(rules: rules.rules, extra: extra) }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        extra += panel.urls
        reload()
    }
}

// MARK: overview

private struct OverviewPage: View {
    var monitor: AdapterMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(5)) {
            PageHeader(symbol: "point.3.connected.trianglepath.dotted", title: "All connections",
                       subtitle: "\(monitor.adapters.filter(monitor.isOnline).count) online · " + engineState,
                       rx: monitor.totalRx, tx: monitor.totalTx)
            if let rec = recommend(monitor.adapters, engine: monitor.engine),
               let best = monitor.adapters.first(where: { $0.id == rec.id }) {
                TitledCard("Recommendation") {
                    RecommendationRow(name: best.name, reason: rec.reason) {
                        let ids = monitor.adapters.map(\.id)
                        RuleStore.shared.setOrdered(true, ids: [rec.id] + ids.filter { $0 != rec.id })
                    }
                }
            }
            TitledCard("Traffic · last 10 minutes") { TrafficChart(samples: combined).padding(Astryx.space(4)) }
            TitledCard("Connections") {
                ForEach(Array(monitor.adapters.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider().overlay(Astryx.Color.border) }
                    ConnectionRow(adapter: a, monitor: monitor)
                }
            }
            TitledCard("Apps") { AppsTable(monitor: monitor) }
        }
    }

    private var engineState: String {
        monitor.engine != nil ? "Netfuse is combining them" : "Netfuse is off"
    }

    /// All adapters' samples added up per second.
    private var combined: [Sample] {
        var byTime: [Int: Sample] = [:]
        for samples in monitor.history.values {
            for s in samples {
                let k = Int(s.time.timeIntervalSince1970)
                var c = byTime[k] ?? Sample(time: Date(timeIntervalSince1970: Double(k)), rx: 0, tx: 0)
                c.rx += s.rx
                c.tx += s.tx
                byTime[k] = c
            }
        }
        return byTime.values.sorted { $0.time < $1.time }
    }
}

private struct ConnectionRow: View {
    var adapter: Adapter
    var monitor: AdapterMonitor

    var body: some View {
        let pub = monitor.publicInfo[adapter.id]
        HStack(spacing: Astryx.space(3)) {
            Image(systemName: adapter.symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(Astryx.Color.textPrimary)
                .frame(width: 28, height: 28)
                .background(Astryx.Color.muted, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
            VStack(alignment: .leading, spacing: 0) {
                Text(adapter.name).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                Text(pub.map { "\($0.isp) · \($0.ip)" } ?? (monitor.isOnline(adapter) ? "Looking up provider…" : "No internet"))
                    .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary).lineLimit(1)
            }
            Spacer()
            if let link = monitor.engine?.link(adapter.id) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(link.capacity.map { "~" + speedText($0) } ?? "").font(Astryx.Font.label).monospacedDigit()
                        .foregroundStyle(Astryx.Color.textPrimary)
                    Text("\(link.active) open · \(monitor.engine?.share(adapter.id).map { "\(Int(($0 * 100).rounded())) %" } ?? "–")")
                        .font(Astryx.Font.supporting).monospacedDigit().foregroundStyle(Astryx.Color.textSecondary)
                }
                .help("Estimated speed, open connections, and the share of new connections it gets")
            }
            Rate(symbol: "arrow.down", value: adapter.rxBytesPerSec, color: Astryx.Color.download).frame(width: 120, alignment: .trailing)
            Rate(symbol: "arrow.up", value: adapter.txBytesPerSec, color: Astryx.Color.upload).frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, Astryx.space(4)).padding(.vertical, Astryx.space(2.5))
        .contentShape(Rectangle())
        .onTapGesture { DetailsFocus.shared.selection = adapter.id }
    }
}

/// Every app the engine has connections for, with where they are open: one list for all links.
private struct AppsTable: View {
    var monitor: AdapterMonitor

    var body: some View {
        if let engine = monitor.engine {
            let rows = Dictionary(grouping: engine.apps, by: \.app)
                .map { (app: $0.key, flows: $0.value.sorted { $0.flows > $1.flows }) }
                .sorted { total($0.flows) > total($1.flows) }
            if rows.isEmpty {
                note("No app has a connection open right now")
            } else {
                let icons = runningIcons()
                ForEach(Array(rows.prefix(20).enumerated()), id: \.element.app) { i, r in
                    if i > 0 { Divider().overlay(Astryx.Color.border) }
                    HStack(spacing: Astryx.space(3)) {
                        Group {
                            if let icon = icons[r.app] ?? installedIcon(r.app) { Image(nsImage: icon).resizable() }
                            else { Image(systemName: "terminal").foregroundStyle(Astryx.Color.iconSecondary) }
                        }
                        .frame(width: 20, height: 20)
                        Text(r.app.isEmpty ? "Virtual machines & system" : r.app).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                            .help(r.app.isEmpty ? "Traffic no app on this Mac owns: virtual machines and Internet Sharing (the system forwards it), or connections that closed before Netfuse looked." : "")
                        if case let rule = RuleStore.shared.policy(for: r.app), rule != .combine {
                            Badge(text: rule.text(name), tone: .neutral)
                        }
                        Spacer()
                        Text(r.flows.map { "\(name($0.adapter)) \($0.flows)" }.joined(separator: " · "))
                            .font(Astryx.Font.supporting).monospacedDigit().foregroundStyle(Astryx.Color.textSecondary)
                        Text("\(total(r.flows))").font(Astryx.Font.label).monospacedDigit()
                            .foregroundStyle(Astryx.Color.textPrimary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, Astryx.space(4)).padding(.vertical, Astryx.space(2))
                }
            }
        } else {
            note("Turn Netfuse on to see which apps use which connection")
        }
    }

    private func total(_ f: [EngineStatus.Flows]) -> Int { f.reduce(0) { $0 + $1.flows } }
    private func name(_ id: String) -> String { monitor.adapters.first { $0.id == id }?.name ?? (id == vpnID ? "VPN" : id) }

    private func note(_ s: String) -> some View {
        Text(s).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Astryx.space(4))
    }
}

// MARK: one adapter

private struct AdapterPage: View {
    var adapter: Adapter
    var monitor: AdapterMonitor
    @State private var error: String?

    private func act(_ f: () throws -> Void) {
        do { try f(); error = nil } catch let e as EngineSwitch.Failure { error = e.message } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        let online = monitor.isOnline(adapter)
        let pub = monitor.publicInfo[adapter.id]
        VStack(alignment: .leading, spacing: Astryx.space(5)) {
            PageHeader(symbol: adapter.symbol, title: adapter.name,
                       subtitle: pub.map { "\($0.isp) · \($0.place)" } ?? (online ? "Looking up provider…" : "No internet"),
                       rx: adapter.rxBytesPerSec, tx: adapter.txBytesPerSec, online: online)
            TitledCard("Traffic · last 10 minutes") {
                TrafficChart(samples: monitor.history[adapter.id] ?? []).padding(Astryx.space(4))
            }
            HStack(alignment: .top, spacing: Astryx.space(4)) {
                TitledCard("Address") {
                    KeyValue("Public IP", pub?.ip)
                    KeyValue("Provider", pub?.isp)
                    KeyValue("Location", pub?.place)
                    KeyValue("Local IP", adapter.ipv4)
                    KeyValue("Router", adapter.router ?? monitor.engine?.link(adapter.id).map { _ in "Through the engine" }, last: true)
                }
                TitledCard("Interface") {
                    KeyValue("Device", adapter.id)
                    KeyValue("MAC address", adapter.mac)
                    KeyValue("Link speed", adapter.linkSpeed > 0 ? "\(adapter.linkSpeed / 1_000_000) Mbit/s" : nil)
                    KeyValue("Open connections", monitor.engine?.link(adapter.id).map { "\($0.active)" })
                    KeyValue("Estimated speed", monitor.engine?.link(adapter.id)?.capacity.map(speedText))
                    KeyValue("Share of new connections", monitor.engine?.share(adapter.id).map { "\(Int(($0 * 100).rounded())) %" })
                    KeyValue("Since app start", monitor.totals[adapter.id].map { "↓ \(bytesText($0.rx))  ↑ \(bytesText($0.tx))" }, last: true)
                }
            }
            TitledCard("Manage") {
                HStack(spacing: Astryx.space(2)) {
                    if adapter.router != nil {
                        Button("Renew address") {
                            act { try EngineSwitch.asAdmin(["/usr/sbin/ipconfig", "set", adapter.id, "DHCP"],
                                                           prompt: "Netfuse will ask \(adapter.name) for a new address.") }
                        }
                        .help("Asks the router for a new address (DHCP). Fixes most \"connected but no internet\" cases.")
                    }
                    if adapter.kind == .wifi {
                        Button("Turn Wi-Fi off") {
                            act { try shell("/usr/sbin/networksetup", "-setairportpower", adapter.id, "off") }
                        }
                    }
                    Button("Network Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                    }
                    Spacer()
                    if let error {
                        Text(error).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
                    }
                }
                .buttonStyle(AstryxButtonStyle())
                .padding(Astryx.space(4))
            }
        }
    }
}

// MARK: building blocks

private struct PageHeader: View {
    var symbol: String
    var title: String
    var subtitle: String
    var rx: Double
    var tx: Double
    var online: Bool? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Astryx.space(3)) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Astryx.Color.textPrimary)
                .frame(width: 44, height: 44)
                .background(Astryx.Color.card, in: RoundedRectangle(cornerRadius: Astryx.Radius.element))
                .overlay(RoundedRectangle(cornerRadius: Astryx.Radius.element).strokeBorder(Astryx.Color.border))
            VStack(alignment: .leading, spacing: Astryx.space(0.5)) {
                HStack(spacing: Astryx.space(2)) {
                    Text(title).font(Astryx.Font.figtree(22, .semibold)).foregroundStyle(Astryx.Color.textPrimary)
                    if let online { Badge(text: online ? "Online" : "Offline", tone: online ? .success : .neutral) }
                }
                Text(subtitle).font(Astryx.Font.body).foregroundStyle(Astryx.Color.textSecondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: Astryx.space(6)) {
                Hero(label: "Download", value: rx, color: Astryx.Color.download)
                Hero(label: "Upload", value: tx, color: Astryx.Color.upload)
            }
        }
    }
}

private struct Hero: View {
    var label: String
    var value: Double
    var color: SwiftUI.Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(speedText(value)).font(Astryx.Font.figtree(20, .semibold)).monospacedDigit().foregroundStyle(Astryx.Color.textPrimary)
            HStack(spacing: Astryx.space(1)) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            }
        }
    }
}

/// A titled card, like the menu's sections.
struct TitledCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(2)) {
            Text(title.uppercased()).font(Astryx.Font.h6).tracking(0.6).foregroundStyle(Astryx.Color.textSecondary)
                .padding(.leading, Astryx.space(1))
            Card { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyValue: View {
    var key: String
    var value: String?
    var last = false
    init(_ key: String, _ value: String?, last: Bool = false) { self.key = key; self.value = value; self.last = last }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(key).font(Astryx.Font.body).foregroundStyle(Astryx.Color.textSecondary)
                Spacer(minLength: Astryx.space(3))
                Text(value ?? "—").font(Astryx.Font.label).monospacedDigit().foregroundStyle(Astryx.Color.textPrimary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(.horizontal, Astryx.space(4)).padding(.vertical, Astryx.space(2.5))
            if !last { Divider().overlay(Astryx.Color.border).padding(.leading, Astryx.space(4)) }
        }
    }
}

@MainActor private func runningIcons() -> [String: NSImage] {
    var out: [String: NSImage] = [:]
    for app in NSWorkspace.shared.runningApplications {
        guard let url = app.bundleURL, let icon = app.icon else { continue }
        out[appName(forPath: url.path)] = out[appName(forPath: url.path)] ?? icon
    }
    return out
}

/// Apps whose network work runs in a helper or daemon are often not "running" as such.
private func installedIcon(_ name: String) -> NSImage? {
    guard !name.isEmpty else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/Applications", "\(home)/Applications", "/System/Applications"].map { "\($0)/\(name).app" }
        .first(where: FileManager.default.fileExists(atPath:))
        .map(NSWorkspace.shared.icon(forFile:))
}

/// Download above the line, upload below it, both in Mbit/s on one scale; hover for values.
private struct TrafficChart: View {
    var samples: [Sample]
    @State private var hover: Date?

    var body: some View {
        let now = samples.last?.time ?? Date()
        // One scale for both directions, centred on zero so the halves compare at a glance.
        let peak = max(samples.map { max(mbit($0.rx), mbit($0.tx)) }.max() ?? 0, 0.1) * 1.1
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
        .chartYScale(domain: -peak...peak)
        .chartYAxisLabel("Mbit/s", position: .leading)
        .chartXSelection(value: $hover)
        .frame(height: 200)
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

/// Runs a command as the user; throws its error output if it fails.
func shell(_ path: String, _ args: String...) throws {
    let p = Process()
    p.executableURL = URL(filePath: path)
    p.arguments = args
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        throw EngineSwitch.Failure(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
