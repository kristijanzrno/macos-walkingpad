import Foundation

struct DayTotals: Codable, Equatable {
    var steps = 0
    /// metres
    var distance = 0
    /// seconds
    var time = 0
}

struct DayEntry: Identifiable, Equatable {
    var date: Date
    var key: String
    var totals: DayTotals
    var id: String { key }
}

enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WalkingPad", isDirectory: true)
    }()

    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Per-day totals built from the pad's per-session counters.
///
/// The pad's counters only go up within a session and drop back to zero when
/// a new one begins, so a drop means "new session": count the new value from
/// zero instead of as a negative delta.
final class History {
    static let file = "history.json"
    static let keepDays = 30

    private(set) var days: [String: DayTotals]
    private var last: (Int, Int, Int)?
    private var dirtySince: Date?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        days = Storage.read(Self.file, as: [String: DayTotals].self) ?? [:]
    }

    static func key(for date: Date) -> String { formatter.string(from: date) }

    func update(_ s: PadStatus) {
        let cur = (s.steps, s.distance, s.time)
        guard let prev = last else {
            // First reading after (re)connecting: we can't know what part of it
            // was already counted, so just take it as the baseline.
            last = cur
            return
        }
        func delta(_ c: Int, _ p: Int) -> Int { c >= p ? c - p : c }
        let d = (delta(cur.0, prev.0), delta(cur.1, prev.1), delta(cur.2, prev.2))
        last = cur
        guard d.0 != 0 || d.1 != 0 || d.2 != 0 else { return }
        let k = Self.key(for: Date())
        var day = days[k] ?? DayTotals()
        day.steps += d.0
        day.distance += d.1
        day.time += d.2
        days[k] = day
        if dirtySince == nil { dirtySince = Date() }
    }

    func resetBaseline() { last = nil }

    func flush(force: Bool = false) {
        guard let since = dirtySince else { return }
        if !force && Date().timeIntervalSince(since) < 30 { return }
        let keep = days.keys.sorted().suffix(Self.keepDays)
        days = days.filter { keep.contains($0.key) }
        Storage.write(days, to: Self.file)
        dirtySince = nil
    }

    func recent(_ n: Int = 7) -> [DayEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            let k = Self.key(for: d)
            return DayEntry(date: d, key: k, totals: days[k] ?? DayTotals())
        }
    }
}
