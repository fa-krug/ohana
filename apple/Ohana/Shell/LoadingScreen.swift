import SwiftUI

/// Covers the whole app while it loads an account: at launch, after a server was connected
/// (until its data is there, so the demo's never shows as the server's) and after it was removed
/// (until the demo is back). `RootView` shows it in place of the shell, which closes any sheet.
struct LoadingScreen: View {
    var switching: AppModel.Switch?
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 88
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 24) {
            OhanaLogo(size: logoSize)
                .scaleEffect(pulsing ? 1.04 : 0.96)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 420)
            ProgressView()
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { OhanaBackground() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { pulsing = true }
    }

    private var title: String {
        switch switching {
        case let .server(host): String(localized: "Syncing with \(host)…")
        case .demo: String(localized: "Loading the demo…")
        case nil: String(localized: "Loading your families…")
        }
    }

    private var detail: String? {
        switch switching {
        case .server: String(localized: "Your families and their data are on the way.")
        case .demo: String(localized: "This device is no longer connected to a server. Until you connect one, Ohana shows a demo family.")
        case nil: nil
        }
    }
}

#Preview("Server") { LoadingScreen(switching: .server(host: "ohana.example.com")) }
#Preview("Demo") { LoadingScreen(switching: .demo) }
