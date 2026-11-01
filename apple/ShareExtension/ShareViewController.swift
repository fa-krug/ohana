import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
/// The share extension's principal class (Info.plist `NSExtensionPrincipalClass`): hosts
/// `ShareView` and starts saving the shared page right away.
@objc(OhanaShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        model.finish = { [weak self] done in self?.finish(done) }
        model.start(extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
    }

    private func finish(_ done: Bool) {
        if done {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
#else
/// The share extension's principal class (Info.plist `NSExtensionPrincipalClass`): hosts
/// `ShareView` and starts saving the shared page right away.
@objc(OhanaShareViewController)
final class ShareViewController: NSViewController {
    private let model = ShareModel()

    override func loadView() {
        let host = NSHostingView(rootView: ShareView(model: model))
        host.frame.size = host.fittingSize
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] done in self?.finish(done) }
        model.start(extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
    }

    private func finish(_ done: Bool) {
        if done {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}
#endif
