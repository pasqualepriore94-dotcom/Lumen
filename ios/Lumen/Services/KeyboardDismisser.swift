import UIKit

/// Chiude la tastiera toccando un punto qualsiasi dello schermo (anche dentro i fogli modali).
/// I tocchi passano comunque ai pulsanti sottostanti; quelli sui campi di testo vengono ignorati.
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private var installed = Set<ObjectIdentifier>()

    func install() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !installed.contains(ObjectIdentifier(window)) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tap.cancelsTouchesInView = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
                installed.insert(ObjectIdentifier(window))
            }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        gesture.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
