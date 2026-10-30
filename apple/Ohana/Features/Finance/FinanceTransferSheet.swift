import SwiftUI

/// Finds bookings of the period that look like money moved between two of the family's
/// accounts, and combines the ticked pairs into transfers in one undoable step
/// (transfer-dialog.tsx).
struct FinanceTransferSheet: View {
    @Bindable var store: FinanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: LoadState<[FinanceTransferPair]> = .idle
    @State private var checked: Set<String> = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            LoadStateView(state: pairs, retry: load) { pairs in
                List {
                    Section {
                        Text("The same amount leaves one of your accounts and arrives on another within a few days. Combined, both count nothing: the money stayed in the family.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if pairs.isEmpty {
                        ContentUnavailableView("No likely transfers", systemImage: "arrow.left.arrow.right",
                                               description: Text("A transfer is the same amount leaving one account and arriving on another, at most 4 days apart."))
                    } else {
                        Section {
                            ForEach(pairs) { pair in row(pair) }
                        }
                    }
                }
            }
            .navigationTitle("Find transfers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Ticks are suggestions, not work to keep: Cancel closes without asking.
                ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: false) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Combine \(checked.count)") {
                        Task {
                            busy = true
                            let chosen = (pairs.value ?? []).filter { checked.contains($0.id) }
                            if await store.linkPairs(chosen) { dismiss() }
                            busy = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || checked.isEmpty)
                }
            }
            .task { await load() }
        }
        .errorBanner()
        .presentationDetents([.medium, .large])
        .financeSheetFrame(minWidth: 460, minHeight: 420)
    }

    private func load() async {
        await LoadState.run($pairs) {
            let found = try await store.suggestions()
            checked = Set(found.map(\.id))
            return found
        }
    }

    private func row(_ pair: FinanceTransferPair) -> some View {
        let on = checked.contains(pair.id)
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated)
        func day(_ t: FinanceTransaction) -> String { t.day?.date.formatted(format) ?? t.date }
        func account(_ t: FinanceTransaction) -> String { store.account(t.accountId)?.name ?? String(localized: "Without account") }
        let title = [pair.out.payee, pair.out.description, pair.incoming.payee, pair.incoming.description].first { !$0.isEmpty } ?? "—"
        return Button {
            if on { checked.remove(pair.id) } else { checked.insert(pair.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? ModuleTint.finance : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(verbatim: "\(pair.out.date == pair.incoming.date ? day(pair.out) : "\(day(pair.out)) – \(day(pair.incoming))") · \(account(pair.out)) → \(account(pair.incoming))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(store.money(pair.incoming.amountCents))
                    .font(.body.weight(.semibold).monospacedDigit())
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
