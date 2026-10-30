import SwiftUI

/// The family's settings (the web app's settings page with its tabs): the name, the household
/// (members, people without an account and invites; the home address; notifications), links to
/// the modules' settings, export / import, and leaving or deleting the family. Viewers see
/// everything read-only.
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
            FamilySettingsPageView(page: page, model: model).id(page)
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

    func load(_ api: FamilyAPI) async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.get("/household"))
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error.localizedDescription) } else { ErrorBanner.shared.show(error) }
        }
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
        state = .loaded(household)
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
            if !household.canEdit {
                Section {
                    Label("You are a viewer in this family: you can look at everything but not change it.",
                          systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                if household.canEdit {
                    HStack {
                        TextField("Family name", text: $name)
                            .onSubmit(rename)
                            .submitLabel(.done)
                        if trimmedName != household.name {
                            Button("Save", action: rename)
                                .buttonStyle(.glassProminent)
                                .disabled(trimmedName.isEmpty)
                        }
                    }
                } else {
                    LabeledContent("Family name", value: household.name)
                }
            }

            Section("Household") {
                NavigationLink {
                    FamilySettingsPageView(page: .members, model: model)
                } label: {
                    LabeledContent {
                        Text(household.members.count + household.people.count, format: .number)
                    } label: {
                        FamilySettingsLabel(title: "Members", systemImage: "person.2.fill", tint: .ohana)
                    }
                }
                NavigationLink {
                    FamilySettingsPageView(page: .home, model: model)
                } label: {
                    LabeledContent {
                        Text(household.home.address ?? String(localized: "Not set."))
                            .lineLimit(1)
                    } label: {
                        FamilySettingsLabel(title: "Home address", systemImage: "house.fill", tint: .indigo)
                    }
                }
                NavigationLink {
                    FamilySettingsPageView(page: .notifications, model: model)
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
                    FamilySettingsPageView(page: .calendar, model: model)
                } label: {
                    FamilySettingsLabel(title: "Calendar", systemImage: Module.calendar.systemImage, tint: ModuleTint.calendar)
                }
                NavigationLink {
                    FamilySettingsPageView(page: .finance, model: model)
                } label: {
                    FamilySettingsLabel(title: "Finance", systemImage: Module.finance.systemImage, tint: ModuleTint.finance)
                }
                NavigationLink {
                    FamilySettingsPageView(page: .assistant, model: model)
                } label: {
                    FamilySettingsLabel(title: "Assistant", systemImage: "sparkles", tint: ModuleTint.assistant)
                }
            }

            Section("Data") {
                NavigationLink {
                    FamilySettingsPageView(page: .data, model: model)
                } label: {
                    FamilySettingsLabel(title: "Export and import", systemImage: "externaldrive.fill", tint: .teal)
                }
            }

            Section {
                if memberCount > 1 {
                    Button("Leave the family", role: .destructive) { confirmLeave = true }
                }
                if household.canEdit {
                    Button("Delete the family", role: .destructive) { confirmDelete = true }
                        .disabled(memberCount > 1)
                }
            } header: {
                Text("Leave or delete")
            } footer: {
                if household.canEdit && memberCount > 1 {
                    Text("Only possible when you are the last member.")
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

    private func rename() {
        let new = trimmedName
        guard household.canEdit, !new.isEmpty, new != household.name else { return }
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
