# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The recordings folder and the two kinds of recordings that end up there.
#
# Stream recording ("R" in a player): what is playing - a radio station, a
# podcast episode, a YouTube video - is written to MP3 while it plays. The
# MP3 encoder of BASSenc_MP3 sits directly on the playing channel and writes
# the file itself (BASS_Encode_MP3_StartFile), so no native callback is
# involved and it works the same on every platform, the phones included. The
# encoder receives the decoded sound before the volume is applied: turning the
# player down does not make the recording quieter, pausing simply pauses it.
# Each recording gets the next free number in a folder named after what is
# playing: <recordings>/<title>/recording 001.mp3.
#
# Microphone recording (a quick action, Control+F11 by default): the first
# press starts recording from the input device into
# <recordings>/Microphone/recording 001.mp3, the second one saves it.
#
# The folder is <documents>/Klangten/Recordings unless the user chose another
# one (Settings, Media).

require "fileutils"
require "monitor"

module KlangtenRecordings
  CONFIG_GROUP = "Media".freeze
  CONFIG_KEY = "RecordingsFolder".freeze
  BITRATE = 128
  NUMBER_DIGITS = 3
  RESTRICTED = /[\t"\/\\*?<>|:\x00-\x1f]/.freeze
  BASS_UNICODE = 0x80000000
  BASS_ENCODE_AUTOFREE = 0x40000

  # One running stream recording.
  class StreamRecording
    attr_reader :path, :number, :title

    def initialize(handle, path, number, title)
      @handle = handle
      @path = path
      @number = number
      @title = title
    end

    def stop
      return if @handle.to_i == 0
      Bass::BASS_Encode_Stop.call(@handle)
      @handle = 0
    rescue StandardError
      @handle = 0
    end

    def stopped?
      @handle.to_i == 0
    end
  end

  @lock = Monitor.new
  @streams = {}.compare_by_identity
  @microphone = nil

  class << self
    # ------------------------------------------------------------ folder

    def default_folder
      base = Dirs.documents
      mobile? ? File.join(base, "Recordings") : File.join(base, "Klangten", "Recordings")
    end

    def folder
      value = readconfig(CONFIG_GROUP, CONFIG_KEY, "").to_s
      value == "" ? default_folder : value
    rescue StandardError
      default_folder
    end

    def folder=(path)
      writeconfig(CONFIG_GROUP, CONFIG_KEY, path.to_s)
    end

    def custom_folder?
      readconfig(CONFIG_GROUP, CONFIG_KEY, "").to_s != ""
    rescue StandardError
      false
    end

    # A file or folder name made of title: characters no file system takes
    # become "_", and an empty title becomes the fallback.
    def safe_name(title, fallback = "Unknown")
      name = title.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).gsub(RESTRICTED, "_").strip
      name = name.sub(/\A\.+/, "").sub(/[. ]+\z/, "")
      name = name[0, 80].strip if name.size > 80
      name == "" ? fallback.to_s : name
    end

    # The next free numbered file in dir: the highest number already there
    # plus one ("recording 007.mp3" -> "recording 008.mp3"), three digits.
    # Returns [path, "008"]; the folder is created.
    def next_numbered(dir, prefix, extension)
      FileUtils.mkdir_p(dir)
      extension = extension.start_with?(".") ? extension : ".#{extension}"
      highest = 0
      (Dir.children(dir) rescue []).each do |name|
        next if File.extname(name).downcase != extension.downcase
        stem = File.basename(name, File.extname(name))
        next if !stem.downcase.start_with?(prefix.downcase)
        rest = stem[prefix.size..].to_s
        next if !rest.match?(/\A\d+\z/)
        highest = [highest, rest.to_i].max
      end
      number = format("%0#{NUMBER_DIGITS}d", highest + 1)
      [File.join(dir, "#{prefix}#{number}#{extension}"), number]
    end

    # ------------------------------------------------- stream recording

    def available?
      defined?(KlangtenMp3) && KlangtenMp3.available? && Bass::BASS_Encode_Stop.is_a?(Fiddle::Function)
    rescue StandardError
      false
    end

    def recording?(sound)
      return false if sound == nil
      @lock.synchronize do
        recording = @streams[sound]
        recording != nil && !recording.stopped?
      end
    end

    def recording_of(sound)
      @lock.synchronize { @streams[sound] }
    end

    # Starts recording sound into <folder>/<title>/recording NNN.mp3.
    # Returns the StreamRecording; raises when it cannot be started.
    def start_stream(sound, title)
      raise "MP3 encoder is not available" if !available?
      raise "Nothing is playing" if sound == nil || sound.closed?
      @lock.synchronize do
        existing = @streams[sound]
        return existing if existing != nil && !existing.stopped?
        channel = recording_channel(sound)
        raise "The sound has no channel" if channel == 0
        directory = File.join(folder, safe_name(title))
        path, number = next_numbered(directory, "recording ", ".mp3")
        options = KlangtenMp3.options(BITRATE, { "TITLE" => title.to_s })
        handle = KlangtenMp3.start_file.call(channel, unicode(options), BASS_UNICODE | BASS_ENCODE_AUTOFREE, unicode(path))
        raise "Cannot start the MP3 encoder: #{Bass.error_name}" if handle.to_i == 0
        recording = StreamRecording.new(handle, path, number, title.to_s)
        @streams[sound] = recording
        log(:info, "Stream recording #{number} started: #{path}")
        recording
      end
    end

    # Stops the recording of sound; returns it (nil when none was running).
    def stop_stream(sound)
      return nil if sound == nil
      recording = @lock.synchronize { @streams.delete(sound) }
      return nil if recording == nil
      recording.stop
      log(:info, "Stream recording #{recording.number} saved: #{recording.path}")
      recording
    end

    # Starts or stops recording sound and says so (UI thread).
    def toggle_stream(sound, title)
      if recording?(sound)
        announce_stopped(stop_stream(sound))
        return :stopped
      end
      if !available?
        alert(p_("Klangten", "Recording is not available on this system."))
        return nil
      end
      recording = start_stream(sound, title)
      play_sound("recording_start")
      alert(p_("Klangten", "Recording %{number}") % { number: recording.number }, false)
      :started
    rescue StandardError => e
      log(:warning, "Stream recording failed: #{e.class}: #{e.message}")
      alert(p_("Klangten", "The recording could not be started."))
      nil
    end

    def announce_stopped(recording)
      return if recording == nil
      play_sound("recording_stop")
      alert(p_("Klangten", "Recording %{number} saved") % { number: recording.number }, false)
    end

    # --------------------------------------------- microphone recording

    def microphone_recording?
      @microphone != nil
    end

    # First call starts recording from the microphone, the second one saves
    # it (UI thread; this is what the quick action and the global key call).
    def toggle_microphone
      return stop_microphone if @microphone != nil
      EltenSystemHelpers.request_microphone_access if EltenSystemHelpers.respond_to?(:request_microphone_access)
      directory = File.join(folder, "Microphone")
      mp3 = defined?(KlangtenMp3) && KlangtenMp3.available?
      path, number = next_numbered(directory, "recording ", mp3 ? ".mp3" : ".ogg")
      recorder = mp3 ? Recorder.new(path, Mp3AudioEncoder.new(BITRATE)) : Recorder.vorbis_recording(path, BITRATE)
      @microphone = [recorder, path, number]
      play_sound("recording_start")
      alert(p_("Klangten", "Recording %{number}") % { number: number }, false)
      true
    rescue StandardError => e
      @microphone = nil
      log(:warning, "Microphone recording failed: #{e.class}: #{e.message}")
      alert(p_("Klangten", "The recording could not be started."))
      false
    end

    def stop_microphone
      recorder, path, number = @microphone
      @microphone = nil
      return false if recorder == nil
      begin
        recorder.stop
      rescue StandardError => e
        log(:warning, "Microphone recording could not be finished: #{e.class}: #{e.message}")
      end
      play_sound("recording_stop")
      if File.file?(path) && File.size(path) > 0
        alert(p_("Klangten", "Recording %{number} saved") % { number: number }, false)
      else
        File.delete(path) if File.exist?(path) rescue nil
        alert(p_("Klangten", "The recording could not be saved."), false)
      end
      true
    end

    private

    # The channel whose sound the user hears: the output stream when the sound
    # runs through Klangten's effect pipeline, otherwise its own channel.
    def recording_channel(sound)
      output = sound.instance_variable_get(:@playback_channel).to_i
      output = sound.channel.to_i if output == 0
      output
    end

    def mobile?
      %w[ios android].include?(EltenSystemHelpers.platform_os.to_s)
    rescue StandardError
      false
    end

    def log(level, message)
      Log.__send__(level, message) if defined?(Log) && Log.respond_to?(level)
    rescue StandardError
      nil
    end
  end
end
