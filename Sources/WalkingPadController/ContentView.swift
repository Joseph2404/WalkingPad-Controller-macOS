import SwiftUI
import AppKit

private final class ControllerViewState: ObservableObject {
    @Published var showSettings = false
    @Published var draftSpeed = 1.0
    @Published var dragging = false
    @Published var showActivities = false
}

private let amber = Color(red: 1, green: 0.68, blue: 0.29)

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothController
    @AppStorage("presetOne") private var presetOne = 1.5
    @AppStorage("presetTwo") private var presetTwo = 2.5
    @AppStorage("presetThree") private var presetThree = 3.5
    @AppStorage("distanceGoal") private var distanceGoal = 3.0
    @StateObject private var viewState = ControllerViewState()

    private var speed: Double { bluetooth.displayedSpeedMPH ?? 0 }
    private var target: Double { bluetooth.selectedMPH ?? max(1, speed) }
    private var dialSpeed: Double {
        guard bluetooth.isRunning else { return 0 }
        if viewState.dragging { return viewState.draftSpeed }
        return bluetooth.selectedMPH.map { ($0 * 10).rounded() / 10 } ?? speed
    }
    private var progress: Double {
        guard distanceGoal.isFinite, distanceGoal > 0 else { return 0 }
        return min(1, max(0, (bluetooth.distanceMiles ?? 0) / distanceGoal))
    }
    private var clock: String {
        guard let seconds = bluetooth.elapsedSeconds else { return "—:—" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        GeometryReader { geometry in
        let scale = min(geometry.size.width / 560, geometry.size.height / 800)
        ScrollView {
        VStack(spacing: 16) {
            header
            dial
            HStack(spacing: 18) {
                ForEach(Array([presetOne, presetTwo, presetThree].enumerated()), id: \.offset) { _, value in
                    Button { bluetooth.setSpeedMPH(value) } label: {
                        VStack(spacing: 3) {
                            Text(String(format: "%.1f", value)).font(.title2)
                            Text("mph").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(.white.opacity(0.06)))
                        .overlay(Capsule().stroke(abs(target - value) < 0.06 && bluetooth.isRunning ? amber : .white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!bluetooth.canAdjustSpeed)
                    .accessibilityLabel("Set speed to \(value, specifier: "%.1f") miles per hour")
                }
            }
            Divider()
            HStack {
                Image(systemName: "mappin.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION DISTANCE").font(.caption).tracking(1.4).foregroundStyle(.secondary)
                    Text("\(bluetooth.distanceMiles.map { String(format: "%.2f", $0) } ?? "—") / \(String(format: "%.1f", distanceGoal)) mi")
                        .font(.title3).monospacedDigit()
                }
                Spacer()
                Divider().frame(height: 44)
                Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(.secondary).padding(.leading, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSION CLOCK").font(.caption).tracking(1.4).foregroundStyle(.secondary)
                    Text(clock).font(.title3).monospacedDigit()
                }
            }
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(amber.gradient).frame(width: geo.size.width * progress)
                    }
            }.frame(height: 10)
            DisclosureGroup(isExpanded: $viewState.showActivities) {
                VStack(spacing: 12) {
                    if bluetooth.activityHistory.activities.isEmpty {
                        Text("No past activity yet.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ForEach(bluetooth.activityHistory.activities) { activity in
                            HStack {
                                Text(activity.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.2f mi", activity.miles))
                                Text(activity.duration).frame(width: 78, alignment: .trailing)
                            }
                            .font(.callout).monospacedDigit()
                            Divider()
                        }
                    }
                    Button("Reset Activities") { bluetooth.resetActivities() }
                        .disabled(bluetooth.activityHistory.activities.isEmpty)
                }.padding(.top, 12)
            } label: {
                Text("Past activity").font(.callout.weight(.medium))
            }
            .tint(amber)
            if let warning = bluetooth.warning {
                Text(warning).font(.caption).foregroundStyle(amber)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 22)
        }
        .frame(width: 560, height: geometry.size.height / scale)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 560 * scale, height: geometry.size.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(GlassBackground())
        .sheet(isPresented: $viewState.showSettings) {
            VStack(spacing: 0) {
                WalkingPadSettingsView()
                Button("Done") { viewState.showSettings = false }
                    .keyboardShortcut(.cancelAction).padding(.bottom, 20)
            }.frame(width: 500)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk").font(.title)
            Text("WalkingPad Controller").font(.title3.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            Circle().fill(bluetooth.controlsEnabled ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(bluetooth.connectionTitle).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: 140, alignment: .leading)
            Button { viewState.showSettings = true } label: { Image(systemName: "gearshape").font(.title3) }
                .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }
    }

    private var dial: some View {
        VStack(spacing: 0) {
            ZStack {
                SpeedTicks().stroke(.white.opacity(0.45), lineWidth: 1)
                ForEach(1...4, id: \.self) { value in
                    let angle = (135 + Double(value) / 4 * 270) * Double.pi / 180
                    Text("\(value)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .offset(x: 103 * cos(angle), y: 103 * sin(angle))
                }
                SpeedArc().stroke(.white.opacity(0.16), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                SpeedArc().trim(from: 0, to: min(1, max(0, dialSpeed / 4)))
                    .stroke(amber.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .shadow(color: amber.opacity(0.45), radius: 7)
                Circle().fill(.white).frame(width: 20, height: 20)
                    .offset(x: 138 * cos(dialAngle), y: 138 * sin(dialAngle))
                VStack(spacing: 6) {
                    Text(bluetooth.startCountdown == nil ? "SPEED" : "STARTING").font(.caption).tracking(3).foregroundStyle(.secondary)
                    Text(bluetooth.startCountdown.map { String($0) } ?? bluetooth.displayedSpeedMPH.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 76, weight: .light)).monospacedDigit()
                    Text(bluetooth.startCountdown == nil ? "mph" : " ").font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, height: 300)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    guard bluetooth.canAdjustSpeed else { return }
                    viewState.dragging = true
                    let dx = value.location.x - 150
                    let dy = value.location.y - 150
                    var angle = atan2(dy, dx) * 180 / .pi - 135
                    if angle < 0 { angle += 360 }
                    let fraction = angle > 270 ? (angle > 315 ? 0.0 : 1.0) : angle / 270
                    viewState.draftSpeed = max(1, min(4, (fraction * 40).rounded() / 10))
                }
                .onEnded { _ in
                    if viewState.dragging { bluetooth.setSpeedMPH(viewState.draftSpeed) }
                    viewState.dragging = false
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Speed")
            .accessibilityValue("\(speed, specifier: "%.1f") miles per hour")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { adjust(0.1) }
                if direction == .decrement { adjust(-0.1) }
            }
            HStack(spacing: 62) {
                roundButton("minus", size: 58, enabled: bluetooth.canAdjustSpeed) { adjust(-0.1) }
                    .accessibilityLabel("Decrease speed")
                roundButton("power", size: 86, enabled: bluetooth.isRunning ? bluetooth.canStop : bluetooth.canStart, accented: true) {
                    if bluetooth.isRunning { bluetooth.stop() } else { bluetooth.start() }
                }
                .accessibilityLabel(bluetooth.isRunning ? "Stop treadmill" : "Start treadmill")
                .help(bluetooth.isRunning ? "Stop" : "Start")
                roundButton("plus", size: 58, enabled: bluetooth.canAdjustSpeed) { adjust(0.1) }
                    .accessibilityLabel("Increase speed")
            }.padding(.top, -45)
        }
    }

    private func adjust(_ delta: Double) {
        let current = (target * 10).rounded() / 10
        bluetooth.setSpeedMPH(min(4, max(1, current + delta)))
    }

    private var dialAngle: Double {
        return (135 + min(4, max(0, dialSpeed)) / 4 * 270) * .pi / 180
    }

    private func roundButton(_ symbol: String, size: CGFloat, enabled: Bool, accented: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.36, weight: .light))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.07)))
                .overlay(Circle().stroke(accented ? amber : .white.opacity(0.22), lineWidth: accented ? 2 : 1))
                .shadow(color: accented ? amber.opacity(0.2) : .clear, radius: 8)
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

private struct SpeedArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 12,
                    startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
        return path
    }
}

