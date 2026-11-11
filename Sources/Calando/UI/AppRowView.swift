import AppKit
import SwiftUI

struct AppRowView: View {
    let app: AudioApp
    let engine: AudioEngineManager

    private static let snapDistance: Float = 0.02

    private var isDuckedNow: Bool {
        app.role == .ducked && engine.isDucking
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(app.isPlaying ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(app.isPlaying ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Playing now")
                    }
                    Spacer(minLength: 6)
                    if isDuckedNow {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .help("Lowered while a priority app is playing")
                    }
                    Text(percentText(app.volume))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(app.volume > VolumeCurve.unity ? Color.orange : Color.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Button {
                        engine.setMuted(!app.isMuted, forAppID: app.id)
                    } label: {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                    .help(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

                    Slider(value: volumeBinding, in: VolumeCurve.minimum...VolumeCurve.maximum)
                        .controlSize(.small)
                        .tint(app.volume > VolumeCurve.unity ? .orange : .accentColor)
                        .opacity(app.isMuted ? 0.5 : 1)

                    roleMenu
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var roleMenu: some View {
        Menu {
            Section("When audio overlaps") {
                roleButton("No automatic changes", role: .normal)
                roleButton("Priority: lower the others while this plays", role: .priority)
                roleButton("Lower this while a priority app plays", role: .ducked)
            }
            Section("Lowered volume") {
                ForEach(DuckingPolicy.duckLevelChoices, id: \.self) { level in
                    Button {
                        engine.setDuckLevel(level)
                    } label: {
                        if engine.duckLevel == level {
                            Label(percentText(level), systemImage: "checkmark")
                        } else {
                            Text(percentText(level))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: roleSymbol)
                .font(.system(size: 11))
                .foregroundStyle(roleTint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(roleHelp)
    }

    private func roleButton(_ title: String, role: AppRole) -> some View {
        Button {
            engine.setRole(role, forAppID: app.id)
        } label: {
            if app.role == role {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var roleSymbol: String {
        switch app.role {
        case .normal:
            return "ellipsis.circle"
        case .priority:
            return "star.fill"
        case .ducked:
            return "arrow.down.right.circle.fill"
        }
    }

    private var roleTint: Color {
        switch app.role {
        case .normal:
            return .secondary
        case .priority:
            return .yellow
        case .ducked:
            return .accentColor
        }
    }

    private var roleHelp: String {
        switch app.role {
        case .normal:
            return "Automatic ducking options"
        case .priority:
            return "Priority app: others are lowered while it plays"
        case .ducked:
            return "Lowered automatically while a priority app plays"
        }
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { app.volume },
            set: { requested in
                let previous = app.volume
                let unity = VolumeCurve.unity
                let snapped = abs(requested - unity) < Self.snapDistance ? unity : requested
                let reachedUnity = snapped == unity && previous != unity
                let crossedUnity = (previous - unity) * (snapped - unity) < 0
                if reachedUnity || crossedUnity {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                engine.setVolume(snapped, forAppID: app.id)
            }
        )
    }
}
