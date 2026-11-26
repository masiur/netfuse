import Darwin
import Foundation
import Observation
import SystemConfiguration

/// One network adapter that can carry internet traffic: Wi-Fi, Ethernet, a phone tether.
struct Adapter: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case wifi, ethernet, iPhone, android, bluetooth, other }

    var id: String           // BSD name, "en0": what rules store, since display names can change
    var name: String         // what System Settings calls it, "Wi-Fi"
    var kind: Kind
    var ipv4: String?
    var router: String?      // the default gateway, i.e. a way to the internet
    var mac: String?
    var linkSpeed: UInt64 = 0 // bits/s as the driver reports it; 0 when unknown
    var hasRouter: Bool { router != nil }
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0
}

extension Adapter {
    /// SF Symbol for the kind of link.
    var symbol: String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .iPhone, .android: "iphone"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .other: "network"
        }
    }
}

/// One second of an adapter's traffic.
struct Sample: Sendable {
    var time: Date
    var rx: Double // bytes/s
    var tx: Double
}

/// Adapters, their speeds and the engine's status, sampled once a second for as long as the app
/// runs, so the details window can show the last ten minutes.
@MainActor @Observable
final class AdapterMonitor {
    static let shared = AdapterMonitor()
    static let historyLength = 600

    private(set) var adapters: [Adapter] = []
    private(set) var history: [String: [Sample]] = [:]
    private(set) var totals: [String: (rx: Double, tx: Double)] = [:] // bytes since the app started
    private(set) var engine: EngineStatus?
    private(set) var publicInfo: [String: PublicInfo] = [:]
    private var last: (time: Date, counters: [String: (rx: UInt32, tx: UInt32)])?
    private var names: [String: (String, Adapter.Kind)] = [:]
    private var tick = 0
    private var started = false
    private var fetching: Set<String> = []

    var totalRx: Double { adapters.reduce(0) { $0 + $1.rxBytesPerSec } }
    var totalTx: Double { adapters.reduce(0) { $0 + $1.txBytesPerSec } }

    /// Online: macOS knows a router for it, or the engine drives it (an Android phone).
    func isOnline(_ a: Adapter) -> Bool { a.hasRouter || engine?.link(a.id) != nil }

