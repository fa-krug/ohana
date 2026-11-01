import SwiftUI

/// Notifications on this device (`PushNotifications`): on or off, which of the account's
/// families, a test. Shown only when the server pushes through this build's relay; the events and
/// channels are the family's (Settings → Household → Notifications).
struct PushSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var push = PushNotifications.shared
    @State private var testing = false
    @State private var testSent = false

    var body: some View {
        if let client = app.client, !client.isDemo, PushNotifications.isAvailable(app.serverInfo) {
            Section {
                Toggle("Notifications on this device", isOn: Binding(get: { push.isOn }, set: { on in
                    Task {
                        do {
                            if on {
                                try await push.enable(client: client, info: app.serverInfo)
                            } else {
                                await push.disable(client: client)
                            }
                        } catch {
                            ErrorBanner.shared.show(error.localizedDescription)
                        }
                    }
                }))
                .disabled(push.busy)

                if push.isOn, push.device?.registered == true {
                    if app.families.count > 1 {
                        ForEach(app.families) { family in
                            Toggle(isOn: Binding(
                                get: { push.device?.mutedFamilyIds.contains(family.id) != true },
                                set: { on in
                                    Task {
                                        do {
                                            try await push.setMuted(family.id, muted: !on, client: client)
                                        } catch {
                                            ErrorBanner.shared.show(error.localizedDescription)
                                        }
                                    }
                                }
                            )) {
                                Text(verbatim: family.name)
                            }
                            .padding(.leading, 12)
                        }
                    }
                    Button {
                        test(client)
                    } label: {
                        if testing {
                            ProgressView()
                        } else {
                            Label(testSent ? "Test notification sent" : "Send a test notification",
                                  systemImage: testSent ? "checkmark" : "bell.badge")
                        }
                    }
                    .disabled(testing)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("They go through Ohana’s notification service, which can’t read them: only this device can. What is sent is chosen under Household → Notifications.")
            }
            .task(id: ObjectIdentifier(client)) { await push.load(client: client, info: app.serverInfo) }
        }
    }

    private func test(_ client: APIClient) {
        testing = true
        Task {
            do {
                try await push.sendTest(client: client)
                testSent = true
            } catch {
                ErrorBanner.shared.show(String(localized: "Sending failed: \(error.localizedDescription)"))
            }
            testing = false
        }
    }
}
