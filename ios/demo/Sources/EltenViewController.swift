// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.

import UIKit

/// The full-screen self-voicing surface. It recognises the Elten gesture
/// vocabulary and, in the full app, forwards each gesture to the embedded Ruby
/// core (IOSTouchInput.perform). Here it drives a small in-memory list + edit
/// field so the identical interaction model can be verified on a real device.
final class EltenViewController: UIViewController {

    // A tiny stand-in for an Elten scene: a navigable list plus one edit field.
    private var items = ["Forum", "Messages", "Contacts", "Conferences", "Settings", "Write a post"]
    private var index = 0
    private var isEditingText = false
    private var editBuffer = ""

    private var keyboard: OnScreenKeyboardView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Elten voices itself; take direct touches rather than exposing
        // per-element VoiceOver buttons.
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.allowsDirectInteraction]
        view.accessibilityLabel = "Elten"
        installGestures()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        EltenSpeech.shared.speak("Elten. \(items[index]).")
    }

    // MARK: gesture installation (mirrors IOSTouchInput's vocabulary)

    private func installGestures() {
        addSwipe(.right, fingers: 1, action: #selector(swipeRight))
        addSwipe(.left, fingers: 1, action: #selector(swipeLeft))
        addSwipe(.up, fingers: 1, action: #selector(swipeUp))
        addSwipe(.down, fingers: 1, action: #selector(swipeDown))

        addTap(taps: 2, fingers: 1, action: #selector(doubleTap))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        view.addGestureRecognizer(longPress)

        addTap(taps: 1, fingers: 2, action: #selector(twoFingerTap))
        addTap(taps: 2, fingers: 2, action: #selector(twoFingerDoubleTap))
        addSwipe(.left, fingers: 2, action: #selector(twoFingerBack))
        addSwipe(.down, fingers: 2, action: #selector(twoFingerBack))

        addSwipe(.right, fingers: 3, action: #selector(threeFingerNext))
        addSwipe(.left, fingers: 3, action: #selector(threeFingerPrev))
        addTap(taps: 2, fingers: 3, action: #selector(toggleKeyboardGesture))
    }

    private func addSwipe(_ dir: UISwipeGestureRecognizer.Direction, fingers: Int, action: Selector) {
        let g = UISwipeGestureRecognizer(target: self, action: action)
        g.direction = dir
        g.numberOfTouchesRequired = fingers
        view.addGestureRecognizer(g)
    }

    private func addTap(taps: Int, fingers: Int, action: Selector) {
        let g = UITapGestureRecognizer(target: self, action: action)
        g.numberOfTapsRequired = taps
        g.numberOfTouchesRequired = fingers
        view.addGestureRecognizer(g)
    }

    // MARK: navigation actions

    @objc private func swipeRight() { move(1) }
    @objc private func swipeLeft() { move(-1) }
    @objc private func swipeUp() { move(-1) }
    @objc private func swipeDown() { move(1) }

    private func move(_ delta: Int) {
        index = (index + delta + items.count) % items.count
        EltenSpeech.shared.speak(items[index])
    }

    @objc private func doubleTap() {
        let item = items[index]
        if item == "Write a post" {
            startEditing()
        } else {
            EltenSpeech.shared.speak("Opening \(item).")
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        EltenSpeech.shared.speak("Context menu for \(items[index]).")
    }

    @objc private func twoFingerTap() { EltenSpeech.shared.stop() }

    @objc private func twoFingerDoubleTap() {
        EltenSpeech.shared.speak("Main menu. Home, Programs are not available on iOS, Tools, Help.")
    }

    @objc private func twoFingerBack() {
        if isEditingText { stopEditing(); return }
        EltenSpeech.shared.speak("Back. \(items[index]).")
    }

    @objc private func threeFingerNext() { EltenSpeech.shared.speak("Next control.") }
    @objc private func threeFingerPrev() { EltenSpeech.shared.speak("Previous control.") }

    @objc private func toggleKeyboardGesture() {
        keyboard == nil ? presentKeyboard() : dismissKeyboard()
    }

    // MARK: editing + on-screen keyboard

    private func startEditing() {
        isEditingText = true
        editBuffer = ""
        EltenSpeech.shared.speak("Edit field. Opening keyboard.")
        presentKeyboard()
    }

    private func stopEditing() {
        isEditingText = false
        dismissKeyboard()
        EltenSpeech.shared.speak("Text entered: \(editBuffer.isEmpty ? "empty" : editBuffer)")
    }

    private func presentKeyboard() {
        guard keyboard == nil else { return }
        let kb = OnScreenKeyboardView(frame: view.bounds.insetBy(dx: 0, dy: view.bounds.height * 0.35))
        kb.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        kb.onType = { [weak self] ch in
            self?.editBuffer.append(ch)
            EltenSpeech.shared.speak(ch == " " ? "space" : ch)
        }
        kb.onControlKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case "backspace":
                if !self.editBuffer.isEmpty { self.editBuffer.removeLast() }
                EltenSpeech.shared.speak("delete")
            case "enter":
                self.stopEditing()
            case "tab":
                EltenSpeech.shared.speak("tab")
            default: break
            }
        }
        kb.onClose = { [weak self] in self?.dismissKeyboard() }
        view.addSubview(kb)
        keyboard = kb
        kb.present()
    }

    private func dismissKeyboard() {
        keyboard?.removeFromSuperview()
        keyboard = nil
        EltenSpeech.shared.speak("Keyboard closed.")
    }
}
