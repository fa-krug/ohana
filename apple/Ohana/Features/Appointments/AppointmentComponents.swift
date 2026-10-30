import SwiftUI

/// A run's status (or "queued") as a small chip (status-badge.tsx); the word says it, the color
/// only repeats it.
struct AppointmentStatusBadge: View {
    let status: String

    var body: some View {
        Text(AppointmentLogic.statusLabel(status))
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .chip(tint: color == .secondary ? nil : color)
            .accessibilityLabel(Text("Status: \(AppointmentLogic.statusLabel(status))"))
    }

    private var color: Color {
        switch status {
        case "OK": .ohana
        case "ERROR": .red
        case "RUNNING", "QUEUED": .blue
        default: .secondary
        }
    }
}

/// "paused" next to the status of a search that's off.
struct AppointmentPausedBadge: View {
    var body: some View {
        Text("paused")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .chip()
    }
}

/// One doctor's earliest slot (appointment-card.tsx): name, practice and reason, time, source,
/// the distance from home when known.
struct AppointmentDoctorRow: View {
    let doctor: AppointmentDoctorSlot
    var distance: String?
    var showDate = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TintedIcon(systemImage: "stethoscope", tint: ModuleTint.appointments, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(doctor.doctorName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                let description = [doctor.practiceName, doctor.motiveLabel].filter { !$0.isEmpty }.joined(separator: " · ")
                if !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // The time and its details in a line; stacked at accessibility text sizes.
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Text(slotText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ModuleTint.appointments)
                    if doctor.isNextSlot {
                        Text("(next available)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: "· \(doctor.sourceName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let distance {
                        Text(verbatim: "· \(distance)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var slotText: String {
        guard let date = doctor.date else { return doctor.slot }
        return showDate ? date.formatted(date: .abbreviated, time: .shortened) : date.formatted(date: .omitted, time: .shortened)
    }
}

/// A run's counts: "3 found · 2 matching · 5 appointments".
struct AppointmentRunCounts: View {
    let run: AppointmentRunSummary

    var body: some View {
        Text(AppointmentLogic.runCounts(found: run.doctorsFound, matched: run.doctorsMatched, slots: run.slotsFound))
    }
}

/// A run's error (or note) as the pages show it: red for errors, muted otherwise.
struct AppointmentRunMessage: View {
    let run: AppointmentRunSummary
    var lineLimit: Int?

    var body: some View {
        if !run.errorMessage.isEmpty {
            Text(run.errorMessage)
                .font(.caption)
                .foregroundStyle(run.status == "ERROR" ? Color.red : Color.secondary)
                .lineLimit(lineLimit)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((run.status == "ERROR" ? Color.red : Color.secondary).opacity(0.1), in: .rect(cornerRadius: 12))
                .textSelection(.enabled)
        }
    }
}

/// Reloads like the web's `useRunRefresh`: every 3 s while a run is queued or running, else every
/// 45 s, while the page is on screen and the app active; and right away when the app becomes
/// active again (runs the worker made meanwhile show up).
struct AppointmentPolling: ViewModifier {
    let busy: Bool
    let reload: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Hashable {
        let busy: Bool
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(busy: busy, active: scenePhase == .active)) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: AppointmentRefresh.interval(busy: busy))
                    if Task.isCancelled { return }
                    await reload()
                }
            }
            .onChange(of: scenePhase) { old, new in
                if new == .active, old != .active {
                    Task { await reload() }
                }
            }
    }
}

extension View {
    func appointmentPolling(busy: Bool, reload: @escaping () async -> Void) -> some View {
        modifier(AppointmentPolling(busy: busy, reload: reload))
    }
}
