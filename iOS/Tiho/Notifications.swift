import SwiftUI
import UserNotifications

@MainActor final class PushRegistration: NSObject, UIApplicationDelegate {
    static var token: String?
    static let supported = Bundle.main.object(forInfoDictionaryKey:"StupidChatPush") as? String == "Push.entitlements"
    static var failure: String?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.failure = nil
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.failure = "Эта сборка не зарегистрирована в APNs."
    }
}

struct PushSettings: View {
    @AppStorage("pushEnabled") private var enabled = false
    @State private var note = ""
    var body: some View {
        Section("Уведомления") {
            if PushRegistration.supported { Toggle("Новые сообщения", isOn: $enabled)
                .onChange(of: enabled) { _, value in
                    guard value else { note = ""; return }
                    Task {
                        do {
                            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                            guard allowed else { enabled = false; note = "Разрешите уведомления в настройках iPhone."; return }
                            UIApplication.shared.registerForRemoteNotifications()
                        } catch { enabled = false; note = error.localizedDescription }
                    }
                }
            } else { Text("Для push требуется сборка с поддержкой APNs.").foregroundStyle(.secondary) }
            if !note.isEmpty { Text(note).font(.footnote) }
        }
    }
}
