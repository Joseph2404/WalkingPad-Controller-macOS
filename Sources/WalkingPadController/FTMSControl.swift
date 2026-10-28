import Foundation

struct SpeedLimits: Equatable {
    let minimum: Int
    let maximum: Int
    let increment: Int
    static let deskCapMPH = 4.0

    init?(data: Data) {
        guard data.count == 6 else { return nil }
        let b = Array(data)
        minimum = Int(b[0]) | Int(b[1]) << 8
        maximum = Int(b[2]) | Int(b[3]) << 8
        increment = Int(b[4]) | Int(b[5]) << 8
        guard minimum < maximum, increment > 0, increment <= maximum - minimum else { return nil }
    }

    var cappedMaximum: Int {
        min(maximum, Int((Self.deskCapMPH * 1.609344 * 100).rounded(.down)))
    }
    var hasDeskRange: Bool { minimum <= cappedMaximum }

    /// Quantize to the reported grid, then enforce limits again to prevent rounding overshoot.
    func target(mph: Double) -> Int? {
        guard mph.isFinite, mph > 0, mph <= Self.deskCapMPH + 0.000001, hasDeskRange else { return nil }
        let raw = mph * 1.609344 * 100
        let maxSteps = (cappedMaximum - minimum) / increment
        let steps = min(maxSteps, max(0, Int(((raw - Double(minimum)) / Double(increment)).rounded())))
        return minimum + steps * increment
    }
}

/// One FTMS procedure at a time. ATT acknowledgement is NOT command acceptance.
struct FTMSControlSession {
    // KS-Z1D can apply motor commands without sending a control-point indication.
    var confirmMotorCommandsFromTelemetry = false
    enum Command: Equatable {
        case requestControl
        case start
        case speed(Int) // Hundredths of km/h, already bounded and quantized.
        case stop

        var opcode: UInt8 {
            switch self { case .requestControl: return 0; case .start: return 7; case .speed: return 2; case .stop: return 8 }
        }
        var payload: Data {
            switch self {
            case .requestControl: return Data([0])
            case .start: return Data([7])
            case .speed(let value): return Data([2, UInt8(value & 255), UInt8((value >> 8) & 255)])
            case .stop: return Data([8, 1])
            }
        }
    }
    struct Pending {
        let command: Command
        let deadline: TimeInterval
        var writeAcknowledged = false
        var result: UInt8?
        var telemetryConfirmed = false
    }
    enum Outcome: Equatable {
        case accepted(Command)
        case speedSent
        case motorSent
        case failed(String)
    }

    private(set) var granted = false
    private(set) var pending: Pending?
    private(set) var requiresReconnect = false
    private(set) var speedRejected = false

    mutating func begin(_ command: Command, now: TimeInterval) -> Data? {
        guard pending == nil, !requiresReconnect else { return nil }
        if command != .requestControl && !granted { return nil }
        if case .speed(let value) = command {
            guard !speedRejected, value > 0, value <= 65535 else { return nil }
        }
        pending = Pending(command: command, deadline: now + (confirmMotorCommandsFromTelemetry && command != .requestControl ? 10 : 3))
        return command.payload
    }

    mutating func didWrite(error: String?) -> Outcome? {
        guard pending != nil else { return nil }
        if let error {
            invalidate()
            return .failed("Bluetooth write failed: \(error). Use the remote; reconnect before more commands.")
        }
        pending?.writeAcknowledged = true
        return finishIfComplete()
    }

    mutating func receive(_ data: Data) -> Outcome? {
        let b = Array(data)
        guard b.count == 3, b[0] == 0x80, let pending, pending.result == nil,
              b[1] == pending.command.opcode, (1...5).contains(b[2]) else { return nil }
        // Success indications may arrive late on this firmware. Only actual speed
        // confirms a motor command, so a previous command's reply cannot complete a new one.
        if confirmMotorCommandsFromTelemetry && pending.command != .requestControl && b[2] == 1 { return nil }
        self.pending?.result = b[2]
        return finishIfComplete()
    }

    mutating func observeSpeed(kph: Double) -> Outcome? {
        guard confirmMotorCommandsFromTelemetry, let p = pending else { return nil }
        switch p.command {
        case .start: pending?.telemetryConfirmed = kph > 0.05
        case .speed(let target):
            pending?.telemetryConfirmed = abs(kph - Double(target) / 100) <= 0.051
        case .stop: pending?.telemetryConfirmed = kph <= 0.05
        case .requestControl: return nil
        }
        return finishIfComplete()
    }

    mutating func tick(now: TimeInterval) -> Outcome? {
        guard let pending, now >= pending.deadline else { return nil }
        if confirmMotorCommandsFromTelemetry, pending.command != .requestControl, pending.writeAcknowledged {
            self.pending = nil
            if case .speed = pending.command { return .speedSent }
            return .motorSent
        }
        invalidate() // Late responses must never authorize another command in this connection.
        return .failed("Treadmill reply timed out. Command outcome is unknown; use the remote and reconnect.")
    }

    mutating func invalidate() {
        granted = false
        pending = nil
        requiresReconnect = true
    }

    mutating func makeRoomForStop() {
        // On the telemetry-confirmed profile the ATT write has already finished.
        // Stop may supersede waiting for movement; no delayed speed/start is replayed.
        if confirmMotorCommandsFromTelemetry, pending?.writeAcknowledged == true,
           pending?.command != .requestControl { pending = nil }
    }

    private mutating func finishIfComplete() -> Outcome? {
        guard let p = pending, p.writeAcknowledged else { return nil }
        let result: UInt8
        if confirmMotorCommandsFromTelemetry && p.command != .requestControl {
            if let reply = p.result, reply != 1 { result = reply }
            else if p.telemetryConfirmed { result = 1 }
            else { return nil }
        } else {
            guard let reply = p.result else { return nil }
            result = reply
        }
        pending = nil
        if result == 1 {
            if p.command == .requestControl { granted = true }
            return .accepted(p.command)
        }
        if result == 5 || p.command == .requestControl { granted = false }
        if case .speed = p.command { speedRejected = true }
        let reason = [2: "command not supported", 3: "invalid speed or parameter",
                      4: "operation failed", 5: "control not permitted"][Int(result)] ?? "unknown error"
        return .failed("Treadmill rejected the command: \(reason). Use the physical remote.")
    }
}
