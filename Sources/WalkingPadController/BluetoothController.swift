import AppKit
import CoreBluetooth
import Foundation

final class BluetoothController: NSObject, ObservableObject {
    @Published private(set) var activityHistory: ActivityHistory = {
        guard let data = UserDefaults.standard.data(forKey: "walkingActivityHistory"),
              let history = try? JSONDecoder().decode(ActivityHistory.self, from: data) else {
            return ActivityHistory()
        }
        return history
    }()

    func resetActivities() {
        activityHistory.reset()
        persistActivities()
    }

    private func persistActivities() {
        if let data = try? JSONEncoder().encode(activityHistory) {
            UserDefaults.standard.set(data, forKey: "walkingActivityHistory")
        }
    }
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var protocolFamily: ProtocolFamily = .unsupported
    @Published private(set) var gattEntries: [GATTEntry] = []
    @Published private(set) var warning: String?
    @Published private(set) var observationStatus = "Not connected"
    @Published private(set) var reportedSpeedRange: String?
    @Published private(set) var controlStatus = "Connect, then enable control"
    @Published private(set) var selectedMPH: Double?
    @Published private var startCountdownDeadline: TimeInterval?
    var startCountdown: Int? {
        guard let deadline = startCountdownDeadline, deadline > now else { return nil }
        return min(3, Int(ceil(deadline - now)))
    }
    @Published private(set) var distanceMeters: UInt32?
    @Published private(set) var elapsedSeconds: UInt16?
    @Published private(set) var savedDeviceID = UserDefaults.standard.string(forKey: "walkingPadDeviceID")
    @Published private(set) var savedDeviceName = UserDefaults.standard.string(forKey: "walkingPadDeviceName") ?? "No device selected"
    private var reconnectTimer: Timer?
    private var selectingDevice = false
    private var sleeping = false
    private var wakeObserver: NSObjectProtocol?
    var isRunning: Bool { (displayedSpeed ?? (lastWasMoving ? 1 : 0)) > 0.05 }
    var connectionTitle: String {
        if isReady { return controlsEnabled ? "Connected" : "Preparing controls…" }
        if savedDeviceID == nil { return "Select a device in Settings" }
        return connection.label
    }

    func chooseDevice(_ device: DiscoveredDevice) {
        if connected?.identifier == device.id {
            selectingDevice = false
            central.stopScan()
            return
        }
        closeConnection()
        savedDeviceID = device.id.uuidString
        savedDeviceName = device.name
        UserDefaults.standard.set(savedDeviceID, forKey: "walkingPadDeviceID")
        UserDefaults.standard.set(savedDeviceName, forKey: "walkingPadDeviceName")
        distanceMeters = nil; elapsedSeconds = nil
        selectingDevice = false
        connect(device)
    }

