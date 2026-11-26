import AppKit

/// What the engine (the root process that does the routing) writes to status.json every second.
struct EngineStatus: Decodable, Sendable {
    struct Link: Decodable, Sendable {
        var name: String      // BSD name, "en0"
        var active: Int       // open connections
        var coolingDown: Bool // its link just failed; new connections avoid it for a while
        var label: String?    // a name macOS has none for: the Android phone's model
        var capacity: Double? // bytes/s the engine estimates it can carry; flows are shared by it
    }
    struct Flows: Decodable, Sendable {
        var app: String       // "" when the engine could not tell which app it was
        var adapter: String
        var flows: Int
    }
    var updated: TimeInterval
    var vpn: String?          // a VPN is up on this tunnel; the engine stepped aside for it
    var adapters: [Link]
    var apps: [Flows]

    static let path = "/var/run/netfuse/status.json"

    /// nil when the engine is not running: no file, or one it stopped rewriting.
    static func read(now: Date = Date()) -> EngineStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(data, now: now)
    }

    static func decode(_ data: Data, now: Date) -> EngineStatus? {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let s = try? dec.decode(EngineStatus.self, from: data),
              now.timeIntervalSince1970 - s.updated < 5 else { return nil }
        return s
    }

    func link(_ adapter: String) -> Link? { adapters.first { $0.name == adapter } }

    /// The part of new connections an adapter gets: its capacity over all of them (0...1).
    func share(_ adapter: String) -> Double? {
        let total = adapters.reduce(0) { $0 + ($1.capacity ?? 0) }
        guard total > 0, let c = link(adapter)?.capacity else { return nil }
        return c / total
    }

    /// Where an app's connections are open now, busiest adapter first.
    func flows(for app: String) -> [(adapter: String, flows: Int)] {
        apps.filter { $0.app == app }.map { ($0.adapter, $0.flows) }.sorted { $0.flows > $1.flows }
    }
}

/// The on switch. The engine runs as a root LaunchDaemon that launchd starts while the flag file
/// exists; the app installs it (asking for an administrator password) the first time it is
/// switched on, and again whenever the engine bundled with the app differs from the installed one.
@MainActor
enum EngineSwitch {
    static let flag = RuleStore.defaultURL.deletingLastPathComponent().appending(path: "enabled")
    static let installedBinary = "/Library/PrivilegedHelperTools/app.netfuse.engine"
    static let plist = "/Library/LaunchDaemons/app.netfuse.engine.plist"
    static let log = "/var/log/netfuse-engine.log"

    static var isOn: Bool { FileManager.default.fileExists(atPath: flag.path) }

    /// The engine inside the app differs from the installed one (the app was updated).
    static var updateReady: Bool {
        guard let engine = bundledEngine, FileManager.default.fileExists(atPath: plist) else { return false }
        return !FileManager.default.contentsEqual(atPath: engine.path, andPath: installedBinary)
    }

    private static var bundledEngine: URL? {
        Bundle.main.resourceURL.map { $0.appending(path: "netfuse-engine") }.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
    }

    /// When it was switched on (the flag's age), to tell "starting" from "failed to start".
    static var onSince: Date? {
        (try? FileManager.default.attributesOfItem(atPath: flag.path))?[.modificationDate] as? Date
    }

    static func set(_ on: Bool) throws {
        let fm = FileManager.default
        guard on else {
            if isOn { try fm.removeItem(at: flag) } // the engine sees it gone and stops within a second
            return
        }
        try installIfNeeded()
        try fm.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: flag)
    }

    /// Installs the bundled engine unless the same one is installed; `force` reinstalls anyway
    /// (it is installed but not running, e.g. launchd did not load it).
    static func installIfNeeded(force: Bool = false) throws {
        guard let res = Bundle.main.resourceURL,
              case let engine = res.appending(path: "netfuse-engine"), case let script = res.appending(path: "install-engine.sh"),
              FileManager.default.fileExists(atPath: engine.path)
        else { throw Failure("The engine is not inside this copy of Netfuse. Build it with scripts/bundle.sh.") }
        let fm = FileManager.default
        if !force, fm.fileExists(atPath: plist), fm.contentsEqual(atPath: engine.path, andPath: installedBinary) { return }
        try asAdmin([script.path, engine.path, fm.homeDirectoryForCurrentUser.path],
                    prompt: "Netfuse needs to install its routing engine.")
    }

    /// Stops the engine and removes it from the system. The app stays; switching on installs it again.
    static func uninstall() throws {
        guard let script = Bundle.main.resourceURL?.appending(path: "install-engine.sh") else { return }
        if isOn { try FileManager.default.removeItem(at: flag) }
        try asAdmin([script.path, "--uninstall"], prompt: "Netfuse will remove its routing engine.")
    }

    /// Runs one command as root after macOS asks for an administrator password.
    static func asAdmin(_ args: [String], prompt: String) throws {
        // AppleScript's own quoting, so paths with spaces or quotes stay one argument.
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let cmd = args.map { "quoted form of \(lit($0))" }.joined(separator: " & \" \" & ")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \(cmd) with administrator privileges with prompt \(lit(prompt))")?
            .executeAndReturnError(&err)
        if let err {
            if err[NSAppleScript.errorNumber] as? Int == -128 { throw Failure(nil) } // password prompt cancelled
            throw Failure("\(err[NSAppleScript.errorMessage] ?? "unknown error")")
        }
    }

    struct Failure: Error { var message: String?; init(_ m: String?) { message = m } }
}
