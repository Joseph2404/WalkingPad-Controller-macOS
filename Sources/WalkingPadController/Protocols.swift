import Foundation

/// Bluetooth speeds stay metric. Convert only when presenting them to the user.
enum SpeedUnits {
    static func mph(fromKPH speed: Double) -> Double { speed / 1.609344 }
}

enum DistanceUnits {
    static func miles(fromMeters meters: Double) -> Double { meters / 1609.344 }
}

enum FTMSCommand {
    static let requestControl = Data([0x00])
    static let start = Data([0x07])
    static let stop = Data([0x08, 0x01])

    static func speed(kph: Double) -> Data {
        let raw = UInt16((kph * 100).rounded())
        return Data([0x02, UInt8(raw & 0xff), UInt8(raw >> 8)])
    }
}

enum WiLinkCommand {
    static let start = framed([0xF7, 0xA2, 0x04, 0x01, 0x00, 0xFD])
    static let stop = speed(kph: 0)
    static let status = Data([0xF7, 0xA2, 0x00, 0x00, 0xA2, 0xFD])

    static func speed(kph: Double) -> Data {
        // Legacy KingSmith units are 1/10 km/h.
        framed([0xF7, 0xA2, 0x01, UInt8((kph * 10).rounded()), 0x00, 0xFD])
    }

    static func framed(_ bytes: [UInt8]) -> Data {
        var result = bytes
        guard result.count >= 3 else { return Data(result) }
        result[result.count - 2] = result[1..<(result.count - 2)].reduce(0) { $0 &+ $1 }
        return Data(result)
    }
}

enum TreadmillParser {
    static func ftmsElapsedSeconds(_ data: Data) -> UInt16? {
        let b = Array(data)
        guard b.count >= 2 else { return nil }
        let flags = UInt16(b[0]) | UInt16(b[1]) << 8
        guard flags & (1 << 10) != 0 else { return nil }
        var offset = 2
        if flags & 1 == 0 { offset += 2 }
        let fields = [(1, 2), (2, 3), (3, 4), (4, 4), (5, 1), (6, 1), (7, 5), (8, 1), (9, 1)]
        for (bit, size) in fields where flags & (1 << bit) != 0 { offset += size }
        guard b.count >= offset + 2 else { return nil }
        return UInt16(b[offset]) | UInt16(b[offset + 1]) << 8
    }

    static func ftmsDistanceMeters(_ data: Data) -> UInt32? {
        let b = Array(data)
        guard b.count >= 2, b[0] & 0x04 != 0 else { return nil }
        var offset = 2
        if b[0] & 0x01 == 0 { offset += 2 } // Instantaneous speed present.
        if b[0] & 0x02 != 0 { offset += 2 } // Optional average speed.
        guard b.count >= offset + 3 else { return nil }
        return UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16
    }

    static func supportedSpeedRange(_ data: Data) -> (Double, Double, Double)? {
        guard data.count == 6 else { return nil }
        let b = [UInt8](data)
        let min = UInt16(b[0]) | UInt16(b[1]) << 8
        let max = UInt16(b[2]) | UInt16(b[3]) << 8
        let step = UInt16(b[4]) | UInt16(b[5]) << 8
        guard min < max, step > 0, step <= max - min else { return nil }
        return (Double(min) / 100, Double(max) / 100, Double(step) / 100)
    }

    static func ftmsSpeed(_ data: Data) -> Double? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data)
        // FTMS bit 0 (More Data) means this notification omits instantaneous speed.
        // Bytes 2–3 then belong to another field and must not be treated as speed.
        guard b[0] & 0x01 == 0 else { return nil }
        return Double(UInt16(b[2]) | UInt16(b[3]) << 8) / 100
    }

    static func wiLinkSpeed(_ data: Data) -> Double? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0xF8, b[1] == 0xA2 else { return nil }
        let expected = b[1..<(b.count - 2)].reduce(0) { $0 &+ $1 }
        guard expected == b[b.count - 2], b.last == 0xFD else { return nil }
        return Double(b[3]) / 10
    }
}

/// Uptime is monotonic, so changing the Mac's clock cannot revive stale telemetry.
struct SpeedSample {
    private var speed: Double?
    private var receivedAt: TimeInterval?

    mutating func receive(_ value: Double, at uptime: TimeInterval) {
        speed = value
        receivedAt = uptime
    }

    func current(at uptime: TimeInterval) -> Double? {
        guard let receivedAt, uptime >= receivedAt, uptime - receivedAt < 3 else { return nil }
        return speed
    }
}