    func findDevices() {
        selectingDevice = true
        devices = []
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func finishSelectingDevice() {
        selectingDevice = false
        central.stopScan()
        reconnectIfNeeded()
    }

    private func reconnectIfNeeded() {
        guard !sleeping, !selectingDevice, central.state == .poweredOn, connected == nil,
              savedDeviceID != nil else { return }
        if !central.isScanning { scan() }
    }
    @Published private(set) var disconnectUnconfirmed = false
    @Published private var sample = SpeedSample()
    @Published private var now = ProcessInfo.processInfo.systemUptime
    @Published private var values: [String: String] = [:]
    @Published private var packetCount = 0
    @Published private var session = FTMSControlSession(confirmMotorCommandsFromTelemetry: true)
    @Published private var setupComplete = false
    @Published private var enabling = false
    @Published private var stopQueued = false
    @Published private var stopLatched = false
    @Published private var remoteStopped = false
    @Published private var leaving = false

    private enum Operation {
        case read(CBCharacteristic), subscribe(CBCharacteristic)
        var characteristic: CBCharacteristic {
            switch self { case .read(let c), .subscribe(let c): return c }
        }
    }
    private var central: CBCentralManager!
    private var connected: CBPeripheral?
    private var pendingServices = 0
    private var operations: [Operation] = []
    private var activeOperation: Operation?
    private var operationTimeout: Timer?
    private var operationDelay: DispatchWorkItem?
    private var ticker: Timer?
    private var connectTimeout: Timer?
    private var generation = 0
    private var limits: SpeedLimits?
    private var dataSubscribed = false
    private var controlSubscribed = false
    private var statusSubscribed = false
    private var everGranted = false
    private var lastWasMoving = false
    private var stopSentAt: TimeInterval?
    private var stopAccepted = false
    private var confirmedStopped = false
    private var stopDeadline: TimeInterval?
    private var shutdownDeadline: TimeInterval?
    private var terminationCompletion: ((Bool) -> Void)?
    private var lastCommandAt = -Double.infinity
    private var sleepObserver: NSObjectProtocol?

    var isReady: Bool { if case .ready = connection { return true }; return false }
    var canDisconnect: Bool { connected != nil && !leaving }
    var controlsEnabled: Bool { session.granted }
    var displayedSpeed: Double? { sample.current(at: now) }
    var displayedSpeedMPH: Double? { displayedSpeed.map { SpeedUnits.mph(fromKPH: $0) } }
    var distanceMiles: Double? { distanceMeters.map { DistanceUnits.miles(fromMeters: Double($0)) } }
    var speedCaption: String {
        if displayedSpeed != nil { return "mph · live" }
        if !isReady { return "Not connected" }
        return packetCount > 0 ? "Speed data is stale" : "Waiting for speed data"
    }
    var canEnableControl: Bool {
        isReady && setupComplete && protocolFamily == .ftms && limits?.hasDeskRange == true
        && dataSubscribed && !session.granted && session.pending == nil
        && !session.requiresReconnect && !enabling && !leaving
    }
    var canAdjustSpeed: Bool {
        isReady && session.granted && session.pending == nil && !session.requiresReconnect && !session.speedRejected
        && dataSubscribed && controlSubscribed && !stopLatched && !remoteStopped && !leaving
        && now - lastCommandAt >= 0.5
        && (sample.current(at: ProcessInfo.processInfo.systemUptime) ?? 0) > 0.05
    }
    var canStop: Bool {
        isReady && controlSubscribed && session.granted && !session.requiresReconnect && !stopQueued
        && session.pending?.command != .stop
    }
    var canStart: Bool {
        isReady && session.granted && session.pending == nil && !session.requiresReconnect
        && controlSubscribed && dataSubscribed && !leaving && !stopQueued
        && (displayedSpeed ?? (lastWasMoving ? 1 : 0)) <= 0.05
    }
    private var hasFreshStoppedReading: Bool {
        guard let speed = sample.current(at: ProcessInfo.processInfo.systemUptime) else { return false }
        return confirmedStopped && speed <= 0.05
    }
    var needsStopBeforeQuit: Bool { connected != nil && everGranted && !hasFreshStoppedReading }
    var inspectorReport: String {
        (["WalkingPad GATT report", "Bluetooth name: \(connected?.name ?? "Disconnected")",
          "Protocol: \(protocolFamily.rawValue)", "Observation: \(observationStatus)",
          "Control: \(controlStatus)", "Warning: \(warning ?? "None")",
          "Speed notifications: \(packetCount)", "Speed range: \(reportedSpeedRange ?? "Not reported")",
          "App speed ceiling: 4.0 mph",
          "Session distance (miles, last reported): \(distanceMiles.map { String(format: "%.3f", $0) } ?? "Unknown")",
          "Session distance (meters, last reported): \(distanceMeters.map(String.init) ?? "Unknown")",
          "Live speed (mph): \(displayedSpeedMPH.map { String(format: "%.2f", $0) } ?? "Unknown")",
          "Bluetooth speed (km/h): \(displayedSpeed.map { String(format: "%.2f", $0) } ?? "Unknown")"]
         + values.keys.sorted().map { "\($0): \(values[$0]!)" }
         + ["Service\tCharacteristic\tProperties"]
         + gattEntries.map { "\($0.service)\t\($0.characteristic)\t\($0.properties)" }).joined(separator: "\n")
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconnectIfNeeded()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sleeping = false
            self?.reconnectIfNeeded()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true
            self.central.stopScan()
            guard let p = self.connected else { return }
            self.warning = "Disconnected while Mac sleeps."
            self.invalidateConnection()
            self.central.cancelPeripheralConnection(p)
            self.connection = .disconnected("Disconnected for sleep")
        }
    }

