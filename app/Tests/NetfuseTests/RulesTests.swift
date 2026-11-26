import Foundation
import Testing
@testable import Netfuse

@Test func policyRoundTripsThroughRouteText() {
    let cases: [(String, Policy, String)] = [
        ("auto", .combine, "auto"),
        ("*", .combine, "auto"),
        ("en4", .only("en4"), "en4"),
        (" en4 >  * ", .prefer("en4"), "en4 > *"),
        ("Wi-Fi+en4 > iPhone USB", .custom("Wi-Fi+en4 > iPhone USB"), "Wi-Fi+en4 > iPhone USB"),
    ]
    for (text, policy, route) in cases {
        #expect(Policy(route: text) == policy, "\(text)")
        #expect(policy.route == route)
    }
}

@Test func appNameIsTheOutermostBundle() {
    #expect(appName(forPath: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") == "Google Chrome")
    #expect(appName(forPath: "/Applications/Steam.app") == "Steam")
    #expect(appName(forPath: "/usr/bin/curl") == "curl")
}

@Test func counterRateSurvivesWrap() {
    #expect(rate(UInt32.max - 99, 100, 1) == 200)
    #expect(rate(1000, 3000, 2) == 1000)
}

@Test @MainActor func rulesSaveInTheEngineFormat() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "netfuse-\(UUID())/rules.json")
    let store = RuleStore(url: url)
    store.set(.prefer("en4"), for: "Google Chrome")
    store.set(.only("en0"), for: "Zoom")
    store.set(.combine, for: "Zoom") // back to default: removed
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(json?["version"] as? Int == 1)
    #expect(json?["rules"] as? [String: String] == ["Google Chrome": "en4 > *"])
    #expect(RuleStore(url: url).policy(for: "Google Chrome") == .prefer("en4"))
}

@Test func readsTheEngineStatus() throws {
    let json = Data("""
    {"pid": 1, "updated": 1000, "tunnel": "utun9",
     "adapters": [{"name": "en0", "ip": "10.0.0.2", "active": 3, "total": 9, "failed": 1, "cooling_down": true},
                  {"name": "feth7700", "ip": "172.23.226.192", "active": 1, "total": 1, "failed": 0, "cooling_down": false,
                   "label": "HONOR DNY-NX9"}],
     "apps": [{"app": "curl", "adapter": "en0", "flows": 1}, {"app": "curl", "adapter": "en10", "flows": 4}]}
    """.utf8)
    let s = try #require(EngineStatus.decode(json, now: Date(timeIntervalSince1970: 1002)))
    #expect(s.link("en0")?.active == 3)
    #expect(s.link("en0")?.coolingDown == true)
    #expect(s.link("en0")?.label == nil)
    #expect(s.link("feth7700")?.label == "HONOR DNY-NX9")
    #expect(s.share("en0") == nil) // no capacities in this file
    #expect(s.flows(for: "curl").map(\.adapter) == ["en10", "en0"])
    #expect(EngineStatus.decode(json, now: Date(timeIntervalSince1970: 1010)) == nil) // stale: engine stopped
}

@Test func readsTheProviderFromIpinfo() throws {
    let json = Data(#"{"ip":"115.127.217.90","city":"Dhaka","country":"BD","org":"AS24342 BRACNet Limited"}"#.utf8)
    let p = try #require(PublicInfo.parse(json, localIP: "10.0.0.2"))
    #expect((p.ip, p.isp, p.place) == ("115.127.217.90", "BRACNet Limited", "Dhaka, BD"))
    #expect(PublicInfo.parse(Data("rate limited".utf8), localIP: nil) == nil)
}

@Test func newerVersionCompare() {
    #expect(isNewer("v1.2.0", than: "1.1.9"))
    #expect(isNewer("v1.0.1", than: "1.0"))
    #expect(!isNewer("v1.0.0", than: "1.0"))
    #expect(!isNewer("v0.9.9", than: "1.0.0"))
}

@Test @MainActor func adapterOrderAndDisabledSave() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "netfuse-\(UUID()).json")
    let store = RuleStore(url: url)
    store.setOrdered(true, ids: ["en0", "en4"])
    store.move("en4", by: -1, ids: ["en0", "en4", "en7"])
    store.setEnabled(false, "en7")
    let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect(j["order"] as? [String] == ["en4", "en0", "en7"])
    #expect(j["disabled"] as? [String] == ["en7"])
    #expect(RuleStore(url: url).order == ["en4", "en0", "en7"])
}

@Test func recommendsTheMeasuredFasterLinkElseCable() {
    let wifi = Adapter(id: "en0", name: "Wi-Fi", kind: .wifi, ipv4: "1", router: "r", mac: nil, linkSpeed: 866_000_000)
    let cable = Adapter(id: "en5", name: "Ethernet", kind: .ethernet, ipv4: "2", router: "r", mac: nil, linkSpeed: 100_000_000)
    #expect(recommend([wifi], engine: nil) == nil)
    #expect(recommend([wifi, cable], engine: nil)?.id == "en5")
    let json = #"""
    {"updated": 9e9, "apps": [], "adapters": [
        {"name": "en0", "active": 1, "cooling_down": false, "capacity": 9000000, "total": 10, "failed": 0},
        {"name": "en5", "active": 1, "cooling_down": false, "capacity": 3000000, "total": 10, "failed": 0}]}
    """#
    let engine = EngineStatus.decode(Data(json.utf8), now: Date(timeIntervalSince1970: 9e9))
    #expect(engine != nil)
    let r = recommend([wifi, cable], engine: engine)
    #expect(r?.id == "en0")
    #expect(r?.reason.hasPrefix("3.0× faster than Ethernet") == true)
}

@Test func parsesPingSummary() {
    let out = "--- 1.1.1.1 ping statistics ---\n4 packets transmitted, 3 packets received, 25.0% packet loss\nround-trip min/avg/max/stddev = 33.067/55.135/77.203/22.068 ms\n"
    #expect(Probe.parsePing(out) == .ms(55.135, loss: 25))
    #expect(Probe.parsePing("4 packets transmitted, 0 packets received, 100.0% packet loss\n") == nil)
}
