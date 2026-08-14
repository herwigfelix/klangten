# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS speech output.
#
# Elten self-voices; on iOS that is done with AVSpeechSynthesizer. The audio
# session, interruption handling and VoiceOver coexistence all belong to the
# native Swift host, so this class is a thin SpeechOutput adapter that delegates
# to IOSHostBridge. When the host is not attached (headless tooling / load
# phase) it reports as unavailable, so SpeechOutput.default_output simply skips
# it instead of crashing.
#
# Subclassing SpeechOutput auto-registers this backend (SpeechOutput.inherited).

class IOSSpeech < SpeechOutput
  NativeVoice = Struct.new(:id, :name, :language, :backend)
  DEFAULT_VOICE_ID = "default (iOS)"
  DEFAULT_VOICE_NAME = "default (iOS)"

  class << self
    def bridge
      return @bridge if defined?(@bridge) && @bridge != nil
      @bridge = (defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:speech_available?)) ? IOSHostBridge : nil
    end

    def available?
      bridge != nil && bridge.speech_available?
    rescue Exception
      false
    end

    def usable?
      available? && voices.size > 0
    end

    def default?
      usable?
    end

    def native_voices
      return [] unless available?
      Array(bridge.speech_voices).map do |voice|
        NativeVoice.new(voice[:id].to_s, voice[:name].to_s, voice[:language].to_s, :native)
      end
    rescue Exception
      []
    end

    def voices
      @voices ||= begin
        default_voice = SpeechOutput::Voice.new(
          id: DEFAULT_VOICE_ID,
          name: DEFAULT_VOICE_NAME,
          output: self,
          native: NativeVoice.new("", DEFAULT_VOICE_NAME, "", :default)
        )
        native = native_voices.map do |voice|
          label = voice.language.to_s == "" ? voice.name.to_s : "#{voice.name} (#{voice.language})"
          SpeechOutput::Voice.new(id: voice.id, name: label, output: self, native: voice)
        end
        [default_voice] + native
      end
    end

    def reset_voices!
      @voices = nil
    end

    def voice_for(voice)
      voice = voice.to_s
      return voices.first if voice == ""
      voices.find do |item|
        item.voiceid == voice || item.name.to_s == voice ||
          (item.native != nil && (item.native.name.to_s == voice || item.native.id.to_s == voice))
      end
    end

    def matches_voice?(voice)
      voice_for(voice) != nil
    end

    def apply_voice(voice)
      selected = voice_for(voice)
      return false if selected == nil
      if selected.native != nil && selected.native.backend == :default
        @voice_id = ""
      else
        @voice_id = selected.native.id.to_s
      end
      true
    end

    def apply_default_voice
      @voice_id = ""
      true
    end

    def set_rate(rate)
      @rate = clamp(rate)
      @rate
    end

    def set_volume(volume)
      @volume = clamp(volume)
      @volume
    end

    def set_pitch(pitch)
      @pitch = clamp(pitch)
      @pitch
    end

    def set_paused(paused)
      return 1 unless available?
      @paused = paused == true
      @paused ? bridge.speech_pause : bridge.speech_resume
      0
    rescue Exception
      1
    end

    def paused?
      @paused == true
    end

    def stop
      return 1 unless available?
      bridge.speech_stop
      @paused = false
      0
    rescue Exception
      1
    end

    def speaking?
      available? && bridge.speech_speaking?
    rescue Exception
      false
    end

    def rate_supported?
      true
    end

    def volume_supported?
      true
    end

    def pitch_supported?
      true
    end

    def pause_supported?
      true
    end

    def indexed_supported?
      available? && bridge.respond_to?(:speech_speak_indexed)
    rescue Exception
      false
    end

    def spelling_supported?
      true
    end

    def speak_text(text, method: 1, spelling: false, interrupt: true, pitch: 50)
      return 1 unless available?
      value = text.to_s
      value = value.chars.join(" ") if spelling
      bridge.speech_speak(value, @voice_id.to_s, rate_value, volume_value, pitch_value(pitch), interrupt != false)
      @paused = false
      0
    rescue Exception => e
      Log.warning("iOS speech failed: #{e.class}: #{e.message}") if defined?(Log)
      1
    end

    def speak_sequence(seq)
      seq.reset if seq.respond_to?(:reset)
      if seq.respond_to?(:texts) && seq.respond_to?(:indexes)
        speak_indexed(seq.texts, seq.indexes, seq.respond_to?(:id) ? seq.id : nil)
      else
        speak_text(seq.respond_to?(:text) ? seq.text : seq.to_s, method: 1)
      end
    end

    def speak_indexed(texts, indexes, id = nil)
      return 1 unless available?
      @index_id = id
      if indexed_supported?
        bridge.speech_speak_indexed(Array(texts).map(&:to_s), Array(indexes), id, @voice_id.to_s, rate_value, volume_value)
      else
        speak_text(Array(texts).join, method: 1)
      end
      @paused = false
      0
    rescue Exception => e
      Log.warning("iOS indexed speech failed: #{e.class}: #{e.message}") if defined?(Log)
      1
    end

    def index
      return [nil, nil] unless available? && bridge.respond_to?(:speech_index)
      value = bridge.speech_index
      return [nil, nil] if value == nil
      [value[:index], value[:id] == nil ? @index_id : value[:id]]
    rescue Exception
      [nil, nil]
    end

    private

    def clamp(value)
      [[value.to_i, 0].max, 100].min
    end

    def rate_value
      clamp(@rate || 50)
    end

    def volume_value
      clamp(@volume || 100)
    end

    def pitch_value(pitch)
      clamp(pitch == nil ? (@pitch || 50) : pitch)
    end
  end
end
