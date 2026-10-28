import Foundation

struct WalkingActivity: Codable, Identifiable {
    var id = UUID()
    var timestamp = Date()
    var meters: UInt32 = 0
    var seconds: UInt16 = 0
    var miles: Double { Double(meters) / 1609.344 }
    var duration: String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

struct ActivityHistory: Codable {
    var activities: [WalkingActivity] = []
    private var current: WalkingActivity?
    private var deviceID: String?
    private var stopped = false

    mutating func observe(device: String, meters: UInt32?, seconds: UInt16?, speed: Double?) {
        if let current, deviceID != device
            || meters.map({ $0 < current.meters }) == true
            || seconds.map({ $0 < current.seconds }) == true {
            saveCurrent()
            self.current = nil
            stopped = false
        }
        deviceID = device
        if current == nil {
            guard let speed, speed > 0.05 else { return }
            current = WalkingActivity()
        }
        if let meters { current?.meters = meters }
        if let seconds { current?.seconds = seconds }
        if let speed { stopped = speed <= 0.05 }
        if stopped { saveCurrent() }
    }

    mutating func reset() {
        activities = []
        // Do not re-add the cleared session on another idle notification.
        if stopped { current = nil }
    }

    private mutating func saveCurrent() {
        guard let current else { return }
        if let index = activities.firstIndex(where: { $0.id == current.id }) {
            activities[index] = current
        } else {
            activities.insert(current, at: 0)
        }
    }
}
