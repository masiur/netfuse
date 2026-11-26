import AppKit
import SwiftUI

@main
struct NethanceApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("Nethance", systemImage: "point.3.connected.trianglepath.dotted") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    /// `--window` also shows the menu's content in a normal window (`--details`: the details
    /// window's): easier to look at and debug than a menu-bar popover. `--snapshot out.png
    /// [--delay SECONDS]` renders that window to a file after a few seconds of live data, then
    /// quits (for checking the layout without screen-recording rights).
    @MainActor
    func applicationDidFinishLaunching(_ note: Notification) {
        AdapterMonitor.shared.start()
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let snapshot = value("--snapshot")
        let details = args.contains("--details")
        guard args.contains("--window") || details || snapshot != nil else { return }
        defer {
            if let snapshot, let view = window?.contentView {
                let delay = value("--delay").flatMap(Double.init) ?? 3
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: snapshot))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        let root = details ? AnyView(DetailsView().frame(width: 940, height: 1100)) : AnyView(MenuView())
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.title = "Nethance"
        w.styleMask = [.titled, .closable]
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}
