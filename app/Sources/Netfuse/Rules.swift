import AppKit
import Foundation
import Observation

/// What one app may use. The engine reads routes as text: adapter tiers tried left to right
/// across ">", adapters joined by "+" are combined, "*" is every adapter ("en4 > *" = Ethernet,
/// anything when it is down). The menu offers the common shapes; anything else stays as written.
enum Policy: Hashable, Sendable {
    case combine                // every adapter, the default
    case only(String)           // this adapter or nothing
    case prefer(String)         // this adapter, any other when it is down
    case custom(String)         // a route typed by hand, kept as is

    init(route: String) {
        let r = route.trimmingCharacters(in: .whitespaces)
        let tiers = r.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        switch true {
        case r.isEmpty, r == "*", r.caseInsensitiveCompare("auto") == .orderedSame:
            self = .combine
        case tiers.count == 1 && !r.contains("+"):
            self = .only(r)
        case tiers.count == 2 && tiers[1] == "*" && !tiers[0].contains("+") && !tiers[0].isEmpty:
            self = .prefer(tiers[0])
        default:
            self = .custom(r)
        }
    }

    var route: String {
        switch self {
        case .combine: "auto"
        case .only(let a): a
        case .prefer(let a): "\(a) > *"
        case .custom(let r): r
        }
    }
}

/// The app's rules, saved where the engine reads them:
/// ~/Library/Application Support/Netfuse/rules.json, {"version":1,"rules":{"Google Chrome":"en4 > *"}}.
/// Keys are app names as the engine sees them: the outermost .app bundle's name.
@MainActor @Observable
final class RuleStore {
    private(set) var rules: [String: Policy] = [:]
    /// Per-site routes by domain ("youtube.com" covers its subdomains); they win over app rules.
    private(set) var sites: [String: Policy] = [:]
    /// Adapters (BSD names) switched off: the engine sends nothing through them.
    private(set) var disabled: [String] = []
    /// Priority order: apps without a rule use the first working adapter, then the next.
    /// Empty = combine every adapter.
    private(set) var order: [String] = []
    /// Keep combining while a VPN is connected; off (default): Netfuse steps aside for it.
    private(set) var keepWithVPN = false
    private(set) var lastError: String?
    let url: URL

    init(url: URL = RuleStore.defaultURL) {
        self.url = url
        load()
    }

    static let shared = RuleStore()

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Netfuse/rules.json")
    }

    func policy(for app: String) -> Policy { rules[app] ?? .combine }
    func policy(forSite domain: String) -> Policy { sites[domain] ?? .combine }

    func set(_ policy: Policy, for app: String) {
        if case .combine = policy { rules[app] = nil } else { rules[app] = policy }
        save()
    }

    /// Sets a site's route; `.combine` removes it. Returns false for an empty domain.
    @discardableResult
    func setSite(_ policy: Policy, for domain: String) -> Bool {
        guard let d = normalizeDomain(domain) else { return false }
        if case .combine = policy { sites[d] = nil } else { sites[d] = policy }
        save()
        return true
    }

    func isDisabled(_ id: String) -> Bool { disabled.contains(id) }

    func setEnabled(_ on: Bool, _ id: String) {
        disabled.removeAll { $0 == id }
        if !on { disabled.append(id) }
        save()
    }

    /// Switches between combining (empty order) and priority order over `ids`.
    func setOrdered(_ on: Bool, ids: [String]) {
        order = on ? ids : []
        save()
    }

    /// Moves an adapter one place up (-1) or down (+1) in the priority order of `ids`.
    func move(_ id: String, by step: Int, ids: [String]) {
        var o = sorted(ids)
        guard let i = o.firstIndex(of: id), o.indices.contains(i + step) else { return }
        o.swapAt(i, i + step)
        order = o
        save()
    }

    func setKeepWithVPN(_ on: Bool) {
        keepWithVPN = on
        save()
    }

    /// `ids` in priority order; ones not in the order yet go last.
    func sorted(_ ids: [String]) -> [String] {
        ids.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    private struct File: Codable {
        var version = 1
        var rules: [String: String]
        var sites: [String: String]?
        var disabled: [String]?
        var order: [String]?
        var keepWithVpn: Bool?

        enum CodingKeys: String, CodingKey {
            case version, rules, sites, disabled, order
            case keepWithVpn = "keep_with_vpn"
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return } // no file yet: no rules
        do {
            let f = try JSONDecoder().decode(File.self, from: data)
            rules = f.rules.mapValues(Policy.init(route:)).filter { $0.value != .combine }
            sites = (f.sites ?? [:]).mapValues(Policy.init(route:)).filter { $0.value != .combine }
            disabled = f.disabled ?? []
            order = f.order ?? []
            keepWithVPN = f.keepWithVpn ?? false
        } catch {
            lastError = "rules.json: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(File(rules: rules.mapValues(\.route), sites: sites.isEmpty ? nil : sites.mapValues(\.route), disabled: disabled, order: order, keepWithVpn: keepWithVPN ? true : nil)).write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save rules: \(error.localizedDescription)"
        }
    }
}

/// An app a rule can be set for.
struct AppEntry: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var icon: NSImage?
}

/// The engine's name for an app: the outermost .app bundle's name, so an app's helpers
/// ("Google Chrome Helper.app" inside "Google Chrome.app") share its rule.
func appName(forPath path: String) -> String {
    if let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) {
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }
    return (path as NSString).lastPathComponent
}

/// Running apps with a Dock icon, plus apps that have a rule but are not running.
@MainActor
func listApps(rules: [String: Policy], extra: [URL]) -> [AppEntry] {
    var seen: [String: AppEntry] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let url = app.bundleURL else { continue }
        let name = appName(forPath: url.path)
        if name == "Netfuse" { continue }
        seen[name] = AppEntry(name: name, icon: app.icon)
    }
    for url in extra {
        let name = appName(forPath: url.path)
        seen[name] = seen[name] ?? AppEntry(name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }
    for name in rules.keys where seen[name] == nil {
        seen[name] = AppEntry(name: name, icon: nil)
    }
    return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

extension Policy {
    /// "Only Wi-Fi", "Wi-Fi first", with adapter names from `name`.
    func text(_ name: (String) -> String) -> String {
        switch self {
        case .combine: "All connections"
        case .only(let a): "Only \(name(a))"
        case .prefer(let a): "\(name(a)) first"
        case .custom(let r): r
        }
    }
}

/// "https://www.YouTube.com/watch" -> "www.youtube.com", "*.x.com" -> "x.com"; nil if empty.
/// Same as the engine's sites::normalize.
func normalizeDomain(_ s: String) -> String? {
    var d = s.trimmingCharacters(in: .whitespaces).lowercased()
    if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
    d = String(d.prefix { !"/:?".contains($0) })
    if d.hasPrefix("*.") { d.removeFirst(2) }
    d = d.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return d.isEmpty ? nil : d
}
