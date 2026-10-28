import SwiftUI

@main
struct WalkingPadControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bluetooth = BluetoothController()

    var body: some Scene {
        Window("WalkingPad Controller", id: "main") {
            ContentView()
                .environmentObject(bluetooth)
                .frame(minWidth: 438, minHeight: 630)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 438, height: 630)
        .windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarControllerView()
                .environmentObject(bluetooth)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: TreadmillMenuIcon.image)
                .accessibilityLabel("WalkingPad")
        }
        .menuBarExtraStyle(.window)
        Settings {
            WalkingPadSettingsView()
                .environmentObject(bluetooth)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
