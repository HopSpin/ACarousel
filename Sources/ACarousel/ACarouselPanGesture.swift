/**
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

import SwiftUI
import UIKit

/// The strip's drag gesture (HopSpin ledger item 46, G-1 (a)): a
/// `UIPanGestureRecognizer` brought into SwiftUI through
/// `UIGestureRecognizerRepresentable`, so that UIKit's own arbitration
/// decides between the strip and the vertical scroll view behind it. The
/// coordinator is the recognizer's delegate: the pan begins only when the
/// first movement is horizontal-dominant (G-3 (a)) and the carousel can move
/// (G-4 (a)); otherwise it fails on its first move and the enclosing scroll
/// view takes the touch from the first point. The scroll view's own pan is
/// asked to wait for that decision (`shouldBeRequiredToFailBy`), so the
/// outcome never depends on which recognizer reaches `.began` first.
///
/// A stationary touch never begins a pan, so a slide's tap gesture sees a
/// tap as before; a pan that begins cancels the touch in the view, so a
/// drag is never also a tap.
///
/// The recognizer reports in the coordinate space of the view it is attached
/// to; the strip is only ever offset, never rotated or scaled, so the
/// horizontal component is the same in any space.
struct ACarouselPanGesture: UIGestureRecognizerRepresentable {

    /// `false` for a carousel of one slide: the pan never begins and the
    /// page scrolls in every direction over the card (G-4 (a)).
    let canMove: Bool
    /// `.began` and every `.changed`: the translation so far.
    let onChanged: (CGSize) -> Void
    /// `.ended`: the translation and the velocity at lift; `.cancelled`: the
    /// translation and a zero velocity.
    let onEnded: (CGSize, CGSize) -> Void

    /// Built by `ACarouselViewModel.dragGesture`, which is not main-actor
    /// isolated: an explicit nonisolated initializer that only assigns the
    /// stored properties, where the synthesized one would inherit the
    /// protocol's isolation.
    nonisolated init(canMove: Bool, onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize, CGSize) -> Void) {
        self.canMove = canMove
        self.onChanged = onChanged
        self.onEnded = onEnded
    }

    /// The gate as a pure function, for the pins: true only for a
    /// horizontal-dominant first movement of a carousel that can move. A tie
    /// goes to the page (G-3 (a)); one slide never begins (G-4 (a)).
    nonisolated static func shouldBegin(translation: CGSize, canMove: Bool) -> Bool {
        guard canMove else { return false }
        return abs(translation.width) > abs(translation.height)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(canMove: canMove)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.canMove = canMove
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view))
        case .cancelled:
            onEnded(translation, .zero)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {

        var canMove: Bool

        init(canMove: Bool) {
            self.canMove = canMove
        }

        /// Asked once the touch has moved past the recognizer's own
        /// hysteresis: the translation is the first movement itself.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return ACarouselPanGesture.shouldBegin(translation: pan.translation(in: pan.view), canMove: canMove)
        }

        /// The enclosing scroll view's pan waits for this recognizer to begin
        /// or fail: UIKit's nested-scroll contract, made explicit.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
    }
}
