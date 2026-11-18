import Foundation
import UserNotifications

@MainActor
final class NameAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let categoryIdentifier = "io.github.rdanieli.calando.nameAlert"
    private nonisolated static let raiseActionIdentifier = "io.github.rdanieli.calando.nameAlert.raise"

    var onRaiseRequested: (@MainActor () -> Void)?
    private var isConfigured = false

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func prepare() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        if !isConfigured {
            isConfigured = true
            center.delegate = self
            let raise = UNNotificationAction(identifier: Self.raiseActionIdentifier, title: "Raise Volume", options: [])
            let category = UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [raise],
                intentIdentifiers: [],
                options: []
            )
            center.setNotificationCategories([category])
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(heard: String, appName: String, didRaiseVolume: Bool) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Someone said \u{201C}\(heard)\u{201D}"
        content.body = didRaiseVolume
            ? "\(appName) was quiet, so Calando brought its volume back."
            : "\(appName) is quiet. Raise the volume to hear it."
        content.sound = .default
        if !didRaiseVolume {
            content.categoryIdentifier = Self.categoryIdentifier
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.raiseActionIdentifier else { return }
        await MainActor.run {
            onRaiseRequested?()
        }
    }
}
