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

/// The editor's fields as typed: compared with how they started to tell unsaved changes.
struct FinanceTransactionDraft: Equatable {
    var income = false
    var amount = ""
    var date = Date()
    var payee = ""
    var description = ""
    var categoryId: String?
    var accountId: String?
    var note = ""

    init() {}

    init(_ t: FinanceTransaction) {
        income = t.amountCents > 0
        amount = FinanceMoney.input(t.amountCents)
        date = t.day?.date ?? Date()
        payee = t.payee
        description = t.description
        categoryId = t.categoryId
        accountId = t.accountId
        note = t.note
    }

    /// The amount in cents, signed by the kind; nil unless it is a number other than 0.
    var cents: Int? {
        guard let cents = FinanceMoney.parse(amount), cents != 0 else { return nil }
        return income ? abs(cents) : -abs(cents)
    }

    /// Typed, but not an amount (an empty field just keeps Save off).
    var amountInvalid: Bool {
        !amount.trimmingCharacters(in: .whitespaces).isEmpty && cents == nil
    }

    var fields: FinanceOp.Fields? {
        guard let cents else { return nil }
        return FinanceOp.Fields(
            date: Day(date).description,
            amountCents: cents,
            payee: payee.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryId: categoryId,
            accountId: accountId,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The same day counts as the same date (the picker keeps the time of day it was given).
    static func == (a: Self, b: Self) -> Bool {
        a.income == b.income && a.amount == b.amount && Day(a.date) == Day(b.date) && a.payee == b.payee
            && a.description == b.description && a.categoryId == b.categoryId && a.accountId == b.accountId
            && a.note == b.note
    }
}

/// Adds a transaction, or edits one (transaction-dialog.tsx); viewers see it read-only.
struct FinanceTransactionEditor: View {
    @Bindable var store: FinanceStore
    let target: FinanceEditTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(FamilyContext.self) private var family

    @State private var draft = FinanceTransactionDraft()
    @State private var original = FinanceTransactionDraft()
    @State private var filled = false
    @State private var busy = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    private var existing: FinanceTransaction? {
        if case let .existing(t) = target { t } else { nil }
    }

    private var hasChanges: Bool { store.canEdit && draft != original }

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
        .errorBanner()
        .discardGuard(hasChanges: hasChanges)
        .presentationDetents([.large])
        .financeSheetFrame(minWidth: 420, minHeight: 520)
        .onAppear(perform: fill)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.canEdit {
            ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasChanges) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.fields == nil)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var editForm: some View {
        Section {
            Picker("Kind", selection: $draft.income) {
                Text("Expense").tag(false)
                Text("Income").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draft.income) {
                // A category of the other kind doesn't fit any more.
                if let c = store.category(draft.categoryId), !FinanceCategoryTree.fits(c, income: draft.income) { draft.categoryId = nil }
            }
            LabeledContent {
                TextField("Amount", text: $draft.amount, prompt: Text(FinanceMoney.placeholder))
                    .multilineTextAlignment(.trailing)
                    .font(.title3.monospacedDigit())
                    .focused($amountFocused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            } label: {
                Text("Amount (\(store.currency))")
            }
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        } footer: {
            if draft.amountInvalid {
                Text("Enter an amount, e.g. \(FinanceMoney.input(1250))").foregroundStyle(.red)
            }
        }
        Section {
            TextField(draft.income ? String(localized: "From") : String(localized: "Payee"), text: $draft.payee)
            TextField("Description", text: $draft.description)
        }
        Section {
            NavigationLink {
                FinanceCategoryPickerList(tree: store.tree, selection: $draft.categoryId,
                                          fits: { FinanceCategoryTree.fits($0, income: draft.income) })
            } label: {
                LabeledContent("Category") { FinanceCategoryLabel(category: store.category(draft.categoryId)) }
            }
            if !store.accounts.isEmpty || draft.accountId != nil {
                Picker("Account", selection: $draft.accountId) {
                    Text("Without account").tag(String?.none)
                    ForEach(store.accounts) { Text($0.label).tag(Optional($0.id)) }
                }
            }
        }
        Section("Note") {
            TextField("Note", text: $draft.note, axis: .vertical)
                .lineLimit(2...6)
                .labelsHidden()
        }
        if let existing { links(existing) }
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
        // A groceries transaction near a shopping day links to that day's list.
        if let trip = store.shoppingLinks.list(for: t.date, categoryId: t.categoryId) {
            Section {
                Button("Shopping list of this day", systemImage: "cart") {
                    dismiss()
                    family.open(.shoppingList(id: trip.id))
                }
            }
        }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        if let t = existing {
            draft = FinanceTransactionDraft(t)
        } else {
            // A new one goes to the account the list shows, else the first one.
            let shown = store.filter.account
            draft.accountId = !shown.isEmpty && shown != "none" ? shown : store.accounts.first?.id
            amountFocused = true
        }
        original = draft
    }

    private func save() async {
        guard let fields = draft.fields else { return }
        busy = true
        let op = existing.map { FinanceOp.update($0.id, fields) } ?? FinanceOp.add(fields)
        let ok = await store.change([op], message: existing == nil ? String(localized: "Transaction added") : String(localized: "Saved"))
        busy = false
        if ok != nil { dismiss() }
    }
}