    func start() {
        guard !started else { return }
        started = true
        Task {
            while true {
                refresh()
                engine = EngineStatus.read() // rewritten by the engine every second
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refresh() {
        if tick % 5 == 0 || names.isEmpty { names = Self.displayNames() } // slow-changing, slower to ask
        tick += 1
        let routers = Self.routers()
        let now = Date()
        let snap = Self.snapshot()
        var out: [Adapter] = []
        for (bsd, s) in snap where Self.isHardware(bsd) && (s.ipv4 != nil || routers[bsd] != nil) {
            var (name, kind) = names[bsd] ?? Self.fallbackName(bsd)
            if let label = engine?.link(bsd)?.label { name = label }
            var a = Adapter(id: bsd, name: name, kind: kind, ipv4: s.ipv4, router: routers[bsd], mac: s.mac, linkSpeed: s.speed)
            if let last, let prev = last.counters[bsd] {
                let dt = now.timeIntervalSince(last.time)
                a.rxBytesPerSec = rate(prev.rx, s.rx, dt)
                a.txBytesPerSec = rate(prev.tx, s.tx, dt)
                totals[bsd, default: (0, 0)].rx += Double(s.rx &- prev.rx)
                totals[bsd, default: (0, 0)].tx += Double(s.tx &- prev.tx)
            }
            history[bsd, default: []].append(Sample(time: now, rx: a.rxBytesPerSec, tx: a.txBytesPerSec))
            if history[bsd]!.count > Self.historyLength { history[bsd]!.removeFirst() }
            out.append(a)
        }
        last = (now, snap.mapValues { ($0.rx, $0.tx) })
        adapters = out.sorted { ($0.hasRouter ? 0 : 1, $0.id) < ($1.hasRouter ? 0 : 1, $1.id) }
    }

    /// Looks up each online adapter's public address and ISP, again after 10 minutes or when its
    /// local address changes.
    func refreshPublicInfo() {
        for a in adapters where isOnline(a) && !fetching.contains(a.id) {
            if let p = publicInfo[a.id], p.localIP == a.ipv4, Date().timeIntervalSince(p.fetched) < 600 { continue }
            fetching.insert(a.id)
            let (id, local) = (a.id, a.ipv4)
            Task.detached {
                let info = PublicInfo.fetch(through: id, localIP: local)
                await MainActor.run {
                    self.fetching.remove(id)
                    if let info { self.publicInfo[id] = info }
                }
            }
        }
    }

    /// Same filter as the engine: real hardware is enN; TetherKit's Android tethers are fethN.
    static func isHardware(_ bsd: String) -> Bool {
        bsd.wholeMatch(of: /(en|feth)\d+/) != nil
    }

    static func fallbackName(_ bsd: String) -> (String, Adapter.Kind) {
        bsd.hasPrefix("feth") ? ("Android USB", .android) : (bsd, .other)
    }

    typealias Snap = (ipv4: String?, rx: UInt32, tx: UInt32, mac: String?, speed: UInt64)

    /// Interface name -> address, byte counters, MAC and link speed, from getifaddrs.
    private static func snapshot() -> [String: Snap] {
        var out: [String: Snap] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0, let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            var e = out[name] ?? (nil, 0, 0, nil, 0)
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    e.rx = data.ifi_ibytes
                    e.tx = data.ifi_obytes
                    e.speed = UInt64(data.ifi_baudrate)
                }
                // sdl_data holds the name then the address and runs past the struct's declared
                // 12 bytes, so read it from the sockaddr itself, within its sdl_len.
                let d = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                let start = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(d.sdl_nlen)
                if d.sdl_alen == 6, start + 6 <= Int(d.sdl_len) {
                    let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(sa) + start, count: 6)
                    e.mac = raw.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            case AF_INET:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !ip.hasPrefix("169.254.") { e.ipv4 = ip } // self-assigned: no DHCP, no internet
                }
            default: break
            }
            out[name] = e
        }
        return out
    }

    /// Interface -> IPv4 router of its network service (macOS keeps one per service).
    private static func routers() -> [String: String] {
        guard let store = SCDynamicStoreCreate(nil, "Nethance" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String]
        else { return [:] }
        var out: [String: String] = [:]
        for key in keys {
            guard let v = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let router = v["Router"] as? String, let ifname = v["InterfaceName"] as? String else { continue }
            out[ifname] = router
        }
        return out
    }

    private static func displayNames() -> [String: (String, Adapter.Kind)] {
        var out: [String: (String, Adapter.Kind)] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(i)
            let kind: Adapter.Kind
            switch true {
            case type == kSCNetworkInterfaceTypeIEEE80211: kind = .wifi
            case type == kSCNetworkInterfaceTypeBluetooth: kind = .bluetooth
            case name.localizedCaseInsensitiveContains("iPhone"), name.localizedCaseInsensitiveContains("iPad"): kind = .iPhone
            case type == kSCNetworkInterfaceTypeEthernet: kind = .ethernet
            default: kind = .other
            }
            out[bsd] = (name, kind)
        }
        return out
    }
}

/// Bytes per second between two samples of a 32-bit counter (getifaddrs' counters wrap at 4 GiB).
func rate(_ before: UInt32, _ after: UInt32, _ seconds: Double) -> Double {
    guard seconds > 0 else { return 0 }
    return Double(after &- before) / seconds
}

/// "12.3 Mbit/s", the unit the engine and its speed caps use.
func speedText(_ bytesPerSec: Double) -> String {
    let mbit = bytesPerSec * 8 / 1_000_000
    switch mbit {
    case ..<0.01: return "0 Mbit/s"
    case ..<10: return String(format: "%.2f Mbit/s", mbit)
    case ..<100: return String(format: "%.1f Mbit/s", mbit)
    default: return String(format: "%.0f Mbit/s", mbit)
    }
}

/// Where an adapter meets the internet: its public address and ISP, from ipinfo.io.
struct PublicInfo: Sendable {
    var ip: String
    var isp: String
    var place: String
    var localIP: String?
    var fetched: Date

    /// Asks through one adapter: curl --interface binds its socket to it (IP_BOUND_IF), so the
    /// request leaves there even while the engine routes everything else.
    nonisolated static func fetch(through bsd: String, localIP: String?) -> PublicInfo? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "8", "--interface", bsd, "https://ipinfo.io/json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(data, localIP: localIP)
    }

    nonisolated static func parse(_ data: Data, localIP: String?) -> PublicInfo? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ip = j["ip"] as? String else { return nil }
        // "AS24342 BRACNet Limited" -> "BRACNet Limited"
        let org = (j["org"] as? String ?? "").replacing(/^AS\d+\s+/, with: "")
        let place = [j["city"], j["country"]].compactMap { $0 as? String }.joined(separator: ", ")
        return PublicInfo(ip: ip, isp: org.isEmpty ? "Unknown" : org, place: place, localIP: localIP, fetched: Date())
    }
}
