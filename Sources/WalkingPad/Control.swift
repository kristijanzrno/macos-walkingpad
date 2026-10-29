import AppKit
import Foundation

/// Control from outside the app, for keyboard shortcuts and scripts.
///
/// The app binary doubles as a command line tool: run with a command it posts
/// a distributed notification to the running app instead of starting a new
/// one. `walkingpad://` URLs do the same through Launch Services, which is
/// what the Shortcuts app and most launchers use.
enum Control {
    static let bundleID = "io.github.kristijanzrno.walkingpad"
    static let commandNote = Notification.Name("\(bundleID).command")
    static let replyNote = Notification.Name("\(bundleID).reply")

    static let usage = """
    Usage: walkingpad <command>

      toggle                 start / stop the belt
      start [km/h]           start the belt (optionally at a speed)
      stop                   stop the belt
      faster | slower        change speed by one step
      speed <km/h>           set the speed
      mode <manual|auto|standby>
      connect | disconnect   take or release the pad (the phone app needs it free)
      forget                 forget the saved pad
      open | close | popup   show / hide / toggle the menu bar popup
      status                 print the current state as JSON

    The WalkingPad app has to be running.
    """

    static let commands: Set<String> = [
        "toggle", "start", "stop", "faster", "slower", "speed", "mode", "connect", "disconnect",
        "forget", "open", "close", "popup", "status", "help", "--help", "-h",
    ]

    /// Handles a command line invocation. Returns false when the process was
    /// launched as the app (no arguments, or ones macOS passes like -NSDocumentRevisionsDebugMode).
    static func runCLI(_ args: [String]) -> Bool {
        guard args.count > 1, commands.contains(args[1].lowercased()) else { return false }
        let cmd = args[1].lowercased()
        if cmd == "help" || cmd.hasPrefix("-") {
            print(usage)
            exit(0)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            FileHandle.standardError.write("WalkingPad isn't running. Start it with: open -a WalkingPad\n".data(using: .utf8)!)
            exit(1)
        }

        let line = args.dropFirst().joined(separator: " ")
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        var reply: String?
        let token = center.addObserver(forName: replyNote, object: id, queue: .main) { note in
            reply = note.userInfo?["reply"] as? String ?? ""
        }
        center.postNotificationName(commandNote, object: id, userInfo: ["command": line], deliverImmediately: true)

        let deadline = Date().addingTimeInterval(3)
        while reply == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(token)

        guard let reply else {
            FileHandle.standardError.write("WalkingPad didn't answer\n".data(using: .utf8)!)
            exit(1)
        }
        if reply.hasPrefix("error: ") {
            FileHandle.standardError.write((reply.dropFirst(7) + "\n").data(using: .utf8)!)
            exit(1)
        }
        print(reply)
        exit(0)
    }

    /// Listens for CLI commands in the running app.
    static func listen(handle: @escaping (String) -> String) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: commandNote, object: nil, queue: .main) { note in
            guard let id = note.object as? String, let line = note.userInfo?["command"] as? String else { return }
            let reply = handle(line)
            center.postNotificationName(replyNote, object: id, userInfo: ["reply": reply], deliverImmediately: true)
        }
    }

    /// walkingpad://toggle, walkingpad://speed/3.5, walkingpad://mode/auto …
    static func command(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "walkingpad", let host = url.host() else { return nil }
        return ([host] + url.pathComponents.filter { $0 != "/" }).joined(separator: " ")
    }
}
