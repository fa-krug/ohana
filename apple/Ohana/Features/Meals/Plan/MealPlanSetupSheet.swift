import SwiftUI

/// The plan's settings (the web's "Generate meal plan" form): weeks per iteration, servings, the
/// share of known recipes, leftover days, 1–2 shopping days and tags to leave out. Saving plans
/// anew from today; replacing a plan asks first, since it can't be undone.
struct MealPlanSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input: MealPlanSetupInput
    private let original: MealPlanSetupInput
    let tags: [MealPlanTag]
    let replacesPlan: Bool
    var save: (MealPlanSetupInput) async throws -> Void
    @State private var saving = false
    @State private var confirmReplace = false

    init(initial: MealPlanSetupInput, tags: [MealPlanTag], replacesPlan: Bool,
         save: @escaping (MealPlanSetupInput) async throws -> Void) {
        _input = State(initialValue: initial)
        original = initial
        self.tags = tags
        self.replacesPlan = replacesPlan
        self.save = save
    }

    private var daysValid: Bool { MealPlanWeekday.validShoppingDays(input.shoppingDays) }
    private var hasChanges: Bool { input != original }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $input.iterationWeeks, in: 1...3) {
                        LabeledContent("Weeks per iteration", value: "\(input.iterationWeeks)")
                    }
                    Stepper(value: $input.servings, in: 1...12) {
                        LabeledContent("Servings", value: "\(input.servings)")
                    }
                    Stepper(value: $input.defaultLeftoverDays, in: 0...3) {
                        LabeledContent("Leftover days", value: "\(input.defaultLeftoverDays)")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Known-recipe ratio",
                                       value: input.knownRatio.formatted(.percent.precision(.fractionLength(0))))
                        Slider(value: $input.knownRatio, in: 0...1, step: 0.1)
                            .tint(ModuleTint.meals)
                            .accessibilityLabel("Known-recipe ratio")
                    }
                } footer: {
                    Text("The share of meals from your favourites; the rest are recipes you want to try.")
                }

                Section {
                    MealPlanFlowLayout(spacing: 8) {
                        ForEach(0..<7, id: \.self) { day in
                            MealsChipButton(title: MealPlanWeekday.shortNames[day], isOn: input.shoppingDays.contains(day),
                                            tint: ModuleTint.meals) {
                                toggle(day, in: &input.shoppingDays)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Shopping days")
                } footer: {
                    Text("Pick 1–2 shopping days, at least 3 days apart.")
                        .foregroundStyle(daysValid ? Color.secondary : Color.red)
                }

                if !tags.isEmpty {
                    Section {
                        MealPlanFlowLayout(spacing: 8) {
                            ForEach(tags) { tag in
                                MealsChipButton(title: tag.name, isOn: input.excludedTagIds.contains(tag.id), tint: .red) {
                                    toggle(tag.id, in: &input.excludedTagIds)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Exclude tags")
                    } footer: {
                        Text("Recipes with these tags aren’t planned.")
                    }
                }

                if replacesPlan {
                    Section {
                        Label("Saving plans anew from today: the current meals are replaced.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Generate meal plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate", systemImage: "sparkles", role: .confirm) {
                        if replacesPlan { confirmReplace = true } else { submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!daysValid || saving)
                }
            }
            .confirmationDialog("Replace the current plan?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace Plan", role: .destructive) { submit() }
            } message: {
                Text("The meals of every iteration are deleted and planned anew from today. This can’t be undone.")
            }
        }
        .errorBanner()
        .discardGuard(hasChanges: hasChanges || saving)
        .presentationDetents([.large])
    }

    private func toggle<T: Equatable>(_ value: T, in list: inout [T]) {
        if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
    }

    private func submit() {
        var input = input
        input.shoppingDays.sort()
        input.knownRatio = (input.knownRatio * 10).rounded() / 10
        saving = true
        perform {
            defer { saving = false }
            try await save(input)
            dismiss()
        }
    }
}

/// Lays chips out in rows, wrapping like text.
struct MealPlanFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
