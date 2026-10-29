import CoreBluetooth
import Foundation
import Observation

/// Owns the Bluetooth link to the pad and mirrors its state for the UI.
///
/// Everything runs on the main queue: CoreBluetooth delivers its callbacks
/// there, and commands and stat polls share one queue so the pad always gets
/// its breathing room between frames.
@Observable
final class Pad: NSObject {
    enum Connection: String {
        case idle, scanning, connecting, connected, disconnected, bluetoothOff, unauthorized
    }

    struct SavedDevice: Codable {
        var identifier: UUID
        var name: String
    }

    // Mirrored state -----------------------------------------------------------

    private(set) var connection: Connection = .idle
    private(set) var deviceName = ""
    private(set) var deviceID: UUID?
    private(set) var error = ""
    private(set) var status: PadStatus?
    private(set) var today = DayTotals()
    private(set) var week: [DayEntry] = []

    /// Optimistic target speed: set on click, cleared once the pad agrees or
    /// gives up, so the slider doesn't snap back while the command is in flight.
    private(set) var pendingSpeed: Double?

    var connected: Bool { connection == .connected }
    var busy: Bool { connection == .scanning || connection == .connecting }
    var belt: Int { status?.belt ?? -1 }
    var running: Bool { connected && belt == 1 }
    var starting: Bool { connected && belt == 9 }
    var mode: PadMode? { status?.padMode }
    var speed: Double { status?.speed ?? 0 }
    var displaySpeed: Double { pendingSpeed ?? speed }

    var statusText: String {
        switch connection {
        case .scanning: return "Searching for WalkingPad…"
        case .connecting: return "Connecting…"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access needed"
        case .idle, .disconnected: return error.isEmpty ? "Not connected" : "Disconnected"
        case .connected: break
        }
        guard let status else { return "Connected" }
        let modeName = status.padMode?.label ?? status.mode
        if running { return "Walking · \(modeName)" }
        if starting { return "Starting belt…" }
        if status.padMode == .standby { return "Standby" }
        return "Ready · \(modeName)"
    }

    // Bluetooth ----------------------------------------------------------------

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var notifyChar: CBCharacteristic?
    @ObservationIgnored private let history = History()

    @ObservationIgnored private(set) var wantConnected: Bool
    @ObservationIgnored private var userDisconnect = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var backoff: TimeInterval = 3
    @ObservationIgnored private var retryWork: DispatchWorkItem?

    @ObservationIgnored private var queue: [Data] = []
    @ObservationIgnored private var pumpScheduled = false
    @ObservationIgnored private var nextCommandAt = Date.distantPast
    @ObservationIgnored private var lastCommandAt = Date.distantPast
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var pendingTimeout: DispatchWorkItem?
    /// (km/h, deadline) to apply once the belt runs
    @ObservationIgnored private var startSpeed: (Double, Date)?

    /// Called on every state change, for the CLI status mirror.
    @ObservationIgnored var onChange: (() -> Void)?

    override init() {
        wantConnected = Settings.autoConnect
        super.init()
        if let saved = Storage.read("device.json", as: SavedDevice.self) {
            deviceID = saved.identifier
            deviceName = saved.name
        }
        refreshHistory()
        central = CBCentralManager(delegate: self, queue: .main)
        pollTimer = Timer.scheduledTimer(withTimeInterval: PadProtocol.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Keep "today" right across midnight even when nothing is walking.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.history.flush()
            self?.refreshHistory()
        }
    }

    /// A disconnected copy filled with sample data, for rendering screenshots.
    init(previewWithSampleData: Void) {
        wantConnected = false
        super.init()
        connection = .connected
        deviceName = "R1 Pro"
        deviceID = UUID()
        var st = PadStatus(frame: Data([0xF8, 0xA2, 1, 25, 1, 0, 0x0B, 0x5E, 0, 0, 0xD7, 0, 0x0B, 0xB8, 0, 0, 0]))!
        st.speed = 2.5
        status = st
        let steps = [4120, 6830, 0, 9210, 5340, 7720, 3000 + st.steps]
        week = history.recent(7).enumerated().map { i, d in
            DayEntry(date: d.date, key: d.key, totals: DayTotals(steps: steps[i], distance: steps[i] * 6 / 10, time: steps[i] * 6 / 10))
        }
        today = week.last!.totals
    }

    // Public commands ----------------------------------------------------------

    func start() {
        let s = Settings.startSpeed
        startBelt(at: s == "keep" ? nil : Double(s))
    }

    func stop() {
        clearPending()
        guard requireConnected() else { return }
        startSpeed = nil
        enqueue(PadProtocol.speed(tenths: 0))
    }

    func toggleBelt() { running || starting ? stop() : start() }

