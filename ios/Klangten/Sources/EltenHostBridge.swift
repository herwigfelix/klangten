// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// Elten is free software: GNU General Public License v3.
//
// Native side of the Ruby <-> host bridge. These @_cdecl functions are linked
// into the app executable and resolved from Ruby by name (Fiddle.dlopen(nil))
// in src/platforms/ios/eapi/hostbridge.rb. The C ABI here MUST stay in sync with
// that file.

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

// Keeps returned C strings alive until the next call of the same kind.
private final class CStringHolder {
    static let shared = CStringHolder()
    private var buffers: [String: UnsafeMutablePointer<CChar>] = [:]
    private let lock = NSLock()
    func store(_ key: String, _ value: String) -> UnsafePointer<CChar> {
        lock.lock(); defer { lock.unlock() }
        if let old = buffers[key] { free(old) }
        let dup = strdup(value)!
        buffers[key] = dup
        return UnsafePointer(dup)
    }
}

private let hostSpeech = AVSpeechSynthesizer()

// Debug builds only: KLANGTEN_MUTE=1 silences speech (nothing reaches the
// audio system, the text is still shown) and every sound (null device), for
// automated simulator runs on a machine where someone is working.
#if DEBUG
let hostMuted = ProcessInfo.processInfo.environment["KLANGTEN_MUTE"] == "1"
#else
let hostMuted = false
#endif

private func mapRate(_ rate: Int32) -> Float {
    // Elten rate 0..100 -> AVSpeechUtterance min..max
    let clamped = max(0, min(100, Int(rate)))
    return AVSpeechUtteranceMinimumSpeechRate +
        (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * Float(clamped) / 100.0
}

// MARK: - speech

@_cdecl("elten_host_speech_available")
public func elten_host_speech_available() -> Int32 { return 1 }

@_cdecl("elten_host_speech_voices_json")
public func elten_host_speech_voices_json() -> UnsafePointer<CChar> {
    let voices = AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: String] in
        ["id": voice.identifier, "name": voice.name, "language": voice.language]
    }
    let data = (try? JSONSerialization.data(withJSONObject: voices)) ?? Data("[]".utf8)
    return CStringHolder.shared.store("voices", String(data: data, encoding: .utf8) ?? "[]")
}

@_cdecl("elten_host_speech_speak")
public func elten_host_speech_speak(_ text: UnsafePointer<CChar>?, _ voice: UnsafePointer<CChar>?,
                                    _ rate: Int32, _ volume: Int32, _ pitch: Int32, _ interrupt: Int32) {
    let string = text.map { String(cString: $0) } ?? ""
    let voiceId = voice.map { String(cString: $0) } ?? ""
    guard !string.isEmpty else { return }
    DispatchQueue.main.async {
        if interrupt != 0 && hostSpeech.isSpeaking { hostSpeech.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: string)
        if !voiceId.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId) }
        utterance.rate = mapRate(rate)
        utterance.volume = max(0, min(100, Float(volume))) / 100.0
        utterance.pitchMultiplier = 0.5 + max(0, min(100, Float(pitch))) / 100.0
        if !hostMuted { hostSpeech.speak(utterance) }
        EltenGestureViewController.current?.showSpokenText(string, interrupt: interrupt != 0)
    }
}

@_cdecl("elten_host_speech_stop")
public func elten_host_speech_stop() {
    DispatchQueue.main.async { if hostSpeech.isSpeaking { hostSpeech.stopSpeaking(at: .immediate) } }
}

@_cdecl("elten_host_speech_speaking")
public func elten_host_speech_speaking() -> Int32 { return hostSpeech.isSpeaking ? 1 : 0 }

@_cdecl("elten_host_speech_pause")
public func elten_host_speech_pause() {
    DispatchQueue.main.async { hostSpeech.pauseSpeaking(at: .immediate) }
}

@_cdecl("elten_host_speech_resume")
public func elten_host_speech_resume() {
    DispatchQueue.main.async { hostSpeech.continueSpeaking() }
}

// MARK: - clipboard

@_cdecl("elten_host_clipboard_get")
public func elten_host_clipboard_get() -> UnsafePointer<CChar> {
    return CStringHolder.shared.store("clipboard", UIPasteboard.general.string ?? "")
}

