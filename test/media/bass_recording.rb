# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Stream recording with the real sound engine (klangten_audio, macOS and Linux
# builds in bin/): an endless "radio station" on a local HTTP server is played
# on the engine's null device, KlangtenRecordings puts the MP3 encoder on the
# playing channel, and the recording that comes out is opened again and must
# hold several seconds of audio. The station's MP3 is made by the same
# encoder from a generated tone, so no test file and no network is needed.

require "minitest/autorun"
require "socket"
require "fiddle"
require_relative "support"

module BassTestLibrary
  def self.directory
    case RUBY_PLATFORM
    when /darwin/ then File.join(ROOT, "bin", "osx")
    when /x86_64-linux/ then File.join(ROOT, "bin", "linux-x64")
    when /aarch64-linux/ then File.join(ROOT, "bin", "linux-arm64")
    end
  end

  def self.extension
    RUBY_PLATFORM.include?("darwin") ? "dylib" : "so"
  end

  def self.available?
    directory != nil && File.file?(File.join(directory, "libklangten_audio.#{extension}"))
  end
end

if BassTestLibrary.available?
  module Bass
    F_INT = Fiddle::TYPE_INT
    F_UINT = Fiddle::TYPE_UINT
    F_PTR = Fiddle::TYPE_VOIDP
    F_QWORD = Fiddle::TYPE_LONG_LONG
    F_DOUBLE = Fiddle::TYPE_DOUBLE
    BASS_ABI = Fiddle::Function::DEFAULT
    dir = BassTestLibrary.directory
    ext = BassTestLibrary.extension
    # every BASS_* name is the engine's KA_* (see src/eapi/audio/bass.rb)
    class EngineSymbols
      def initialize(handle) = @handle = handle
      def [](name) = @handle[name.to_s.sub(/\ABASS_/, "KA_")]
    end
    ENV["KLANGTEN_AUDIO_NULL"] = "1"
    BASSDLL = EngineSymbols.new(Fiddle.dlopen(File.join(dir, "libklangten_audio.#{ext}")))
    BASSENC = BASSDLL
    BASSENCMP3 = BASSDLL
    BASS_Init = Fiddle::Function.new(BASSDLL["BASS_Init"], [F_INT, F_UINT, F_UINT, F_PTR, F_PTR], F_INT)
    BASS_ErrorGetCode = Fiddle::Function.new(BASSDLL["BASS_ErrorGetCode"], [], F_INT)
    BASS_StreamCreate = Fiddle::Function.new(BASSDLL["BASS_StreamCreate"], [F_UINT, F_UINT, F_UINT, F_PTR, F_PTR], F_UINT)
    BASS_StreamCreateURL = Fiddle::Function.new(BASSDLL["BASS_StreamCreateURL"], [F_PTR, F_UINT, F_UINT, F_PTR, F_PTR], F_UINT)
    BASS_StreamCreateFile = Fiddle::Function.new(BASSDLL["BASS_StreamCreateFile"], [F_INT, F_PTR, F_QWORD, F_QWORD, F_UINT], F_UINT)
    BASS_StreamFree = Fiddle::Function.new(BASSDLL["BASS_StreamFree"], [F_UINT], F_INT)
    BASS_ChannelPlay = Fiddle::Function.new(BASSDLL["BASS_ChannelPlay"], [F_UINT, F_INT], F_INT)
    BASS_ChannelGetLength = Fiddle::Function.new(BASSDLL["BASS_ChannelGetLength"], [F_UINT, F_UINT], F_QWORD)
    BASS_ChannelBytes2Seconds = Fiddle::Function.new(BASSDLL["BASS_ChannelBytes2Seconds"], [F_UINT, F_QWORD], F_DOUBLE)
    BASS_Encode_Write = Fiddle::Function.new(BASSENC["BASS_Encode_Write"], [F_UINT, F_PTR, F_UINT], F_INT)
    BASS_Encode_Stop = Fiddle::Function.new(BASSENC["BASS_Encode_Stop"], [F_UINT], F_INT)

    def self.error_name
      "BASS_ERROR_#{BASS_ErrorGetCode.call}"
    end
  end

  class MediaEncoder; end
  load File.join(ROOT, "src/eapi/audio/encoders/base.rb")
  load File.join(ROOT, "src/eapi/audio/encoders/mp3.rb")

  class StreamRecordingTest < Minitest::Test
    SAMPLE_RATE = 44_100

    # A real channel playing an internet stream, in the shape the recorder
    # expects from a Sound.
    class StreamSound
      attr_reader :channel

      def initialize(url)
        @channel = Bass::BASS_StreamCreateURL.call(unicode(url), 0, 0x80000000 | 0x100, nil, nil)
        raise "Cannot open #{url}: #{Bass.error_name}" if @channel == 0
        Bass::BASS_ChannelPlay.call(@channel, 0)
      end

      def closed?
        @channel == 0
      end

      def close
        Bass::BASS_StreamFree.call(@channel)
        @channel = 0
      end
    end

    def setup
      Bass::BASS_Init.call(0, SAMPLE_RATE, 0, nil, nil)
      Spoken.clear
      @dir = File.join(TEST_DATA, "bass")
      FileUtils.mkdir_p(@dir)
      KlangtenRecordings.folder = File.join(@dir, "recordings")
    end

    # Ten seconds of a 440 Hz tone as MP3, through the same encoder.
    def station_mp3
      path = File.join(@dir, "station.mp3")
      encoder = Mp3AudioEncoder.new(128)
      output = File.open(path, "wb")
      sink = Object.new
      sink.define_singleton_method(:write) { |data| output.write(data) }
      encoder.start(sink, frequency: SAMPLE_RATE, channels: 2)
      frames = (0...SAMPLE_RATE * 10).map { |index| (Math.sin(2 * Math::PI * 440 * index / SAMPLE_RATE) * 12_000).to_i }
      encoder.process_pcm(frames.flat_map { |sample| [sample, sample] }.pack("s<*"))
      encoder.finish
      output.close
      File.binread(path)
    end

    # An endless station: the MP3 again and again, a little faster than real
    # time, like a radio server keeps its listeners' buffers filled.
    def start_station(data)
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        loop do
          client = server.accept
          Thread.new(client) do |connection|
            nil while (line = connection.gets) && line != "\r\n"
            connection.write("HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nicy-name: Test station\r\n\r\n")
            offset = 0
            loop do
              connection.write(data.byteslice(offset, 24_000))
              offset = (offset + 24_000) % data.bytesize
              sleep(0.5)
            end
          rescue StandardError
            connection.close rescue nil
          end
        end
      rescue IOError
        nil
      end
      [server, thread]
    end

    def recorded_seconds(path)
      channel = Bass::BASS_StreamCreateFile.call(0, unicode(path), 0, 0, 0x80000000 | 0x200000)
      assert channel != 0, "the recording cannot be opened: #{Bass.error_name}"
      Bass::BASS_ChannelBytes2Seconds.call(channel, Bass::BASS_ChannelGetLength.call(channel, 0))
    ensure
      Bass::BASS_StreamFree.call(channel) if channel.to_i != 0
    end

    def test_a_playing_station_is_recorded_into_a_numbered_mp3
      assert KlangtenRecordings.available?
      server, thread = start_station(station_mp3)
      sound = StreamSound.new("http://127.0.0.1:#{server.addr[1]}/stream")
      KlangtenRecordings.toggle_stream(sound, "Test: Station")
      assert_equal "Recording 001", Spoken.lines.last
      assert KlangtenRecordings.recording?(sound)
      sleep(4)
      KlangtenRecordings.toggle_stream(sound, "Test: Station")
      assert_equal "Recording 001 saved", Spoken.lines.last
      path = File.join(@dir, "recordings", "Test_ Station", "recording 001.mp3")
      assert File.file?(path), "no recording at #{path}"
      seconds = recorded_seconds(path)
      assert seconds > 2.5, "only #{seconds} seconds recorded"
      KlangtenRecordings.toggle_stream(sound, "Test: Station")
      assert_equal "Recording 002", Spoken.lines.last
      sleep(1)
      sound.close
      KlangtenRecordings.stop_stream(sound)
      assert File.file?(File.join(@dir, "recordings", "Test_ Station", "recording 002.mp3"))
    ensure
      sound&.close if sound != nil && !sound.closed?
      server&.close
      thread&.kill
    end
  end
else
  class StreamRecordingTest < Minitest::Test
    def test_needs_the_bass_libraries
      skip "BASS libraries for this platform are not in bin/"
    end
  end
end
