import SwiftUI

/// Settings → Notifications: this device's push notifications (`PushSettingsSection`, everyone's),
/// which events reach the family's channels (and which channels), and the channels themselves
/// (Pushbullet, Pushover, Telegram, ntfy, email; editors open each one's sheet, with its test and
/// deleting at its foot). Editors change them; viewers see them. Events of a module the server has
/// off don't show.
struct FamilyNotificationsView: View {
    @Environment(FamilyContext.self) private var family
    let model: FamilySettingsModel

    @State private var editing: FamilyChannelEditing?
    @State private var confirmation: FamilyConfirmation?
    @State private var testing: String?

    var body: some View {
        Group {
            if let household = model.household {
                form(household)
            } else {
                PageLoadingView()
            }
        }
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Notifications")
        .sheet(item: $editing) { editing in
            FamilyChannelSheet(channel: editing.channel,
                               test: editing.channel.map { channel in { await channel.sendTest(family.api) } },
                               deletion: editing.channel.map { .deleteChannel($0, family: family, model: model) }) { input in
                try await editing.save(input, family: family, model: model)
            }
        }
        .familyConfirmation($confirmation)
    }

    private func form(_ household: FamilyHousehold) -> some View {
        Form {
            PushSettingsSection(family: family.family)

            Section {
                ForEach(household.events.filter { pref in pref.module.map { family.isEnabled($0) } ?? true }) { pref in
                    FamilyEventRow(pref: pref, channels: household.channels, canEdit: household.canEdit,
                                   showsApp: family.serverInfo?.push != nil) { next in
                        save(next)
                    }
                }
            } header: {
                Text("What Ohana tells you")
            } footer: {
                Text("Each message is sent once.")
            }

            Section {
                if household.channels.isEmpty {
                    Text("No notification channels yet.").foregroundStyle(.secondary)
                }
                ForEach(household.channels) { channel in
                    channelRow(channel, canEdit: household.canEdit)
                }
                if household.canEdit {
                    Button {
                        editing = FamilyChannelEditing(channel: nil)
                    } label: {
                        Label("Add a channel", systemImage: "plus")
                    }
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("Where Ohana sends the family’s news, e.g. a newly free appointment.")
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(family.api) }
    }

    /// A channel's row; editors open its sheet (and have its actions in the context menu).
    @ViewBuilder
    private func channelRow(_ channel: FamilyChannel, canEdit: Bool) -> some View {
        if canEdit {
            Button {
                editing = FamilyChannelEditing(channel: channel)
            } label: {
                channelLabel(channel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu { channelActions(channel) }
        } else {
            channelLabel(channel)
        }
    }

    private func channelLabel(_ channel: FamilyChannel) -> some View {
        HStack(spacing: 12) {
            TintedIcon(systemImage: channel.kind?.systemImage ?? "bell", tint: channel.enabled ? .red : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name).fontWeight(.medium).lineLimit(2)
                    if !channel.enabled { Text("(off)").foregroundStyle(.secondary) }
                }
                Text([channel.kind?.title ?? channel.provider, channel.target].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if testing == channel.id {
                Spacer(minLength: 8)
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func channelActions(_ channel: FamilyChannel) -> some View {
        Button {
            test(channel)
        } label: {
            Label("Test", systemImage: "paperplane")
        }
        Button {
            editing = FamilyChannelEditing(channel: channel)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            confirmation = .deleteChannel(channel, family: family, model: model)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func test(_ channel: FamilyChannel) {
        let api = family.api
        testing = channel.id
        Task {
            await channel.sendTest(api)
            testing = nil
        }
    }

    private func save(_ pref: FamilyEventPref) {
        let api = family.api
        model.replace(pref)
        perform {
            do {
                let _: FamilyEventPref = try await api.send(.put, "/household/notifications/events/\(pref.event)",
                                                            body: pref.input)
            } catch {
                await model.load(api)
                throw error
            }
        }
    }
}

struct FamilyChannelEditing: Identifiable {
    let channel: FamilyChannel?
    var id: String { channel?.id ?? "new" }
}

/// One event: on or off, and for those that pick them here, its channels.
private struct FamilyEventRow: View {
    let pref: FamilyEventPref
    let channels: [FamilyChannel]
    let canEdit: Bool
    /// The server pushes to the app (`ServerInfo.push`).
    let showsApp: Bool
    let save: (FamilyEventPref) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { pref.enabled }, set: { on in
            var next = pref
            next.enabled = on
            save(next)
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pref.title)
                Text(pref.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canEdit)

        // The Ohana app (push through the relay); appointment searches choose it themselves.
        if showsApp, pref.hasChannels && pref.enabled, let app = pref.app {
            Toggle("Ohana app", isOn: Binding(get: { app }, set: { on in
                var next = pref
                next.app = on
                save(next)
            }))
            .font(.callout)
            .disabled(!canEdit)
            .padding(.leading, 12)
        }

        if pref.hasChannels && pref.enabled, !channels.isEmpty {
            DisclosureGroup {
                Toggle("All channels", isOn: Binding(get: { pref.channelIds == nil }, set: { all in
                    var next = pref
                    next.channelIds = all ? nil : channels.map(\.id)
                    save(next)
                }))
                .disabled(!canEdit)
                if pref.channelIds != nil {
                    ForEach(channels) { channel in
                        Toggle(isOn: Binding(get: { pref.channelIds?.contains(channel.id) == true }, set: { on in
                            save(pref.toggling(channel.id, on: on, all: channels.map(\.id)))
                        })) {
                            Text(channel.name)
                                .foregroundStyle(channel.enabled ? .primary : .secondary)
                        }
                        .disabled(!canEdit)
                    }
                }
            } label: {
                LabeledContent("Send to") {
                    Text(summary)
                }
                .font(.callout)
            }
            .padding(.leading, 12)
        }
    }

    private var summary: String {
        guard let ids = pref.channelIds else { return String(localized: "All channels") }
        let names = channels.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "None") : names.joined(separator: ", ")
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
    /// Asks before deleting a channel (the row's context menu, the channel's sheet).
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
