import AppKit

/// What the engine (the root process that does the routing) writes to status.json every second.
struct EngineStatus: Decodable, Sendable {
    struct Link: Decodable, Sendable {
        var name: String      // BSD name, "en0"
        var active: Int       // open connections
        var coolingDown: Bool // its link just failed; new connections avoid it for a while
    }
    struct Flows: Decodable, Sendable {
        var app: String       // "" when the engine could not tell which app it was
        var adapter: String
        var flows: Int
    }
    var updated: TimeInterval
    var adapters: [Link]
    var apps: [Flows]

    static let path = "/var/run/nethance/status.json"

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
    static let installedBinary = "/Library/PrivilegedHelperTools/app.nethance.engine"
    static let plist = "/Library/LaunchDaemons/app.nethance.engine.plist"
    static let log = "/var/log/nethance-engine.log"

    static var isOn: Bool { FileManager.default.fileExists(atPath: flag.path) }

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

    private static func installIfNeeded() throws {
        guard let res = Bundle.main.resourceURL,
              case let engine = res.appending(path: "nethance-engine"), case let script = res.appending(path: "install-engine.sh"),
              FileManager.default.fileExists(atPath: engine.path)
        else { throw Failure("The engine is not inside this copy of Nethance. Build it with scripts/bundle.sh.") }
        let fm = FileManager.default
        if fm.fileExists(atPath: plist), fm.contentsEqual(atPath: engine.path, andPath: installedBinary) { return }
        // AppleScript's own quoting, so paths with spaces or quotes stay one argument.
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let cmd = [script.path, engine.path, fm.homeDirectoryForCurrentUser.path].map { "quoted form of \(lit($0))" }
            .joined(separator: " & \" \" & ")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \(cmd) with administrator privileges "
                      + "with prompt \"Nethance needs to install its routing engine.\"")?.executeAndReturnError(&err)
        if let err {
            if err[NSAppleScript.errorNumber] as? Int == -128 { throw Failure(nil) } // password prompt cancelled
            throw Failure("Could not install the engine: \(err[NSAppleScript.errorMessage] ?? "unknown error")")
        }
    }

    struct Failure: Error { var message: String?; init(_ m: String?) { message = m } }
}
