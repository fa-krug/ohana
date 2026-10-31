import SwiftUI

/// Above every module while the app shows the demo: says so, and connects a server. A solid
/// strip across the page, not glass: the content scrolls under it and mustn't show through.
/// Can be hidden for good (`hidden`); the family picker still connects a server.
struct DemoBanner: View {
    @Environment(AppModel.self) private var app
    @Binding var hidden: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(Color.ohana)
                .accessibilityHidden(true)
            // One line where it fits, the explanation below the title where it doesn't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { title; detail }
                VStack(alignment: .leading, spacing: 1) { title; detail }
            }
            Spacer(minLength: 0)
            Button("Connect") { app.showsConnect = true }
                .buttonStyle(.borderedProminent)
                .tint(.ohana)
                #if os(macOS)
                .controlSize(.small)
                #endif
                .help("Connect your Ohana server")
            Button("Hide the demo notice", systemImage: "xmark") {
                withAnimation { hidden = true }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .rowHitTarget()
            .help("Hide the demo notice")
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Color.ohana.opacity(0.12)
                .background(Color.pageBackground)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: some View {
        Text("Demo data").fontWeight(.semibold)
    }

    private var detail: some View {
        Text("Connect your Ohana server to see your own family.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// The demo's banner above a module's page (`DemoBanner`), only in the demo.
    func demoBanner() -> some View {
        modifier(DemoBannerInset())
    }
}

private struct DemoBannerInset: ViewModifier {
    @Environment(AppModel.self) private var app
    @AppStorage("demoBannerHidden") private var hidden = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if app.isDemo, !hidden {
                DemoBanner(hidden: $hidden)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
