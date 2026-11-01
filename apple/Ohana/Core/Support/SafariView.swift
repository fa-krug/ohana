#if os(iOS)
import SafariServices
import SwiftUI

/// A web page in an in-app Safari view (`SFSafariViewController`: Safari's autofill and
/// Reader, its own Done button). Present it with `.fullScreenCover`; Done dismisses it, so the
/// cover's `onDismiss` says the user is back.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.ohana)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.dismiss = dismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var dismiss: DismissAction

        init(dismiss: DismissAction) { self.dismiss = dismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { dismiss() }
    }
}
#endif
