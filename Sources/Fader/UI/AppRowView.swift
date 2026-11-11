import AppKit
import SwiftUI

struct AppRowView: View {
    let app: AudioApp
    let engine: AudioEngineManager

    private static let snapDistance: Float = 0.02

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Tocando agora")
                    }
                    Spacer(minLength: 6)
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
                    .help(app.isMuted ? "Reativar o som de \(app.name)" : "Silenciar \(app.name)")

                    Slider(value: volumeBinding, in: VolumeCurve.minimum...VolumeCurve.maximum)
                        .controlSize(.small)
                        .tint(app.volume > VolumeCurve.unity ? .orange : .accentColor)
                        .opacity(app.isMuted ? 0.5 : 1)
                }
            }
        }
        .padding(.horizontal, 14)
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
