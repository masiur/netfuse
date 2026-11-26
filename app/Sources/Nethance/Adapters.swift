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
    var hasRouter: Bool      // a default gateway, i.e. a way to the internet
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0
}

/// Lists adapters and samples their speeds once a second while something is watching.
@MainActor @Observable
final class AdapterMonitor {
    private(set) var adapters: [Adapter] = []
    private var last: (time: Date, counters: [String: (rx: UInt32, tx: UInt32)])?
    private var names: [String: (String, Adapter.Kind)] = [:]
    private var tick = 0

    var totalRx: Double { adapters.reduce(0) { $0 + $1.rxBytesPerSec } }
    var totalTx: Double { adapters.reduce(0) { $0 + $1.txBytesPerSec } }

    /// Runs until the calling task is cancelled (the menu closes).
    func run() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
        last = nil
    }

    func refresh() {
        if tick % 5 == 0 || names.isEmpty { names = Self.displayNames() } // slow-changing, slower to ask
        tick += 1
        let routers = Self.interfacesWithRouter()
        let now = Date()
        let snap = Self.snapshot()
        var out: [Adapter] = []
        for (bsd, s) in snap where Self.isHardware(bsd) && (s.ipv4 != nil || routers.contains(bsd)) {
            let (name, kind) = names[bsd] ?? Self.fallbackName(bsd)
            var a = Adapter(id: bsd, name: name, kind: kind, ipv4: s.ipv4, hasRouter: routers.contains(bsd))
            if let last, let prev = last.counters[bsd] {
                let dt = now.timeIntervalSince(last.time)
                a.rxBytesPerSec = rate(prev.rx, s.rx, dt)
                a.txBytesPerSec = rate(prev.tx, s.tx, dt)
            }
            out.append(a)
        }
        last = (now, snap.mapValues { ($0.rx, $0.tx) })
        adapters = out.sorted { ($0.hasRouter ? 0 : 1, $0.id) < ($1.hasRouter ? 0 : 1, $1.id) }
    }

    /// Same filter as the engine: real hardware is enN; TetherKit's Android tethers are fethN.
    static func isHardware(_ bsd: String) -> Bool {
        bsd.wholeMatch(of: /(en|feth)\d+/) != nil
    }

    static func fallbackName(_ bsd: String) -> (String, Adapter.Kind) {
        bsd.hasPrefix("feth") ? ("Android USB", .android) : (bsd, .other)
    }

    /// Interface name -> (address, byte counters) from getifaddrs.
    private static func snapshot() -> [String: (ipv4: String?, rx: UInt32, tx: UInt32)] {
        var out: [String: (ipv4: String?, rx: UInt32, tx: UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0, let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            var e = out[name] ?? (nil, 0, 0)
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    e.rx = data.ifi_ibytes
                    e.tx = data.ifi_obytes
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

    /// Interfaces whose network service has an IPv4 router (macOS keeps one per service).
    private static func interfacesWithRouter() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "Nethance" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String]
        else { return [] }
        var out = Set<String>()
        for key in keys {
            guard let v = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  v["Router"] != nil, let ifname = v["InterfaceName"] as? String else { continue }
            out.insert(ifname)
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
