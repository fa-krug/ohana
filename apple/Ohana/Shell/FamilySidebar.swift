#if os(iOS)
import SwiftUI

/// The family page on iPhone and where the tab view has no sidebar (a narrow iPad window), like
/// Mail's mailboxes: a page of its own behind the page on screen (the tabs on iPad). The back
/// button (iPhone) or the family button, or a swipe from the leading edge on a module's root,
/// slides the page away to show it, following the finger; picking a row or swiping back slides
/// it in again (`AppModel.showsFamilySidebar`).
struct FamilySidebarHost: ViewModifier {
    /// Where the tab view has no sidebar of its own.
    let active: Bool
    /// The page on screen.
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
        .onChange(of: app.showsFamilySidebar) {
            // A field of the page left (a kept page's search) gives up the keyboard.
            if app.showsFamilySidebar {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .onAppear {
            // Another family was picked: its page slides in.
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

/// The family page: the family on screen under the title, every page in the sidebar's order (not
/// the assistant: the Ask Ohana bar or the ✨ open it), the one on screen highlighted, scanning a
/// letter and the settings last (the families to switch to are there, `FamilyListSection`). It
/// also shows the invite links the app was opened with (`InviteInbox`).
private struct FamilySidebar: View {
    let current: Module
    @Binding var dragged: CGFloat?
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(FamilyContext.self) private var family
    @State private var joining: InviteRequest?

    var body: some View {
        NavigationStack {
            List {
                if !pages.isEmpty {
                    Section {
                        ForEach(pages) { page in
                            row(page.title, systemImage: page.systemImage, tint: page.tint) {
                                // The search ready to type.
                                if page == .search { family.startSearch() } else { page.open() }
                            }
                                .listRowBackground(page == current ? Color.ohana.opacity(0.15) : nil)
                                .accessibilityAddTraits(page == current ? .isSelected : [])
                        }
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
            .navigationSubtitleCompat(app.selectedFamily?.name ?? "")
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
        // In the demo an invite waits for the server (the connect sheet shows it).
        .inviteJoinSheet($joining, claimsLinks: !app.isDemo)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, tint: Color = .ohana,
                     action: @escaping () -> Void) -> some View {
        Button {
            // The page first, so the one sliding in is the new one.
            action()
            close()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
    }

    /// The pages the server has on, in the sidebar's order: the overview, the modules and the
    /// search (the settings have their own row below; the assistant has the bar or the ✨).
    private var pages: [Module] {
        ([.overview] + Module.modules + [.search]).filter { $0 != .assistant && app.isEnabled($0) }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) { app.showsFamilySidebar = false }
    }
}

#endif
