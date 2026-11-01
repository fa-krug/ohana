import SwiftUI

/// The sidebar's header: the family on screen; a click opens the family picker.
struct FamilySwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        FamilyPickerButton {
            // Stacked, so the family's name has the sidebar's whole width (narrow by default on
            // the Mac).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    FamilyBadge(name: app.selectedFamily?.name ?? "", id: app.selectedFamilyID ?? "", size: 30)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.selectedFamily?.name ?? "")
                        .font(.headline)
                        .lineLimit(2)
                    Text(app.me?.displayName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .contentShape(.rect(cornerRadius: 16))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

/// Opens the family picker: the families to switch to, and creating or joining one (in the
/// demo: connecting a server). `showsPages` adds the settings, where there is no sidebar to show
/// them (on iPhone also the appointments: `Module.phonePages`). The visible one shows invite links the app
/// was opened with (`InviteInbox`).
struct FamilyPickerButton<ButtonLabel: View>: View {
    @Environment(AppModel.self) private var app
    var showsPages = false
    @ViewBuilder let label: ButtonLabel
    @State private var showsPicker = false
    /// What the picker asked for, done once it has closed: a sheet can't open while it shows.
    @State private var pending: FamilyPickerAction?
    @State private var creating = false
    @State private var joining: InviteRequest?

    var body: some View {
        Button { showsPicker.toggle() } label: { label }
            .help("Switch family")
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                FamilyPicker(showsPages: showsPages) { action in
                    if case let .family(id) = action {
                        app.selectedFamilyID = id
                    } else {
                        pending = action
                    }
                    showsPicker = false
                }
                .onDisappear(perform: runPending)
            }
            .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
            // In the demo an invite waits for the server (the connect sheet shows it).
            .inviteJoinSheet($joining, claimsLinks: !app.isDemo)
    }

    private func runPending() {
        guard let action = pending else { return }
        pending = nil
        switch action {
        case .family: break
        case .create: creating = true
        case .join: joining = InviteRequest()
        case .connect: app.showsConnect = true
        case let .page(page): page.open()
        }
    }
}

private enum FamilyPickerAction {
    case family(String), create, join, connect, page(Module)
}

/// The picker's panel: a row per family (the current one checked), then what else it offers.
private struct FamilyPicker: View {
    @Environment(AppModel.self) private var app
    let showsPages: Bool
    let choose: (FamilyPickerAction) -> Void

    /// The pages the sidebar would show.
    private var pages: [Module] {
        Module.phonePages.isEmpty ? [.settings] : Module.phonePages.filter { app.isEnabled($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Families")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(app.families) { family in
                familyRow(family)
            }

            Divider().padding(.vertical, 4)
            if app.isDemo {
                actionRow("Connect your Ohana…", systemImage: "server.rack", .connect)
            } else {
                actionRow("New family…", systemImage: "plus", .create)
                actionRow("Join a family…", systemImage: "person.badge.plus", .join)
            }
            if showsPages {
                Divider().padding(.vertical, 4)
                ForEach(pages) { page in
                    actionRow(page.title, systemImage: page.systemImage, .page(page))
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private func familyRow(_ family: FamilySummary) -> some View {
        let selected = family.id == app.selectedFamilyID
        let subtitle: LocalizedStringKey = family.canEdit
            ? "\(family.memberCount) members"
            : "\(family.memberCount) members · View only"
        return PickerRow(selected: selected) { choose(.family(family.id)) } content: {
            FamilyBadge(name: family.name, id: family.id, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(family.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, _ action: FamilyPickerAction) -> some View {
        PickerRow { choose(action) } content: {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 32)
            Text(title)
            Spacer(minLength: 0)
        }
    }
}

/// A row of the picker: highlighted under the pointer and while pressed, tinted when selected.
private struct PickerRow<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { content }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(PickerRowStyle(hovering: hovering, selected: selected))
        .onHover { hovering = $0 }
    }
}

private struct PickerRowStyle: ButtonStyle {
    let hovering: Bool
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: .rect(cornerRadius: 10))
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
        if pressed { return AnyShapeStyle(.primary.opacity(0.12)) }
        if hovering { return AnyShapeStyle(.primary.opacity(0.07)) }
        if selected { return AnyShapeStyle(.tint.opacity(0.12)) }
        return AnyShapeStyle(.clear)
    }
}

/// A family's mark: its initial on a color of its own (the same on every device: from its id),
/// so families tell apart at a glance.
struct FamilyBadge: View {
    let name: String
    let id: String
    @ScaledMetric private var size: CGFloat

    init(name: String, id: String, size: CGFloat = 32) {
        self.name = name
        self.id = id
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private static let palette: [Color] = [.ohana, .blue, .orange, .pink, .purple, .green, .indigo, .teal]

    private var tint: Color {
        // Not `hashValue`: Swift seeds it anew at every launch.
        Self.palette[id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.palette.count]
    }

    var body: some View {
        Text(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "")
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}
