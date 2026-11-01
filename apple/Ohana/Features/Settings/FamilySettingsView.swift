import SwiftUI

/// All settings in one place, like the system's Settings: the account (a card that opens its
/// page) on top, then the family's (the web app's settings page with its tabs: the name, the
/// household (members, people without an account and invites; the home address; notifications),
/// links to the modules' settings, export / import, and leaving or deleting the family; viewers
/// see them read-only), this device's, and the server's administration for administrators. The
/// settings of a module the server has off don't show.
struct FamilySettingsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var model = FamilySettingsModel()
    /// A page opened by a route (`family.open(.settings(.home))`).
    @State private var page: SettingsPage?

    var body: some View {
        LoadStateView(state: model.state, retry: { await model.load(family.api) }) { household in
            FamilySettingsForm(model: model, household: household)
        }
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Settings")
        .task(id: [family.revision(.family), family.revision(.settings)]) { await model.load(family.api) }
        .navigationDestination(item: $page) { page in
            FamilySettingsPageView(page: page, model: model).id(page).assistantButton()
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .settings) else { return }
            page = FamilySettingsPageView.page(for: route)
        }
    }
}

/// One page of the settings: the household's (members, home address, notifications), a module's
/// settings, or the family's data.
struct FamilySettingsPageView: View {
    let page: SettingsPage
    let model: FamilySettingsModel

    /// The page a route opens; nil for the settings themselves.
    static func page(for route: AppRoute) -> SettingsPage? {
        if case let .settings(page) = route { return page }
        return nil
    }

    var body: some View {
        switch page {
        case .members: FamilyMembersView(model: model)
        case .home: FamilyHomeAddressView(model: model)
        case .notifications: FamilyNotificationsView(model: model)
        case .calendar: CalendarSettingsView()
        case .finance: FinanceSettingsView()
        case .assistant: AssistantSettingsView()
        case .data: FamilyDataView(familyName: model.household?.name ?? "", canEdit: model.household?.canEdit ?? false)
        }
    }
}

/// What the settings pages show: GET /household, shared by the root and the pages it opens (they
/// reload it after their changes, since the root's task doesn't run while they cover it).
@Observable
final class FamilySettingsModel {
    var state: LoadState<FamilyHousehold> = .idle

    var household: FamilyHousehold? { state.value }

    /// Changes to what's shown wait while it's the copy on the device.
    var canEdit: Bool { household?.canEdit == true && !state.isSaved }

    func load(_ api: FamilyAPI) async {
        await LoadState.run(Binding(get: { self.state }, set: { self.state = $0 }), Self.request(api))
    }

    /// The household's GET (the prefetch asks the same).
    static func request(_ api: FamilyAPI) -> CachedGet<FamilyHousehold> {
        api.cached("/household")
    }

    /// Runs a change (errors go to the banner), then reloads, tells the other screens and
    /// confirms with `success`.
    func change(_ family: FamilyContext, success: String? = nil, _ action: @escaping () async throws -> Void) {
        perform {
            try await action()
            await self.load(family.api)
            family.didChange(.family)
            if let success { ErrorBanner.shared.success(success) }
        }
    }

    /// Shows an event's new state right away (the switch shouldn't wait for the server).
    func replace(_ pref: FamilyEventPref) {
        guard var household = state.value, let i = household.events.firstIndex(where: { $0.id == pref.id }) else { return }
        household.events[i] = pref
        if case let .saved(_, date, updating) = state {
            state = .saved(household, date: date, updating: updating)
        } else {
            state = .loaded(household)
        }
    }
}

/// A settings row's label: a tinted round icon and the title.
struct FamilySettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = ModuleTint.settings

    var body: some View {
        Label {
            Text(title)
        } icon: {
            TintedIcon(systemImage: systemImage, tint: tint, size: 28)
        }
    }
}

