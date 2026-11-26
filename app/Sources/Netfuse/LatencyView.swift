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
                Text("Quickest response: \(best)").font(Astryx.Font.label).foregroundStyle(Astryx.Color.textSuccess)
            }
            if adapters.count > 1, let fastest = adapters.compactMap({ a -> (String, Double)? in
                if case .mbps(let v) = results["speed.cloudflare.com|\(a.id)"] { (a.name, v) } else { nil }
            }).max(by: { $0.1 < $1.1 }) {
                Text("Fastest download: \(fastest.0)").font(Astryx.Font.label).foregroundStyle(Astryx.Color.textSuccess)
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
        case .mbps(let v):
            Text(String(format: v < 10 ? "%.1f Mbit/s" : "%.0f Mbit/s", v))
                .font(Astryx.Font.label).monospacedDigit().foregroundStyle(Astryx.Color.textPrimary)
        case .ms(let ms, let loss, let jitter):
            Text("\(Int(ms.rounded())) ms" + (jitter.map { " ±\(Int($0.rounded()))" } ?? "") + (loss > 0 ? " · \(Int(loss))% lost" : ""))
                .font(Astryx.Font.label).monospacedDigit()
                .help(jitter.map { "Jitter \(Int($0.rounded())) ms: how much the time varies. Under 30 is good for calls." } ?? "")
                .foregroundStyle(ms < 60 && loss == 0 && (jitter ?? 0) < 30 ? Astryx.Color.textSuccess : ms < 150 ? Astryx.Color.textWarning : Astryx.Color.textError)
        }
    }

    /// The adapter with the lowest average over targets both reached.
    private func bestAdapter(_ adapters: [Adapter]) -> String? {
        guard adapters.count > 1 else { return nil }
        let avg = adapters.compactMap { a -> (String, Double)? in
            let ms = Probe.groups.flatMap(\.targets).compactMap { t -> Double? in
                if case .ms(let v, _, _) = results["\(t.host)|\(a.id)"] { v } else { nil }
            }
            return ms.isEmpty ? nil : (a.name, ms.reduce(0, +) / Double(ms.count))
        }
        return avg.min { $0.1 < $1.1 }?.0
    }

    private func run(_ adapters: [Adapter]) async {
        running = true
        results = [:]
        let all = Probe.groups.flatMap(\.targets)
        // Latency first, then the downloads: a download running alongside would slow the pings.
        for phase in [all.filter { $0.kind != .download }, all.filter { $0.kind == .download }] {
            await withTaskGroup(of: (String, Probe.Result).self) { g in
                for a in adapters {
                    for t in phase {
                        g.addTask { ("\(t.host)|\(a.id)", await Probe.measure(t, via: a)) }
                    }
                }
                for await (k, r) in g { results[k] = r }
            }
        }
        running = false
        lastRun = Date()
    }
}

enum Probe {
    struct Target { var name: String; var host: String; var kind: Kind }
    static let routerHost = "router" // stands for each adapter's own router
    struct Group { var title: String; var targets: [Target] }
    enum Result: Equatable { case ms(Double, loss: Double, jitter: Double?), mbps(Double), failed(String) }
    enum Kind { case ping, connect, download }

    static let groups = [
        Group(title: "Download speed", targets: [
            Target(name: "Cloudflare", host: "speed.cloudflare.com", kind: .download),
        ]),
        Group(title: "Your router · ping", targets: [
            Target(name: "Router", host: routerHost, kind: .ping),
        ]),
        Group(title: "DNS servers · ping", targets: [
            Target(name: "Cloudflare", host: "1.1.1.1", kind: .ping),
            Target(name: "Google", host: "8.8.8.8", kind: .ping),
            Target(name: "Quad9", host: "9.9.9.9", kind: .ping),
            Target(name: "OpenDNS", host: "208.67.222.222", kind: .ping),
        ]),
        Group(title: "Sites · secure connection time", targets: [
            Target(name: "Google", host: "www.google.com", kind: .connect),
            Target(name: "YouTube", host: "www.youtube.com", kind: .connect),
            Target(name: "Facebook", host: "www.facebook.com", kind: .connect),
            Target(name: "GitHub", host: "github.com", kind: .connect),
            Target(name: "Netflix", host: "www.netflix.com", kind: .connect),
            Target(name: "Cloudflare", host: "www.cloudflare.com", kind: .connect),
        ]),
    ]

    static func measure(_ t: Target, via a: Adapter) async -> Result {
        let adapter = a.id
        switch t.kind {
        case .download:
            // 10 MB, about a second on a fast link; enough to fill a typical connection.
            let (out, ok) = await run("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "15", "--interface", adapter,
                                      "-w", "%{speed_download}", "https://speed.cloudflare.com/__down?bytes=10000000")
            guard ok, let bps = Double(out), bps > 0 else { return .failed("Download failed") }
            return .mbps(bps * 8 / 1_000_000)
        case .ping:
            guard let host = t.host == routerHost ? a.router : t.host else { return .failed("No router known for this connection") }
            // -b binds to the adapter (macOS ping), so the reply time is that link's.
            let (out, _) = await run("/sbin/ping", "-c", "4", "-i", "0.2", "-q", "-t", "4", "-b", adapter, host)
            return parsePing(out) ?? .failed("No reply")
        case .connect:
            break
        }
        // TCP + TLS handshake, the wait before a page starts loading. curl binds to the adapter.
        let (out, ok) = await run("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "6", "--interface", adapter,
                                  "-w", "%{time_connect} %{time_appconnect}", "https://\(t.host)/")
        guard ok, let tls = out.split(separator: " ").last.flatMap({ Double($0) }), tls > 0 else { return .failed("Could not connect") }
        return .ms(tls * 1000, loss: 0, jitter: nil)
    }

    /// "4 packets transmitted, 3 packets received, 25.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 33.0/55.1/77.2/22.0 ms" -> 55.1 ms, 25% lost, jitter 22.0
    /// (the standard deviation: how much the time jumps around).
    static func parsePing(_ out: String) -> Result? {
        let loss = out.split(separator: "\n").first { $0.contains("packet loss") }
            .flatMap { $0.split(separator: ",").last?.split(separator: "%").first }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = out.split(separator: "\n").first(where: { $0.contains("round-trip") }),
              let nums = line.split(separator: "=").last?.split(separator: "/"), nums.count >= 2,
              let avg = Double(nums[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let jitter = nums.count >= 4 ? Double(nums[3].split(separator: " ").first ?? "") : nil
        return .ms(avg, loss: loss ?? 0, jitter: jitter)
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
