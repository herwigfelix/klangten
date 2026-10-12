# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klangten's side of Spotify (src/eapi/spotify.rb): where the library and the
# data live, the BASS push stream the player writes to, the protected
# credential file and the remembered positions of audiobooks and podcasts.
#
# Everything is created on first use, so a Klangten without the library (iOS,
# Android, a build without Rust) loses nothing but the menu entry.

require "json"
require_relative "spotify" unless defined?(::KlangtenSpotify::Library)

module KlangtenSpotify
  # Spotify PCM (44.1 kHz, stereo, 32-bit float) -> a push stream of the
  # sound engine, played through a tempo stream, so that tempo, pitch and
  # balance work like in every other player of Klangten.
  class BassSink
    DEFAULT_FREQUENCY = SAMPLE_RATE

    attr_reader :tempo, :frequency, :pan

    def initialize(volume_scale: nil)
      @handle = 0
      @source = 0
      @mutex = Mutex.new
      @volume = 0.8
      @volume_scale = volume_scale
      @tempo = 0.0
      @frequency = DEFAULT_FREQUENCY.to_f
      @pan = 0.0
    end

    # Tempo in percent (0 = normal), frequency in Hz (playback rate: pitch
    # and speed), pan -1..1 - the same scales as Sound#tempo/frequency/pan.
    def tempo=(value)
      @tempo = value.to_f
      @mutex.synchronize { apply_effects_locked }
    end

    def frequency=(value)
      @frequency = value.to_f
      @mutex.synchronize { apply_effects_locked }
    end

    def pan=(value)
      @pan = [[value.to_f, -1.0].max, 1.0].min
      @mutex.synchronize { apply_effects_locked }
    end

    def open
      @mutex.synchronize { open_locked }
    end

    def write(bytes)
      @mutex.synchronize do
        open_locked if @handle == 0
        return if @handle == 0
        if Bass::BASS_StreamPutData.call(@source, bytes, bytes.bytesize).to_i < 0
          # The output device was reinitialised (settings): open a new stream.
          Log.warning("Spotify audio stream lost: #{Bass.error_name}") if defined?(Log)
          @handle = 0
        end
      end
    rescue Exception => e
      Log.error("Spotify audio write: #{e.class}: #{e.message}") if defined?(Log)
    end

    # Bytes not yet heard: the push stream's queue plus what already sits in
    # its playback buffer (BASS moves data from the queue into the buffer as
    # it plays).
    def queued_bytes
      @mutex.synchronize do
        return 0 if @handle == 0
        queued = Bass::BASS_StreamPutData.call(@source, nil, 0).to_i
        buffered = Bass::BASS_ChannelGetData.call(@handle, nil, 0).to_i # decoded ahead by the tempo stream
        [queued, 0].max + [buffered, 0].max
      end
    rescue Exception
      0
    end

    def pause
      @mutex.synchronize { Bass::BASS_ChannelPause.call(@handle) if @handle != 0 }
    rescue Exception
      nil
    end

    def resume
      @mutex.synchronize { Bass::BASS_ChannelPlay.call(@handle, 0) if @handle != 0 }
    rescue Exception
      nil
    end

    # Drops queued and buffered audio; keeps a paused stream paused.
    def flush
      @mutex.synchronize do
        return if @handle == 0
        active = Bass::BASS_ChannelIsActive.call(@handle).to_i
        Bass::BASS_ChannelPlay.call(@handle, 1)
        Bass::BASS_ChannelPause.call(@handle) if active != 1
      end
    rescue Exception
      nil
    end

    def volume=(value)
      @volume = value.to_f
      @mutex.synchronize { apply_volume_locked }
    end

    def close
      @mutex.synchronize do
        Bass::BASS_StreamFree.call(@handle) if @handle != 0
        Bass::BASS_StreamFree.call(@source) if @source != 0
        @handle = 0
        @source = 0
      end
    rescue Exception
      @handle = 0
      @source = 0
    end

    private

    def open_locked
      return if @handle != 0
      return unless defined?(::Bass) && Bass.respond_to?(:initialized?) && Bass.initialized?
      Bass.with_output_device(nil) do
        @source = Bass::BASS_StreamCreate.call(SAMPLE_RATE, CHANNELS, Bass::BASS_SAMPLE_FLOAT | Bass::BASS_STREAM_DECODE, Bass::STREAMPROC_PUSH, nil).to_i
        @handle = Bass::BASS_FX_TempoCreate.call(@source, Bass::BASS_SAMPLE_FLOAT).to_i if @source != 0
      end
      if @source == 0 || @handle == 0
        Log.error("Spotify audio stream: #{Bass.error_name}") if defined?(Log)
        Bass::BASS_StreamFree.call(@source) if @source != 0
        @source = 0
        @handle = 0
        return
      end
      apply_volume_locked
      apply_effects_locked
    rescue Exception => e
      @handle = 0
      Log.error("Spotify audio open: #{e.class}: #{e.message}") if defined?(Log)
    end

    def apply_effects_locked
      return if @handle == 0
      Bass::BASS_ChannelSetAttribute.call(@handle, Bass::BASS_ATTRIB_TEMPO, @tempo)
      Bass::BASS_ChannelSetAttribute.call(@handle, Bass::BASS_ATTRIB_FREQ, @frequency)
      Bass::BASS_ChannelSetAttribute.call(@handle, Bass::BASS_ATTRIB_PAN, @pan)
    rescue Exception
      nil
    end

    def apply_volume_locked
      return if @handle == 0
      scale = @volume_scale == nil ? 1.0 : @volume_scale.call.to_f
      Bass::BASS_ChannelSetAttribute.call(@handle, Bass::BASS_ATTRIB_VOL, [[@volume * scale, 0.0].max, 1.0].min)
    rescue Exception
      nil
    end
  end

  # Where audiobooks and podcasts were left, and the episode heard last
  # (it is offered as "Resume" in the episode list of its show).
  class Positions
    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @data = nil
    end

    def get(uri)
      @mutex.synchronize { data["positions"][uri.to_s].to_i }
    end

    def set(uri, ms)
      @mutex.synchronize do
        data["positions"][uri.to_s] = ms.to_i
        save_locked
      end
    end

    def delete(uri)
      @mutex.synchronize do
        next unless data["positions"].key?(uri.to_s)
        data["positions"].delete(uri.to_s)
        save_locked
      end
    end

    def set_last_episode(uri)
      @mutex.synchronize do
        next if data["last_episode"] == uri.to_s
        data["last_episode"] = uri.to_s
        save_locked
      end
    end

    def last_episode
      @mutex.synchronize { data["last_episode"].to_s }
    end

    # Index (0-based) of the chapter or episode to resume in a show, or nil.
    def resume_index(tracks)
      last = last_episode
      index = tracks.index { |t| t.uri == last } if last != ""
      index = tracks.index { |t| get(t.uri) > 0 } if index == nil
      index
    end

    private

    def data
      return @data if @data != nil
      @data = begin
        parsed = File.file?(@path) ? JSON.parse(File.read(@path, encoding: "UTF-8")) : {}
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end
      @data["positions"] = {} unless @data["positions"].is_a?(Hash)
      # Only the 200 most recent shows: nobody listens to more at once.
      @data["positions"] = @data["positions"].to_a.last(200).to_h
      @data
    end

    def save_locked
      dir = File.dirname(@path)
      Dir.mkdir(dir) unless File.directory?(dir)
      File.write(@path, JSON.generate(data))
    rescue StandardError
      nil
    end
  end

  class << self
    # Tests put a double of Library here (test/support/fake_spotify.rb)
    # before the first use.
    attr_writer :library_override

    # False on iOS and Android, where Spotify is left out, and wherever the
    # library is missing. Loads the library on the first call.
    def available?
      client != nil
    end

    def unavailable_reason
      client
      @library_error
    end

    def mobile?
      defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) && EltenBoot.platform?(:ios)
    rescue Exception
      false
    end

    def data_dir
      File.join(Dirs.eltendata, "spotify")
    end

    def client
      return @client if @checked
      @checked = true
      if mobile? && @library_override == nil
        @library_error = "Spotify is not offered on mobile devices"
        return nil
      end
      root = EltenRuntimePaths.root
      platform = EltenRuntimePaths.platform
      runtime = EltenRuntimePaths.runtime_directory_name
      if platform.to_s == "osx" && EltenRuntimePaths.architecture != "arm64" && @library_override == nil
        @library_error = "Spotify library is only built for Apple silicon"
        return nil
      end
      library, error = if @library_override != nil
                         [@library_override, nil]
                       else
                         Library.open(Library.candidates(root: root, platform: platform, runtime_dir: runtime))
                       end
      if library == nil
        @library_error = error
        Log.info("Spotify unavailable: #{error}")
        return nil
      end
      dir = data_dir
      Dir.mkdir(dir) unless File.directory?(dir)
      log_path = File.join(dir, "spotify.log")
      begin
        File.delete(log_path) if File.file?(log_path) && File.size(log_path) > 1_000_000
      rescue StandardError
        nil
      end
      library.init(File.join(dir, "cache"), log_path)
      library.login_page = login_page
      @client = Client.new(library: library, store: credential_store, logger: method(:log_message))
      Log.info("Spotify library loaded: #{library.path}")
      @client
    rescue Exception => e
      @library_error = "#{e.class}: #{e.message}"
      Log.error("Spotify setup: #{@library_error}")
      @client = nil
    end

    # The one player of the session. Playback outlives the Spotify screens
    # only while something calls #update on it (see Scene_Spotify).
    def player
      return nil if client == nil
      @player ||= Player.new(
        library: client.library,
        sink: BassSink.new(volume_scale: -> { master_volume }),
        positions: positions,
        logger: method(:log_message),
        volume: LocalConfig["SpotifyVolume", 80, type: :numeric].to_f / 100.0
      )
    end

    def player?
      @player != nil
    end

    def positions
      @positions ||= Positions.new(File.join(data_dir, "positions.json"))
    end

    def save_volume
      LocalConfig["SpotifyVolume"] = (@player.volume * 100).round if @player != nil
    rescue Exception
      nil
    end

    def credential_store
      protector = nil
      unprotector = nil
      if defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:autologin_key_encryption_supported?) &&
         EltenSystemHelpers.autologin_key_encryption_supported?
        protector = ->(data) { EltenSystemHelpers.protect_data(data, "Klangten Spotify") }
        unprotector = ->(data) { EltenSystemHelpers.unprotect_data(data, "Klangten Spotify") }
      end
      CredentialStore.new(File.join(data_dir, "login.dat"), protect: protector, unprotect: unprotector)
    end

    def master_volume
      value = Configuration.volume
      value == nil ? 1.0 : value.to_f / 100.0
    rescue Exception
      1.0
    end

    def login_page
      title = CGI.escapeHTML(p_("Spotify", "Klangten is connected to Spotify."))
      body = CGI.escapeHTML(p_("Spotify", "You can close this window and return to Klangten."))
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>Klangten</title></head><body><h1>#{title}</h1><p>#{body}</p></body></html>"
    rescue Exception
      ""
    end

    def log_message(level, message)
      case level
      when :error then Log.error(message)
      when :warning then Log.warning(message)
      else Log.info(message)
      end
    rescue Exception
      nil
    end
  end
end
