import AppKit
import SwiftUI

@main
struct CalandoApp: App {
    @State private var engine = AudioEngineManager()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MainPopoverView(engine: engine)
        } label: {
            Image(systemName: engine.isMasterMuted ? "speaker.slash.fill" : "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
