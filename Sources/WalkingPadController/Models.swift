import CoreBluetooth
import Foundation

enum ConnectionState: Equatable {
    case bluetoothUnavailable(String)
    case idle
    case scanning
    case connecting(String)
    case discovering(String)
    case ready(String)
    case disconnected(String)

    var label: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .idle: return "Ready to scan"
        case .scanning: return "Scanning nearby devices…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .discovering(let name): return "Inspecting \(name)…"
        case .ready(let name): return "Connected to \(name)"
        case .disconnected(let reason): return reason
        }
    }
}

enum ProtocolFamily: String {
    case ftms = "FTMS"
    case legacyWiLink = "Legacy WiLink"
    case unsupported = "Unknown"
}

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var advertisedServices: [CBUUID]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.rssi == rhs.rssi }
}

struct GATTEntry: Identifiable {
    let id = UUID()
    let service: String
    let characteristic: String
    let properties: String
}

struct TreadmillState: Equatable {
    var actualSpeedKPH = 0.0
    var targetSpeedKPH = 1.0
    var minSpeedKPH = 0.5
    var maxSpeedKPH = 6.0
    var speedIncrementKPH = 0.1
    var isRunning = false
}

enum WalkingPadUUID {
    static let deviceInformation = CBUUID(string: "180A")
    static let modelNumber = CBUUID(string: "2A24")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let ftmsService = CBUUID(string: "1826")
    static let fitnessFeature = CBUUID(string: "2ACC")
    static let treadmillData = CBUUID(string: "2ACD")
    static let speedRange = CBUUID(string: "2AD4")
    static let controlPoint = CBUUID(string: "2AD9")
    static let machineStatus = CBUUID(string: "2ADA")
    static let trainingStatus = CBUUID(string: "2AD3")
    static let odm = CBUUID(string: "D18D2C10-C44C-11E8-A355-529269FB1459")

    static let wiLinkService = CBUUID(string: "FE00")
    static let wiLinkNotify = CBUUID(string: "FE01")
    static let wiLinkWrite = CBUUID(string: "FE02")
}
