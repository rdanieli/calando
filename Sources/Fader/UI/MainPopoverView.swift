import AppKit
import ServiceManagement
import SwiftUI
import os

struct MainPopoverView: View {
    let engine: AudioEngineManager

    private static let width: CGFloat = 340
    private static let minimumHeight: CGFloat = 180
    private static let maximumHeight: CGFloat = 480
    private static let headerHeight: CGFloat = 82
    private static let footerHeight: CGFloat = 40
    private static let dividerHeight: CGFloat = 1
    private static let rowHeight: CGFloat = 56
    private static let listPadding: CGFloat = 6
    private static let emptyStateHeight: CGFloat = 104
    private static let warningHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(engine: engine)
                .frame(height: Self.headerHeight)
            separator
            if engine.showsCaptureWarning {
                CaptureWarningView(engine: engine)
                    .frame(height: Self.warningHeight)
                separator
            }
            Group {
                if engine.apps.isEmpty {
                    EmptyStateView()
                } else {
                    appList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            separator
            FooterView()
                .frame(height: Self.footerHeight)
        }
        .frame(width: Self.width, height: popoverHeight)
        .background(.ultraThinMaterial)
    }

    private var separator: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: Self.dividerHeight)
    }

    private var popoverHeight: CGFloat {
        var chrome = Self.headerHeight + Self.footerHeight + Self.dividerHeight * 2
        if engine.showsCaptureWarning {
            chrome += Self.warningHeight + Self.dividerHeight
        }
        let content: CGFloat
        if engine.apps.isEmpty {
            content = Self.emptyStateHeight
        } else {
            content = CGFloat(engine.apps.count) * Self.rowHeight + Self.listPadding * 2
        }
        return min(max(chrome + content, Self.minimumHeight), Self.maximumHeight)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(engine.apps) { app in
                    AppRowView(app: app, engine: engine)
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.vertical, Self.listPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct HeaderView: View {
    let engine: AudioEngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: engine.outputDeviceSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(engine.outputDeviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    engine.resetAll()
                } label: {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Set every app back to 100%")
            }

            HStack(spacing: 8) {
                Button {
                    engine.setMasterMuted(!engine.isMasterMuted)
                } label: {
                    Image(systemName: engine.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(engine.isMasterMuted ? Color.red : Color.primary)
                .disabled(!engine.isMasterMuteAvailable)
                .help(engine.isMasterMuted ? "Unmute output" : "Mute output")

                Slider(value: masterBinding, in: 0...1)
                    .controlSize(.small)
                    .disabled(!engine.isMasterVolumeAvailable)

                Text(percentText(engine.masterVolume))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
    }

    private var masterBinding: Binding<Float> {
        Binding(
            get: { engine.masterVolume },
            set: { engine.setMasterVolume($0) }
        )
    }
}

private struct CaptureWarningView: View {
    let engine: AudioEngineManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            Text("Fader is not receiving audio. Allow it under System Audio Recording, or the controlled apps stay silent.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open Settings") {
                engine.openCaptureSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No apps with audio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Apps show up here as soon as they open an audio session.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

private struct FooterView: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private static let log = Logger(subsystem: "com.local.fader", category: "LoginItem")

    var body: some View {
        HStack {
            Toggle("Launch at Login", isOn: loginBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    Self.log.error("Failed to change the login item: \(error.localizedDescription, privacy: .public)")
                }
                launchesAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }
}

func percentText(_ value: Float) -> String {
    "\(Int((value * 100).rounded()))%"
}
