import SwiftUI

/// Settings → Notifications: which events reach the family's channels (and which channels),
/// and the channels themselves (Pushbullet, Pushover, Telegram, email). Editors change them;
/// viewers see them.
struct FamilyNotificationsView: View {
    @Environment(FamilyContext.self) private var family
    let model: FamilySettingsModel

    @State private var editing: FamilyChannelEditing?
    @State private var confirmation: FamilyConfirmation?
    @State private var testing: String?
    @State private var testSent = false

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
                if let channel = editing.channel {
                    try await family.api.perform(.patch, "/household/notifications/channels/\(channel.id)", body: input)
                } else {
                    try await family.api.perform(.post, "/household/notifications/channels", body: input)
                }
                await model.load(family.api)
                family.didChange(.family)
            }
        }
        .familyConfirmation($confirmation)
        .alert("Test message sent.", isPresented: $testSent) {
            Button("OK", role: .cancel) {}
        }
    }

    private func form(_ household: FamilyHousehold) -> some View {
        Form {
            Section {
                ForEach(household.events) { pref in
                    FamilyEventRow(pref: pref, channels: household.channels, canEdit: household.canEdit) { next in
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
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(family.api) }
    }

    private func channelRow(_ channel: FamilyChannel, canEdit: Bool) -> some View {
        HStack(spacing: 12) {
            TintedIcon(systemImage: channel.kind?.systemImage ?? "bell", tint: channel.enabled ? .red : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name).fontWeight(.medium).lineLimit(1)
                    if !channel.enabled { Text("(off)").foregroundStyle(.secondary) }
                }
                Text([channel.kind?.title ?? channel.provider, channel.target].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if canEdit {
                if testing == channel.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Test") { test(channel) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Menu {
                    channelActions(channel)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("Actions for \(channel.name)"))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
        .contextMenu {
            if canEdit { channelActions(channel) }
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
            confirmation = FamilyConfirmation(
                title: String(localized: "Delete the channel “\(channel.name)”?"),
                button: String(localized: "Delete"),
                message: String(localized: "Searches stop sending to it.")
            ) {
                let api = family.api
                model.change(family) {
                    try await api.perform(.delete, "/household/notifications/channels/\(channel.id)")
                }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func test(_ channel: FamilyChannel) {
        let api = family.api
        testing = channel.id
        Task {
            do {
                try await api.perform(.post, "/household/notifications/channels/\(channel.id)/test")
                testSent = true
            } catch is CancellationError {
            } catch {
                ErrorBanner.shared.show(String(localized: "Sending failed: \(error.localizedDescription)"))
            }
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
