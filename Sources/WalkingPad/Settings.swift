import Foundation

/// User settings, stored in UserDefaults. Keys and values match the Omarchy
/// plugin so the two read the same way.
enum Settings {
    enum Key {
        static let barLabel = "barLabel"
        static let maxSpeed = "maxSpeed"
        static let speedStep = "speedStep"
        static let startSpeed = "startSpeed"
        static let autoConnect = "autoConnect"
    }

    static let defaults: [String: Any] = [
        Key.barLabel: "speed",
        Key.maxSpeed: 6.0,
        Key.speedStep: 0.5,
        Key.startSpeed: "2.0",
        Key.autoConnect: true,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static let minSpeed = 0.5

    /// speed | steps | today | icon
    static var barLabel: String { UserDefaults.standard.string(forKey: Key.barLabel) ?? "speed" }
    static var maxSpeed: Double { positive(Key.maxSpeed, 6.0) }
    static var speedStep: Double { positive(Key.speedStep, 0.5) }
    /// "keep" or a km/h value
    static var startSpeed: String { UserDefaults.standard.string(forKey: Key.startSpeed) ?? "2.0" }
    static var autoConnect: Bool { UserDefaults.standard.bool(forKey: Key.autoConnect) }

    private static func positive(_ key: String, _ fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
