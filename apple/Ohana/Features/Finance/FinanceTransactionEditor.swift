import SwiftUI

/// What the editor sheet shows: a new transaction, or one of the list.
enum FinanceEditTarget: Identifiable {
    case new
    case existing(FinanceTransaction)

    var id: String {
        switch self {
        case .new: "new"
        case let .existing(t): t.id
        }
    }
}

/// Adds a transaction, or edits one (transaction-dialog.tsx); viewers see it read-only.
struct FinanceTransactionEditor: View {
    @Bindable var store: FinanceStore
    let target: FinanceEditTarget
    @Environment(\.dismiss) private var dismiss

    @State private var income = false
    @State private var amount = ""
    @State private var date = Date()
    @State private var payee = ""
    @State private var description = ""
    @State private var categoryId: String?
    @State private var accountId: String?
    @State private var note = ""
    @State private var problem: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    private var existing: FinanceTransaction? {
        if case let .existing(t) = target { t } else { nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.canEdit { editForm } else { readOnly }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? String(localized: "New transaction") : store.canEdit ? String(localized: "Edit transaction") : String(localized: "Transaction"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let existing else { return }
                    Task {
                        await store.delete([existing.id])
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .financeSheetFrame(minWidth: 420, minHeight: 520)
        .onAppear(perform: fill)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(store.canEdit ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() }
        }
        if store.canEdit {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(busy)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var editForm: some View {
        Section {
            Picker("Kind", selection: $income) {
                Text("Expense").tag(false)
                Text("Income").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: income) {
                // A category of the other kind doesn't fit any more.
                if let c = store.category(categoryId), !FinanceCategoryTree.fits(c, income: income) { categoryId = nil }
            }
            LabeledContent {
                TextField("Amount", text: $amount, prompt: Text(FinanceMoney.placeholder))
                    .multilineTextAlignment(.trailing)
                    .font(.title3.monospacedDigit())
                    .focused($amountFocused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            } label: {
                Text("Amount (\(store.currency))")
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)
        }
        Section {
            TextField(income ? String(localized: "From") : String(localized: "Payee"), text: $payee)
            TextField("Description", text: $description)
        }
        Section {
            NavigationLink {
                FinanceCategoryPickerList(tree: store.tree, selection: $categoryId,
                                          fits: { FinanceCategoryTree.fits($0, income: income) })
            } label: {
                LabeledContent("Category") { FinanceCategoryLabel(category: store.category(categoryId)) }
            }
            if !store.accounts.isEmpty || accountId != nil {
                Picker("Account", selection: $accountId) {
                    Text("Without account").tag(String?.none)
                    ForEach(store.accounts) { Text($0.label).tag(Optional($0.id)) }
                }
            }
        }
        Section("Note") {
            TextField("Note", text: $note, axis: .vertical)
                .lineLimit(2...6)
                .labelsHidden()
        }
        if let existing { links(existing) }
        if let problem {
            Section { Text(problem).foregroundStyle(.red) }
        }
        if existing != nil {
            Section {
                Button("Delete transaction", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private var readOnly: some View {
        if let t = existing {
            Section {
                LabeledContent("Amount") { FinanceAmountText(store: store, transaction: t) }
                LabeledContent("Date", value: t.day?.formatted(.dateTime.day().month(.wide).year()) ?? t.date)
                if !t.payee.isEmpty { LabeledContent(t.amountCents > 0 ? String(localized: "From") : String(localized: "Payee"), value: t.payee) }
                if !t.description.isEmpty { LabeledContent("Description", value: t.description) }
            }
            Section {
                LabeledContent("Category") { FinanceCategoryLabel(category: store.category(t.categoryId)) }
                LabeledContent("Account", value: store.account(t.accountId)?.label ?? String(localized: "Without account"))
            }
            if !t.note.isEmpty { Section("Note") { Text(t.note) } }
            links(t)
        }
    }

    @ViewBuilder
    private func links(_ t: FinanceTransaction) -> some View {
        if let (icon, text) = FinanceLinkInfo(store.list?.transactions ?? [t]).detail(t, store: store) {
            Section {
                Label(text, systemImage: icon).foregroundStyle(.secondary)
                if t.imported { Label("Imported from a bank statement", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
            }
        } else if t.imported {
            Section { Label("Imported from a bank statement", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
        }
    }

    private func fill() {
        if let t = existing {
            income = t.amountCents > 0
            amount = FinanceMoney.input(t.amountCents)
            date = t.day?.date ?? Date()
            payee = t.payee
            description = t.description
            categoryId = t.categoryId
            accountId = t.accountId
            note = t.note
        } else {
            // A new one goes to the account the list shows, else the first one.
            let shown = store.filter.account
            accountId = !shown.isEmpty && shown != "none" ? shown : store.accounts.first?.id
            amountFocused = true
        }
    }

    private func save() async {
        guard let cents = FinanceMoney.parse(amount), cents != 0 else {
            problem = String(localized: "Enter an amount, e.g. \(FinanceMoney.input(1250))")
            return
        }
        let fields = FinanceOp.Fields(
            date: Day(date).description,
            amountCents: income ? abs(cents) : -abs(cents),
            payee: payee.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryId: categoryId,
            accountId: accountId,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        busy = true
        let op = existing.map { FinanceOp.update($0.id, fields) } ?? FinanceOp.add(fields)
        let ok = await store.change([op], message: existing == nil ? String(localized: "Transaction added") : String(localized: "Saved"))
        busy = false
        if ok != nil { dismiss() }
    }
}