private struct SpeedTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - 26
        for tenth in 10...40 {
            let angle = (135 + Double(tenth) / 40 * 270) * Double.pi / 180
            let length: Double = tenth % 10 == 0 ? 10 : (tenth % 5 == 0 ? 7 : 4)
            path.move(to: CGPoint(x: rect.midX + radius * cos(angle),
                                 y: rect.midY + radius * sin(angle)))
            path.addLine(to: CGPoint(x: rect.midX + (radius - length) * cos(angle),
                                    y: rect.midY + (radius - length) * sin(angle)))
        }
        return path
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WalkingPadSettingsView: View {
    @EnvironmentObject private var bluetooth: BluetoothController
    @AppStorage("presetOne") private var presetOne = 1.5
    @AppStorage("presetTwo") private var presetTwo = 2.5
    @AppStorage("presetThree") private var presetThree = 3.5
    @AppStorage("distanceGoal") private var distanceGoal = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("WALKINGPAD").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(bluetooth.savedDeviceName)
                    Spacer()
                    Button("Find devices") { bluetooth.findDevices() }
                }
                Text("Your selection connects automatically whenever the app is open.")
                    .font(.caption).foregroundStyle(.secondary)
                if !bluetooth.devices.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(bluetooth.devices) { device in
                                Button { bluetooth.chooseDevice(device) } label: {
                                    HStack {
                                        Text(device.name)
                                        Spacer()
                                        if device.id.uuidString == bluetooth.savedDeviceID {
                                            Image(systemName: "checkmark").foregroundStyle(amber)
                                        }
                                    }.padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 130)
                }
            }
            Divider()
            Text("PRESET SPEEDS · MPH").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                presetBox("Preset 1", value: $presetOne)
                presetBox("Preset 2", value: $presetTwo)
                presetBox("Preset 3", value: $presetThree)
            }
            Divider()
            HStack {
                Text("Distance goal")
                Spacer()
                SettingsNumberField(title: "Miles", value: $distanceGoal, range: 0.1...999)
                    .frame(width: 80)
                Text("mi").foregroundStyle(.secondary)
            }
            Text("The goal tracks progress. Reaching it does not stop the belt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26).frame(width: 500)
        .onDisappear { bluetooth.finishSelectingDevice() }
    }

    private func presetBox(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            SettingsNumberField(title: title, value: value, range: 1...4)
        }
    }
}

private final class NumberFieldDraft: ObservableObject {
    @Published var text = ""
    var editing = false
}

private struct SettingsNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @StateObject private var draft = NumberFieldDraft()

    var body: some View {
        TextField(title, text: $draft.text, onEditingChanged: { editing in
            draft.editing = editing
            if !editing { commit() }
        })
        .textFieldStyle(.roundedBorder)
        .onSubmit { commit() }
        .onAppear { refresh() }
        .onDisappear { commit() }
        .onChange(of: value) { _ in if !draft.editing { refresh() } }
    }

    private func refresh() {
        draft.text = value.formatted(.number.precision(.fractionLength(1)))
    }

    private func commit() {
        if let number = try? Double(draft.text, format: .number), number.isFinite {
            value = min(range.upperBound, max(range.lowerBound, (number * 10).rounded() / 10))
        }
        refresh()
    }
}
