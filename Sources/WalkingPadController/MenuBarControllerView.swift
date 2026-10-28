import SwiftUI
import AppKit

enum TreadmillMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let deck = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 20, height: 4),
                                    xRadius: 1.5, yRadius: 1.5)
            deck.lineWidth = 1.4
            deck.stroke()
            let frame = NSBezierPath()
            frame.lineWidth = 1.6
            frame.lineCapStyle = .round
            frame.move(to: NSPoint(x: 17, y: 5))
            frame.line(to: NSPoint(x: 14, y: 15))
            frame.line(to: NSPoint(x: 9, y: 15))
            frame.move(to: NSPoint(x: 13, y: 11))
            frame.line(to: NSPoint(x: 7, y: 11))
            frame.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WalkingPad"
        return image
    }()
}

struct MenuBarControllerView: View {
    @EnvironmentObject private var bluetooth: BluetoothController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("presetOne") private var presetOne = 1.5
    @AppStorage("presetTwo") private var presetTwo = 2.5
    @AppStorage("presetThree") private var presetThree = 3.5
    @AppStorage("distanceGoal") private var distanceGoal = 3.0
    private let accent = Color(red: 1, green: 0.68, blue: 0.29)

    private var progress: Double {
        guard distanceGoal.isFinite, distanceGoal > 0 else { return 0 }
        return min(1, max(0, (bluetooth.distanceMiles ?? 0) / distanceGoal))
    }
    private var stopping: Bool {
        bluetooth.isRunning || bluetooth.startCountdown != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("WalkingPad Controller").font(.headline)
                Spacer()
                Text(bluetooth.controlsEnabled ? "Connected" : "Offline")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bluetooth.startCountdown.map(String.init)
                     ?? bluetooth.displayedSpeedMPH.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 40, weight: .light)).monospacedDigit()
                Text(bluetooth.startCountdown == nil ? "mph" : "Starting…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if stopping { bluetooth.stop() } else { bluetooth.start() }
                } label: {
                    Label(stopping ? "Stop" : "Start", systemImage: "power")
                        .frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .disabled(stopping ? !bluetooth.canStop : !bluetooth.canStart)
            }
            HStack(spacing: 8) {
                ForEach(Array([presetOne, presetTwo, presetThree].enumerated()), id: \.offset) { _, speed in
                    Button { bluetooth.setSpeedMPH(speed) } label: {
                        Text("\(speed, specifier: "%.1f") mph")
                            .font(.callout).monospacedDigit()
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!bluetooth.canAdjustSpeed)
                }
            }
            Divider()
            HStack {
                Text("\(Int((progress * 100).rounded(.down)))% completed")
                Spacer()
                Text("Goal: \(distanceGoal, specifier: "%.1f") mi")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: progress).tint(accent)
                .accessibilityLabel("Distance goal progress")
            if let warning = bluetooth.warning {
                Text(warning).font(.caption).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open App") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.plain).font(.callout)
        }
        .padding(16).frame(width: 290)
    }
}
