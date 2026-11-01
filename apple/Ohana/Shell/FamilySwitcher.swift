import SwiftUI

/// The sidebar's header: the family on screen; a click opens the family menu.
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
        // The label as it is, not a pop-up button (the Mac).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

/// Opens the family menu (a system menu everywhere): the families to switch to, creating or
/// joining one (in the demo: connecting a server), scanning a letter, and with `showsPages` the
/// pages the sidebar would show where there is none (`Module.phonePages`). The visible one shows
/// invite links the app was opened with (`InviteInbox`).
struct FamilyPickerButton<ButtonLabel: View>: View {
    @Environment(AppModel.self) private var app
    /// The family on screen (scanning a letter goes to its shell).
    @Environment(FamilyContext.self) private var family: FamilyContext?
    var showsPages = false
    @ViewBuilder let label: ButtonLabel
    @State private var creating = false
    @State private var joining: InviteRequest?

    var body: some View {
        Menu {
            FamilyMenu(showsPages: showsPages, scans: family != nil, choose: run)
        } label: {
            label
        }
        .menuIndicator(.hidden)
        .help("Switch family")
        .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
        // In the demo an invite waits for the server (the connect sheet shows it).
        .inviteJoinSheet($joining, claimsLinks: !app.isDemo)
    }

    private func run(_ action: FamilyPickerAction) {
        switch action {
        case let .family(id): app.selectedFamilyID = id
        case .create: creating = true
        case .join: joining = InviteRequest()
        case .connect: app.showsConnect = true
        case let .page(page): page.open()
        case .scanLetter: family?.scanLetter()
        }
    }
}

private enum FamilyPickerAction {
    case family(String), create, join, connect, page(Module), scanLetter
}

/// The family menu's items, a plain list: the families (the current one checked), creating or
/// joining one, then scanning a letter and the pages, each with its icon.
private struct FamilyMenu: View {
    @Environment(AppModel.self) private var app
    let showsPages: Bool
    /// Offers scanning a letter (inside a family's shell).
    let scans: Bool
    let choose: (FamilyPickerAction) -> Void

    var body: some View {
        ForEach(app.families) { family in
            Toggle(family.name, isOn: Binding(
                get: { family.id == app.selectedFamilyID },
                set: { _ in choose(.family(family.id)) }
            ))
        }
        Divider()
        if app.isDemo {
            Button("Connect your Ohana", systemImage: "server.rack") { choose(.connect) }
        } else {
            Button("New family", systemImage: "plus") { choose(.create) }
            Button("Join a family", systemImage: "person.badge.plus") { choose(.join) }
        }
        if scans || showsPages {
            Divider()
        }
        if scans {
            Button("Scan letter", systemImage: "doc.text.viewfinder") { choose(.scanLetter) }
        }
        if showsPages {
            ForEach(pages) { page in
                Button(page.title, systemImage: page.systemImage) { choose(.page(page)) }
            }
        }
    }

    /// The pages the sidebar would show (a narrow iPad window has no sidebar either).
    private var pages: [Module] {
        Module.phonePages.isEmpty ? [.settings] : Module.phonePages.filter { app.isEnabled($0) }
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
