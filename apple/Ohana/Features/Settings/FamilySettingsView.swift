import SwiftUI

/// All settings in one place, like the system's Settings: the account (a card that opens its
/// page) on top, on iPhone and a narrow iPad the families to switch to, then the family's pages
/// (general: the name, export / import, leaving or deleting the family (deleting only for its last
/// member); the household's members, home address and notifications, this device's push
/// notifications among them), links to the modules' settings (the shopping list in Reminders and
/// the knowledge folder among them, this device's), this device's, and the server's administration
/// for administrators; viewers see them read-only. The settings of a module the server has off
/// don't show. The list shows at once: every row is a link, what the household holds (GET
/// /household, loaded meanwhile) shows on the pages.
struct FamilySettingsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var model = FamilySettingsModel()
    /// A page opened by a route (`family.open(.settings(.home))`).
    @State private var page: SettingsPage?

    var body: some View {
        FamilySettingsForm(model: model)
            .ohanaBackground(ModuleTint.settings)
            .navigationTitle("Settings")
            // The household, for the pages, before one opens.
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

/// One page of the settings: the family's (general, members, home address, notifications), a
/// module's settings, the family's data, or this device's.
struct FamilySettingsPageView: View {
    let page: SettingsPage
    let model: FamilySettingsModel
    @Environment(FamilyContext.self) private var family

    /// The page a route opens; nil for the settings themselves.
    static func page(for route: AppRoute) -> SettingsPage? {
        if case let .settings(page) = route { return page }
        return nil
    }

    var body: some View {
        switch page {
        case .general: household(FamilyGeneralView(model: model))
        case .members: household(FamilyMembersView(model: model))
        case .home: household(FamilyHomeAddressView(model: model))
        case .notifications: household(FamilyNotificationsView(model: model))
        case .calendar: CalendarSettingsView()
        case .finance: FinanceSettingsView()
        case .shopping: ShoppingRemindersView()
        case .assistant: AssistantSettingsView()
        case .knowledge: KnowledgeSettingsView()
        case .data: FamilyDataView(familyName: model.household?.name ?? family.family.name, canEdit: family.canEdit)
        case .device: DeviceSettingsView()
        }
    }

    /// A page of the household's: while it loads (or failed) that over the page.
    private func household(_ content: some View) -> some View {
        content.overlay {
            switch model.state {
            case .idle, .loading:
                PageLoadingView()
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.load(family.api) } }
                        .buttonStyle(.glassProminent)
                }
            case .loaded, .saved:
                EmptyView()
            }
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

    /// Runs a change (errors go to the banner), then reloads and tells the other screens.
    func change(_ family: FamilyContext, _ action: @escaping () async throws -> Void) {
        perform {
            try await action()
            await self.load(family.api)
            family.didChange(.family)
        }
    }

    /// A change from a sheet: thrown errors stay in the sheet.
    func update(_ family: FamilyContext, _ action: (FamilyAPI) async throws -> Void) async throws {
        try await action(family.api)
        await load(family.api)
        family.didChange(.family)
    }

    /// A new invite link, for `personId`'s member without an account or anyone.
    func createInvite(_ family: FamilyContext, role: FamilyRole, personId: String?) async throws -> URL? {
        let invite: FamilyNewInvite = try await family.api.send(.post, "/household/invites",
                                                                 body: FamilyInviteInput(role: role, personId: personId))
        await load(family.api)
        return URL(string: invite.url)
    }

    /// Shows an event's new state right away (the switch shouldn't wait for the server).
    func replace(_ pref: FamilyEventPref) {
        edit { household in
            guard let i = household.events.firstIndex(where: { $0.id == pref.id }) else { return }
            household.events[i] = pref
        }
    }

    /// Shows a member as the server answered a change of theirs (their photo), before the reload.
    func replace(_ member: FamilyMember) {
        edit { household in
            guard let i = household.members.firstIndex(where: { $0.userId == member.userId }) else { return }
            household.members[i] = member
        }
    }

    /// Shows a member without an account as the server answered a change of theirs.
    func replace(_ person: FamilyPerson) {
        edit { household in
            guard let i = household.people.firstIndex(where: { $0.id == person.id }) else { return }
            household.people[i] = person
        }
    }

    private func edit(_ change: (inout FamilyHousehold) -> Void) {
        guard var household = state.value else { return }
        change(&household)
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let model: FamilySettingsModel

    /// Where there's no sidebar with the family menu: the families here.
    private var listsFamilies: Bool {
        #if os(iOS)
        Module.onPhone || sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Form {
            accountSection

            if listsFamilies { FamilyListSection() }

            if !family.canEdit {
                Section {
                    Label("You are a viewer in this family: you can look at everything but not change it.",
                          systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                link(.general) {
                    FamilySettingsLabel(title: "General", systemImage: "gearshape.fill", tint: .gray)
                }
                link(.members) {
                    FamilySettingsLabel(title: "Members", systemImage: "person.2.fill", tint: .ohana)
                }
                link(.home) {
                    FamilySettingsLabel(title: "Home address", systemImage: "house.fill", tint: .indigo)
                }
                link(.notifications) {
                    FamilySettingsLabel(title: "Notifications", systemImage: "bell.badge.fill", tint: .red)
                }
            } header: {
                Text(verbatim: app.selectedFamily?.name ?? family.family.name)
            }

            Section("Modules") {
                link(.calendar) {
                    FamilySettingsLabel(title: "Calendar", systemImage: Module.calendar.systemImage, tint: ModuleTint.calendar)
                }
                if family.isEnabled(.finance) {
                    link(.finance) {
                        FamilySettingsLabel(title: "Finance", systemImage: Module.finance.systemImage, tint: ModuleTint.finance)
                    }
                }
                if family.isEnabled(.meals), !app.isDemo {
                    link(.shopping) {
                        FamilySettingsLabel(title: "Shopping List", systemImage: "checklist", tint: ModuleTint.meals)
                    }
                }
                if family.isEnabled(.assistant) {
                    link(.assistant) {
                        FamilySettingsLabel(title: "Assistant", systemImage: "sparkles", tint: ModuleTint.assistant)
                    }
                }
                if family.knowledgeAvailable {
                    link(.knowledge) {
                        FamilySettingsLabel(title: "Knowledge", systemImage: "books.vertical.fill", tint: ModuleTint.knowledge)
                    }
                }
            }

            Section {
                link(.device) {
                    #if os(macOS)
                    FamilySettingsLabel(title: "This device", systemImage: "desktopcomputer", tint: .blue)
                    #else
                    FamilySettingsLabel(title: "This device", systemImage: "iphone", tint: .blue)
                    #endif
                }
            }

            if app.me?.isAdmin == true, !app.isDemo {
                Section("Server") {
                    NavigationLink {
                        AdminView().assistantButton()
                    } label: {
                        FamilySettingsLabel(title: "Administration", systemImage: "person.badge.shield.checkmark", tint: .indigo)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(family.api) }
    }

    private func link(_ page: SettingsPage, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink {
            FamilySettingsPageView(page: page, model: model).assistantButton()
        } label: {
            label()
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
}

/// Settings → General: the family's name, its export and import, leaving it or (its last member)
/// deleting it.
private struct FamilyGeneralView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    let model: FamilySettingsModel

    @State private var name = ""
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            if let household = model.household {
                content(household)
            }
        }
        .formStyle(.grouped)
        .readableWidth()
        .scrollContentBackground(.hidden)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("General")
        .refreshable { await model.load(family.api) }
        .onChange(of: model.household?.name, initial: true) { _, new in name = new ?? "" }
    }

    @ViewBuilder
    private func content(_ household: FamilyHousehold) -> some View {
        Section {
            if model.canEdit {
                HStack {
                    TextField("Family name", text: $name)
                        .onSubmit { rename(household) }
                        .submitLabel(.done)
                    if trimmedName != household.name {
                        Button("Save") { rename(household) }
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

        Section("Data") {
            NavigationLink {
                FamilySettingsPageView(page: .data, model: model).assistantButton()
            } label: {
                FamilySettingsLabel(title: "Export and import", systemImage: "externaldrive.fill", tint: .teal)
            }
            if household.members.count > 1 {
                Button("Leave the family", role: .destructive) { confirmLeave = true }
                    .disabled(model.state.isSaved)
            }
            // Only its last member deletes a family.
            if household.canEdit, household.members.count <= 1 {
                Button("Delete the family", role: .destructive) { confirmDelete = true }
                    .disabled(model.state.isSaved)
            }
        }
        .confirmationDialog(Text("Leave \(household.name)?"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave the family", role: .destructive) { leave(household) }
        } message: {
            Text("You won’t see it anymore unless someone adds you again.")
        }
        .confirmationDialog(Text("Delete \(household.name)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete the family", role: .destructive, action: delete)
        } message: {
            Text("Everything in it is deleted. This can’t be undone.")
        }
    }

    private func rename(_ household: FamilyHousehold) {
        let new = trimmedName
        guard model.canEdit, !new.isEmpty, new != household.name else { return }
        let api = family.api
        model.change(family) {
            try await api.perform(.patch, "", body: FamilyNameInput(name: new))
            await app.refresh()
        }
    }

    private func leave(_ household: FamilyHousehold) {
        let api = family.api, selfId = household.selfId
        perform {
            try await api.perform(.delete, "/household/members/\(selfId)")
            await app.refresh()
        }
    }

    private func delete() {
        let api = family.api
        perform {
            try await api.perform(.delete, "/household")
            await app.refresh()
        }
    }
}

/// Settings → This device: the theme and (on the Mac) the menu bar assistant.
private struct DeviceSettingsView: View {
    var body: some View {
        Form {
            DeviceSettingsSection()
        }
        .formStyle(.grouped)
        .readableWidth()
        .scrollContentBackground(.hidden)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("This device")
    }
}
