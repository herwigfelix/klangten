// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// Elten is free software: GNU General Public License v3.
//
// Thread-safe host -> Ruby input queue. The UI thread pushes recognised
// gestures and keyboard-explore events; the Ruby core drains them from its own
// thread via elten_host_next_input (see src/platforms/ios/eapi/hostbridge.rb and
// IOSTouchInput.start_host_pump). Keeping input one-directional through a plain
// queue avoids calling into the Ruby VM off its GVL thread.

import Foundation

final class EltenInputQueue {
    static let shared = EltenInputQueue()
    private var tokens: [String] = []
    private let lock = NSLock()

    func push(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        // Cap the backlog so a stuck Ruby thread can never grow this unbounded.
        if tokens.count > 4096 { tokens.removeFirst(tokens.count - 4096) }
        tokens.append(token)
    }

    func pushGesture(_ name: String) { push("gesture:\(name)") }
    func pushKeyboardPoint(_ x: CGFloat, _ y: CGFloat) { push("kpoint:\(x),\(y)") }
    func pushKeyboardCommit() { push("kcommit") }
    func pushKeyboardCancel() { push("kcancel") }
    func pushKeyboardText(_ text: String) { push("ktext:\(text)") }
    func pushSystemKeyboardState(_ visible: Bool) { push("ksys:\(visible ? 1 : 0)") }
    func pushActive(_ active: Bool) { push("active:\(active ? 1 : 0)") }

    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return tokens.isEmpty ? "" : tokens.removeFirst()
    }
}

private let nextInputHolder = NSLock()
private var nextInputBuffer: UnsafeMutablePointer<CChar>?

@_cdecl("elten_host_next_input")
public func elten_host_next_input() -> UnsafePointer<CChar> {
    let token = EltenInputQueue.shared.next()
    nextInputHolder.lock(); defer { nextInputHolder.unlock() }
    if let old = nextInputBuffer { free(old) }
    let dup = strdup(token)!
    nextInputBuffer = dup
    return UnsafePointer(dup)
}