    func setSpeed(_ v: Double) {
        guard requireConnected() else { return }
        let s = clamp(v)
        pendingSpeed = s
        pendingTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingSpeed = nil }
        pendingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        enqueue(PadProtocol.speed(tenths: Int((s * 10).rounded())))
    }

    func faster() { if running { setSpeed(displaySpeed + Settings.speedStep) } }
    func slower() { if running { setSpeed(displaySpeed - Settings.speedStep) } }

    func setMode(_ m: PadMode) {
        guard requireConnected() else { return }
        enqueue(PadProtocol.mode(m))
    }

    func cycleMode() {
        let order: [PadMode] = [.manual, .auto, .standby]
        let i = mode.flatMap { order.firstIndex(of: $0) } ?? -1
        setMode(order[(i + 1) % order.count])
    }

    func connect() {
        wantConnected = true
        userDisconnect = false
        backoff = 3
        guard !connected, !busy else { return }
        retryWork?.cancel()
        connectOnce()
    }

    func disconnect() {
        wantConnected = false
        retryWork?.cancel()
        attempt += 1
        central.stopScan()
        if let p = peripheral {
            userDisconnect = true
            central.cancelPeripheralConnection(p)
        }
        setConnection(.idle)
    }

    func toggleConnection() { connected || busy ? disconnect() : connect() }

    func forget() {
        disconnect()
        Storage.remove("device.json")
        deviceID = nil
        deviceName = ""
        emit()
    }

    func settingsChanged() {
        if Settings.autoConnect && !wantConnected && connection != .connected { connect() }
    }

    /// Text commands, for the CLI and walkingpad:// URLs:
    /// start | stop | toggle | faster | slower | speed <km/h> | mode <manual|auto|standby>
    /// connect | disconnect | forget
    @discardableResult
    func perform(_ line: String) -> String? {
        let parts = line.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
        guard let cmd = parts.first else { return "No command" }
        let arg = parts.count > 1 ? parts[1] : nil
        let beltCommands: Set = ["start", "stop", "toggle", "faster", "slower", "speed", "mode"]
        if beltCommands.contains(cmd) && !connected { return "Not connected" }
        switch cmd {
        case "start": startBelt(at: arg.flatMap(Double.init) ?? (Settings.startSpeed == "keep" ? nil : Double(Settings.startSpeed)))
        case "stop": stop()
        case "toggle": toggleBelt()
        case "faster": faster()
        case "slower": slower()
        case "speed":
            guard let v = arg.flatMap(Double.init) else { return "Usage: speed <km/h>" }
            setSpeed(v)
        case "mode":
            guard let m = arg.flatMap(PadMode.init(name:)) else { return "Usage: mode <manual|auto|standby>" }
            setMode(m)
        case "connect": connect()
        case "disconnect": disconnect()
        case "forget": forget()
        default: return "Unknown command: \(line)"
        }
        return nil
    }

    func shutdown() {
        history.flush(force: true)
        // Leave the pad free for the phone app once we let go.
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    var snapshot: [String: Any] {
        var s: [String: Any] = [
            "connection": connection.rawValue,
            "device": deviceName,
            "statusText": statusText,
            "error": error,
            "today": ["steps": today.steps, "distance": today.distance, "time": today.time],
        ]
        if let st = status {
            s["status"] = ["belt": st.belt, "speed": st.speed, "mode": st.mode,
                           "time": st.time, "distance": st.distance, "steps": st.steps]
        }
        return s
    }

    // Internals ----------------------------------------------------------------

    private func clamp(_ v: Double) -> Double {
        (max(Settings.minSpeed, min(Settings.maxSpeed, v)) * 10).rounded() / 10
    }

    private func clearPending() {
        pendingTimeout?.cancel()
        pendingSpeed = nil
    }

    private func requireConnected() -> Bool {
        if connected { return true }
        error = "Not connected"
        emit()
        return false
    }

    private func startBelt(at target: Double?) {
        guard requireConnected() else { return }
        if let m = mode, m != .manual { enqueue(PadProtocol.mode(.manual)) }
        enqueue(PadProtocol.startBelt())
        // The pad ignores speed changes until the belt is actually moving,
        // so the start speed waits for the first "running" status.
        startSpeed = target.map { (clamp($0), Date().addingTimeInterval(20)) }
    }

    private func refreshHistory() {
        week = history.recent(7)
        today = week.last?.totals ?? DayTotals()
    }

    private func emit() { onChange?() }

    private func setConnection(_ c: Connection, error e: String = "") {
        connection = c
        error = e
        if c != .connected {
            status = nil
            writeChar = nil
            notifyChar = nil
            queue.removeAll()
            startSpeed = nil
            clearPending()
            history.resetBaseline()
        }
        emit()
    }

    // Command queue: one frame at a time, spaced by the command gap.

    private func enqueue(_ frame: Data) {
        queue.append(frame)
        schedulePump()
    }

    private func schedulePump() {
        guard !pumpScheduled, !queue.isEmpty else { return }
        pumpScheduled = true
        let delay = max(0, nextCommandAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pumpScheduled = false
            guard !self.queue.isEmpty else { return }
            self.write(self.queue.removeFirst())
            self.nextCommandAt = Date().addingTimeInterval(PadProtocol.commandGap)
            self.lastCommandAt = Date()
            self.schedulePump()
        }
    }

    private func poll() {
        guard connected, queue.isEmpty, !pumpScheduled,
              Date().timeIntervalSince(lastCommandAt) >= PadProtocol.pollInterval else { return }
        write(PadProtocol.askStats())
        history.flush()
    }

    private func write(_ data: Data) {
        guard let p = peripheral, let c = writeChar else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: c, type: type)
    }

    // Connection

    private func connectOnce() {
        guard wantConnected else { return }
        switch central.state {
        case .poweredOn: break
        case .unauthorized:
            setConnection(.unauthorized, error: "Allow WalkingPad to use Bluetooth in System Settings › Privacy & Security › Bluetooth.")
            return
        case .unknown, .resetting:
            return // centralManagerDidUpdateState will call back
        default:
            setConnection(.bluetoothOff, error: "Bluetooth is off")
            return
        }

        attempt += 1
        let token = attempt

        // Already connected at the system level (e.g. by a previous run)?
        if let p = central.retrieveConnectedPeripherals(withServices: [PadProtocol.service])
            .first(where: { deviceID == nil || $0.identifier == deviceID }) {
            open(p, token: token)
            return
        }
        if let id = deviceID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            open(p, token: token)
            return
        }

        setConnection(.scanning)
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.attempt == token, self.connection == .scanning else { return }
            self.central.stopScan()
            self.failed("WalkingPad not found. Is it powered on and not connected to the phone app?")
        }
    }

    private func open(_ p: CBPeripheral, token: Int) {
        peripheral = p
        p.delegate = self
        userDisconnect = false
        if let n = p.name, !n.isEmpty { deviceName = n }
        setConnection(.connecting)
        central.connect(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.attempt == token, self.connection == .connecting else { return }
            self.central.cancelPeripheralConnection(p)
            self.failed("Couldn't connect. Is the pad powered on and not connected to the phone app?")
        }
    }

    private func failed(_ message: String) {
        attempt += 1
        if let p = peripheral, p.state != .disconnected {
            userDisconnect = true
            central.cancelPeripheralConnection(p)
        }
        setConnection(.disconnected, error: message)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wantConnected else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connectOnce() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(30, backoff * 2)
    }

    private func didBecomeReady(_ p: CBPeripheral) {
        backoff = 3
        deviceID = p.identifier
        deviceName = p.name ?? (deviceName.isEmpty ? "WalkingPad" : deviceName)
        Storage.write(SavedDevice(identifier: p.identifier, name: deviceName), to: "device.json")
        setConnection(.connected)
        poll()
    }

    private func handle(status st: PadStatus) {
        if let (target, deadline) = startSpeed, st.belt == 1 {
            startSpeed = nil
            if Date() < deadline { setSpeed(target) }
        }
        if let p = pendingSpeed, abs(st.speed - p) < 0.05 { clearPending() }
        if error == "Not connected" { error = "" }
        if status != st { status = st }
        history.update(st)
        refreshHistory()
        emit()
    }
}

