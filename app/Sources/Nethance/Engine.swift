import Foundation

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
