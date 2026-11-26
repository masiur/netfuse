import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuView: View {
    private var monitor = AdapterMonitor.shared
    private var rules = RuleStore.shared
    @State private var extraApps: [URL] = []
    @State private var apps: [AppEntry] = []
    @State private var isOn = EngineSwitch.isOn
    @State private var switchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(4)) {
            header
            section("Connections") { connections }
            section("Apps") { appList }
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
                apps = listApps(rules: rules.rules, extra: extraApps)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            while !Task.isCancelled {
                isOn = EngineSwitch.isOn
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
                Text("Nethance").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
                Text("↓ \(speedText(monitor.totalRx))   ↑ \(speedText(monitor.totalTx))")
                    .font(Astryx.Font.supporting).monospacedDigit()
                    .foregroundStyle(Astryx.Color.textSecondary)
            }
            Spacer()
            HStack(alignment: .center, spacing: Astryx.space(2)) {
                state
                Toggle("Nethance on", isOn: Binding(get: { isOn }, set: flip))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var state: some View {
        if engine != nil {
            Badge(text: "Combining", tone: .success)
        } else if !isOn {
            Badge(text: "Off", tone: .neutral).help("Rules are saved and apply when Nethance is on.")
        } else if let since = EngineSwitch.onSince, Date().timeIntervalSince(since) > 15 {
            Badge(text: "Not running", tone: .error).help("The engine did not start. Its log: \(EngineSwitch.log)")
        } else {
            Badge(text: "Starting", tone: .neutral)
        }
    }

    private func flip(_ on: Bool) {
        do {
            try EngineSwitch.set(on)
            switchError = nil
        } catch let e as EngineSwitch.Failure {
            switchError = e.message
        } catch {
            switchError = error.localizedDescription
        }
        isOn = EngineSwitch.isOn
    }

    @ViewBuilder private var connections: some View {
        if monitor.adapters.isEmpty {
            emptyRow("No connections found")
        }
        ForEach(Array(monitor.adapters.enumerated()), id: \.element.id) { i, a in
            if i > 0 { Divider().overlay(Astryx.Color.border) }
            AdapterRow(adapter: a, link: engine?.link(a.id))
                .contentShape(Rectangle())
                .onTapGesture { showDetails(a.id) }
                .help("Show details")
        }
        let online = monitor.adapters.filter(monitor.isOnline).count
        if online == 1 {
            Divider().overlay(Astryx.Color.border)
            Text("Connect a second internet source to combine: Ethernet, or a phone over USB with Personal Hotspot or USB tethering on.")
                .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Astryx.space(3))
        }
    }

    @ViewBuilder private var appList: some View {
        if apps.isEmpty {
            emptyRow("No apps open")
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    if i > 0 { Divider().overlay(Astryx.Color.border) }
                    AppRow(app: app, policy: rules.policy(for: app.name), adapters: monitor.adapters,
                           live: engine?.flows(for: app.name) ?? []) {
                        rules.set($0, for: app.name)
                        apps = listApps(rules: rules.rules, extra: extraApps)
                    }
                }
            }
            // Rows have a fixed height, so the list can be sized exactly: up to 7 rows, then it scrolls.
            ScrollView { rows }
                .frame(height: CGFloat(min(apps.count, 7)) * (AppRow.height + 1) - 1)
                .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var footer: some View {
        HStack {
            Button("Add app…", action: addApp).buttonStyle(AstryxButtonStyle())
            Button("Details") { showDetails(nil) }.buttonStyle(AstryxButtonStyle())
            Spacer()
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

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        extraApps += panel.urls
        apps = listApps(rules: rules.rules, extra: extraApps)
    }
}

struct AdapterRow: View {
    var adapter: Adapter
    var link: EngineStatus.Link? // nil while the engine is off or not using this adapter

    /// An Android phone's adapter has no router macOS knows of: the engine drives it, and lists it.
    private var online: Bool { adapter.hasRouter || link != nil }

    var body: some View {
        HStack(spacing: Astryx.space(3)) {
            Image(systemName: adapter.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(online ? Astryx.Color.textPrimary : Astryx.Color.textDisabled)
                .frame(width: 28, height: 28)
                .background(Astryx.Color.muted, in: RoundedRectangle(cornerRadius: Astryx.Radius.inner))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Astryx.space(1.5)) {
                    Text(adapter.name).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                    Text(adapter.id).font(Astryx.Font.code).foregroundStyle(Astryx.Color.textSecondary)
                }
                Text(detail)
                    .font(Astryx.Font.supporting)
                    .foregroundStyle(link?.coolingDown == true ? Astryx.Color.textWarning : Astryx.Color.textSecondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text("↓ " + speedText(adapter.rxBytesPerSec))
                Text("↑ " + speedText(adapter.txBytesPerSec))
            }
            .font(Astryx.Font.supporting).monospacedDigit()
            .foregroundStyle(Astryx.Color.textSecondary)
            Circle().fill(!online ? Astryx.Color.textDisabled
                          : link?.coolingDown == true ? Astryx.Color.textWarning : Astryx.Color.success)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, Astryx.space(3))
        .padding(.vertical, Astryx.space(2.5))
    }

    private var detail: String {
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
