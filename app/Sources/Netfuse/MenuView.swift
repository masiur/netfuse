import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuView: View {
    private var monitor = AdapterMonitor.shared
    private var rules = RuleStore.shared
    @State private var apps: [AppEntry] = []
    @State private var isOn = EngineSwitch.isOn
    @State private var switchError: String?
    @State private var updateReady = EngineSwitch.updateReady

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(4)) {
            header
            if updateReady {
                banner("A new engine is ready", button: "Install update") { try EngineSwitch.installIfNeeded() }
            } else if notRunning {
                banner("The engine is not running", button: "Reinstall") { try EngineSwitch.installIfNeeded(force: true) }
            }
            section("Connections") { connections }
            if !routed.isEmpty { section("App routes") { routedList } }
            if let msg = Updater.shared.status {
                Text(msg).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
            }
            if let err = switchError ?? rules.lastError {
                Text(err).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
            }
            footer
        }
        .padding(Astryx.space(4))
        .frame(width: 380)
        .background(Astryx.Color.body)
        .task {
            while !Task.isCancelled {
                apps = listApps(rules: rules.rules, extra: [])
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            while !Task.isCancelled {
                isOn = EngineSwitch.isOn
                updateReady = EngineSwitch.updateReady
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var engine: EngineStatus? { monitor.engine }

    /// Opens the details window, scrolled to one adapter's card (nil: the top).
    private func showDetails(_ adapter: String?) {
        let menu = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra") }
        DetailsView.show(focus: adapter)
        menu?.close() // the menu would otherwise stay open over the window
    }

    // MARK: sections

    private var header: some View {
        // Top-aligned: a switch has no text baseline, and baseline alignment pushed it down.
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Astryx.space(0.5)) {
                Text("Netfuse").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
                Text("↓ \(speedText(monitor.totalRx))   ↑ \(speedText(monitor.totalTx))")
                    .font(Astryx.Font.supporting).monospacedDigit()
                    .foregroundStyle(Astryx.Color.textSecondary)
            }
            Spacer()
            HStack(alignment: .center, spacing: Astryx.space(2)) {
                state
                Toggle("Netfuse on", isOn: Binding(get: { isOn }, set: flip))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if let vpn = engine?.vpn {
            Badge(text: "Paused for VPN", tone: .neutral)
                .help("A VPN (\(vpn)) is connected, so all traffic goes through it. Netfuse resumes when it disconnects.")
        } else if engine != nil {
            Badge(text: "Combining", tone: .success)
        } else if !isOn {
            Badge(text: "Off", tone: .neutral).help("Rules are saved and apply when Netfuse is on.")
        } else if let since = EngineSwitch.onSince, Date().timeIntervalSince(since) > 15 {
            Badge(text: "Not running", tone: .error).help("The engine did not start. Its log: \(EngineSwitch.log)")
        } else {
            Badge(text: "Starting", tone: .neutral)
        }
    }

    /// Switched on, but the engine has not written its status for a while.
    private var notRunning: Bool {
        guard isOn, engine == nil, let since = EngineSwitch.onSince else { return false }
        return Date().timeIntervalSince(since) > 15
    }

    private func banner(_ text: String, button: String, action: @escaping () throws -> Void) -> some View {
        HStack(spacing: Astryx.space(2)) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Astryx.Color.textPrimary)
            Text(text).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
            Spacer()
            Button(button) {
                run(action)
            }
            .buttonStyle(AstryxButtonStyle(primary: true))
        }
        .padding(Astryx.space(3))
        .background(Astryx.Color.card, in: RoundedRectangle(cornerRadius: Astryx.Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Astryx.Radius.container).strokeBorder(Astryx.Color.border))
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            switchError = nil
        } catch let e as EngineSwitch.Failure {
            switchError = e.message
        } catch {
            switchError = error.localizedDescription
        }
        isOn = EngineSwitch.isOn
        updateReady = EngineSwitch.updateReady
    }

    private func flip(_ on: Bool) {
        run { try EngineSwitch.set(on) }
    }

    @ViewBuilder private var connections: some View {
        if monitor.adapters.isEmpty {
            emptyRow("No connections found")
        }
        let ids = monitor.adapters.map(\.id)
        let ordered = !rules.order.isEmpty
        if monitor.adapters.count > 1 {
            Picker("Mode", selection: Binding(get: { ordered }, set: { rules.setOrdered($0, ids: rules.sorted(ids)) })) {
                Text("Combine all").tag(false)
                Text("Priority order").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(Astryx.space(2))
            .help("Priority order: apps without a rule use the first connection while it works, then the next.")
            Divider().overlay(Astryx.Color.border)
        }
        if let rec = recommend(monitor.adapters, engine: engine),
           let best = monitor.adapters.first(where: { $0.id == rec.id }),
           !(ordered && rules.sorted(ids).first == rec.id) {
            RecommendationRow(name: best.name, reason: rec.reason) {
                rules.setOrdered(true, ids: [rec.id] + ids.filter { $0 != rec.id })
            }
            Divider().overlay(Astryx.Color.border)
        }
        let list = ordered ? rules.sorted(ids).compactMap { id in monitor.adapters.first { $0.id == id } } : monitor.adapters
        ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
            if i > 0 { Divider().overlay(Astryx.Color.border) }
            let off = rules.isDisabled(a.id)
            HStack(spacing: 0) {
                AdapterRow(adapter: a, link: engine?.link(a.id), note: off ? "Turned off in Netfuse" : nil,
                           rank: ordered ? i + 1 : nil)
                    .opacity(off ? 0.5 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture { showDetails(a.id) }
                    .help("Show details")
                Menu {
                    Button(off ? "Turn on" : "Turn off") { rules.setEnabled(off, a.id) }
                    if ordered {
                        Button("Move up") { rules.move(a.id, by: -1, ids: ids) }.disabled(i == 0)
                        Button("Move down") { rules.move(a.id, by: 1, ids: ids) }.disabled(i == list.count - 1)
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Astryx.Color.textSecondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, Astryx.space(3))
            }
        }
        if let phone = monitor.usbPhone {
            if !monitor.adapters.isEmpty { Divider().overlay(Astryx.Color.border) }
            AdapterRow(adapter: Adapter(id: "USB", name: phone, kind: .android),
                       note: isOn ? "Connecting… (is USB tethering on?)" : "Turn Netfuse on to use it")
        }
        if let iPhone = monitor.idleIPhone {
            Divider().overlay(Astryx.Color.border)
            IPhoneHint(name: iPhone)
        }
        let online = monitor.adapters.filter(monitor.isOnline).count
        if online == 1 && monitor.idleIPhone == nil {
            Divider().overlay(Astryx.Color.border)
            Text("Connect a second internet source to combine: Ethernet, or a phone over USB with Personal Hotspot or USB tethering on.")
                .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Astryx.space(3))
        }
    }

    /// Apps with a route of their own; the full list lives in the details window.
    private var routed: [AppEntry] { apps.filter { rules.policy(for: $0.name) != .combine } }

    private var routedList: some View {
        ForEach(Array(routed.enumerated()), id: \.element.id) { i, app in
            if i > 0 { Divider().overlay(Astryx.Color.border) }
            AppRow(app: app, policy: rules.policy(for: app.name), adapters: monitor.adapters,
                   live: engine?.flows(for: app.name) ?? []) {
                rules.set($0, for: app.name)
                apps = listApps(rules: rules.rules, extra: [])
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("App routes…") { showDetails(DetailsFocus.routes) }.buttonStyle(AstryxButtonStyle())
            Button("Details") { showDetails(nil) }.buttonStyle(AstryxButtonStyle())
            Spacer()
            Button { NSWorkspace.shared.open(URL(string: "https://github.com/masiur/netfuse/issues/new")!) } label: {
                Image(systemName: "exclamationmark.bubble")
            }
            .buttonStyle(AstryxButtonStyle()).help("Report an issue on GitHub")
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(AstryxButtonStyle())
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Astryx.space(2)) {
            Text(title.uppercased()).font(Astryx.Font.h6).tracking(0.6)
                .foregroundStyle(Astryx.Color.textSecondary)
                .padding(.leading, Astryx.space(1))
            Card { content() }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(Astryx.Font.body).foregroundStyle(Astryx.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Astryx.space(3))
    }

}

struct AdapterRow: View {
    var adapter: Adapter
    var link: EngineStatus.Link? // nil while the engine is off or not using this adapter
    var note: String? // in place of the address line
    var rank: Int? // place in the priority order

    /// An Android phone's adapter has no router macOS knows of: the engine drives it, and lists it.
    private var online: Bool { adapter.hasRouter || link != nil }

    var body: some View {
        HStack(spacing: Astryx.space(3)) {
            Image(systemName: adapter.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(online ? Astryx.Color.textPrimary : Astryx.Color.textDisabled)
                .frame(width: 36, height: 36)
                .background(Astryx.Color.muted, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Astryx.space(1.5)) {
                    Text(adapter.name).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                    Text(adapter.id).font(Astryx.Font.code).foregroundStyle(Astryx.Color.textSecondary)
                    if let rank { Badge(text: "#\(rank)", tone: rank == 1 ? .success : .neutral) }
                }
                Text(detail).lineLimit(1)
                    .font(Astryx.Font.supporting)
                    .foregroundStyle(link?.coolingDown == true ? Astryx.Color.textWarning : Astryx.Color.textSecondary)
                if note == nil, !specs.isEmpty {
                    Text(specs).lineLimit(1)
                        .font(Astryx.Font.supporting).monospacedDigit()
                        .foregroundStyle(Astryx.Color.textSecondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text("↓ " + speedText(adapter.rxBytesPerSec))
                Text("↑ " + speedText(adapter.txBytesPerSec))
            }
            .font(Astryx.Font.supporting).monospacedDigit()
            .foregroundStyle(Astryx.Color.textSecondary)
            .opacity(note == nil ? 1 : 0) // no traffic to show; kept for the row's height
            Circle().fill(!online ? Astryx.Color.textDisabled
                          : link?.coolingDown == true ? Astryx.Color.textWarning : Astryx.Color.success)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, Astryx.space(3))
        .padding(.vertical, Astryx.space(3.5))
    }

    /// Gateway, the driver's link rate, and what the engine measured it can carry.
    private var specs: String {
        var parts: [String] = []
        if let r = adapter.router { parts.append("via \(r)") }
        if adapter.linkSpeed > 0 { parts.append("link " + speedText(Double(adapter.linkSpeed) / 8)) }
        if let c = link?.capacity, c > 0 { parts.append("capacity ~" + speedText(c)) }
        return parts.joined(separator: " · ")
    }

    private var detail: String {
        if let note { return note }
        guard online else { return "No internet" }
        let ip = adapter.ipv4 ?? "IPv6 only"
        guard let link else { return ip }
        if link.coolingDown { return "\(ip) · link failed, retrying soon" }
        return "\(ip) · \(link.active) open"
    }
}

struct AppRow: View {
    var app: AppEntry
    var policy: Policy
    var adapters: [Adapter]
    var live: [(adapter: String, flows: Int)] // where its connections are open now, from the engine
    var onChange: (Policy) -> Void

    var body: some View {
        HStack(spacing: Astryx.space(3)) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(Astryx.Color.iconSecondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary).lineLimit(1)
                if !live.isEmpty {
                    Text(live.map { "\(name($0.adapter)) \($0.flows)" }.joined(separator: " · "))
                        .font(Astryx.Font.supporting).monospacedDigit()
                        .foregroundStyle(Astryx.Color.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: Astryx.space(2))
            Menu {
                Button("All connections (combine)") { onChange(.combine) }
                Section("Only this connection") {
                    ForEach(adapters) { a in Button(a.name) { onChange(.only(a.id)) } }
                }
                Section("Prefer, fall back to the others") {
                    ForEach(adapters) { a in Button(a.name) { onChange(.prefer(a.id)) } }
                }
            } label: {
                HStack(spacing: Astryx.space(1)) {
                    Text(label).font(Astryx.Font.supporting.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(isDefault ? Astryx.Color.textSecondary : Astryx.Color.textPrimary)
            }
            .menuStyle(.button)
            .buttonStyle(AstryxButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, Astryx.space(3))
        .frame(height: Self.height)
    }

    static let height: CGFloat = 44

    private var isDefault: Bool { policy == .combine }

    private func name(_ id: String) -> String { adapters.first { $0.id == id }?.name ?? id }

    private var label: String { policy.text(name) }
}

/// An iPhone is plugged in but gives no internet. macOS keeps "iPhone USB" down unless nothing else
/// is online ("Disable unless needed"), which is never the case while combining; only the user
/// can switch that off, in Network settings.
private struct IPhoneHint: View {
    var name: String

    var body: some View {
        HStack(alignment: .top, spacing: Astryx.space(3)) {
            Image(systemName: "iphone")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Astryx.Color.textDisabled)
                .frame(width: 28, height: 28)
                .background(Astryx.Color.muted, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
            VStack(alignment: .leading, spacing: Astryx.space(2)) {
                Text("\(name) is connected but not sharing internet")
                    .font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                Text("Turn on Personal Hotspot on the iPhone. Then in Network settings, open \(name), click Details… and turn off “Disable unless needed”.")
                    .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Network Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                }
                .buttonStyle(AstryxButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Astryx.space(3))
    }
}

/// "Ethernet is the better connection" with a button that puts it first in the priority order.
struct RecommendationRow: View {
    var name: String
    var reason: String
    var apply: () -> Void

    var body: some View {
        HStack(spacing: Astryx.space(3)) {
            Image(systemName: "sparkles").foregroundStyle(Astryx.Color.success).frame(width: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Best: \(name)").font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                Text(reason).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Astryx.space(2))
            Button("Use first", action: apply).buttonStyle(AstryxButtonStyle(primary: true))
                .help("Priority order with \(name) first: apps without a rule use it while it works, then the others.")
        }
        .padding(Astryx.space(3))
    }
}
