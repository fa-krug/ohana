import SwiftUI
#if os(iOS)
import VisionKit

/// VisionKit's document camera: finds the paper's edges (a receipt, a letter), straightens it and
/// takes one or more pages. Hands over at most `maxPages` pages, or none when cancelled.
struct DocumentCamera: UIViewControllerRepresentable {
    var maxPages = 5
    var done: ([CGImage]) -> Void

    /// Not in the Simulator or on devices without a camera: the file picker then.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(maxPages: maxPages, done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let maxPages: Int
        let done: ([CGImage]) -> Void

        init(maxPages: Int, done: @escaping ([CGImage]) -> Void) {
            self.maxPages = maxPages
            self.done = done
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<min(scan.pageCount, maxPages)).compactMap { scan.imageOfPage(at: $0).cgImage })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            ErrorBanner.shared.show(error)
            done([])
        }
    }
}
#endif
