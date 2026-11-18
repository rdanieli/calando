import AppKit
import SwiftUI

enum NameAlertWindow {
    static let id = "name-alert-settings"
}

extension NameAlertController.Status {
    var summary: String {
        switch self {
        case .off: return "Off"
        case .unsupportedSystem: return "Needs macOS 26 or newer"
        case .needsNames: return "Add your name to start"
        case .speechDenied: return "Speech Recognition is not allowed"
        case .languageUnsupported: return "Language not supported"
        case .downloadingModel: return "Downloading the speech model"
        case .modelUnavailable: return "Speech model could not be installed"
        case .ready: return "Ready"
        case .listening(let appName): return "Listening to \(appName)"
        case .failed: return "Stopped after an error"
        }
    }

    var isProblem: Bool {
        switch self {
        case .unsupportedSystem, .speechDenied, .languageUnsupported, .modelUnavailable, .failed: return true
        default: return false
        }
    }
}

struct NameAlertBar: View {
    let controller: NameAlertController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isListening ? "ear.badge.waveform" : "bell")
                .font(.system(size: 12))
                .foregroundStyle(isListening ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Name Alert")
                    .font(.system(size: 11, weight: .medium))
                Text(controller.status.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(controller.status.isProblem ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Set up Name Alert")
            Toggle("Name Alert", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
    }

    private var isListening: Bool {
        if case .listening = controller.status { return true }
        return false
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.isEnabled },
            set: { enabled in
                controller.setEnabled(enabled)
                if enabled, controller.settings.names.isEmpty {
                    openSettings()
                }
            }
        )
    }

    private func openSettings() {
        openWindow(id: NameAlertWindow.id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct NameAlertBanner: View {
    let controller: NameAlertController
    let alert: NameAlertController.ActiveAlert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !alert.didRaiseVolume {
                Button("Raise") {
                    controller.raiseNow()
                }
                .controlSize(.small)
            }
            Button("Not Me") {
                controller.reportFalseAlarm()
            }
            .controlSize(.small)
            .help("Undo and stop treating this word as your name")
            Button {
                controller.dismissAlert()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
    }

    private var message: String {
        let heard = "\u{201C}\(alert.heard)\u{201D} was said in \(alert.appName)."
        return alert.didRaiseVolume ? "\(heard) Volume restored." : heard
    }
}

struct NameAlertSettingsView: View {
    let controller: NameAlertController
    @State private var namesDraft = ""

    private static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if NameAlertController.isSystemSupported {
                namesSection
                optionsSection
                variantsSection
            }
            privacyNote
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear {
            namesDraft = controller.namesText
            controller.loadLocaleChoices()
        }
        .onDisappear {
            controller.setNames(namesDraft)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: enabledBinding) {
                Text("Alert me when someone says my name")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .disabled(!NameAlertController.isSystemSupported)
            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(controller.status.summary, systemImage: controller.status.isProblem ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(controller.status.isProblem ? Color.orange : Color.secondary)
        }
    }

    private var explanation: String {
        NameAlertController.isSystemSupported
            ? "Works on apps marked with a star, while they play muted or below 50%, or while the output is muted."
            : "Name Alert needs the on-device speech model that ships with macOS 26 or newer."
    }

    private var namesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Names and nicknames")
                .font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                TextField("Rafael, Rafa", text: $namesDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.setNames(namesDraft) }
                Button("Save") {
                    controller.setNames(namesDraft)
                }
                .controlSize(.small)
                .disabled(NameMatcher.parseNames(namesDraft) == controller.settings.names)
            }
            Text("Separate with commas, written the way people call you.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Call language", selection: localeBinding) {
                if !controller.localeChoices.contains(where: { $0.id == selectedLocale }) {
                    Text(selectedLocale).tag(selectedLocale)
                }
                ForEach(controller.localeChoices) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
            }
            .font(.system(size: 11))
            Text("Pick the language people speak in the call, even if your Mac is set to another one.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Raise the volume automatically", isOn: raiseBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
        }
    }

    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How the recognizer hears your name")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if controller.isFindingVariants {
                    ProgressView(value: controller.variantProgress)
                        .frame(width: 90)
                        .controlSize(.small)
                } else {
                    Button("Find Variations") {
                        controller.setNames(namesDraft)
                        controller.findVariants()
                    }
                    .controlSize(.small)
                    .disabled(controller.settings.names.isEmpty || !controller.isArmed)
                }
            }
            Text("Calando speaks your names with the system voices and checks what the recognizer writes. Tick only the words you want treated as your name: common words cause false alerts.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = controller.variantNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.settings.suggestions) { suggestion in
                Toggle(isOn: variantBinding(suggestion.word)) {
                    HStack(spacing: 6) {
                        Text(suggestion.word)
                            .font(.system(size: 12))
                        Text("heard \(suggestion.occurrences) times for \(suggestion.name)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var privacyNote: some View {
        Text("While Name Alert is listening, the audio of that app is transcribed on this Mac to spot your name. Nothing is recorded, stored or sent anywhere.")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedLocale: String {
        controller.settings.localeIdentifier ?? controller.resolvedLocaleIdentifier
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.isEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var raiseBinding: Binding<Bool> {
        Binding(
            get: { controller.settings.raisesVolume },
            set: { controller.setRaisesVolume($0) }
        )
    }

    private var localeBinding: Binding<String> {
        Binding(
            get: { selectedLocale },
            set: { controller.setLocaleIdentifier($0) }
        )
    }

    private func variantBinding(_ word: String) -> Binding<Bool> {
        Binding(
            get: { controller.isVariantApproved(word) },
            set: { controller.setVariant(word, approved: $0) }
        )
    }
}
