import SwiftUI

/// All Chores: every chore of the family (the `ChoresStore`'s), by morning, day and evening, each
/// with how it repeats or when it's due, for managing them. Pushed from the chores page.
struct ChoresAllView: View {
    @Environment(FamilyContext.self) private var family
    @Binding var filter: ChoreFilter
    @State private var editing: ChoreEditorTarget?
    @State private var deleting: Chore?

    private var today: Day { Day.today }
    private var store: ChoresStore { family.chores }
    private var canEdit: Bool { store.canEdit }

    var body: some View {
        Group {
            if let page = store.page { content(page) }
        }
        .ohanaBackground(ModuleTint.chores)
        .navigationTitle("All Chores")
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chore", systemImage: "plus") { editing = .new }
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Whose chores", selection: $filter) { ChoreFilterChoices(people: store.page?.people ?? [], me: store.me) }
                        .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: filter == .everyone
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .sheet(item: $editing) { target in
            ChoreEditorHost(target: target, filter: filter, day: today)
        }
        .confirmationDialog(
            Text("Delete “\(deleting?.title ?? "")”?"), isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { chore in
            Button("Delete", role: .destructive) { store.delete(chore.id) }
        }
    }

    @ViewBuilder
    private func content(_ page: ChoresPage) -> some View {
        let parts = ChoreParts.chores(page.chores, filter: filter)
        if parts.isEmpty {
            ContentUnavailableView {
                Label("No chores yet", systemImage: Module.chores.systemImage)
            } actions: {
                if filter != .everyone {
                    Button("Show Everyone’s") { filter = .everyone }
                        .buttonStyle(.glass)
                } else if canEdit {
                    Button("New Chore", systemImage: "plus") { editing = .new }
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            List {
                ForEach(parts, id: \.part) { part in
                    Section {
                        ForEach(part.items) { row($0) }
                    } header: {
                        Label(part.part.title, systemImage: part.part.systemImage)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .readableWidth()
            .refreshable { await store.refresh() }
        }
    }

    private func row(_ chore: Chore) -> some View {
        Button { editing = .chore(chore) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chore.title)
                        .strikethrough(chore.done)
                        .foregroundStyle(chore.done ? .secondary : .primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if chore.isRepeating {
                            Image(systemName: "repeat").accessibilityLabel(Text("Repeating"))
                        }
                        Text(ChoreText.schedule(chore, today: today))
                        if let assignee = chore.assignee {
                            Label(assignee.name, systemImage: "person.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chore.subscribed {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(ModuleTint.chores)
                        .accessibilityLabel(Text("Notifies you"))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(canEdit ? "Edit" : "Show", systemImage: canEdit ? "pencil" : "info.circle") { editing = .chore(chore) }
            if canEdit {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = chore }
            }
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = chore }
            }
        }
    }
}
