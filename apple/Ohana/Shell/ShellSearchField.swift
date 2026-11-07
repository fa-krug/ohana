import SwiftUI

#if os(macOS)
/// The Mac's search across the modules: a field at the right end of every page's toolbar, the
/// assistant's button left of it, then the page's own items (`AssistantButton` adds both). Typing
/// shows the search page (`FamilySearchView`, which lists what `family.searchQuery` finds), Return
/// opens its first hit, Escape empties the field, ⌘K puts the keyboard in it.
///
/// Each page has its own field (a toolbar item on the tab view itself lands in the sidebar's part
/// of the window toolbar), so the search page's field takes over the keyboard when typing elsewhere
/// switched to it (`searchHandoff`).
struct ShellSearchField: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.controlActiveState) private var windowState
    /// The page on screen.
    let module: Binding<Module>
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    /// In the window's toolbar: the toolbar shows only the top page's items.
    @State private var onScreen = false

    private var hasQuery: Bool { !family.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var family = family
        ToolbarSearchFieldChrome(text: $family.searchQuery, width: 220) {
            family.searchQuery = ""
            focused = true
        } field: {
            TextField("Search", text: $family.searchQuery, selection: $selection, prompt: Text("Search"))
                .focused($focused)
                .onSubmit {
                    guard hasQuery else { return }
                    if module.wrappedValue == .search { family.submitSearch() } else { show() }
                }
        }
        .help("Search (⌘K)")
        .onChange(of: family.searchQuery) {
            if focused, hasQuery, module.wrappedValue != .search { show() }
        }
        .onChange(of: family.searchRequest) {
            if onScreen, windowState == .key { focused = true }
        }
        .onAppear {
            onScreen = true
            guard family.searchHandoff, module.wrappedValue == .search else { return }
            family.searchHandoff = false
            // Typing goes on where it was: the caret at the end, nothing selected.
            Task {
                focused = true
                selection = TextSelection(insertionPoint: family.searchQuery.endIndex)
            }
        }
        .onDisappear { onScreen = false }
    }

    /// The search page, its field taking the keyboard.
    private func show() {
        family.searchHandoff = focused
        module.wrappedValue = .search
    }
}

/// A page's own search field in the Mac's toolbar (`pageSearchable`).
private struct PageSearchField: View {
    @Binding var text: String
    let prompt: Text
    @FocusState private var focused: Bool

    var body: some View {
        ToolbarSearchFieldChrome(text: $text, width: 180) {
            text = ""
            focused = true
        } field: {
            TextField(text: $text, prompt: prompt) { prompt }
                .focused($focused)
        }
    }
}

/// A search field's look in the Mac's toolbar (whose item draws the glass around it): the
/// magnifying glass, the field, a clear button while there is text; Escape empties it.
private struct ToolbarSearchFieldChrome<Field: View>: View {
    @Binding var text: String
    let width: CGFloat
    let clear: () -> Void
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width)
    }
}
#endif

extension View {
    /// A page's own search field, which filters what the page shows. On the Mac a field among the
    /// page's toolbar items, left of the search across the modules (`ShellSearchField`) at the
    /// right end: the system's search field would go after them. None on iPhone: it would take a
    /// bottom toolbar under the assistant's floating button (the search page finds recipes).
    @ViewBuilder
    func pageSearchable(text: Binding<String>, prompt: Text) -> some View {
        #if os(macOS)
        toolbar {
            // Its own capsule, as the system's.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { PageSearchField(text: text, prompt: prompt) }
        }
        #else
        if Module.onPhone {
            self
        } else {
            searchable(text: text, prompt: prompt)
        }
        #endif
    }
}
