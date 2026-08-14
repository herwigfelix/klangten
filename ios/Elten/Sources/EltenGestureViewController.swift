// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Full-app self-voicing surface. Unlike the demo, gestures are not handled
// locally: each recognised gesture is pushed onto EltenInputQueue and the
// embedded Ruby core (IOSTouchInput) decides what it means and voices the
// result through the host speech bridge.
//
// Text entry uses the native iOS on-screen keyboard: Ruby asks the host to
// show it (elten_host_system_keyboard_show), a hidden text field becomes first
// responder, and pressing Return dismisses the keyboard and hands the typed
// text back to Ruby as a "ktext:" input token.

import UIKit

final class EltenGestureViewController: UIViewController, UITextFieldDelegate {
    // The host bridge C entry points resolve the controller through this.
    private(set) static weak var current: EltenGestureViewController?

    private var keyboardActive = false
    private let textEntryField = UITextField(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        EltenGestureViewController.current = self
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.allowsDirectInteraction]
        view.accessibilityLabel = "Elten"
        installGestures()
        installTextEntryField()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func didBecomeActive() { EltenInputQueue.shared.pushActive(true) }
    @objc private func didEnterBackground() { EltenInputQueue.shared.pushActive(false) }

    // Legacy Elten key-grid keyboard mode (fallback hosts only); toggled by
    // Ruby via the "keyboard" host callback.
    func setKeyboardActive(_ active: Bool) { keyboardActive = active }

    // MARK: - native system keyboard

    var systemKeyboardVisible: Bool { textEntryField.isFirstResponder }

    func showSystemKeyboard() {
        textEntryField.text = ""
        textEntryField.becomeFirstResponder()
    }

    func hideSystemKeyboard() {
        textEntryField.resignFirstResponder()
    }

    private func installTextEntryField() {
        // Zero-sized but in the hierarchy, so it can become first responder and
        // raise the system keyboard without showing any UI of its own.
        textEntryField.delegate = self
        textEntryField.autocorrectionType = .default
        textEntryField.returnKeyType = .done
        textEntryField.isAccessibilityElement = false
        view.addSubview(textEntryField)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Return closes the keyboard and hands the collected text to Ruby.
        let text = textField.text ?? ""
        textField.text = ""
        textField.resignFirstResponder()
        if !text.isEmpty { EltenInputQueue.shared.pushKeyboardText(text) }
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        EltenSystemKeyboardState.shared.set(true)
        EltenInputQueue.shared.pushSystemKeyboardState(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        EltenSystemKeyboardState.shared.set(false)
        EltenInputQueue.shared.pushSystemKeyboardState(false)
    }

    // MARK: - gestures

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
        EltenInputQueue.shared.pushGesture(n)
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { EltenInputQueue.shared.pushGesture("long_press") }
    }

    // While the legacy key-grid keyboard is open, one-finger touches drive
    // explore-by-touch. Inactive when the native system keyboard is used.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard keyboardActive, let t = touches.first else { return }
        let p = t.location(in: view)
        EltenInputQueue.shared.pushKeyboardPoint(p.x / max(view.bounds.width, 1), p.y / max(view.bounds.height, 1))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if keyboardActive { EltenInputQueue.shared.pushKeyboardCommit() }
    }
}
