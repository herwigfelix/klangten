# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Ruby binding for Klangten's Spotify library (ext/klangten_spotify, built on
# librespot).
#
# The library does everything that talks to Spotify: the browser login,
# search, the user's library and playlists, artists, albums, shows, and the
# playback itself, which it decodes to 44.1 kHz stereo float PCM. It has no
# speaker: KlangtenSpotify::Player pulls that PCM (ks_read_pcm) on its own
# thread and hands it to an audio sink - in Klangten a BASS push stream
# (src/eapi/spotify_host.rb). Spotify audio goes nowhere else: it is neither
# cached on disk nor offered for recording or saving.
#
# Queries block (up to about 40 seconds on a bad connection). Fiddle releases
# the GVL during the call, so they run on worker threads (Client#call_async)
# and the user interface stays responsive.
#
# This file has no Elten dependencies, so it can be tested headlessly with a
# fake library and a fake sink (test/spotify_test.rb). Paths, BASS, the
# protected credential storage and the scenes live in
# src/eapi/spotify_host.rb and src/scenes/spotify.rb.

require "fiddle"
require "json"
require "thread"

module KlangtenSpotify
  class Error < StandardError; end

  # Version of the C ABI this binding was written for (ffi.rs: ABI_VERSION).
  ABI_VERSION = 1
  SAMPLE_RATE = 44_100
  CHANNELS = 2
  BYTES_PER_FRAME = CHANNELS * 4

  # Login states reported by the library.
  STATE_LOGGED_OUT = "loggedout".freeze
  STATE_LOGGING_IN = "loggingin".freeze
  STATE_OK = "ok".freeze
  STATE_NO_PREMIUM = "nopremium".freeze
  STATE_FAILED = "failed".freeze
  STATE_UNAVAILABLE = "unavailable".freeze
  FINAL_STATES = [STATE_OK, STATE_FAILED, STATE_LOGGED_OUT, STATE_NO_PREMIUM, STATE_UNAVAILABLE].freeze

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rescue StandardError
    Time.now.to_f
  end

  # A track (or an episode of a show) as the library lists it.
  Track = Struct.new(:uri, :title, :artist, :album, :duration, :artist_uri, :album_uri, keyword_init: true) do
    def self.from(hash)
      hash = {} unless hash.is_a?(Hash)
      new(
        uri: hash["uri"].to_s, title: hash["title"].to_s, artist: hash["artist"].to_s,
        album: hash["album"].to_s, duration: hash["duration"].to_i,
        artist_uri: hash["artist_uri"].to_s, album_uri: hash["album_uri"].to_s
      )
    end

    # "Artist - Title", or the title alone (chapters of audiobooks have no artist).
    def label
      t = title.to_s == "" ? uri.to_s : title.to_s
      artist.to_s == "" ? t : "#{artist} - #{t}"
    end

    def episode?
      uri.to_s.start_with?("spotify:episode:")
    end

    # Duration in seconds.
    def seconds
      duration.to_i / 1000.0
    end
  end

  # One row of the typed search: kind is track, artist, album, playlist,
  # audiobook or podcast.
  SearchRow = Struct.new(:kind, :uri, :name, :sub, :duration, :artist_uri, :album_uri, keyword_init: true) do
    def self.from(hash)
      hash = {} unless hash.is_a?(Hash)
      new(
        kind: hash["kind"].to_s, uri: hash["uri"].to_s, name: hash["name"].to_s, sub: hash["sub"].to_s,
        duration: hash["duration"].to_i, artist_uri: hash["artist_uri"].to_s, album_uri: hash["album_uri"].to_s
      )
    end

    def track?
      kind == "track"
    end

    def to_track
      Track.new(uri: uri, title: name, artist: sub, album: "", duration: duration, artist_uri: artist_uri, album_uri: album_uri)
    end
  end

  Named = Struct.new(:uri, :name, keyword_init: true) do
    def self.from(hash)
      hash = {} unless hash.is_a?(Hash)
      new(uri: hash["uri"].to_s, name: hash["name"].to_s)
    end
  end

  # An album, an audiobook or a podcast: its tracks, chapters or episodes.
  Collection = Struct.new(:uri, :name, :artist, :tracks, keyword_init: true) do
    def self.from(hash)
      return nil unless hash.is_a?(Hash)
      new(uri: hash["uri"].to_s, name: hash["name"].to_s, artist: hash["artist"].to_s,
          tracks: Array(hash["tracks"]).map { |t| Track.from(t) })
    end
  end

  Artist = Struct.new(:uri, :name, :biography, :top, :albums, :related, keyword_init: true) do
    def self.from(hash)
      return nil unless hash.is_a?(Hash)
      new(uri: hash["uri"].to_s, name: hash["name"].to_s, biography: hash["biography"].to_s,
          top: Array(hash["top"]).map { |t| Track.from(t) },
          albums: Array(hash["albums"]).map { |a| Named.from(a) },
          related: Array(hash["related"]).map { |a| Named.from(a) })
    end

    # The biography comes with HTML links.
    def plain_biography
      text = biography.to_s.gsub(/<[^>]*>/, "")
      { "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&#39;" => "'", "&nbsp;" => " " }.each { |k, v| text = text.gsub(k, v) }
      text.strip
    end
  end

  NowPlaying = Struct.new(:uri, :title, :artist, :album, :duration, :position, :state, keyword_init: true) do
    def self.from(hash)
      hash = {} unless hash.is_a?(Hash)
      new(uri: hash["uri"].to_s, title: hash["title"].to_s, artist: hash["artist"].to_s, album: hash["album"].to_s,
          duration: hash["duration"].to_i, position: hash["position"].to_i, state: hash["state"].to_s)
    end
  end

  # Thin Fiddle wrapper around the C ABI of ext/klangten_spotify/src/ffi.rs.
  class Library
    ENV_PATH = "KLANGTEN_SPOTIFY_LIB".freeze

    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID
    P = Fiddle::TYPE_VOIDP
    LL = Fiddle::TYPE_LONG_LONG

    SIGNATURES = {
      "ks_abi_version" => [[], I],
      "ks_init" => [[P, P], I],
      "ks_free_string" => [[P], V],
      "ks_login" => [[], P],
      "ks_status" => [[], P],
      "ks_has_login" => [[], I],
      "ks_logout" => [[], V],
      "ks_set_credentials" => [[P], I],
      "ks_credentials" => [[], P],
      "ks_credentials_serial" => [[], LL],
      "ks_set_login_page" => [[P], V],
      "ks_cancel_login" => [[], V],
      "ks_search" => [[P, LL], P],
      "ks_search_typed" => [[P, LL], P],
      "ks_library" => [[LL], P],
      "ks_playlists" => [[LL], P],
      "ks_playlist_tracks" => [[P, LL], P],
      "ks_track_radio" => [[P, LL], P],
      "ks_show" => [[P, LL], P],
      "ks_artist" => [[P, LL], P],
      "ks_album" => [[P, LL], P],
      "ks_open" => [[P, LL], LL],
      "ks_read_pcm" => [[LL, P, I], I],
      "ks_stream_finished" => [[LL], I],
      "ks_stream_get" => [[LL, P], P],
      "ks_stream_close" => [[LL], V],
      "ks_control" => [[P, LL], V],
      "ks_now_playing" => [[], P],
      "ks_test_stream" => [[I, I], LL],
      "ks_test_gate" => [[LL, I], V],
      "ks_test_shapes" => [[], P]
    }.freeze

    # File name of the library on a platform, nil where none is built.
    # Windows: x64 and x86 (tools\build-spotify.bat); macOS: Apple silicon;
    # Linux: x64 and arm64 (tools/build-spotify.sh). Not on iOS and Android:
    # neither the App Store nor Spotify's terms allow a second player there.
    def self.file_name(platform, runtime_dir = nil)
      case platform.to_s
      when "windows"
        %w[windows-x64 windows-x86].include?(runtime_dir.to_s) ? "klangten_spotify.dll" : nil
      when "osx"
        "libklangten_spotify.dylib"
      when "linux"
        %w[linux-x64 linux-arm64].include?(runtime_dir.to_s) ? "libklangten_spotify.so" : nil
      else
        nil
      end
    end

    # Candidate paths: $KLANGTEN_SPOTIFY_LIB, bin/<runtime>/, bin/.
    def self.candidates(root:, platform:, runtime_dir:)
      list = []
      env = ENV[ENV_PATH].to_s
      list << env if env != ""
      name = file_name(platform, runtime_dir)
      if name != nil
        list << File.join(root, "bin", runtime_dir.to_s, name)
        list << File.join(root, "bin", name)
      end
      list.uniq
    end

    # Returns [library, nil] or [nil, "reason"].
    def self.open(candidates)
      path = candidates.find { |candidate| File.file?(candidate) }
      return [nil, "Spotify library not available for this platform"] if path == nil
      library = new(path)
      version = library.abi_version
      return [nil, "Spotify library #{path} has ABI #{version}, expected #{ABI_VERSION}"] if version != ABI_VERSION
      [library, nil]
    rescue Fiddle::DLError, StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end

    attr_reader :path

    def initialize(path)
      @path = path
      @handle = Fiddle.dlopen(path)
      @functions = {}
      SIGNATURES.each do |name, (args, ret)|
        @functions[name] = Fiddle::Function.new(@handle[name], args, ret)
      end
    end

    def abi_version
      fn("ks_abi_version").call.to_i
    end

    # Cache directory (librespot's volume file) and log file. Only the first
    # call in a process counts.
    def init(cache_dir, log_path)
      fn("ks_init").call(cstr(cache_dir), cstr(log_path)) == 1
    end

    def login
      take_string(fn("ks_login").call)
    end

    def status
      take_string(fn("ks_status").call)
    end

    def has_login?
      fn("ks_has_login").call == 1
    end

    def logout
      fn("ks_logout").call
    end

    # true when the library accepted them.
    def set_credentials(json)
      fn("ks_set_credentials").call(cstr(json.to_s)) == 1
    end

    def credentials
      take_string(fn("ks_credentials").call)
    end

    def credentials_serial
      fn("ks_credentials_serial").call.to_i
    end

    def login_page=(html)
      fn("ks_set_login_page").call(cstr(html.to_s))
    end

    def cancel_login
      fn("ks_cancel_login").call
    end

    def search(query, limit = 0)
      take_json(fn("ks_search").call(cstr(query), limit.to_i), [])
    end

    def search_typed(query, limit = 0)
      take_json(fn("ks_search_typed").call(cstr(query), limit.to_i), [])
    end

    def library(limit = 0)
      take_json(fn("ks_library").call(limit.to_i), [])
    end

    def playlists(limit = 0)
      take_json(fn("ks_playlists").call(limit.to_i), [])
    end

    def playlist_tracks(uri, limit = 0)
      take_json(fn("ks_playlist_tracks").call(cstr(uri), limit.to_i), [])
    end

    def track_radio(uri, limit = 0)
      take_json(fn("ks_track_radio").call(cstr(uri), limit.to_i), [])
    end

    def show(uri, limit = 0)
      take_json(fn("ks_show").call(cstr(uri), limit.to_i), nil)
    end

    def artist(uri, limit = 0)
      take_json(fn("ks_artist").call(cstr(uri), limit.to_i), nil)
    end

    def album(uri, limit = 0)
      take_json(fn("ks_album").call(cstr(uri), limit.to_i), nil)
    end

    # Handle > 0, or 0 when the track cannot be opened.
    def open_track(uri, start_ms = 0)
      fn("ks_open").call(cstr(uri), [start_ms.to_i, 0].max).to_i
    end

    # Copies up to buffer.bytesize / 8 stereo float frames into buffer.
    # Returns the number of frames, or -1 when the stream has ended.
    def read_pcm(handle, buffer)
      fn("ks_read_pcm").call(handle.to_i, buffer, buffer.bytesize / BYTES_PER_FRAME).to_i
    end

    def stream_finished?(handle)
      fn("ks_stream_finished").call(handle.to_i) == 1
    end

    def stream_get(handle, key)
      take_string(fn("ks_stream_get").call(handle.to_i, cstr(key)))
    end

    def stream_close(handle)
      fn("ks_stream_close").call(handle.to_i)
    end

    # play | pause | stop | seek (ms) | seekrel (+-ms)
    def control(action, arg = 0)
      fn("ks_control").call(cstr(action), arg.to_i)
    end

    def now_playing
      take_json(fn("ks_now_playing").call, {})
    end

    # Test helpers of the library (no Spotify account needed).
    def test_stream(frames, done)
      fn("ks_test_stream").call(frames.to_i, done ? 1 : 0).to_i
    end

    def test_gate(handle, on)
      fn("ks_test_gate").call(handle.to_i, on ? 1 : 0)
    end

    def test_shapes
      take_json(fn("ks_test_shapes").call, {})
    end

    private

    def fn(name)
      @functions.fetch(name)
    end

    def cstr(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).delete("\0") + "\0"
    end

    def take_string(pointer)
      return "" if pointer == nil || pointer.null?
      text = pointer.to_s
      fn("ks_free_string").call(pointer)
      text.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : text.scrub("?")
    end

    def take_json(pointer, default)
      text = take_string(pointer)
      return default if text == ""
      value = JSON.parse(text)
      value == nil ? default : value
    rescue JSON::ParserError
      default
    end
  end

  # Stores the reusable Spotify credentials the library hands out. The
  # protector encrypts them (DPAPI on Windows); without one the file is only
  # readable by the user (mode 0600).
  class CredentialStore
    MAGIC = "KLSPOT1".b

    def initialize(path, protect: nil, unprotect: nil)
      @path = path
      @protect = protect
      @unprotect = unprotect
    end

    attr_reader :path

    def load
      return "" unless File.file?(@path)
      data = File.binread(@path)
      return "" unless data.start_with?(MAGIC)
      mode = data.byteslice(MAGIC.bytesize, 1)
      body = data.byteslice(MAGIC.bytesize + 1, data.bytesize).to_s
      text = case mode
             when "P" then @unprotect == nil ? nil : @unprotect.call(body)
             when "J" then body
             end
      text.to_s.dup.force_encoding(Encoding::UTF_8)
    rescue StandardError
      ""
    end

    def save(json)
      json = json.to_s
      return delete if json == ""
      protected_body = @protect == nil ? nil : @protect.call(json.b)
      data = if protected_body.is_a?(String) && protected_body.bytesize > 0
               MAGIC + "P" + protected_body.b
             else
               MAGIC + "J" + json.b
             end
      dir = File.dirname(@path)
      Dir.mkdir(dir) unless File.directory?(dir)
      temp = "#{@path}.tmp"
      File.open(temp, "wb", 0o600) { |f| f.write(data) }
      begin
        File.chmod(0o600, temp)
      rescue StandardError
        nil
      end
      File.rename(temp, @path)
      true
    rescue StandardError
      false
    end

    def delete
      File.delete(@path) if File.file?(@path)
      true
    rescue StandardError
      false
    end
  end

  # The session-wide connection to the library: login, queries and the
  # credentials kept in sync with the store.
  class Client
    QUERY_LIMIT_TRACKS = 0
    LOGIN_TIMEOUT = 320

    attr_reader :library, :store

    def initialize(library:, store: nil, logger: nil)
      @library = library
      @store = store
      @logger = logger
      @mutex = Mutex.new
      @seen_serial = library.credentials_serial
      json = store == nil ? "" : store.load
      if json != ""
        if library.set_credentials(json)
          log(:info, "Spotify: stored login loaded")
        else
          log(:warning, "Spotify: stored login unreadable, discarded")
          store.delete
        end
      end
    end

    def status
      @library.status
    end

    def logged_in?
      status == STATE_OK
    end

    def stored_login?
      @library.has_login?
    end

    # Starts the login (opens the browser when there is no stored login) and
    # returns the state at once.
    def start_login
      @library.login
    end

    def cancel_login
      @library.cancel_login
    end

    # Waits for a final state; the block is called between the checks and may
    # return :cancel. Returns the final state, or :cancelled.
    def wait_for_login(timeout: LOGIN_TIMEOUT)
      deadline = KlangtenSpotify.monotonic + timeout
      loop do
        state = status
        if FINAL_STATES.include?(state) && state != STATE_LOGGED_OUT
          sync_credentials
          return state
        end
        if block_given? && yield == :cancel
          cancel_login
          return :cancelled
        end
        return STATE_FAILED if KlangtenSpotify.monotonic >= deadline
        sleep(0.1)
      end
    end

    def logout
      @library.logout
      deadline = KlangtenSpotify.monotonic + 3
      sleep(0.05) while @library.has_login? && KlangtenSpotify.monotonic < deadline
      sync_credentials(force: true)
      @store.delete if @store != nil
    end

    # Writes the credentials to the store whenever the library changed them
    # (login, reconnect with fresh credentials, logout, account without
    # Premium). Cheap - call it often.
    def sync_credentials(force: false)
      return if @store == nil
      @mutex.synchronize do
        serial = @library.credentials_serial
        return if serial == @seen_serial && !force
        @seen_serial = serial
        json = @library.credentials
        if json == ""
          @store.delete
          log(:info, "Spotify: stored login removed")
        else
          @store.save(json)
          log(:info, "Spotify: login stored")
        end
      end
    rescue StandardError => e
      log(:warning, "Spotify: storing the login failed: #{e.class}: #{e.message}")
    end

    def search_typed(query, limit = 20)
      @library.search_typed(query, limit).map { |row| SearchRow.from(row) }
    end

    def search(query, limit = 30)
      @library.search(query, limit).map { |row| Track.from(row) }
    end

    def library_tracks
      @library.library(QUERY_LIMIT_TRACKS).map { |row| Track.from(row) }
    end

    def playlists
      @library.playlists(500).map { |row| Named.from(row) }
    end

    def playlist_tracks(uri)
      @library.playlist_tracks(uri, QUERY_LIMIT_TRACKS).map { |row| Track.from(row) }
    end

    def track_radio(uri, limit = 50)
      @library.track_radio(uri, limit).map { |row| Track.from(row) }
    end

    def show(uri)
      Collection.from(@library.show(uri, QUERY_LIMIT_TRACKS))
    end

    def album(uri)
      Collection.from(@library.album(uri, QUERY_LIMIT_TRACKS))
    end

    def artist(uri)
      Artist.from(@library.artist(uri, 50))
    end

    def now_playing
      NowPlaying.from(@library.now_playing)
    end

    # Runs a blocking library call on its own thread and waits for it while
    # checking the cancellation token (EltenAPI::Tasks): a cancelled wait
    # returns at once, the call finishes in the background and its result is
    # dropped.
    def call_async(token = nil)
      queue = Queue.new
      worker = Thread.new do
        Thread.current.report_on_exception = false
        begin
          queue << [:ok, yield]
        rescue Exception => e
          queue << [:error, e]
        end
      end
      worker.name = "spotify-call" if worker.respond_to?(:name=)
      loop do
        if token != nil && token.respond_to?(:raise_if_cancelled!)
          token.raise_if_cancelled!
        end
        result = queue.pop(timeout: 0.05)
        next if result == nil
        raise result[1] if result[0] == :error
        return result[1]
      end
    end

    private

    def log(level, message)
      @logger.call(level, message) if @logger != nil
    rescue StandardError
      nil
    end
  end

  # Plays a list of tracks through an audio sink.
  #
  # A worker thread owns the stream handle: it opens tracks (ks_open blocks
  # while the first audio arrives), pulls PCM into the sink, notices the end
  # of a track and moves on to the next one. The user interface calls the
  # public methods from any thread and collects what happened with #events
  # (announcements belong to the UI thread). It does not depend on any
  # screen, so a global media player can host it later: it needs nothing but
  # #update being called regularly.
  #
  # Sink interface: open, write(bytes), queued_bytes, pause, resume, flush,
  # volume=(0.0..1.0), close.
  class Player
    TARGET_QUEUE = (SAMPLE_RATE * BYTES_PER_FRAME * 0.35).to_i
    CHUNK_FRAMES = 4096
    SEEK_STEP = 5
    # Episodes (audiobooks, podcasts) remember where they were left; not in
    # the first or the last half minute.
    POSITION_MARGIN_MS = 30_000

    Event = Struct.new(:type, :track, :index, :detail)

    attr_reader :tracks, :index, :volume

    # positions: optional store with get(uri) -> ms, set(uri, ms), delete(uri).
    def initialize(library:, sink:, positions: nil, logger: nil, volume: 0.8)
      @library = library
      @sink = sink
      @positions = positions
      @logger = logger
      @mutex = Mutex.new
      @commands = Queue.new
      @events = Queue.new
      @tracks = []
      @index = 0
      @handle = 0
      @state = :stopped
      @paused = false
      @ended = false
      @volume = volume.to_f
      @generation = 0
      @closed = false
      @buffer = "\0".b * (CHUNK_FRAMES * BYTES_PER_FRAME)
      @thread = nil
    end

    def state
      @mutex.synchronize { @state }
    end

    def playing?
      state == :playing
    end

    def paused?
      state == :paused
    end

    def active?
      [:loading, :playing, :paused].include?(state)
    end

    def current_track
      @mutex.synchronize { @tracks[@index] }
    end

    # Starts the list at index (0-based).
    def play(tracks, index = 0)
      tracks = Array(tracks).compact
      return false if tracks.empty?
      index = [[index.to_i, 0].max, tracks.size - 1].min
      @mutex.synchronize do
        remember_position_locked
        @tracks = tracks.dup
        @index = index
        @generation += 1
        @state = :loading
        @paused = false
      end
      ensure_thread
      @commands << [:open, @generation, true]
      true
    end

    def jump(index)
      list = @mutex.synchronize { @tracks.dup }
      return false if index.to_i < 0 || index.to_i >= list.size
      play(list, index)
    end

    def next_track
      list, index = @mutex.synchronize { [@tracks.dup, @index] }
      return false if index + 1 >= list.size
      play(list, index + 1)
    end

    def previous_track
      list, index = @mutex.synchronize { [@tracks.dup, @index] }
      return false if index <= 0
      play(list, index - 1)
    end

    def toggle_pause
      paused? ? resume : pause
    end

    def pause
      @mutex.synchronize do
        return false unless @state == :playing || @state == :loading
        @state = :paused
        @paused = true
      end
      @library.control("pause", 0)
      @sink.pause
      true
    end

    def resume
      @mutex.synchronize do
        return false unless @state == :paused
        @state = :playing
        @paused = false
      end
      @library.control("play", 0)
      @sink.resume
      true
    end

    def stop
      handle = nil
      @mutex.synchronize do
        remember_position_locked
        @generation += 1
        handle = @handle
        @handle = 0
        @state = :stopped
        @paused = false
      end
      @library.stream_close(handle) if handle != 0
      @library.control("stop", 0)
      @sink.flush
      true
    end

    # Relative seek in seconds (negative = back).
    def seek(seconds)
      return false unless active?
      @library.control("seekrel", (seconds.to_f * 1000).to_i)
      @sink.flush
      @sink.pause if paused?
      true
    end

    def restart_track
      return false unless active?
      @library.control("seek", 0)
      @sink.flush
      true
    end

    def volume=(value)
      @volume = [[value.to_f, 0.0].max, 1.0].min
      @sink.volume = @volume
    end

    # Position and duration of the current track in seconds.
    def position
      now = NowPlaying.from(@library.now_playing)
      track = current_track
      return 0.0 if track == nil || now.uri != track.uri
      now.position / 1000.0
    end

    def duration
      track = current_track
      track == nil ? 0.0 : track.seconds
    end

    # What happened since the last call: Event(:started | :unavailable |
    # :failed | :finished, track, index).
    def events
      list = []
      loop do
        list << @events.pop(true)
      end
    rescue ThreadError
      list
    end

    def close
      stop
      @closed = true
      @commands << [:quit, nil]
      @thread.join(2) if @thread != nil && @thread != Thread.current
      @sink.close
    end

    private

    def log(level, message)
      @logger.call(level, message) if @logger != nil
    rescue StandardError
      nil
    end

    def ensure_thread
      return if @thread != nil && @thread.alive?
      @thread = Thread.new { run }
      @thread.name = "spotify-player" if @thread.respond_to?(:name=)
    end

    def run
      Thread.current.report_on_exception = false
      until @closed
        command = begin
          @commands.pop(true)
        rescue ThreadError
          nil
        end
        if command != nil
          break if command[0] == :quit
          open_current(command[1], command[2]) if command[0] == :open
          next
        end
        pump
        sleep(0.015)
      end
    rescue Exception => e
      log(:error, "Spotify player: #{e.class}: #{e.message}")
    end

    # flush: drop what the sink still holds (the user chose another track);
    # false when the previous track ended by itself and its last half second
    # is still playing.
    def open_current(generation, flush)
      old = 0
      track = nil
      start_ms = 0
      @mutex.synchronize do
        return if generation != @generation
        old = @handle
        @handle = 0
        track = @tracks[@index]
      end
      @library.stream_close(old) if old != 0
      @sink.flush if flush
      return if track == nil
      start_ms = @positions.get(track.uri).to_i if @positions != nil && track.episode?
      handle = @library.open_track(track.uri, start_ms)
      stale = false
      index = 0
      @mutex.synchronize do
        if generation != @generation
          stale = true
        else
          @handle = handle
          @ended = false
          index = @index
          if handle == 0
            @state = :stopped
          else
            @state = @paused ? :paused : :playing
          end
        end
      end
      if stale
        @library.stream_close(handle) if handle != 0
        return
      end
      if handle == 0
        @events << Event.new(:failed, track, index, nil)
        return
      end
      @positions.set_last_episode(track.uri) if @positions != nil && track.episode? && @positions.respond_to?(:set_last_episode)
      @sink.open
      @sink.volume = @volume
      @sink.resume unless paused?
      @events << Event.new(:started, track, index, nil)
    rescue StandardError => e
      log(:error, "Spotify open: #{e.class}: #{e.message}")
      @events << Event.new(:failed, track, index, e.message)
    end

    # Fills the sink up to TARGET_QUEUE; at the end of a stream waits until
    # the sink has played it out and moves on.
    def pump
      handle, generation, paused = @mutex.synchronize { [@handle, @generation, @paused] }
      return if handle == 0 || paused
      if @ended
        return if @sink.queued_bytes > 0
        finish_track(handle, generation)
        return
      end
      loops = 0
      while @sink.queued_bytes < TARGET_QUEUE && loops < 8
        loops += 1
        frames = @library.read_pcm(handle, @buffer)
        if frames < 0
          @ended = true
          return
        end
        break if frames == 0
        @sink.write(@buffer.byteslice(0, frames * BYTES_PER_FRAME))
      end
    end

    def finish_track(handle, generation)
      state = @library.stream_get(handle, "state")
      track = nil
      index = 0
      advance = false
      @mutex.synchronize do
        return if generation != @generation
        track = @tracks[@index]
        index = @index
        @positions.delete(track.uri) if @positions != nil && track != nil && track.episode? && state != STATE_UNAVAILABLE
        @library.stream_close(handle)
        @handle = 0
        if state == STATE_UNAVAILABLE
          @state = :stopped
        elsif @index + 1 < @tracks.size
          @index += 1
          @generation += 1
          generation = @generation
          @state = :loading
          advance = true
        else
          @state = :stopped
        end
      end
      if state == STATE_UNAVAILABLE
        @events << Event.new(:unavailable, track, index, nil)
      elsif advance
        @commands << [:open, generation, false]
      else
        @events << Event.new(:finished, track, index, nil)
      end
    end

    # Remembers where an episode was left (called with @mutex held).
    def remember_position_locked
      return if @positions == nil || @handle == 0
      track = @tracks[@index]
      return if track == nil || !track.episode?
      now = NowPlaying.from(@library.now_playing)
      return if now.uri != track.uri
      pos = now.position
      dur = now.duration > 0 ? now.duration : track.duration
      if pos > POSITION_MARGIN_MS && (dur <= 0 || pos < dur - POSITION_MARGIN_MS)
        @positions.set(track.uri, pos)
      else
        @positions.delete(track.uri)
      end
    rescue StandardError
      nil
    end
  end
end
