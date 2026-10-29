import CoreBluetooth
import Foundation

// The KingSmith "FE00" protocol used by the A1 / R1 / R1 Pro / C1 / C2 family.
// Frames are F7 <payload…> <sum> FD going out, F8 A2 … status frames coming
// back. Details from https://github.com/ph4r05/ph4-walkingpad.
enum PadProtocol {
    static let service = CBUUID(string: "FE00")
    static let notify = CBUUID(string: "FE01")
    static let write = CBUUID(string: "FE02")

    static let namePattern = try! NSRegularExpression(
        pattern: "walkingpad|^ks-|^r1|^a1|^c1|^c2|^z1", options: [.caseInsensitive]
    )

    /// The pad wants a little room between commands or it drops them.
    static let commandGap: TimeInterval = 0.7
    static let pollInterval: TimeInterval = 1.0

    /// F7 <payload…> <checksum> FD, checksum = sum(payload) & 0xFF.
    static func frame(_ payload: UInt8...) -> Data {
        let sum = payload.reduce(0) { ($0 + Int($1)) & 0xFF }
        return Data([0xF7] + payload + [UInt8(sum), 0xFD])
    }

    static func askStats() -> Data { frame(0xA2, 0x00, 0x00) }
    static func speed(tenths: Int) -> Data { frame(0xA2, 0x01, UInt8(max(0, min(255, tenths)))) }
    static func mode(_ mode: PadMode) -> Data { frame(0xA2, 0x02, mode.rawValue) }
    static func startBelt() -> Data { frame(0xA2, 0x04, 0x01) }

    static func matchesName(_ name: String) -> Bool {
        namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

enum PadMode: UInt8, CaseIterable, Identifiable {
    case auto = 0, manual = 1, standby = 2

    var id: UInt8 { rawValue }
    var name: String {
        switch self {
        case .auto: "auto"
        case .manual: "manual"
        case .standby: "standby"
        }
    }
    var label: String { name.capitalized }
    var help: String {
        switch self {
        case .manual: "Speed set from here or the remote"
        case .auto: "Speed follows where you stand on the belt"
        case .standby: "Sleep"
        }
    }

    init?(name: String) {
        guard let m = PadMode.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = m
    }
}

struct PadStatus: Equatable, Codable {
    /// 0 idle, 1 running, 9 starting, others = transitional
    var belt: Int
    /// km/h
    var speed: Double
    var mode: String
    /// seconds this session
    var time: Int
    /// metres this session
    var distance: Int
    var steps: Int

    var padMode: PadMode? { PadMode(name: mode) }

    /// F8 A2 frame → status, or nil for anything else.
    init?(frame d: Data) {
        let b = [UInt8](d)
        guard b.count >= 17, b[0] == 0xF8, b[1] == 0xA2 else { return nil }
        func u24(_ i: Int) -> Int { Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2]) }
        belt = Int(b[2])
        speed = Double(b[3]) / 10
        mode = PadMode(rawValue: b[4])?.name ?? String(b[4])
        time = u24(5)
        distance = u24(8) * 10
        steps = u24(11)
    }
}
