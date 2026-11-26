import SwiftUI

/// Latency from each connection to popular DNS servers (ping) and sites (HTTPS connect), side by
/// side, so you can see which link is quicker for what. Each probe is bound to its adapter, so it
/// measures that link and not Netfuse's routing.
struct LatencyPage: View {
    var monitor: AdapterMonitor
    @State private var results: [String: Probe.Result] = [:] // "\(target)|\(adapter)"
    @State private var running = false
    @State private var lastRun: Date?

    var body: some View {
        let adapters = monitor.adapters.filter(monitor.isOnline)
        VStack(alignment: .leading, spacing: Astryx.space(5)) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Astryx.space(0.5)) {
                    Text("Latency").font(Astryx.Font.h3).foregroundStyle(Astryx.Color.textPrimary)
                    Text(lastRun.map { "Last run \($0.formatted(date: .omitted, time: .shortened)). Lower is better." }
                         ?? "Pings DNS servers and connects to popular sites through each connection.")
                        .font(Astryx.Font.supporting).foregroundStyle(Astryx.Color.textSecondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(running ? "Testing…" : "Run test") { Task { await run(adapters) } }
                    .buttonStyle(AstryxButtonStyle(primary: true)).disabled(running || adapters.isEmpty)
            }
            ForEach(Probe.groups, id: \.title) { group in
                TitledCard(group.title) {
                    grid(group.targets, adapters: adapters)
                }
            }
            if let best = bestAdapter(adapters) {
                Text("Quickest overall: \(best)").font(Astryx.Font.label).foregroundStyle(Astryx.Color.textSuccess)
            }
        }
    }

    private func grid(_ targets: [Probe.Target], adapters: [Adapter]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Astryx.space(4), verticalSpacing: Astryx.space(2.5)) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(adapters) { a in
                    Text(a.name).font(Astryx.Font.h6).tracking(0.6).foregroundStyle(Astryx.Color.textSecondary)
                        .gridColumnAlignment(.trailing)
                }
            }
            ForEach(targets, id: \.host) { t in
                Divider().overlay(Astryx.Color.border)
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.name).font(Astryx.Font.label).foregroundStyle(Astryx.Color.textPrimary)
                        Text(t.host).font(Astryx.Font.code).foregroundStyle(Astryx.Color.textSecondary)
                    }
                    ForEach(adapters) { a in cell(results["\(t.host)|\(a.id)"]) }
                }
            }
        }
        .padding(Astryx.space(4))
    }

    @ViewBuilder private func cell(_ r: Probe.Result?) -> some View {
        switch r {
        case nil: Text(running ? "…" : "—").foregroundStyle(Astryx.Color.textDisabled)
        case .failed(let why): Text("Failed").foregroundStyle(Astryx.Color.textError).help(why)
        case .ms(let ms, let loss):
            Text("\(Int(ms.rounded())) ms" + (loss > 0 ? " · \(Int(loss))% lost" : ""))
                .font(Astryx.Font.label).monospacedDigit()
                .foregroundStyle(ms < 60 && loss == 0 ? Astryx.Color.textSuccess : ms < 150 ? Astryx.Color.textWarning : Astryx.Color.textError)
        }
    }

    /// The adapter with the lowest average over targets both reached.
    private func bestAdapter(_ adapters: [Adapter]) -> String? {
        guard adapters.count > 1 else { return nil }
        let avg = adapters.compactMap { a -> (String, Double)? in
            let ms = Probe.groups.flatMap(\.targets).compactMap { t -> Double? in
                if case .ms(let v, _) = results["\(t.host)|\(a.id)"] { v } else { nil }
            }
            return ms.isEmpty ? nil : (a.name, ms.reduce(0, +) / Double(ms.count))
        }
        return avg.min { $0.1 < $1.1 }?.0
    }

    private func run(_ adapters: [Adapter]) async {
        running = true
        results = [:]
        await withTaskGroup(of: (String, Probe.Result).self) { g in
            for a in adapters {
                for group in Probe.groups {
                    for t in group.targets {
                        g.addTask { ("\(t.host)|\(a.id)", await Probe.measure(t, via: a.id)) }
                    }
                }
            }
            for await (k, r) in g { results[k] = r }
        }
        running = false
        lastRun = Date()
    }
}

enum Probe {
    struct Target { var name: String; var host: String; var ping: Bool }
    struct Group { var title: String; var targets: [Target] }
    enum Result: Equatable { case ms(Double, loss: Double), failed(String) }

    static let groups = [
        Group(title: "DNS servers · ping", targets: [
            Target(name: "Cloudflare", host: "1.1.1.1", ping: true),
            Target(name: "Google", host: "8.8.8.8", ping: true),
            Target(name: "Quad9", host: "9.9.9.9", ping: true),
            Target(name: "OpenDNS", host: "208.67.222.222", ping: true),
        ]),
        Group(title: "Sites · secure connection time", targets: [
            Target(name: "Google", host: "www.google.com", ping: false),
            Target(name: "YouTube", host: "www.youtube.com", ping: false),
            Target(name: "Facebook", host: "www.facebook.com", ping: false),
            Target(name: "GitHub", host: "github.com", ping: false),
            Target(name: "Netflix", host: "www.netflix.com", ping: false),
            Target(name: "Cloudflare", host: "www.cloudflare.com", ping: false),
        ]),
    ]

    static func measure(_ t: Target, via adapter: String) async -> Result {
        if t.ping {
            // -b binds to the adapter (macOS ping), so the reply time is that link's.
            let (out, _) = await run("/sbin/ping", "-c", "4", "-i", "0.2", "-q", "-t", "4", "-b", adapter, t.host)
            return parsePing(out) ?? .failed("No reply")
        }
        // TCP + TLS handshake, the wait before a page starts loading. curl binds to the adapter.
        let (out, ok) = await run("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "6", "--interface", adapter,
                                  "-w", "%{time_connect} %{time_appconnect}", "https://\(t.host)/")
        guard ok, let tls = out.split(separator: " ").last.flatMap({ Double($0) }), tls > 0 else { return .failed("Could not connect") }
        return .ms(tls * 1000, loss: 0)
    }

    /// "4 packets transmitted, 3 packets received, 25.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 33.0/55.1/77.2/22.0 ms" -> 55.1 ms, 25% lost.
    static func parsePing(_ out: String) -> Result? {
        let loss = out.split(separator: "\n").first { $0.contains("packet loss") }
            .flatMap { $0.split(separator: ",").last?.split(separator: "%").first }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = out.split(separator: "\n").first(where: { $0.contains("round-trip") }),
              let nums = line.split(separator: "=").last?.split(separator: "/"), nums.count >= 2,
              let avg = Double(nums[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return .ms(avg, loss: loss ?? 0)
    }

    private static func run(_ path: String, _ args: String...) async -> (String, Bool) {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(filePath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in
                c.resume(returning: (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus == 0))
            }
            do { try p.run() } catch { c.resume(returning: ("", false)) }
        }
    }
}
