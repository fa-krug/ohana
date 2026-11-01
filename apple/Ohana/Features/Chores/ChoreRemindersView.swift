import SwiftUI

/// The family's chores in Reminders on this device (Settings → Chores in Reminders, and the
/// chores' More menu): asking for the access (saying why first), choosing a list or making a new
/// one, whose chores go there (everyone's, only mine, one person's), turning it off, "Sync now"
/// and how the last sync went. Viewers can use it too; in the demo it isn't offered.
struct ChoreRemindersView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @State private var reminders = ChoreReminders.shared
    @State private var store = RemindersStore.shared
    @State private var lists: [ReminderList] = []
    @State private var people: [ChorePerson] = []
    @State private var asking = false

    private var settings: ChoreRemindersSettings { reminders.settings(for: family.api) }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Ohana puts the family’s chores into a list in Reminders, each due on its day. A repeating chore gets a new reminder each time, three hours before it’s due. Tick a one-off chore off in Reminders and it’s done in Ohana too.")
                } icon: {
                    TintedIcon(systemImage: Module.chores.systemImage, tint: ModuleTint.chores, size: 34)
                }
            }
            if family.api.client.isDemo {
                Section {
                    Text("Connect your Ohana server to put the chores into Reminders.")
                        .foregroundStyle(.secondary)
                }
            } else {
                switch store.access {
                case .granted: chosen
                case .notDetermined: askFirst
                case .denied, .restricted, .writeOnly: denied
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Chores in Reminders")
        .task(id: store.revision) {
            store.refreshAccess()
            lists = store.lists().filter(\.isWritable)
        }
        .task(id: family.revision(.chores)) {
            guard !family.api.client.isDemo else { return }
            people = (try? await ChoresView.request(family.api).fetchOrSaved())?.people ?? people
        }
    }

    // MARK: Access

    private var askFirst: some View {
        Section {
            Button {
                ask()
            } label: {
                if asking {
                    ProgressView()
                } else {
                    Label("Allow Access to Reminders", systemImage: "lock.open")
                }
            }
            .disabled(asking)
        } footer: {
            Text("Ohana needs access to your reminders to write the chores into the list you choose, to keep them up to date and to see which you ticked off. Nothing else of your reminders goes to the server.")
        }
    }

    private var denied: some View {
        Section {
            Label(store.access == .restricted
                  ? "Reminders aren’t allowed on this device."
                  : "Ohana has no access to your reminders.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if store.access != .restricted, let url = RemindersStore.settingsURL {
                Link(destination: url) {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        } footer: {
            Text("Allow Ohana full access to Reminders in the Settings, then come back here.")
        }
    }

    private func ask() {
        asking = true
        Task {
            defer { asking = false }
            do {
                try await store.requestAccess()
                lists = store.lists().filter(\.isWritable)
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }

    // MARK: The list

    @ViewBuilder
    private var chosen: some View {
        let listID = settings.listID
        let missing = listID != nil && !lists.contains { $0.id == listID }
        Section {
            Picker("List", selection: Binding { listID } set: { choose($0) }) {
                Text("Off").tag(String?.none)
                if missing {
                    Text("A list that’s gone").tag(listID)
                }
                ForEach(lists) { list in
                    Text(verbatim: lists.filter({ $0.title == list.title }).count > 1 ? "\(list.title) (\(list.source))" : list.title)
                        .tag(Optional(list.id))
                }
            }
            Button("New List “\(String(localized: "Chores"))”", systemImage: "plus") { createList() }
        } header: {
            Text("Reminders list")
        } footer: {
            if missing {
                Text("The chosen list is gone. Choose another one.").foregroundStyle(.red)
            } else {
                Text("This device only. With a list shared in iCloud, everyone sees the chores: then turn it on on one device.")
            }
        }
        if listID != nil, !missing {
            scope
            status
        }
    }

    /// Whose chores: everyone's, the account's own, or one other person's.
    private var scope: some View {
        let me = app.me?.id
        let others = people.filter { $0.id != me }
        let current = settings.scope
        return Section {
            Picker("Chores of", selection: Binding { current } set: { setScope($0) }) {
                Text("Everyone").tag(String?.none)
                if let me {
                    Text("Only mine").tag(Optional(me))
                }
                ForEach(others) { person in
                    Text(verbatim: person.name).tag(Optional(person.id))
                }
                if let current, current != me, !people.contains(where: { $0.id == current }) {
                    Text("Someone no longer in the family").tag(Optional(current))
                }
            }
        } footer: {
            Text(current == nil
                 ? "Each reminder says whom the chore is for."
                 : "Only their chores; those of the others don’t go to the list.")
        }
    }

    private var status: some View {
        Section {
            Button {
                Task { await reminders.sync(family, reason: .manual) }
            } label: {
                if reminders.isSyncing(family.api) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…")
                    }
                } else {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(reminders.isSyncing(family.api))
            if let error = settings.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let last = settings.lastSync {
                LabeledContent("Last synced") {
                    Text(last, format: .relative(presentation: .named))
                }
                if let result = settings.lastResult {
                    Text(Self.summary(result)).foregroundStyle(.secondary)
                }
            }
            Button("Open Reminders", systemImage: "arrow.up.forward.app") { RemindersStore.openRemindersApp() }
        } header: {
            Text("Sync")
        } footer: {
            Text("It syncs by itself when you open Ohana, when the chores change and when you tick one off in Reminders; while Ohana is open, also when a repeating chore is due again. A reminder you delete stays deleted until its chore changes (a repeating chore’s until its next time).")
        }
    }

    /// "3 added, 1 updated, 2 removed, 1 ticked off", "Nothing to change".
    static func summary(_ result: ChoreSyncResult) -> String {
        guard !result.changedNothing else { return String(localized: "Nothing to change") }
        var parts: [String] = []
        if result.added > 0 { parts.append(String(localized: "\(result.added) added")) }
        if result.updated > 0 { parts.append(String(localized: "\(result.updated) updated")) }
        if result.removed > 0 { parts.append(String(localized: "\(result.removed) removed")) }
        let ticked = result.completed + result.reported
        if ticked > 0 { parts.append(String(localized: "\(ticked) ticked off or reopened")) }
        return parts.joined(separator: ", ")
    }

    private func choose(_ listID: String?) {
        reminders.setList(listID, for: family.api)
        guard listID != nil else { return }
        Task { await reminders.sync(family, reason: .changed) }
    }

    private func setScope(_ scope: String?) {
        reminders.setScope(scope, for: family.api)
        Task { await reminders.sync(family, reason: .changed) }
    }

    private func createList() {
        do {
            let list = try store.createList(title: String(localized: "Chores"))
            lists = store.lists().filter(\.isWritable)
            choose(list.id)
        } catch {
            ErrorBanner.shared.show(error)
        }
    }
}

/// Settings → Chores in Reminders' row: the list they go to, or off.
struct ChoreRemindersStatus: View {
    @Environment(FamilyContext.self) private var family
    @State private var reminders = ChoreReminders.shared
    @State private var store = RemindersStore.shared

    var body: some View {
        if let listID = reminders.settings(for: family.api).listID {
            Text(verbatim: store.list(listID)?.title ?? String(localized: "On"))
        } else {
            Text("Off")
        }
    }
}

/// The chores' sheet of `ChoreRemindersView`.
struct ChoreRemindersSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChoreRemindersView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .errorBanner()
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 560)
        #endif
    }
}

/// Starts the family's chores sync (`ChoreReminders`) from the shell: when the app becomes
/// active, when the shell shows the family (a switch rebuilds it), a few seconds after the chores
/// change, and after Reminders change (a chore ticked off there; the sync's own changes come back
/// too, and the sync after them finds nothing to do).
struct ChoreRemindersUpdates: ViewModifier {
    @Environment(FamilyContext.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = RemindersStore.shared
    /// The revisions the shell started with: only later ones are changes.
    @State private var seen: Int?
    @State private var seenReminders: Int?

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                RemindersStore.shared.refreshAccess()
                await ChoreReminders.shared.sync(family, reason: .automatic)
            }
            .task(id: family.revision(.chores)) {
                let revision = family.revision(.chores)
                guard let seen, seen != revision else {
                    seen = revision
                    return
                }
                self.seen = revision
                // Waits out a burst of changes.
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await ChoreReminders.shared.sync(family, reason: .changed)
            }
            .task(id: store.revision) {
                let revision = store.revision
                guard let seenReminders, seenReminders != revision else {
                    seenReminders = revision
                    return
                }
                self.seenReminders = revision
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await ChoreReminders.shared.sync(family, reason: .changed)
            }
    }
}
