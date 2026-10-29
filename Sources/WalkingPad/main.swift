import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pad: Pad!
    private var statusItem: StatusItemController!
    private var settingsWindow: NSWindow?
    private var listener: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        pad = Pad()
        statusItem = StatusItemController(pad: pad, openSettings: { [weak self] in self?.showSettings() })
        listener = Control.listen { [weak self] line in
            MainActor.assumeIsolated { self?.handle(line) ?? "error: not ready" }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pad.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let line = Control.command(from: url) { _ = handle(line) }
        }
    }

    /// One command from the CLI or a URL. Returns the text to print.
    private func handle(_ line: String) -> String {
        let cmd = line.split(separator: " ").first.map(String.init) ?? ""
        switch cmd {
        case "open": statusItem.open()
        case "close": statusItem.close()
        case "popup": statusItem.toggle()
        case "status":
            let data = try? JSONSerialization.data(withJSONObject: pad.snapshot, options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        default:
            if let err = pad.perform(line) { return "error: \(err)" }
        }
        return "ok"
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(pad: pad))
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = "WalkingPad Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

if Control.runCLI(CommandLine.arguments) { exit(0) }

// Renders the popup with sample data, for the README:  WalkingPad --render-preview out.png
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-preview" {
    MainActor.assumeIsolated { Preview.render(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