    func scan() {
        guard central.state == .poweredOn, connected == nil else { return }
        devices = []; connection = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, token == self.generation, self.connected == nil, !self.selectingDevice else { return }
            self.central.stopScan(); self.connection = .idle
        }
    }

    func connect(_ device: DiscoveredDevice) {
        guard central.state == .poweredOn, connected == nil else { return }
        central.stopScan()
        invalidateConnection()
        values = [:]; gattEntries = []; reportedSpeedRange = nil; limits = nil
        protocolFamily = .unsupported; packetCount = 0; warning = nil
        selectedMPH = nil
        lastWasMoving = false; confirmedStopped = false; everGranted = false
        connected = device.peripheral
        device.peripheral.delegate = self
        connection = .connecting(device.name)
        central.connect(device.peripheral)
        connectTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, let p = self.connected else { return }
            self.warning = "Connection timed out. Retrying…"
            self.invalidateConnection()
            self.central.cancelPeripheralConnection(p)
            self.connection = .disconnected("Connection timed out")
        }
    }

    func enableControl() {
        guard canEnableControl,
              let cp = characteristic(WalkingPadUUID.controlPoint),
              cp.properties.contains(.write), cp.properties.contains(.indicate),
              let status = characteristic(WalkingPadUUID.machineStatus), status.properties.contains(.notify) else { return }
        warning = nil; enabling = true
        controlStatus = "Preparing command replies…"
        if !statusSubscribed { operations.append(.subscribe(status)) }
        if !controlSubscribed { operations.append(.subscribe(cp)) }
        nextOperation()
    }

    func setSpeedMPH(_ mph: Double) {
        guard canAdjustSpeed, let limits,
              let current = sample.current(at: ProcessInfo.processInfo.systemUptime) else { return }
        guard let target = limits.target(mph: mph), abs(Double(target) / 100 - current) > 0.001 else { return }
        selectedMPH = SpeedUnits.mph(fromKPH: Double(target) / 100)
        send(.speed(target))
    }

    func start() {
        guard canStart else { return }
        warning = nil
        stopLatched = false; remoteStopped = false; confirmedStopped = false
        stopAccepted = false; stopSentAt = nil; stopDeadline = nil
        selectedMPH = nil
        send(.start)
    }

    func stop() {
        guard canStop else { return }
        stopLatched = true; stopAccepted = false; confirmedStopped = false
        session.makeRoomForStop()
        if session.pending != nil {
            stopQueued = true // Stop is the only queued action; speed changes are never queued.
            controlStatus = "Stop queued behind the current reply — remote remains available"
        } else { send(.stop) }
    }

    func disconnect() {
        guard connected != nil, !leaving else { return }
        if everGranted && !hasFreshStoppedReading {
            guard canStop || session.pending != nil else {
                disconnectUnconfirmed = true
                warning = "Stop with the remote before choosing Disconnect anyway."
                return
            }
            leaving = true; shutdownDeadline = ProcessInfo.processInfo.systemUptime + 10
            stop()
        } else { closeConnection() }
    }

    func disconnectAnyway() { closeConnection() }

    func stopBeforeTermination(completion: @escaping (Bool) -> Void) {
        guard needsStopBeforeQuit else { completion(true); return }
        guard canStop || session.pending != nil else { completion(false); return }
        terminationCompletion = completion
        leaving = true; shutdownDeadline = ProcessInfo.processInfo.systemUptime + 10
        stop()
    }

    private func characteristic(_ uuid: CBUUID, service: CBUUID = WalkingPadUUID.ftmsService) -> CBCharacteristic? {
        connected?.services?.first { $0.uuid == service }?.characteristics?.first { $0.uuid == uuid }
    }

    private func finishDiscovery() {
        connectTimeout?.invalidate(); connectTimeout = nil
        if characteristic(WalkingPadUUID.treadmillData) != nil && characteristic(WalkingPadUUID.controlPoint) != nil {
            protocolFamily = .ftms
        }
        connection = .ready(connected?.name ?? "WalkingPad")
        guard protocolFamily == .ftms else {
            observationStatus = "Unsupported profile"
            warning = "This device is not supported. Choose your WalkingPad in Settings."
            return
        }
        for (service, uuid) in [
            (WalkingPadUUID.ftmsService, WalkingPadUUID.fitnessFeature),
            (WalkingPadUUID.ftmsService, WalkingPadUUID.speedRange),
            (WalkingPadUUID.deviceInformation, WalkingPadUUID.modelNumber),
            (WalkingPadUUID.deviceInformation, WalkingPadUUID.firmwareRevision)
        ] {
            if let c = characteristic(uuid, service: service), c.properties.contains(.read) { operations.append(.read(c)) }
        }
        if let c = characteristic(WalkingPadUUID.treadmillData), c.properties.contains(.notify) {
            operations.append(.subscribe(c))
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        nextOperation()
    }

    private func nextOperation() {
        guard activeOperation == nil, operationDelay == nil, let p = connected, p.state == .connected else { return }
        guard !operations.isEmpty else {
            setupComplete = true
            observationStatus = dataSubscribed ? "Listening for speed reports" : "Speed subscription unavailable"
            if enabling {
                enabling = false
                if controlSubscribed && statusSubscribed { send(.requestControl) }
                else {
                    warning = "Control setup failed. Reconnecting…"
                    closeConnection()
                }
            } else if canEnableControl {
                enableControl()
            } else if !session.granted && session.pending == nil {
                warning = "Control unavailable for this device. Check your selection in Settings."
            }
            return
        }
        let op = operations.removeFirst()
        activeOperation = op
        operationTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.operations = []; self.activeOperation = nil; self.enabling = false
            self.setupComplete = false; self.session.invalidate()
            self.warning = "Bluetooth setup timed out. Reconnecting…"
            self.closeConnection()
        }
        switch op {
        case .read(let c): observationStatus = "Reading device information…"; p.readValue(for: c)
        case .subscribe(let c): p.setNotifyValue(true, for: c)
        }
    }

    private func finishOperation(_ c: CBCharacteristic, subscription: Bool) {
        guard let op = activeOperation, op.characteristic === c else { return }
        switch op {
        case .read where subscription: return
        case .subscribe where !subscription: return
        default: break
        }
        operationTimeout?.invalidate(); operationTimeout = nil; activeOperation = nil
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.operationDelay = nil; self.nextOperation()
        }
        operationDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func send(_ command: FTMSControlSession.Command) {
        guard let p = connected, p.state == .connected, controlSubscribed,
              let cp = characteristic(WalkingPadUUID.controlPoint), cp.isNotifying,
              let payload = session.begin(command, now: ProcessInfo.processInfo.systemUptime) else { return }
        lastCommandAt = ProcessInfo.processInfo.systemUptime
        values["Last command"] = hex(payload)
        switch command {
        case .start:
            now = ProcessInfo.processInfo.systemUptime
            startCountdownDeadline = now + 3
            controlStatus = "Starting — waiting for belt movement"
        case .requestControl: controlStatus = "Requesting treadmill control…"
        case .speed: controlStatus = "Waiting for speed-command reply…"
        case .stop:
            startCountdownDeadline = nil
            controlStatus = "Stop sent — waiting for confirmation"
            confirmedStopped = false
            stopSentAt = ProcessInfo.processInfo.systemUptime; stopDeadline = stopSentAt! + 10
        }
        p.writeValue(payload, for: cp, type: .withResponse)
    }

    private func handle(_ outcome: FTMSControlSession.Outcome?) {
        guard let outcome else { return }
        switch outcome {
        case .accepted(.start): controlStatus = "Running — adjust speed with the slider"
        case .accepted(.requestControl):
            warning = nil
            everGranted = true
            controlStatus = "Control granted — ready"
        case .accepted(.speed): controlStatus = "Speed confirmed"
        case .speedSent: controlStatus = "Speed sent"
        case .motorSent: controlStatus = "Command sent"
        case .accepted(.stop):
            stopAccepted = true
            if hasFreshStoppedReading { stopDeadline = nil }
            controlStatus = confirmedStopped ? "Stopped — confirmed by speed data" : "Stop accepted — awaiting zero speed"
            finishShutdownIfStopped()
        case .failed(let message):
            startCountdownDeadline = nil
            warning = message; controlStatus = message
            // A rejected speed can still be followed by the user's queued Stop.
            if !session.granted || session.requiresReconnect { stopQueued = false }
            if session.requiresReconnect { closeConnection() }
        }
        if stopQueued && session.pending == nil && session.granted && !session.requiresReconnect {
            stopQueued = false; send(.stop)
        }
    }

    private func tick() {
        now = ProcessInfo.processInfo.systemUptime
        handle(session.tick(now: now))
        if session.granted && displayedSpeed == nil && !stopLatched && session.pending == nil {
            controlStatus = "No fresh speed data — speed changes disabled; Stop remains available"
        }
        if let deadline = stopDeadline, now >= deadline, !confirmedStopped {
            stopDeadline = nil
            controlStatus = "Stop sent"
        }
        if let deadline = shutdownDeadline, now >= deadline {
            shutdownDeadline = nil; leaving = false; disconnectUnconfirmed = true

            let completion = terminationCompletion; terminationCompletion = nil
            completion?(false)
        }
    }

    private func finishShutdownIfStopped() {
        guard hasFreshStoppedReading && stopAccepted && leaving else { return }
        let completion = terminationCompletion; terminationCompletion = nil
        shutdownDeadline = nil
        closeConnection()
        completion?(true)
    }

    private func closeConnection() {
        guard let p = connected else { return }
        invalidateConnection()
        central.cancelPeripheralConnection(p)
        connection = .idle
    }

    private func invalidateConnection() {
        startCountdownDeadline = nil
        generation += 1
        operationTimeout?.invalidate(); connectTimeout?.invalidate(); ticker?.invalidate(); operationDelay?.cancel()
        operationTimeout = nil; connectTimeout = nil; ticker = nil; operationDelay = nil
        operations = []; activeOperation = nil; connected = nil
        setupComplete = false; dataSubscribed = false; controlSubscribed = false; statusSubscribed = false
        enabling = false; stopQueued = false; stopLatched = false; remoteStopped = false
        session = FTMSControlSession(confirmMotorCommandsFromTelemetry: true); sample = SpeedSample(); leaving = false; disconnectUnconfirmed = false
        shutdownDeadline = nil; stopDeadline = nil; stopSentAt = nil; stopAccepted = false
        observationStatus = "Not connected"; controlStatus = "Connect, then enable control"
        let completion = terminationCompletion; terminationCompletion = nil
        completion?(false)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension BluetoothController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            if connected != nil { warning = "Bluetooth unavailable. Belt state is unknown; use the remote." }
            invalidateConnection()
        }
        switch central.state {
        case .poweredOn: connection = .idle; reconnectIfNeeded()
        case .poweredOff: connection = .bluetoothUnavailable("Bluetooth is off")
        case .unauthorized: connection = .bluetoothUnavailable("Bluetooth permission is required")
        default: connection = .bluetoothUnavailable("Bluetooth is unavailable")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard (connected == nil || selectingDevice), rssi.intValue != 127 else { return }
        let device = DiscoveredDevice(id: p.identifier, peripheral: p,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Unnamed device",
            rssi: rssi.intValue, advertisedServices: advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device }
        else { devices.append(device) }
        devices.sort { $0.rssi > $1.rssi }
        if !selectingDevice, device.id.uuidString == savedDeviceID { connect(device) }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === connected else { return }
        connection = .discovering(p.name ?? "WalkingPad"); p.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === connected else { return }
        invalidateConnection()
        connection = .disconnected("Connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === connected else { return }
        invalidateConnection()
        connection = .disconnected("Reconnecting…")
        warning = "Connection lost. Reconnecting…"
    }
}

