import SwiftUI

/// Settings → Notifications: which events reach the family's channels (and which channels),
/// and the channels themselves (Pushbullet, Pushover, Telegram, ntfy, email; editors open each
/// one's page, `FamilyChannelPage`). Editors change them; viewers see them. Events of a module the
/// server has off don't show.
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
                ProgressView()
            }
        }
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Notifications")
        .sheet(item: $editing) { editing in
            FamilyChannelSheet(channel: editing.channel) { input in
                try await editing.save(input, family: family, model: model)
            }
        }
        .familyConfirmation($confirmation)
    }

    private func form(_ household: FamilyHousehold) -> some View {
        Form {
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
                Text("Which news go to the channels below. Each message is sent once; nothing repeats every day.")
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
                Text("Where Ohana sends news for the family, e.g. a newly free appointment. Tokens and passwords are stored encrypted.")
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(family.api) }
    }

    /// A channel's row; editors open its page (and have its actions in the context menu).
    @ViewBuilder
    private func channelRow(_ channel: FamilyChannel, canEdit: Bool) -> some View {
        if canEdit {
            NavigationLink {
                FamilyChannelPage(model: model, channelId: channel.id).assistantButton()
            } label: {
                channelLabel(channel)
            }
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

        if pref.hasChannels && pref.enabled {
            if channels.isEmpty {
                Text("Add a channel below first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
    }

    private var summary: String {
        guard let ids = pref.channelIds else { return String(localized: "All channels") }
        let names = channels.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "None") : names.joined(separator: ", ")
    }
}
