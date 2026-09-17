// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// Elten is free software: GNU General Public License v3.

import AVFoundation

/// Self-voicing output. In the full app the Ruby SpeechOutput layer calls into
/// this via the C bridge (IOSHostBridge.speech_*); here it is exercised directly
/// so the interaction model can be verified end to end on the simulator.
final class EltenSpeech {
    static let shared = EltenSpeech()
    private let synthesizer = AVSpeechSynthesizer()
    private var lastVoiceLanguage = "en-US"

    init() {
        configureSession()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    func speak(_ text: String, interrupt: Bool = true) {
        guard !text.isEmpty else { return }
        if interrupt && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: lastVoiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
