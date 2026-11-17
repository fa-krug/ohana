import CoreGraphics
import SwiftUI

/// Pages of a booklet to read for a member.
struct HealthScanReview: Identifiable {
    let id = UUID()
    let member: HealthMember
    let images: [CGImage]
    let needsCrop: Bool
}

/// Reads a booklet's pages with the family's AI (only the pictures go to the server, which asks
/// the family's AI), then lists what it found to tick: those already recorded unticked. Save
/// records the ticked ones.
struct HealthScanSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let review: HealthScanReview
    @State private var phase: Phase = .reading
    @State private var ticked: Set<String> = []
    @State private var saving = false

    enum Phase {
        case reading
        case found([HealthScanSuggestion])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Reading the booklet…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Couldn’t read the booklet", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await read() } }
                            .buttonStyle(.glassProminent)
                    }
                case let .found(items) where items.isEmpty:
                    ContentUnavailableView("Nothing found",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("No check-ups or vaccinations found on these pages."))
                case let .found(items):
                    list(items)
                }
            }
            .navigationTitle(Text(verbatim: review.member.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: !ticked.isEmpty)
                }
                if case .found = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(ticked.isEmpty || saving)
                    }
                }
            }
        }
        .task { await read() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func list(_ items: [HealthScanSuggestion]) -> some View {
        Form {
            Section {
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { ticked.contains(item.id) },
                                         set: { if $0 { ticked.insert(item.id) } else { ticked.remove(item.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.day.map { HealthText.date($0) } ?? String(localized: "Date not readable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if item.known {
                                Text("Already recorded").font(.caption).foregroundStyle(.secondary)
                            } else if !item.note.isEmpty {
                                Text(item.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Read by the family’s AI. Check each one against the booklet before you save.")
            }
        }
        .formStyle(.grouped)
    }

    private func read() async {
        phase = .reading
        do {
            let pages = await HealthScanPages.encode(review.images, crop: review.needsCrop)
            guard !pages.isEmpty else { throw LetterScanError.unreadable }
            let answer = try await store.scan(family, member: review.member.id, pages: pages)
            guard answer.readable else {
                phase = .failed(String(localized: "Set up the assistant’s AI in the settings to read booklets."))
                return
            }
            ticked = Set(answer.items.filter { !$0.known }.map(\.id))
            phase = .found(answer.items)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() {
        guard case let .found(items) = phase else { return }
        saving = true
        let records = items.filter { ticked.contains($0.id) }
            .map { HealthRecordInput(code: $0.code, day: $0.day, note: $0.note) }
        perform {
            defer { saving = false }
            try await store.record(family, member: review.member.id, records)
            dismiss()
        }
    }
}
