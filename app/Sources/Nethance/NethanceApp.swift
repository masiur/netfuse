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

    /// `--window` also shows the menu's content in a normal window: easier to look at and debug
    /// than a menu-bar popover. `--snapshot out.png` renders that window to a file after a few
    /// seconds of live data, then quits (for checking the layout without screen-recording rights).
    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        let snapshot = args.firstIndex(of: "--snapshot").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        guard args.contains("--window") || snapshot != nil else { return }
        defer {
            if let snapshot, let view = window?.contentView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: snapshot))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: MenuView()))
        w.title = "Nethance"
        w.styleMask = [.titled, .closable]
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}
