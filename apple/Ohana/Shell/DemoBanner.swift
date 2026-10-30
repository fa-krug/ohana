import SwiftUI

/// Above every module while the app shows the demo: says so, and connects a server.
struct DemoBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title3)
                .foregroundStyle(Color.ohana)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo data")
                    .font(.subheadline.bold())
                Text("Connect your Ohana server to see your own family.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Connect") { app.showsConnect = true }
                .buttonStyle(.glassProminent)
                .help("Connect your Ohana server")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
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

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if app.isDemo { DemoBanner() }
        }
    }
}
