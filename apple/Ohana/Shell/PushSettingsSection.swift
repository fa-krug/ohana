import SwiftUI

/// Notifications on this device (`PushNotifications`), the top of Household → Notifications: on
/// or off, this family's on this device (when the account has more than one), a test. Shown only
/// when the server pushes through this build's relay, to viewers too.
struct PushSettingsSection: View {
    /// The family whose page this is.
    let family: FamilySummary
    @Environment(AppModel.self) private var app
    @State private var push = PushNotifications.shared
    @State private var testing = false

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
                    // With one family, the switch above says it all.
                    if app.families.count > 1 {
                        Toggle("From this family", isOn: Binding(
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
                        ))
                    }
                    Button {
                        test(client)
                    } label: {
                        if testing {
                            ProgressView()
                        } else {
                            Label("Send a test notification", systemImage: "bell.badge")
                        }
                    }
                    .disabled(testing)
                }
            } header: {
                Text("This device")
            } footer: {
                Text("Sent through Ohana’s notification service, which can’t read them.")
            }
            .task(id: ObjectIdentifier(client)) { await push.load(client: client, info: app.serverInfo) }
        }
    }

    private func test(_ client: APIClient) {
        testing = true
        Task {
            do {
                try await push.sendTest(client: client)
            } catch {
                ErrorBanner.shared.show(String(localized: "Sending failed: \(error.localizedDescription)"))
            }
            testing = false
        }
    }
}
