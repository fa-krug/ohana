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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage("finance.tab") private var tab = FinanceTab.transactions
    @State private var editing: FinanceEditTarget?
    /// The bank statement the import sheet shows (picked or dropped).
    @State private var importing: FinanceImportFile?
    @State private var choosingFile = false
    @State private var findingTransfers = false
    @State private var dropping = false
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

    /// iPhone (and a narrow iPad window): the period, balances and totals scroll with the list,
    /// the filters are a toolbar menu.
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !compact {
                    FinancePeriodBar(store: store)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .overlay { if dropping { dropHint } }
            // A bank statement dragged from the Finder or Files opens the import with it.
            .dropDestination(for: FinanceImportFile.self) { files, _ in
                guard store.canEdit, let file = files.first else { return false }
                importing = file
                return true
            } isTargeted: { over in
                dropping = over && store.canEdit
            }
            .searchable(text: $query, prompt: Text("Search payee, description, note"))
            #if os(iOS)
            .searchToolbarBehavior(compact ? .minimize : .automatic)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .sheet(item: $importing) { file in FinanceImportSheet(store: store, file: file) }
            .sheet(isPresented: $findingTransfers) { FinanceTransferSheet(store: store) }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: FinanceImportFile.contentTypes) { result in
                do { importing = try FinanceImportFile(url: result.get()) } catch { ErrorBanner.shared.show(error) }
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            .onChange(of: editMode.isEditing) { _, editing in if !editing { store.selected = [] } }
            .onChange(of: tab) { editMode = .inactive }
            // Selecting on the iPhone: the selection's actions take the tab bar's place.
            .toolbar(compact && selecting ? .hidden : .automatic, for: .tabBar)
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
            // File ▸ New Transaction (⌘N) and the Finance menu.
            .focusedSceneValue(\.newItem, store.canEdit ? NewItemAction(title: "New Transaction") { editing = .new } : nil)
            .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Finance") { moduleMenu })
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
            FinanceSummaryView(store: store, showsPeriod: compact)
        }
    }

    /// Shown while a file is dragged over the page.
    private var dropHint: some View {
        Label("Drop a bank statement (CSV) to import it", systemImage: "square.and.arrow.down")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(ModuleTint.finance.opacity(0.2)), in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(ModuleTint.finance, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    @ViewBuilder
    private var bottomBar: some View {
        #if os(macOS)
        let showSelection = store.canEdit && !store.selected.isEmpty && tab == .transactions
        #else
        // iOS shows the selection's actions in the bottom toolbar.
        let showSelection = false
        #endif
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
                #if os(macOS)
                if showSelection {
                    FinanceSelectionBar(store: store)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #endif
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: 640)
        }
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(FinanceTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        #if os(iOS)
        if selecting && tab == .transactions {
            selectionToolbar
        } else {
            pageToolbar
        }
        #else
        pageToolbar
        #endif
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        if store.canEdit {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editing = .new
                } label: {
                    Label("New Transaction", systemImage: "plus")
                }
                .help("New Transaction (⌘N)")
                if !compact {
                    Button {
                        choosingFile = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a bank statement (⇧⌘I)")
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        if compact && tab == .transactions {
            ToolbarItem(placement: .primaryAction) { FinanceFilterMenu(store: store) }
        }
        #if os(iOS)
        if store.canEdit && tab == .transactions {
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { withAnimation { editMode = .active } }
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) { moreMenu }
    }

    #if os(iOS)
    /// While selecting (the iOS edit mode): Select All and Done at the top, what can be done
    /// with the selection at the bottom.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        let all = Set(store.list?.transactions.map(\.id) ?? [])
        let selected = store.selectedTransactions
        ToolbarItem(placement: .topBarLeading) {
            if !all.isEmpty && store.selected == all {
                Button("Deselect All") { store.selected = [] }
            } else {
                Button("Select All") { store.selected = all }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Done") { withAnimation { editMode = .inactive } }
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                FinanceCategoryMenuItems(tree: store.tree, selection: nil) { id in
                    Task { await store.setCategory(selected.map(\.id), to: id) }
                }
            } label: {
                Label("Category", systemImage: "tag")
            }
            .disabled(selected.isEmpty)
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                FinanceCombineButtons(store: store, selected: selected)
            } label: {
                Label("Combine", systemImage: "link")
            }
            .disabled(selected.count < 2)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .status) {
            if !selected.isEmpty { FinanceSelectionSummary(store: store) }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await store.delete(selected.map(\.id)) }
            }
            .disabled(selected.isEmpty)
        }
    }
    #endif

    private var moreMenu: some View {
        Menu {
            if store.canEdit {
                if compact {
                    Button("Import CSV", systemImage: "square.and.arrow.down") { choosingFile = true }
                }
                editActions
            }
            Button("Finance settings", systemImage: "gearshape") { family.open(.settings(.finance)) }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder
    private var editActions: some View {
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

    /// The Finance menu (Mac menu bar, the iPad's ⌘-hold list).
    @ViewBuilder
    private var moduleMenu: some View {
        Picker("View", selection: $tab) {
            ForEach(FinanceTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Previous Period") { Task { await store.step(-1) } }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(store.period.mode == .all)
        Button("Next Period") { Task { await store.step(1) } }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(store.period.mode == .all)
        Button("Today") { Task { await store.goToToday() } }
        if store.canEdit {
            Divider()
            Button("Import CSV…") { choosingFile = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Find Transfers…") { findingTransfers = true }
            Button("Sort into Categories") { Task { await store.autoCategorize() } }
                .disabled(store.categories.isEmpty || store.categorizing != nil)
            Button("Combine Automatically") { Task { await store.autoCombine() } }
        }
        Divider()
        Button("Finance Settings") { family.open(.settings(.finance)) }
    }
}
