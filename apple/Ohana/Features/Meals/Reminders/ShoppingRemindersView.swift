import SwiftUI

/// The family's shopping list in Reminders on this device (Settings → Shopping List, and the meal
/// plan's toolbar): asking for the access (saying why first), choosing a list or making a new
/// one, turning it off, "Sync now" and how the last sync went. Viewers can use it too; in the demo
/// it isn't offered.
struct ShoppingRemindersView: View {
    @Environment(FamilyContext.self) private var family
    @State private var reminders = ShoppingReminders.shared
    @State private var store = RemindersStore.shared
    @State private var lists: [ReminderList] = []
    @State private var asking = false

    private var settings: ShoppingRemindersSettings { reminders.settings(for: family.api) }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Ohana puts what the meal plan needs into a list in Reminders, each item due on its shopping day. Tick items off, change them or add more in Reminders: Ohana leaves what you changed alone.")
                } icon: {
                    TintedIcon(systemImage: "checklist", tint: ModuleTint.meals, size: 34)
                }
            }
            if family.api.client.isDemo {
                Section {
                    Text("Connect your Ohana server to put the shopping list into Reminders.")
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
        .navigationTitle("Shopping List")
        .task(id: store.revision) {
            store.refreshAccess()
            lists = store.lists().filter(\.isWritable)
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
            Text("Ohana needs access to your reminders to write the shopping list into the list you choose and to keep it up to date. Nothing of your reminders goes to the server.")
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
            Button("New List “\(String(localized: "Shopping"))”", systemImage: "plus") { createList() }
        } header: {
            Text("Reminders list")
        } footer: {
            if missing {
                Text("The chosen list is gone. Choose another one.").foregroundStyle(.red)
            } else {
                Text("This device only. With a list shared in iCloud, everyone sees the items: then turn it on on one device.")
            }
        }
        if listID != nil, !missing {
            status
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
            Text("It syncs by itself when you open Ohana and when the meal plan changes. Tick items off in the Reminders app while you shop.")
        }
    }

    /// "3 added, 1 updated, 2 removed", "Nothing to change".
    static func summary(_ result: ShoppingSyncResult) -> String {
        guard !result.changedNothing else { return String(localized: "Nothing to change") }
        var parts: [String] = []
        if result.added > 0 { parts.append(String(localized: "\(result.added) added")) }
        if result.updated > 0 { parts.append(String(localized: "\(result.updated) updated")) }
        if result.removed > 0 { parts.append(String(localized: "\(result.removed) removed")) }
        return parts.joined(separator: ", ")
    }

    private func choose(_ listID: String?) {
        reminders.setList(listID, for: family.api)
        guard listID != nil else { return }
        Task { await reminders.sync(family, reason: .changed) }
    }

    private func createList() {
        do {
            let list = try store.createList(title: String(localized: "Shopping"))
            lists = store.lists().filter(\.isWritable)
            choose(list.id)
        } catch {
            ErrorBanner.shared.show(error)
        }
    }
}

/// Settings → Shopping List's row: the list it goes to, or off.
struct ShoppingRemindersStatus: View {
    @Environment(FamilyContext.self) private var family
    @State private var reminders = ShoppingReminders.shared
    @State private var store = RemindersStore.shared

    var body: some View {
        if let listID = reminders.settings(for: family.api).listID {
            Text(verbatim: store.list(listID)?.title ?? String(localized: "On"))
        } else {
            Text("Off")
        }
    }
}

/// The meal plan's sheet of `ShoppingRemindersView`.
struct ShoppingRemindersSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ShoppingRemindersView()
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

/// Starts the family's shopping sync (`ShoppingReminders`) from the shell: when the app becomes
/// active, when the shell shows the family (a switch rebuilds it), and a few seconds after the
/// meal plan or the recipes change.
struct ShoppingRemindersUpdates: ViewModifier {
    @Environment(FamilyContext.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    /// The revisions the shell started with: only later ones are changes.
    @State private var seen: [Int]?

    private var revisions: [Int] {
        [family.revision(.mealPlan), family.revision(.recipes), family.revision(.meals)]
    }

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                RemindersStore.shared.refreshAccess()
                await ShoppingReminders.shared.sync(family, reason: .automatic)
            }
            .task(id: revisions) {
                guard let seen, seen != revisions else {
                    seen = revisions
                    return
                }
                self.seen = revisions
                // Waits out a burst of changes (the assistant planning a week).
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await ShoppingReminders.shared.sync(family, reason: .changed)
            }
    }
}