@_cdecl("elten_host_clipboard_set")
public func elten_host_clipboard_set(_ text: UnsafePointer<CChar>?) {
    UIPasteboard.general.string = text.map { String(cString: $0) } ?? ""
}

// MARK: - system

@_cdecl("elten_host_open_url")
public func elten_host_open_url(_ url: UnsafePointer<CChar>?) -> Int32 {
    guard let raw = url.map({ String(cString: $0) }), let u = URL(string: raw) else { return 0 }
    DispatchQueue.main.async { UIApplication.shared.open(u) }
    return 1
}

@_cdecl("elten_host_microphone_request")
public func elten_host_microphone_request(_ timeout: Double) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVAudioSession.sharedInstance().requestRecordPermission { ok in granted = ok; semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + max(0.1, timeout))
    return granted ? 1 : 0
}

@_cdecl("elten_host_locale")
public func elten_host_locale() -> UnsafePointer<CChar> {
    // Locale.current follows the bundle's development region (Polish here), so
    // a German phone would report pl_DE and Klangten would start in English.
    // The user's own language order is in preferredLanguages.
    let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
    return CStringHolder.shared.store("locale", preferred)
}

@_cdecl("elten_host_os_version")
public func elten_host_os_version() -> UnsafePointer<CChar> {
    return CStringHolder.shared.store("os", "iOS " + UIDevice.current.systemVersion)
}

@_cdecl("elten_host_frameworks_path")
public func elten_host_frameworks_path() -> UnsafePointer<CChar> {
    let path = Bundle.main.privateFrameworksPath ?? ""
    return CStringHolder.shared.store("frameworks", path)
}

// MARK: - system on-screen keyboard

// Visibility flag mirrored from the main thread so the Ruby pump thread can
// poll it without touching UIKit off-main.
final class EltenSystemKeyboardState {
    static let shared = EltenSystemKeyboardState()
    private var visible = false
    private let lock = NSLock()
    var isVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return visible
    }
    func set(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        visible = value
    }
}

@_cdecl("elten_host_system_keyboard_show")
public func elten_host_system_keyboard_show() {
    DispatchQueue.main.async { EltenGestureViewController.current?.showSystemKeyboard() }
}

// The same keyboard for a password field: typed text is hidden and kept out of
// suggestions and the keyboard's learning.
@_cdecl("elten_host_system_keyboard_show_secure")
public func elten_host_system_keyboard_show_secure() {
    DispatchQueue.main.async { EltenGestureViewController.current?.showSystemKeyboard(secure: true) }
}

// The keyboard for an edit box that already holds text: it starts with that
// text and Return sends back the edited text, which replaces it. The string is
// copied here, before the pointer goes back to Ruby.
@_cdecl("elten_host_system_keyboard_show_text")
public func elten_host_system_keyboard_show_text(_ text: UnsafePointer<CChar>?) {
    let value = text.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async { EltenGestureViewController.current?.showSystemKeyboard(text: value) }
}

@_cdecl("elten_host_system_keyboard_hide")
public func elten_host_system_keyboard_hide() {
    DispatchQueue.main.async { EltenGestureViewController.current?.hideSystemKeyboard() }
}

@_cdecl("elten_host_system_keyboard_visible")
public func elten_host_system_keyboard_visible() -> Int32 {
    return EltenSystemKeyboardState.shared.isVisible ? 1 : 0
}

// --- audio focus (Klangten 0.4, background player) ------------------------------
// iOS has no focus request like Android; what matters are interruptions of the
// audio session (a call, an alarm, Siri). State: 1 = ours, 0 = interrupted
// (continues when the interruption ends and the system says so), -1 = taken.
private final class EltenAudioFocus {
    static let shared = EltenAudioFocus()
    private let lock = NSLock()
    private var value: Int32 = 1
    private var observing = false

    var state: Int32 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Int32) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func observe() {
        lock.lock()
        let first = !observing
        observing = true
        lock.unlock()
        guard first else { return }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                EltenAudioFocus.shared.set(0)
            } else {
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                if options.contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    EltenAudioFocus.shared.set(1)
                } else {
                    EltenAudioFocus.shared.set(-1)
                }
            }
        }
    }
}

@_cdecl("elten_host_audio_focus_request")
public func elten_host_audio_focus_request() -> Int32 {
    EltenAudioFocus.shared.observe()
    try? AVAudioSession.sharedInstance().setActive(true)
    EltenAudioFocus.shared.set(1)
    return 1
}

