# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Test double for the speech output (loaded instead of the platform's
# speech files). It is the only SpeechOutput, so Klangten picks it as the
# current voice. Every utterance goes to the transcript; speaking "takes"
# virtual time in proportion to the text length, and an interrupt (the next
# key press) cuts it short - as with a real voice, so speech_wait, alerts and
# indexed sequences (sounds inside spoken text) behave as they do for users.

class KlangtenTestSpeech < SpeechOutput
  SECONDS_PER_CHAR = 0.03
  MIN_SECONDS = 0.15

  VOICE = SpeechOutput::Voice.new(id: "test:voice", name: "Test voice", output: nil, native: nil)

  class << self
    def reset
      @parts = []
      @started = 0.0
      @sequence_id = nil
      @spoken = 0
    end

    def voices
      [VOICE]
    end

    def indexed_supported?
      true
    end

    def spelling_supported?
      true
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

    def speaking?
      remaining > 0
    end

    def stop
      @parts = []
      @sequence_id = nil
      1
    end

    def speak_text(text, method: 1, spelling: false, interrupt: true, pitch: 50)
      append = !(interrupt || method == 1) && speaking?
      stop unless append
      text = text.to_s
      KlangtenTest.record(:speak, text, spelling: spelling) if text.strip != ""
      queue([text], nil, nil, append)
      0
    end

    def speak_sequence(seq)
      seq.reset
      speak_indexed(seq.texts, seq.indexes, seq.id)
    end

    def speak_indexed(texts, indexes, id = nil)
      stop
      text = texts.join
      KlangtenTest.record(:speak, text) if text.strip != ""
      queue(texts, id, indexes)
      0
    end

    # [index reached, sequence id] - the index of the last part that has been
    # fully "spoken"; SpeechSequence#execute fires the sounds embedded there.
    def index
      return [nil, nil] if @sequence_id == nil
      [spoken_parts, @sequence_id]
    end

    private

    def now
      KlangtenTest::Runtime.clock.elapsed
    end

    # append: queued behind what is still being said (method 0).
    def queue(texts, id, indexes = nil, append = false)
      if append && @parts != nil && !@parts.empty?
        offset = @parts.last[0]
      else
        @started = now
        @parts = []
        offset = 0.0
      end
      @sequence_id = id
      texts.each_with_index do |text, i|
        offset += duration(text)
        @parts << [offset, indexes ? indexes[i] : i + 1]
      end
    end

    def duration(text)
      text = text.to_s
      return 0.0 if text.strip == ""
      [text.length * SECONDS_PER_CHAR, MIN_SECONDS].max
    end

    def remaining
      return 0 if @parts == nil || @parts.empty?
      [@parts.last[0] - (now - @started), 0].max
    end

    def spoken_parts
      elapsed = now - @started
      done = @parts.select { |offset, _| offset <= elapsed }
      done.empty? ? 0 : done.last[1]
    end
  end

  reset
end
