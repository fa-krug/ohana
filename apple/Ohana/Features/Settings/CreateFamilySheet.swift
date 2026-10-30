import SwiftUI

/// Creating a family (the web's families/new): a name; the server adds the calendar's preset
/// types, the finance categories and the meal tags in the account's language. The new family is
/// then the one on screen.
struct CreateFamilySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        TintedIcon(systemImage: "house.fill", tint: .ohana, size: 44)
                        Text("A family keeps your calendar, finances, meals and appointments together. You can invite the others afterwards.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Family name", text: $name, prompt: Text("e.g. The Krugs"))
                        .focused($focused)
                        .onSubmit(create)
                        .submitLabel(.done)
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New family")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create", action: create)
                            .buttonStyle(.glassProminent)
                            .disabled(trimmed.isEmpty || trimmed.count > 100)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .onAppear { focused = true }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

    private func create() {
        guard !trimmed.isEmpty, !busy, let client = app.client else { return }
        busy = true
        error = nil
        let body = FamilyNameInput(name: trimmed)
        Task {
            do {
                let family: FamilySummary = try await client.send(.post, "/api/v1/families", body: body)
                await app.refresh()
                app.selectedFamilyID = family.id
                if let created = app.selectedFamily { app.context(for: created)?.open(.module(.overview)) }
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
