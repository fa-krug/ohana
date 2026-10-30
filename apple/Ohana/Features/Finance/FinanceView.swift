import SwiftUI

/// Finance (web/components/finance/finance-page.tsx): the period, account balances, the
/// transactions and the overview. Lives inside the shell's NavigationStack.
struct FinanceView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store: FinanceStore?

    var body: some View {
        Group {
            if let store, store.family === family {
                FinanceScreen(store: store)
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ohanaBackground(ModuleTint.finance)
        .navigationTitle("Finance")
        .task(id: ObjectIdentifier(family)) {
            if store?.family !== family { store = FinanceStore(family: family) }
        }
    }
}

enum FinanceTab: String, Hashable, CaseIterable {
    case transactions, overview

    var title: LocalizedStringKey {
        switch self {
        case .transactions: "Transactions"
        case .overview: "Overview"
        }
    }
}

struct FinanceScreen: View {
    @Bindable var store: FinanceStore
    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @AppStorage("finance.tab") private var tab = FinanceTab.transactions
    @State private var editing: FinanceEditTarget?
    @State private var importing = false
    @State private var findingTransfers = false
    @State private var query = ""
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    private var selecting: Bool {
        #if os(iOS)
        editMode.isEditing
        #else
        true
        #endif
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                FinancePeriodBar(store: store)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .searchable(text: $query, prompt: Text("Search payee, description, note"))
            .task(id: query) {
                // Search as you type, a moment after the last key.
                if query != store.filter.q { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                await store.setFilter { $0.q = query }
            }
            .task(id: family.revision(.finance)) { await store.revisionChanged(family.revision(.finance)) }
            .refreshable { await store.reloadAll() }
            .toolbar { toolbar }
            .sheet(item: $editing) { target in
                FinanceTransactionEditor(store: store, target: target)
            }
            .sheet(isPresented: $importing) { FinanceImportSheet(store: store) }
            .sheet(isPresented: $findingTransfers) { FinanceTransferSheet(store: store) }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            .onChange(of: editMode.isEditing) { _, editing in if !editing { store.selected = [] } }
            #endif
            .animation(.spring(duration: 0.3), value: store.toast)
            .animation(.spring(duration: 0.3), value: store.selected.isEmpty)
            // Edit → Undo / Redo (⌘Z, ⇧⌘Z) for the changes made here, while the page is shown.
            .onChange(of: undoManager, initial: true) { store.undoRegistry.attach(undoManager) }
            .onDisappear { store.undoRegistry.forgetAll() }
            .onChange(of: family.pendingRoute, initial: true) {
                guard let route = family.takeRoute(for: .finance) else { return }
                open(route)
            }
    }

    /// A place in Finance another module (or a link) sends the user to.
    private func open(_ route: AppRoute) {
        guard case let .financeTransactions(categoryID) = route else { return }
        tab = .transactions
        editing = nil
        query = ""
        #if os(iOS)
        editMode = .inactive
        #endif
        Task { await store.showTransactions(category: categoryID) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .transactions:
            FinanceTransactionsView(store: store, selecting: selecting) { editing = .existing($0) }
        case .overview:
            FinanceSummaryView(store: store)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        let showSelection = store.canEdit && selecting && !store.selected.isEmpty && tab == .transactions
        if showSelection || store.toast != nil || store.categorizing != nil {
            VStack(spacing: 8) {
                if let progress = store.categorizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress.total > 0 ? String(localized: "Sorting… \(progress.done) of \(progress.total)")
                             : String(localized: "Sorting…"))
                            .font(.callout.monospacedDigit())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
                if let toast = store.toast {
                    FinanceToastView(store: store, toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showSelection {
                    FinanceSelectionBar(store: store)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 640)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(FinanceTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if store.canEdit {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editing = .new
                } label: {
                    Label("Add transaction", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add transaction (⌘N)")
                Button {
                    importing = true
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Import a bank statement (⇧⌘I)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { moreMenu }
    }

    private var moreMenu: some View {
        Menu {
            if store.canEdit { editActions }
            Button("Finance settings", systemImage: "gearshape") { family.open(.settings(.finance)) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder
    private var editActions: some View {
        #if os(iOS)
        if tab == .transactions {
            Button(selecting ? String(localized: "Done selecting") : String(localized: "Select"), systemImage: "checkmark.circle") {
                withAnimation { editMode = selecting ? .inactive : .active }
            }
            Divider()
        }
        #endif
        if !store.categories.isEmpty {
            Button {
                Task { await store.autoCategorize() }
            } label: {
                Label("Sort into categories", systemImage: "sparkles")
                Text(store.aiConfigured
                     ? String(localized: "Like similar earlier ones, the rest with AI")
                     : String(localized: "Like similar earlier ones (set up the assistant for the rest)"))
            }
            .disabled(store.categorizing != nil)
            if !store.aiConfigured {
                // The AI isn't set up: Settings → AI.
                Button("Set up the assistant", systemImage: "gearshape.2") { family.open(.settings(.assistant)) }
            }
        }
        Button("Find transfers", systemImage: "arrow.left.arrow.right") { findingTransfers = true }
        Button {
            Task { await store.autoCombine() }
        } label: {
            Label("Combine automatically", systemImage: "wand.and.stars")
            Text("All split bookings and likely transfers of this period, without review")
        }
        Divider()
    }
}
