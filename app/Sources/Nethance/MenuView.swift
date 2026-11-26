import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuView: View {
    @State private var monitor = AdapterMonitor()
    @State private var rules = RuleStore()
    @State private var extraApps: [URL] = []
    @State private var apps: [AppEntry] = []
    @State private var engine = EngineStatus.read()

    var body: some View {
        VStack(alignment: .leading, spacing: Astryx.space(4)) {
            header
            section("Connections") { connections }
            section("Apps") { appList }
            if let err = rules.lastError {
                Text(err).font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textError)
            }
            footer
        }
        .padding(Astryx.space(4))
        .frame(width: 380)
        .background(Astryx.Color.body)
        .task { await monitor.run() }
        .task {
            while !Task.isCancelled {
                apps = listApps(rules: rules.rules, extra: extraApps)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task {
            while !Task.isCancelled {
                engine = EngineStatus.read() // rewritten by the engine every second
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Astryx.space(0.5)) {
                Text("Nethance").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
                Text("↓ \(speedText(monitor.totalRx))   ↑ \(speedText(monitor.totalTx))")
                    .font(Astryx.Font.supporting).monospacedDigit()
                    .foregroundStyle(Astryx.Color.textSecondary)
            }
            Spacer()
            if engine != nil {
                Badge(text: "Combining", tone: .success)
            } else {
                Badge(text: "Engine off", tone: .warning)
                    .help("The Nethance engine is not running yet. Rules are saved and apply when it starts.")
            }
        }
    }

    @ViewBuilder private var connections: some View {
        if monitor.adapters.isEmpty {
            emptyRow("No connections found")
        }
        ForEach(Array(monitor.adapters.enumerated()), id: \.element.id) { i, a in
            if i > 0 { Divider().overlay(Astryx.Color.border) }
            AdapterRow(adapter: a, link: engine?.link(a.id))
        }
        let online = monitor.adapters.filter(\.hasRouter).count
        if online == 1 {
            Divider().overlay(Astryx.Color.border)
            Text("Connect a second internet source to combine: Ethernet, an iPhone over USB, or an Android phone through TetherKit.")
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

    var body: some View {
        HStack(spacing: Astryx.space(3)) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(adapter.hasRouter ? Astryx.Color.textPrimary : Astryx.Color.textDisabled)
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
            Circle().fill(!adapter.hasRouter ? Astryx.Color.textDisabled
                          : link?.coolingDown == true ? Astryx.Color.textWarning : Astryx.Color.success)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, Astryx.space(3))
        .padding(.vertical, Astryx.space(2.5))
    }

    private var detail: String {
        guard adapter.hasRouter else { return "No internet" }
        let ip = adapter.ipv4 ?? "IPv6 only"
        guard let link else { return ip }
        if link.coolingDown { return "\(ip) · link failed, retrying soon" }
        return "\(ip) · \(link.active) open"
    }

    private var symbol: String {
        switch adapter.kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .iPhone, .android: "iphone"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .other: "network"
        }
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

    private var label: String {
        switch policy {
        case .combine: "All connections"
        case .only(let a): "Only \(name(a))"
        case .prefer(let a): "\(name(a)) first"
        case .custom(let r): r
        }
    }
}
