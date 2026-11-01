#if os(iOS)
import SwiftUI

/// The family page where the tab view has no sidebar (iPhone, a narrow iPad window), like Mail's
/// mailboxes: a page of its own behind the tabs. The family button, or a swipe from the leading
/// edge on a module's root, slides the tabs away to show it, following the finger; picking a row
/// or swiping back slides them in again (`AppModel.showsFamilySidebar`).
struct FamilySidebarHost: ViewModifier {
    /// Where the tab view has no sidebar of its own.
    let active: Bool
    /// The tab on screen.
    let current: Module
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 400
    /// How far a swipe has moved, while one does.
    @State private var dragged: CGFloat?

    /// 0: the tabs on screen, 1: the family page.
    private var progress: CGFloat {
        let open: CGFloat = app.showsFamilySidebar ? 1 : 0
        guard let dragged else { return open }
        return min(1, max(0, open + dragged / width))
    }

    func body(content: Content) -> some View {
        let open = app.showsFamilySidebar
        ZStack {
            if active {
                FamilySidebar(current: current, dragged: $dragged, width: width)
                    // Behind the tabs, a little to the side and darker, as a page under a pushed one.
                    .offset(x: (progress - 1) * width * 0.3)
                    .overlay {
                        Color.black.opacity(0.2 * (1 - progress)).allowsHitTesting(false).ignoresSafeArea()
                    }
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
            }
            content
                .offset(x: active ? progress * width : 0)
                .allowsHitTesting(!open)
                .accessibilityHidden(active && open)
                .gesture(LeadingEdgeSwipe(isEnabled: active && !open && app.moduleRootsOnScreen > 0) { x in
                    dragged = x
                } ended: { x, velocity in
                    finish(opening: x + velocity * 0.2 > width / 3)
                })
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .onAppear {
            // Another family was picked: its tabs slide in.
            guard app.showsFamilySidebar else { return }
            withAnimation(.snappy(duration: 0.35).delay(0.05)) { app.showsFamilySidebar = false }
        }
    }

    private func finish(opening: Bool) {
        withAnimation(.snappy(duration: 0.3)) {
            dragged = nil
            app.showsFamilySidebar = opening
        }
    }
}

/// A swipe from the screen's leading edge (UIKit's, so it waits where a navigation stack can go
/// back instead: the host only turns it on while a module's root is on screen).
private struct LeadingEdgeSwipe: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let recognizer = UIScreenEdgePanGestureRecognizer()
        recognizer.edges = .left
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIScreenEdgePanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(x)
        case .ended: ended(x, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }
}

/// The family page: the families to switch to with creating or joining one below them (in the
/// demo: connecting a server), every page of the shell (the tab on screen highlighted; on iPhone
/// the appointments, the chores and the settings aren't tabs, `Module.phonePages`), scanning a letter and
/// the settings last. It also shows the invite links the app was opened with (`InviteInbox`).
private struct FamilySidebar: View {
    let current: Module
    @Binding var dragged: CGFloat?
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(FamilyContext.self) private var family
    @State private var creating = false
    @State private var joining: InviteRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.families) { item in
                        Button { choose(item.id) } label: {
                            FamilyRow(family: item, selected: item.id == app.selectedFamilyID)
                        }
                    }
                    if app.isDemo {
                        row("Connect your Ohana", systemImage: "server.rack") { app.showsConnect = true }
                    } else {
                        row("New family", systemImage: "plus") { creating = true }
                        row("Join a family", systemImage: "person.badge.plus") { joining = InviteRequest() }
                    }
                } footer: {
                    if let me = app.me {
                        Text("Signed in as \(me.displayName)")
                    }
                }
                Section {
                    ForEach(pages) { page in
                        row(page.title, systemImage: page.systemImage, tint: page.tint) { page.open() }
                            .listRowBackground(page == current ? Color.ohana.opacity(0.15) : nil)
                            .accessibilityAddTraits(page == current ? .isSelected : [])
                    }
                }
                Section {
                    row("Scan letter", systemImage: "doc.text.viewfinder") { family.scanLetter() }
                    row(Module.settings.title, systemImage: Module.settings.systemImage) { Module.settings.open() }
                        .listRowBackground(current == .settings ? Color.ohana.opacity(0.15) : nil)
                }
            }
            // Rows read as text, not as links: only their icons and the check take the app's color.
            .tint(.primary)
            .navigationTitle(Text(verbatim: "Ohana"))
        }
        // Swiping back to the tabs; vertical drags stay the list's.
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard value.translation.width < 0,
                          abs(value.translation.width) > abs(value.translation.height) || dragged != nil
                    else { return }
                    dragged = value.translation.width
                }
                .onEnded { value in
                    guard dragged != nil else { return }
                    let back = value.predictedEndTranslation.width < -width / 3
                    withAnimation(.snappy(duration: 0.3)) {
                        dragged = nil
                        if back { app.showsFamilySidebar = false }
                    }
                }
        )
        .accessibilityAction(.escape) { close() }
        .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
        // In the demo an invite waits for the server (the connect sheet shows it).
        .inviteJoinSheet($joining, claimsLinks: !app.isDemo)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, tint: Color = .ohana,
                     action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
    }

    /// The overview, the modules the server has on and the search, in the sidebar's order.
    private var pages: [Module] {
        ([.overview] + Module.modules + [.search]).filter { app.isEnabled($0) }
    }

    private func choose(_ id: String) {
        guard id != app.selectedFamilyID else { return close() }
        // The shell is built anew for that family; its host slides the tabs in.
        app.selectedFamilyID = id
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) { app.showsFamilySidebar = false }
    }
}

/// A family on the page: its badge, name and members, checked when it is on screen.
private struct FamilyRow: View {
    let family: FamilySummary
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            FamilyBadge(name: family.name, id: family.id, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(family.name)
                Text(family.canEdit
                    ? "\(family.memberCount) members"
                    : "\(family.memberCount) members · View only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ohana)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
