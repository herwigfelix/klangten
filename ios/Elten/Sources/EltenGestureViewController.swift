// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Full-app self-voicing surface. Unlike the demo, gestures are not handled
// locally: each recognised gesture is pushed onto EltenInputQueue and the
// embedded Ruby core (IOSTouchInput) decides what it means and voices the
// result through the host speech bridge. The keyboard-mode flag mirrors what
// Ruby's OnScreenKeyboard reports via the "keyboard" host callback.

import UIKit

final class EltenGestureViewController: UIViewController {
    private var keyboardActive = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.allowsDirectInteraction]
        view.accessibilityLabel = "Elten"
        installGestures()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func didBecomeActive() { EltenInputQueue.shared.pushActive(true) }
    @objc private func didEnterBackground() { EltenInputQueue.shared.pushActive(false) }

    // Keyboard mode is toggled by Ruby; the host is told via elten_host_keyboard
    // (see EltenHostBridge). Until that callback lands we flip locally on the
    // toggle gesture so explore-by-touch routing stays correct.
    func setKeyboardActive(_ active: Bool) { keyboardActive = active }

    private func installGestures() {
        addSwipe(.right, 1, "swipe_right"); addSwipe(.left, 1, "swipe_left")
        addSwipe(.up, 1, "swipe_up"); addSwipe(.down, 1, "swipe_down")
        addTap(2, 1, "double_tap")
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        view.addGestureRecognizer(lp)
        addTap(1, 2, "two_finger_tap"); addTap(2, 2, "two_finger_double_tap")
        addSwipe(.left, 2, "two_finger_swipe_left"); addSwipe(.down, 2, "two_finger_swipe_down")
        addSwipe(.up, 2, "two_finger_swipe_up")
        addSwipe(.right, 3, "three_finger_swipe_right"); addSwipe(.left, 3, "three_finger_swipe_left")
        addSwipe(.up, 3, "three_finger_swipe_up"); addSwipe(.down, 3, "three_finger_swipe_down")
        addTap(2, 3, "three_finger_double_tap")
    }

    private func addSwipe(_ dir: UISwipeGestureRecognizer.Direction, _ fingers: Int, _ name: String) {
        let g = UISwipeGestureRecognizer(target: self, action: #selector(onSwipe(_:)))
        g.direction = dir; g.numberOfTouchesRequired = fingers
        g.name = name
        view.addGestureRecognizer(g)
    }

    private func addTap(_ taps: Int, _ fingers: Int, _ name: String) {
        let g = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        g.numberOfTapsRequired = taps; g.numberOfTouchesRequired = fingers
        g.name = name
        view.addGestureRecognizer(g)
    }

    @objc private func onSwipe(_ g: UISwipeGestureRecognizer) { if let n = g.name { EltenInputQueue.shared.pushGesture(n) } }
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let n = g.name else { return }
        if n == "three_finger_double_tap" { keyboardActive.toggle() }
        EltenInputQueue.shared.pushGesture(n)
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { EltenInputQueue.shared.pushGesture("long_press") }
    }

    // While the keyboard is open, one-finger touches drive explore-by-touch.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard keyboardActive, let t = touches.first else { return }
        let p = t.location(in: view)
        EltenInputQueue.shared.pushKeyboardPoint(p.x / max(view.bounds.width, 1), p.y / max(view.bounds.height, 1))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if keyboardActive { EltenInputQueue.shared.pushKeyboardCommit() }
    }
}