// MARK: - CoreBluetooth

extension Pad: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantConnected, !connected, !busy { connectOnce() }
            else if connection == .bluetoothOff || connection == .unauthorized { setConnection(.idle) }
        case .unauthorized:
            setConnection(.unauthorized, error: "Allow WalkingPad to use Bluetooth in System Settings › Privacy & Security › Bluetooth.")
        case .poweredOff, .unsupported:
            attempt += 1
            peripheral = nil
            setConnection(.bluetoothOff, error: "Bluetooth is off")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connection == .scanning else { return }
        let match: Bool
        if let id = deviceID {
            match = p.identifier == id
        } else {
            let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
            match = uuids.contains(PadProtocol.service) || PadProtocol.matchesName(name)
        }
        guard match else { return }
        central.stopScan()
        if deviceName.isEmpty, let n = advertisementData[CBAdvertisementDataLocalNameKey] as? String { deviceName = n }
        open(p, token: attempt)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([PadProtocol.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        failed(error?.localizedDescription ?? "Couldn't connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        if userDisconnect {
            userDisconnect = false
            return
        }
        if connection == .connected || connection == .connecting {
            setConnection(.disconnected, error: "Connection lost")
            scheduleRetry()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == PadProtocol.service }) else {
            return failed("This device doesn't expose the WalkingPad FE00 service")
        }
        p.discoverCharacteristics([PadProtocol.notify, PadProtocol.write], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        writeChar = chars.first { $0.uuid == PadProtocol.write }
        notifyChar = chars.first { $0.uuid == PadProtocol.notify }
        guard let n = notifyChar, writeChar != nil else {
            return failed("This device doesn't expose the WalkingPad FE01/FE02 characteristics")
        }
        p.setNotifyValue(true, for: n)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == PadProtocol.notify, connection == .connecting else { return }
        if let error { return failed(error.localizedDescription) }
        didBecomeReady(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == PadProtocol.notify, let data = c.value, let st = PadStatus(frame: data) else { return }
        handle(status: st)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            self.error = error.localizedDescription
            emit()
        }
    }
}
