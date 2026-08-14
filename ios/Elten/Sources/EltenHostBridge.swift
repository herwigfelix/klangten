// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Native side of the Ruby <-> host bridge. These @_cdecl functions are linked
// into the app executable and resolved from Ruby by name (Fiddle.dlopen(nil))
// in src/platforms/ios/eapi/hostbridge.rb. The C ABI here MUST stay in sync with
// that file.

import Foundation
import AVFoundation
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
        hostSpeech.speak(utterance)
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
    return CStringHolder.shared.store("locale", Locale.current.identifier)
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
    ]
    if keep.count == 0 { fatalError() } // never true; prevents the array being optimised away
}
