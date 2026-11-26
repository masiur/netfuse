import AppKit
import Foundation
import Observation

/// Checks GitHub for a newer release at launch and every 6 hours, and installs it: the same zip
/// install.sh downloads, swapped in place of this app, which then relaunches. The engine keeps
/// running; the new app offers its engine update as usual. Only for a copy in /Applications, so
/// development builds are left alone.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let latestAPI = URL(string: "https://api.github.com/repos/masiur/netfuse/releases/latest")!
    static let zip = URL(string: "https://github.com/masiur/netfuse/releases/latest/download/Netfuse.zip")!

    private(set) var status: String?
    private var started = false

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        guard !started, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        started = true
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.latestAPI),
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String,
              isNewer(tag, than: current) else { return }
        let version = tag.trimmingPrefix("v")
        status = "Updating to \(version)…"
        do {
            try await install()
        } catch {
            status = "Netfuse \(version) is out; update failed: \(error.localizedDescription)"
        }
    }

    private func install() async throws {
        let (file, _) = try await URLSession.shared.download(from: Self.zip)
        let dir = FileManager.default.temporaryDirectory.appending(path: "netfuse-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sh("/usr/bin/ditto", "-x", "-k", file.path, dir.path)
        let new = dir.appending(path: "Netfuse.app")
        guard Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try? sh("/usr/bin/xattr", "-dr", "com.apple.quarantine", new.path)
        // Swap: move the running copy aside, put the new one in, then relaunch from it.
        let dest = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: new)
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", dest.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func sh(_ cmd: String, _ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: cmd)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return p.terminationStatus
    }
}

/// "v1.2.0" is newer than "1.1.9": compares dotted numbers.
nonisolated func isNewer(_ tag: String, than current: String) -> Bool {
    let parts = { (s: String) in s.trimmingPrefix("v").split(separator: ".").map { Int($0) ?? 0 } }
    let (a, b) = (parts(tag), parts(current))
    for i in 0..<max(a.count, b.count) where (a.indices.contains(i) ? a[i] : 0) != (b.indices.contains(i) ? b[i] : 0) {
        return (a.indices.contains(i) ? a[i] : 0) > (b.indices.contains(i) ? b[i] : 0)
    }
    return false
}