extension BluetoothController: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === connected else { return }
        guard error == nil, let services = p.services else { warning = "Service discovery failed"; return }
        pendingServices = services.count
        if services.isEmpty { finishDiscovery() }
        for service in services { p.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === connected else { return }
        if let error { warning = "Incomplete discovery: \(error.localizedDescription)" }
        for c in service.characteristics ?? [] {
            let flags: [(CBCharacteristicProperties, String)] = [(.read, "read"), (.write, "write"),
                (.writeWithoutResponse, "write without response"), (.notify, "notify"), (.indicate, "indicate")]
            gattEntries.append(GATTEntry(service: service.uuid.uuidString, characteristic: c.uuid.uuidString,
                properties: flags.filter { c.properties.contains($0.0) }.map { $0.1 }.joined(separator: ", ")))
        }
        pendingServices -= 1
        if pendingServices == 0 { finishDiscovery() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === connected, c.service?.uuid == WalkingPadUUID.ftmsService else { return }
        let enabled = error == nil && c.isNotifying
        values["\(c.uuid.uuidString) subscription"] = error?.localizedDescription ?? (enabled ? "Enabled" : "Disabled")
        switch c.uuid {
        case WalkingPadUUID.treadmillData: dataSubscribed = enabled; if !enabled { sample = SpeedSample() }
        case WalkingPadUUID.controlPoint: controlSubscribed = enabled
        case WalkingPadUUID.machineStatus: statusSubscribed = enabled
        default: break
        }
        if !enabled && session.granted {
            session.invalidate(); stopQueued = false
            warning = "Bluetooth subscription lost. Reconnecting…"
            closeConnection()
            return
        }
        finishOperation(c, subscription: true)
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === connected, c === characteristic(WalkingPadUUID.controlPoint) else { return }
        handle(session.didWrite(error: error?.localizedDescription))
        if stopQueued && error == nil {
            session.makeRoomForStop()
            if session.pending == nil && session.granted {
                stopQueued = false
                send(.stop)
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === connected else { return }
        defer { finishOperation(c, subscription: false) }
        let key = c.uuid.uuidString
        if let error { values[key] = error.localizedDescription; return }
        guard let data = c.value else { return }
        if c.service?.uuid == WalkingPadUUID.deviceInformation {
            guard c.uuid == WalkingPadUUID.modelNumber || c.uuid == WalkingPadUUID.firmwareRevision else { return }
            values[key] = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "Invalid UTF-8"
            return
        }
        guard c.service?.uuid == WalkingPadUUID.ftmsService else { return }
        values[key] = hex(data)
        switch c.uuid {
        case WalkingPadUUID.speedRange:
            limits = SpeedLimits(data: data)
            if let limits {
                reportedSpeedRange = String(format: "Device: %.1f–%.1f mph · App ceiling: 4.0 mph",
                    SpeedUnits.mph(fromKPH: Double(limits.minimum) / 100),
                    SpeedUnits.mph(fromKPH: Double(limits.maximum) / 100))
            } else { reportedSpeedRange = "Invalid speed limits — controls disabled" }
        case WalkingPadUUID.controlPoint: handle(session.receive(data))
        case WalkingPadUUID.machineStatus:
            if data.first == 0xFF {
                session.invalidate(); stopQueued = false
                warning = "Control connection lost. Reconnecting…"
                closeConnection()
            } else if data.first == 2 || data.first == 3 {
                remoteStopped = true
            } else if data.first == 4 {
                remoteStopped = false
                if session.pending == nil && !leaving { stopLatched = false }
            }
        case WalkingPadUUID.treadmillData:
            packetCount += 1
            activityHistory.observe(device: p.identifier.uuidString,
                meters: TreadmillParser.ftmsDistanceMeters(data),
                seconds: TreadmillParser.ftmsElapsedSeconds(data),
                speed: TreadmillParser.ftmsSpeed(data))
            persistActivities()
            // Distance may appear in a split packet with no instantaneous speed.
            if let meters = TreadmillParser.ftmsDistanceMeters(data) { distanceMeters = meters }
            if let seconds = TreadmillParser.ftmsElapsedSeconds(data) { elapsedSeconds = seconds }
            guard let speed = TreadmillParser.ftmsSpeed(data) else { return }
            now = ProcessInfo.processInfo.systemUptime; sample.receive(speed, at: now)
            handle(session.observeSpeed(kph: speed))
            guard p === connected else { return }
            lastWasMoving = speed > 0.05
            if speed <= 0.05 {
                selectedMPH = nil
                confirmedStopped = true
                if stopLatched && stopSentAt != nil {
                    if stopAccepted {
                        stopDeadline = nil
                        controlStatus = "Stopped — confirmed by speed data"
                    }
                    finishShutdownIfStopped()
                }
            } else {
                // A fresh zero-to-moving transition can reflect a subsequent remote start.
                if confirmedStopped && stopAccepted && session.pending == nil && !leaving {
                    stopLatched = false; remoteStopped = false
                }
                confirmedStopped = false
                if session.granted && session.pending == nil && !stopLatched && !session.speedRejected {
                    controlStatus = "Speed control ready"
                }
            }
        default: break
        }
    }
}