private struct FamilySettingsForm: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    let model: FamilySettingsModel
    let household: FamilyHousehold

    @State private var name = ""
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    private var memberCount: Int { household.members.count }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            accountSection

            if !household.canEdit {
                Section {
                    Label("You are a viewer in this family: you can look at everything but not change it.",
                          systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if model.canEdit {
                    HStack {
                        TextField("Family name", text: $name)
                            .onSubmit(rename)
                            .submitLabel(.done)
                        if trimmedName != household.name {
                            Button("Save", action: rename)
                                .buttonStyle(.borderedProminent)
                                .disabled(trimmedName.isEmpty)
                        }
                    }
                } else {
                    LabeledContent("Family name", value: household.name)
                }
            } header: {
                Text("Family")
            } footer: {
                if model.canEdit && trimmedName.isEmpty {
                    Text("A family needs a name.").foregroundStyle(.red)
                }
            }

            Section("Household") {
                NavigationLink {
                    FamilySettingsPageView(page: .members, model: model).assistantButton()
                } label: {
                    LabeledContent {
                        Text(household.members.count + household.people.count, format: .number)
                    } label: {
                        FamilySettingsLabel(title: "Members", systemImage: "person.2.fill", tint: .ohana)
                    }
                }
                NavigationLink {
                    FamilySettingsPageView(page: .home, model: model).assistantButton()
                } label: {
                    LabeledContent {
                        Text(household.home.address ?? String(localized: "Not set."))
                            .lineLimit(1)
                    } label: {
                        FamilySettingsLabel(title: "Home address", systemImage: "house.fill", tint: .indigo)
                    }
                }
                NavigationLink {
                    FamilySettingsPageView(page: .notifications, model: model).assistantButton()
                } label: {
                    LabeledContent {
                        Text(household.channels.count, format: .number)
                    } label: {
                        FamilySettingsLabel(title: "Notifications", systemImage: "bell.badge.fill", tint: .red)
                    }
                }
            }

            Section("Modules") {
                NavigationLink {
                    FamilySettingsPageView(page: .calendar, model: model).assistantButton()
                } label: {
                    FamilySettingsLabel(title: "Calendar", systemImage: Module.calendar.systemImage, tint: ModuleTint.calendar)
                }
                if family.isEnabled(.finance) {
                    NavigationLink {
                        FamilySettingsPageView(page: .finance, model: model).assistantButton()
                    } label: {
                        FamilySettingsLabel(title: "Finance", systemImage: Module.finance.systemImage, tint: ModuleTint.finance)
                    }
                }
                if family.isEnabled(.assistant) {
                    NavigationLink {
                        FamilySettingsPageView(page: .assistant, model: model).assistantButton()
                    } label: {
                        FamilySettingsLabel(title: "Assistant", systemImage: "sparkles", tint: ModuleTint.assistant)
                    }
                }
            }

            Section("Data") {
                NavigationLink {
                    FamilySettingsPageView(page: .data, model: model).assistantButton()
                } label: {
                    FamilySettingsLabel(title: "Export and import", systemImage: "externaldrive.fill", tint: .teal)
                }
            }

            Section {
                if memberCount > 1 {
                    Button("Leave the family", role: .destructive) { confirmLeave = true }
                        .disabled(model.state.isSaved)
                }
                if household.canEdit {
                    Button("Delete the family", role: .destructive) { confirmDelete = true }
                        .disabled(memberCount > 1 || model.state.isSaved)
                }
            } header: {
                Text("Leave or delete")
            } footer: {
                if household.canEdit && memberCount > 1 {
                    Text("Only possible when you are the last member.")
                }
            }

            DeviceSettingsSection()
            PushSettingsSection()

            if app.me?.isAdmin == true, !app.isDemo {
                Section {
                    NavigationLink {
                        AdminView().assistantButton()
                    } label: {
                        FamilySettingsLabel(title: "Administration", systemImage: "person.badge.shield.checkmark", tint: .indigo)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Users and families of this server.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(family.api) }
        .onAppear { name = household.name }
        .onChange(of: household.name) { _, new in name = new }
        .confirmationDialog(Text("Leave \(household.name)?"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave the family", role: .destructive, action: leave)
        } message: {
            Text("You won’t see it anymore unless someone adds you again.")
        }
        .confirmationDialog(Text("Delete \(household.name)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete the family", role: .destructive, action: delete)
        } message: {
            Text("Everything in it is deleted. This can’t be undone.")
        }
    }

    /// Who is signed in (in the demo: that it is one), opening the account's page.
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountPageView().assistantButton()
            } label: {
                HStack(spacing: 14) {
                    if app.isDemo {
                        TintedIcon(systemImage: "sparkles.rectangle.stack", tint: .ohana, size: 44)
                        VStack(alignment: .leading) {
                            Text("Demo data").font(.headline)
                            Text("No server connected").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        TintedIcon(systemImage: "person.fill", tint: .ohana, size: 44)
                        VStack(alignment: .leading) {
                            Text(app.me?.displayName ?? "").font(.headline)
                            Text("Account, sign-in and security").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func rename() {
        let new = trimmedName
        guard model.canEdit, !new.isEmpty, new != household.name else { return }
        let api = family.api
        model.change(family, success: String(localized: "Family renamed.")) {
            try await api.perform(.patch, "", body: FamilyNameInput(name: new))
            await app.refresh()
        }
    }

    private func leave() {
        let api = family.api, selfId = household.selfId
        perform {
            try await api.perform(.delete, "/household/members/\(selfId)")
            await app.refresh()
            ErrorBanner.shared.success(String(localized: "You left the family."))
        }
    }

    private func delete() {
        let api = family.api
        perform {
            try await api.perform(.delete, "/household")
            await app.refresh()
            ErrorBanner.shared.success(String(localized: "Family deleted."))
        }
    }
}
