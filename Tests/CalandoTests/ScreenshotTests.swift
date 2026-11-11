import AppKit
import SwiftUI
import Testing

@testable import Calando

@MainActor
private func demoApp(
    bundleID: String,
    name: String,
    isPlaying: Bool,
    volume: Float,
    isMuted: Bool = false,
    role: AppRole = .normal
) -> AudioApp {
    let workspace = NSWorkspace.shared
    let icon = workspace.urlForApplication(withBundleIdentifier: bundleID)
        .map { workspace.icon(forFile: $0.path) } ?? workspace.icon(for: .application)
    return AudioApp(
        id: bundleID,
        name: name,
        icon: icon,
        ownerPID: 0,
        processObjectIDs: [],
        isPlaying: isPlaying,
        volume: volume,
        isMuted: isMuted,
        role: role
    )
}

@MainActor
@Test func renderPopoverScreenshotWhenRequested() throws {
    guard let path = ProcessInfo.processInfo.environment["CALANDO_SCREENSHOT_PATH"] else { return }

    let engine = AudioEngineManager(
        previewApps: [
            demoApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isPlaying: true, volume: 1.0, role: .priority),
            demoApp(bundleID: "com.apple.Music", name: "Music", isPlaying: true, volume: 0.7, role: .ducked),
            demoApp(bundleID: "com.apple.Safari", name: "Safari", isPlaying: true, volume: 1.25),
            demoApp(bundleID: "com.apple.podcasts", name: "Podcasts", isPlaying: false, volume: 0.45, isMuted: true),
            demoApp(bundleID: "com.apple.TV", name: "TV", isPlaying: false, volume: 1.0),
        ],
        outputDeviceName: "MacBook Pro Speakers",
        outputDeviceSymbol: "laptopcomputer",
        masterVolume: 0.62,
        isDucking: true
    )

    let appearance = NSAppearance(named: .darkAqua)
    let root = MainPopoverView(engine: engine)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: root)
    host.appearance = appearance
    let size = host.fittingSize
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = appearance
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: representation)
    let png = try #require(representation.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: path))
}
