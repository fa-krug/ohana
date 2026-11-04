import SwiftUI

/// A notification channel's page, opened from its row in Settings → Notifications (editors): the
/// service and where it sends, on or off, a test message, editing and deleting. It shows what
/// `model` holds, so it follows the reloads, and closes once the channel is gone.
struct FamilyChannelPage: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let model: FamilySettingsModel
    let channelId: String

    @State private var editing: FamilyChannelEditing?
    @State private var confirmation: FamilyConfirmation?
    @State private var testing = false
    /// The switch's new state until the reload shows it.
    @State private var enabling: Bool?

    private var channel: FamilyChannel? {
        model.household?.channels.first { $0.id == channelId }
    }

    private var gone: Bool { model.household != nil && channel == nil }

    var body: some View {
        Form {
            if let channel {
                sections(channel)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle(channel?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load(family.api) }
        .onChange(of: gone, initial: true) { if gone { dismiss() } }
        .sheet(item: $editing) { editing in
            FamilyChannelSheet(channel: editing.channel) { input in
                try await editing.save(input, family: family, model: model)
            }
        }
        .familyConfirmation($confirmation)
    }

    @ViewBuilder
    private func sections(_ channel: FamilyChannel) -> some View {
        Section {
            LabeledContent("Service") {
                Label(channel.kind?.title ?? channel.provider, systemImage: channel.kind?.systemImage ?? "bell")
            }
            if let label = channel.kind?.targetLabel, !channel.target.isEmpty {
                LabeledContent(label) {
                    Text(channel.target).textSelection(.enabled)
                }
            }
            if channel.kind == .email, !channel.smtpHost.isEmpty {
                LabeledContent("SMTP server") {
                    Text(verbatim: "\(channel.smtpHost):\(channel.smtpPort)").textSelection(.enabled)
                }
            }
            Toggle("Active", isOn: Binding(get: { enabling ?? channel.enabled }, set: { setEnabled($0, channel) }))
                .disabled(!model.canEdit || enabling != nil)
        }

        Section {
            Button {
                test(channel)
            } label: {
                HStack {
                    Label("Send test message", systemImage: "paperplane")
                    Spacer(minLength: 8)
                    if testing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(testing)
            Button {
                editing = FamilyChannelEditing(channel: channel)
            } label: {
                Label("Edit channel", systemImage: "pencil")
            }
            .disabled(!model.canEdit)
        }

        Section {
            Button("Delete channel", role: .destructive) {
                confirmation = .deleteChannel(channel, family: family, model: model)
            }
            .disabled(!model.canEdit)
        }
    }

    /// Turns the channel on or off: its PATCH with what's stored (the blank token keeps the
    /// stored one).
    private func setEnabled(_ on: Bool, _ channel: FamilyChannel) {
        guard on != channel.enabled else { return }
        var changed = FamilyChannelInput(channel)
        changed.enabled = on
        let input = changed
        enabling = on
        perform {
            defer { enabling = nil }
            try await model.update(family) { api in
                try await api.perform(.patch, "/household/notifications/channels/\(channel.id)", body: input)
            }
        }
    }

    private func test(_ channel: FamilyChannel) {
        let api = family.api
        testing = true
        Task {
            await channel.sendTest(api)
            testing = false
        }
    }
}

extension FamilyChannelEditing {
    /// The channel sheet's Save: a PATCH of the channel or a POST of a new one, then the reload.
    func save(_ input: FamilyChannelInput, family: FamilyContext, model: FamilySettingsModel) async throws {
        try await model.update(family) { api in
            if let channel {
                try await api.perform(.patch, "/household/notifications/channels/\(channel.id)", body: input)
            } else {
                try await api.perform(.post, "/household/notifications/channels", body: input)
            }
        }
    }
}

extension FamilyChannel {
    /// Sends a test message through the channel; a failure goes to the banner.
    func sendTest(_ api: FamilyAPI) async {
        do {
            try await api.perform(.post, "/household/notifications/channels/\(id)/test")
        } catch is CancellationError {
        } catch {
            ErrorBanner.shared.show(String(localized: "Sending failed: \(error.localizedDescription)"))
        }
    }
}

extension FamilyConfirmation {
    /// Asks before deleting a channel (the row's context menu, the channel's page).
    static func deleteChannel(_ channel: FamilyChannel, family: FamilyContext,
                              model: FamilySettingsModel) -> FamilyConfirmation {
        FamilyConfirmation(
            title: String(localized: "Delete the channel “\(channel.name)”?"),
            button: String(localized: "Delete"),
            message: String(localized: "Searches stop sending to it.")
        ) {
            let api = family.api
            model.change(family) {
                try await api.perform(.delete, "/household/notifications/channels/\(channel.id)")
            }
        }
    }
}
