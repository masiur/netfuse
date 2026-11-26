import Foundation
import Testing
@testable import Nethance

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
    let url = FileManager.default.temporaryDirectory.appending(path: "nethance-\(UUID())/rules.json")
    let store = RuleStore(url: url)
    store.set(.prefer("en4"), for: "Google Chrome")
    store.set(.only("en0"), for: "Zoom")
    store.set(.combine, for: "Zoom") // back to default: removed
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(json?["version"] as? Int == 1)
    #expect(json?["rules"] as? [String: String] == ["Google Chrome": "en4 > *"])
    #expect(RuleStore(url: url).policy(for: "Google Chrome") == .prefer("en4"))
}