@_cdecl("elten_host_audio_focus_abandon")
public func elten_host_audio_focus_abandon() {
    EltenAudioFocus.shared.set(1)
}

@_cdecl("elten_host_audio_focus_state")
public func elten_host_audio_focus_state() -> Int32 {
    return EltenAudioFocus.shared.state
}

// --- headset and media buttons (Klangten 0.4) -------------------------------------
// The remote commands of iOS (headset buttons, Bluetooth, lock screen, Control
// Centre) control Klangten's playback when the user wants it (Settings, Media).
// Ruby polls the pressed buttons: 1 play/pause, 2 play, 3 pause, 4 next,
// 5 previous, 6 stop. Now playing: state 0 nothing, 1 playing, 2 paused.
private final class EltenMediaButtons {
    static let shared = EltenMediaButtons()
    private let lock = NSLock()
    private var pressed: [Int32] = []
    private var targets: [(MPRemoteCommand, Any)] = []

    func push(_ code: Int32) {
        lock.lock(); pressed.append(code); lock.unlock()
    }

    func poll() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return pressed.isEmpty ? 0 : pressed.removeFirst()
    }

    func enable(_ on: Bool) {
        DispatchQueue.main.async {
            let center = MPRemoteCommandCenter.shared()
            for (command, target) in self.targets { command.removeTarget(target) }
            self.targets.removeAll()
            let commands: [(MPRemoteCommand, Int32)] = [
                (center.togglePlayPauseCommand, 1), (center.playCommand, 2), (center.pauseCommand, 3),
                (center.nextTrackCommand, 4), (center.previousTrackCommand, 5), (center.stopCommand, 6),
            ]
            for (command, code) in commands {
                command.isEnabled = on
                guard on else { continue }
                let target = command.addTarget { _ in
                    EltenMediaButtons.shared.push(code)
                    return .success
                }
                self.targets.append((command, target))
            }
            if on {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            } else {
                UIApplication.shared.endReceivingRemoteControlEvents()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    func nowPlaying(_ title: String, _ state: Int32) {
        DispatchQueue.main.async {
            let info = MPNowPlayingInfoCenter.default()
            if state == 0 {
                info.nowPlayingInfo = nil
                return
            }
            info.nowPlayingInfo = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: "Klangten",
                MPNowPlayingInfoPropertyPlaybackRate: state == 1 ? 1.0 : 0.0,
            ]
        }
    }
}

@_cdecl("elten_host_media_buttons_enable")
public func elten_host_media_buttons_enable(_ on: Int32) {
    EltenMediaButtons.shared.enable(on != 0)
}

@_cdecl("elten_host_media_buttons_poll")
public func elten_host_media_buttons_poll() -> Int32 {
    return EltenMediaButtons.shared.poll()
}

@_cdecl("elten_host_media_now_playing")
public func elten_host_media_now_playing(_ title: UnsafePointer<CChar>?, _ state: Int32) {
    EltenMediaButtons.shared.nowPlaying(title.map { String(cString: $0) } ?? "", state)
}

// Force-keep the @_cdecl entry points. Only the embedded Ruby calls them (via
// dlsym), so without a Swift-side reference the linker dead-strips them and the
// app becomes silent + unresponsive. `@_used`-style retention via a referenced
// table, touched from AppDelegate at launch.
@inline(never)
public func eltenHostBridgeKeepAlive() {
    let keep: [Any] = [
        elten_host_speech_available, elten_host_speech_voices_json, elten_host_speech_speak,
        elten_host_speech_stop, elten_host_speech_speaking, elten_host_speech_pause,
        elten_host_speech_resume, elten_host_clipboard_get, elten_host_clipboard_set,
        elten_host_open_url, elten_host_microphone_request, elten_host_locale,
        elten_host_os_version, elten_host_frameworks_path, elten_host_next_input,
        elten_host_system_keyboard_show, elten_host_system_keyboard_show_secure,
        elten_host_system_keyboard_show_text, elten_host_system_keyboard_hide,
        elten_host_system_keyboard_visible,
        elten_host_audio_focus_request, elten_host_audio_focus_abandon, elten_host_audio_focus_state,
        elten_host_media_buttons_enable, elten_host_media_buttons_poll, elten_host_media_now_playing,
    ]
    if keep.count == 0 { fatalError() } // never true; prevents the array being optimised away
}
