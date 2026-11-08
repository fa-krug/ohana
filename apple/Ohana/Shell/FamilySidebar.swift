#if os(iOS)
import SwiftUI

/// iPhone: the family page and the page on screen as a split view collapsed into one navigation
/// stack, like Mail's mailboxes: the family page is the stack's root, the page pushed over it.
/// The system's back button ("Ohana") and swipe go back to the family page; picking a row (or a
/// swipe to the left there) pushes the page again (`AppModel.showsFamilySidebar`).
///
/// The page stays the same view while the family page shows, so going back and returning keeps it
/// as it was (scrolled, pushed); only another page replaces it. It opens on the page last shown,
/// also after a launch (the shell's `phoneModule`).
struct PhoneShell<Page: View>: View {
    /// The page on screen.
    let current: Module
    let open: (Module) -> Void
    @ViewBuilder let page: (Module) -> Page
    @Environment(AppModel.self) private var app
    @State private var joining: InviteRequest?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: Binding {
            app.showsFamilySidebar ? .sidebar : .detail
        } set: {
            app.showsFamilySidebar = $0 == .sidebar
        }) {
            FamilySidebar(current: current, open: open)
        } detail: {
            page(current)
                .id(current)
                // Polling pages wait while the family page covers them.
                .environment(\.shellPageVisible, !app.showsFamilySidebar)
        }
        // Here, not on the family page: under a pushed page it can't present the sheet. In the
        // demo an invite waits for the server (the connect sheet shows it).
        .inviteJoinSheet($joining, claimsLinks: !app.isDemo)
    }
}

/// The family page: the family on screen under the title, every page in the sidebar's order (not
/// the assistant: its floating button opens it), the one on screen highlighted, scanning a
/// letter and the settings last (the families to switch to are there, `FamilyListSection`).
private struct FamilySidebar: View {
    let current: Module
    let open: (Module) -> Void
    @Environment(AppModel.self) private var app
    @Environment(FamilyContext.self) private var family

    var body: some View {
        List {
            if !pages.isEmpty {
                Section {
                    ForEach(pages) { page in
                        row(page.title, systemImage: page.systemImage, tint: page.tint) {
                            // The search ready to type.
                            if page == .search { family.startSearch() } else { open(page) }
                        }
                            .listRowBackground(page == current ? Color.ohana.opacity(0.15) : nil)
                            .accessibilityAddTraits(page == current ? .isSelected : [])
                    }
                }
            }
            Section {
                row("Scan letter", systemImage: "doc.text.viewfinder") {
                    family.scanLetter()
                    app.showsFamilySidebar = false
                }
                row(Module.settings.title, systemImage: Module.settings.systemImage) { open(.settings) }
                    .listRowBackground(current == .settings ? Color.ohana.opacity(0.15) : nil)
                    .accessibilityAddTraits(current == .settings ? .isSelected : [])
            }
        }
        // Rows read as text, not as links: only their icons and the check take the app's color.
        .tint(.primary)
        .navigationTitle(Text(verbatim: "Ohana"))
        .navigationSubtitleCompat(app.selectedFamily?.name ?? "")
        // Forward to the page with a swipe to the left, as the slide-over family page had it;
        // vertical drags stay the list's.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let width = value.predictedEndTranslation.width
                    guard width < -120, abs(value.translation.width) > abs(value.translation.height) * 2
                    else { return }
                    app.showsFamilySidebar = false
                }
        )
        .accessibilityAction(.escape) { app.showsFamilySidebar = false }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, tint: Color = .ohana,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
    }

    /// The pages the server has on, in the sidebar's order: the overview, the modules and the
    /// search (the settings have their own row below; the assistant has its floating button).
    private var pages: [Module] {
        ([.overview] + Module.modules + [.search]).filter { $0 != .assistant && app.isEnabled($0) }
    }
}

#endif
