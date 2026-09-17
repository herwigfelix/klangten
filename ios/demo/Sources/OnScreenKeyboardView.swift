// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.

import UIKit

/// Accessible on-screen keyboard, a native mirror of Ruby's OnScreenKeyboard.
/// Explore-by-touch: the finger moving over the grid speaks the key under it;
/// lifting the finger types it. This is the same contract the Ruby control
/// exposes (point / commit), so the two stay behaviourally identical.
final class OnScreenKeyboardView: UIView {

    enum Key {
        case char(String)
        case command(String) // "backspace","enter","space","shift","numbers","symbols","letters","close","tab"

        var label: String {
            switch self {
            case .char(let s): return s == " " ? "Space" : s
            case .command(let c): return c.capitalized
            }
        }
    }

    private let layers: [String: [[Key]]] = [
        "lower": [
            "qwertyuiop".map { .char(String($0)) },
            "asdfghjkl".map { .char(String($0)) },
            [.command("shift")] + "zxcvbnm".map { .char(String($0)) } + [.command("backspace")],
            [.command("numbers"), .char(" "), .command("enter"), .command("close")]
        ],
        "upper": [
            "QWERTYUIOP".map { .char(String($0)) },
            "ASDFGHJKL".map { .char(String($0)) },
            [.command("shift")] + "ZXCVBNM".map { .char(String($0)) } + [.command("backspace")],
            [.command("numbers"), .char(" "), .command("enter"), .command("close")]
        ],
        "numbers": [
            "1234567890".map { .char(String($0)) },
            "-/:;()@\"'".map { .char(String($0)) },
            [.command("symbols")] + ".,?!_".map { .char(String($0)) } + [.command("backspace")],
            [.command("letters"), .char(" "), .command("enter"), .command("close")]
        ],
        "symbols": [
            "[]{}#%^*+=".map { .char(String($0)) },
            "\\|~<>$&`".map { .char(String($0)) },
            [.command("numbers"), .command("tab"), .command("backspace")],
            [.command("letters"), .char(" "), .command("enter"), .command("close")]
        ]
    ]

    private var layerName = "lower"
    private var row = 0
    private var col = 0
    private var lastSpokenKey = ""

    /// Types a character into the app's edit buffer.
    var onType: ((String) -> Void)?
    /// Emits a control key name (backspace/enter/tab) to the app.
    var onControlKey: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var currentLayer: [[Key]] { layers[layerName] ?? layers["lower"]! }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.85)
        isMultipleTouchEnabled = false
        // Elten voices the keys itself, so it takes raw touches instead of
        // exposing per-key VoiceOver buttons.
        accessibilityTraits = [.allowsDirectInteraction]
        isAccessibilityElement = true
        accessibilityLabel = "Klangten on-screen keyboard"
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        layerName = "lower"; row = 0; col = 0; lastSpokenKey = ""
        EltenSpeech.shared.speak("On-screen keyboard. Slide a finger to hear keys, lift to type, swipe with two fingers to close.")
        speakCurrent(detailed: true)
    }

    // MARK: explore-by-touch

    private func keyAt(point p: CGPoint) -> (Int, Int)? {
        guard bounds.height > 0, bounds.width > 0 else { return nil }
        let rows = currentLayer
        var r = Int((p.y / bounds.height) * CGFloat(rows.count))
        r = min(max(r, 0), rows.count - 1)
        let cols = rows[r].count
        var c = Int((p.x / bounds.width) * CGFloat(cols))
        c = min(max(c, 0), cols - 1)
        return (r, c)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { updateSelection(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { updateSelection(touches) }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        commit()
    }

    private func updateSelection(_ touches: Set<UITouch>) {
        guard let t = touches.first else { return }
        guard let (r, c) = keyAt(point: t.location(in: self)) else { return }
        if r != row || c != col {
            row = r; col = c
            speakCurrent()
        }
    }

    private func currentKey() -> Key { currentLayer[row][col] }

    private func speakCurrent(detailed: Bool = false) {
        let key = currentKey()
        let text = detailed ? key.label : key.label
        guard text != lastSpokenKey else { return }
        lastSpokenKey = text
        EltenSpeech.shared.speak(text)
    }

    // MARK: typing

    func commit() {
        switch currentKey() {
        case .char(let s):
            onType?(s)
        case .command(let c):
            runCommand(c)
        }
    }

    private func runCommand(_ command: String) {
        switch command {
        case "shift":
            layerName = (layerName == "lower") ? "upper" : "lower"
            resetSelection(); EltenSpeech.shared.speak(layerName == "upper" ? "Uppercase" : "Lowercase")
        case "numbers": layerName = "numbers"; resetSelection(); EltenSpeech.shared.speak("Numbers")
        case "symbols": layerName = "symbols"; resetSelection(); EltenSpeech.shared.speak("Symbols")
        case "letters": layerName = "lower"; resetSelection(); EltenSpeech.shared.speak("Letters")
        case "close": onClose?()
        default: onControlKey?(command)
        }
    }

    private func resetSelection() { row = 0; col = 0; lastSpokenKey = ""; speakCurrent() }
}
