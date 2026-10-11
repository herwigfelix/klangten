# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The microphone of a test. Klangten's recorder reads PCM from a BASS input
# channel (EltenRecorderRuntime::InputRecording); in tests that class is
# replaced by FakeInputRecording, which "records" a generated signal for as
# long as the recording runs in virtual time - 48 kHz, stereo, 16 bit, the
# format the real input delivers. Everything after it (encoders, Ogg writer,
# upload) is the real code.
#
#   app.microphone.signal = :music       # default: chord + noise, rich spectrum
#   app.microphone.signal = :tone        # 440 Hz sine
#   app.microphone.signal = ->(t) { ... } # sample value -1.0..1.0 at time t
#   app.microphone.recordings            # every recording made in this test
#   app.opus_encoders                    # [{application:, bitrate:}, ...]

module KlangtenTest
  module Microphone
    RATE = 48_000
    CHANNELS = 2

    Recording = Struct.new(:seconds, :stopped, keyword_init: true)

    class << self
      attr_accessor :signal

      def active
        @active ||= []
      end

      def recordings
        @recordings ||= []
      end

      def opus_encoders
        @opus_encoders ||= []
      end

      def install
        @signal ||= :music
        @noise = Random.new(4711)
        @real = EltenRecorderRuntime::InputRecording
        EltenRecorderRuntime.send(:remove_const, :InputRecording)
        EltenRecorderRuntime.const_set(:InputRecording, FakeInputRecording)
        Runtime.add_frame_hook { active.dup.each(&:pump) }
        spy_opus
      end

      # Which application and bitrate every Opus encoder was opened with.
      def spy_opus
        encoders = opus_encoders
        Hooks.wrap(Opus::Encoder, :initialize) do |original, freq = 48000, ch = 2, app = :audio|
          encoders << { application: app == :audio ? 2049 : 2048, channels: ch, bitrate: nil }
          original.call(freq, ch, app)
        end
        Hooks.wrap(Opus::Encoder, :bitrate=) do |original, value|
          encoders.last[:bitrate] = value.to_i if encoders.last
          original.call(value)
        end
      end

      def sample(t)
        case @signal
        when :tone then 0.4 * Math.sin(2 * Math::PI * 440 * t)
        when :silence then 0.0
        when Proc then @signal.call(t).to_f
        else
          # A chord with overtones plus noise: keeps a variable-bitrate
          # encoder busy across the whole band, like real music would.
          v = [220, 277.2, 329.6, 440, 880, 1760, 3520, 7040].each_with_index.sum do |f, i|
            Math.sin(2 * Math::PI * f * t + i) / (i + 2)
          end
          0.35 * v + 0.15 * (@noise.rand * 2 - 1)
        end
      end

      def pcm(first_sample, count)
        values = Array.new(count * CHANNELS)
        count.times do |i|
          v = (sample((first_sample + i).to_f / RATE).clamp(-1.0, 1.0) * 32767).round
          values[i * 2] = v
          values[i * 2 + 1] = v
        end
        values.pack("s<*")
      end
    end

    class FakeInputRecording
      def initialize(session_factory, _read_buffer_bytes = 384_000, _record_flags = 0)
        @paused = false
        @stopped = false
        @samples = 0
        @last = Runtime.clock.elapsed
        @carry = 0.0
        @info = Recording.new(seconds: 0.0, stopped: false)
        Microphone.recordings << @info
        $recording = true
        @session = session_factory.call
        Microphone.active << self
      end

      # Delivers the PCM for the virtual time since the last call.
      def pump
        now = Runtime.clock.elapsed
        dt = now - @last
        @last = now
        return if @paused || @stopped || dt <= 0
        exact = dt * RATE + @carry
        count = exact.floor
        @carry = exact - count
        return if count <= 0
        @session.process_pcm(Microphone.pcm(@samples, count))
        @samples += count
        @info.seconds = @samples.to_f / RATE
      end

      def stop
        return if @stopped
        pump
        @stopped = true
        $recording = false
        Microphone.active.delete(self)
        @info.stopped = true
        @session.finish if @session != nil
        @session = nil
      end

      def pause
        pump
        $recording = false
        @paused = true
      end

      def resume
        @last = Runtime.clock.elapsed
        $recording = true
        @paused = false
      end

      def paused
        @paused == true
      end
    end
  end
end
