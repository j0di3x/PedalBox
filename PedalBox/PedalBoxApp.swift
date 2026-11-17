import SwiftUI

@main
struct PedalBoxApp: App {
    @StateObject private var hid = HIDMonitor()
    @StateObject private var gc = GCMonitor()
    @StateObject private var ffb = FFBController()

    var body: some Scene {
        MenuBarExtra("PedalBox", systemImage: "steeringwheel") {
            MenuContent()
                .environmentObject(ffb)
        }
        Window("PedalBox", id: "main") {
            SpikeView()
                .environmentObject(hid)
                .environmentObject(gc)
                .environmentObject(ffb)
        }
        .defaultSize(width: 820, height: 720)
    }
}

private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var ffb: FFBController

    var body: some View {
        Button("Open PedalBox…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Toggle("Force feedback for BeamNG", isOn: $ffb.enabled)
        Divider()
        Button("Quit PedalBox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
