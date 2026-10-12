# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Test doubles for Spotify: a library with the interface of
# KlangtenSpotify::Library that needs no account and no network, and an
# audio sink that only counts. Used by test/unit/test_spotify_core.rb and by
# flow tests (KlangtenSpotify.library_override = FakeSpotify::Library.new).

require "json"

module FakeSpotify
  TRACKS = [
    { "uri" => "spotify:track:1", "title" => "Das Model", "artist" => "Kraftwerk", "album" => "Die Mensch-Maschine", "duration" => 219_606, "artist_uri" => "spotify:artist:k", "album_uri" => "spotify:album:m" },
    { "uri" => "spotify:track:2", "title" => "Neonlicht", "artist" => "Kraftwerk", "album" => "Die Mensch-Maschine", "duration" => 543_000, "artist_uri" => "spotify:artist:k", "album_uri" => "spotify:album:m" },
    { "uri" => "spotify:track:3", "title" => "Hallogallo", "artist" => "Neu!", "album" => "Neu!", "duration" => 600_000, "artist_uri" => "spotify:artist:n", "album_uri" => "spotify:album:n" }
  ].freeze

  EPISODES = [
    { "uri" => "spotify:episode:a", "title" => "Kapitel 1", "artist" => "", "album" => "", "duration" => 1_800_000, "artist_uri" => "", "album_uri" => "" },
    { "uri" => "spotify:episode:b", "title" => "Kapitel 2", "artist" => "", "album" => "", "duration" => 1_800_000, "artist_uri" => "", "album_uri" => "" }
  ].freeze

  class Library
    attr_accessor :login_result, :login_delay, :frames_per_track, :unavailable_uris, :unopenable_uris
    attr_reader :controls, :opened, :closed, :path, :login_page

    def initialize(login_result: "ok", stored: false)
      @path = "fake"
      @login_result = login_result
      @login_delay = 0.05
      @state = "loggedout"
      @credentials = stored ? JSON.generate("username" => "u", "auth_type" => 1, "auth_data" => "c2VjcmV0") : ""
      @serial = 0
      @frames_per_track = 44_100 / 10
      @handles = {}
      @next_handle = 1
      @controls = []
      @opened = []
      @closed = []
      @unavailable_uris = []
      @unopenable_uris = []
      @now = { "uri" => "", "position" => 0, "duration" => 0, "state" => "" }
      @mutex = Mutex.new
    end

    def init(_cache, _log) = true
    def login_page=(html)
      @login_page = html
    end

    def status
      @mutex.synchronize { @state }
    end

    def login
      @mutex.synchronize { @state = "loggingin" }
      result = @login_result
      Thread.new do
        sleep(@login_delay)
        @mutex.synchronize do
          next unless @state == "loggingin"
          @state = result
          if result == "ok"
            @credentials = JSON.generate("username" => "u", "auth_type" => 1, "auth_data" => "c2VjcmV0")
            @serial += 1
          end
        end
      end
      "loggingin"
    end

    def cancel_login
      @mutex.synchronize { @state = "failed" if @state == "loggingin" }
    end

    def has_login? = @mutex.synchronize { @credentials != "" }

    def logout
      @mutex.synchronize do
        @state = "loggedout"
        @credentials = ""
        @serial += 1
      end
    end

    def set_credentials(json)
      return false if json.to_s != "" && !json.to_s.start_with?("{")
      @mutex.synchronize { @credentials = json.to_s }
      true
    end

    def credentials = @mutex.synchronize { @credentials }
    def credentials_serial = @mutex.synchronize { @serial }

    def search_typed(query, _limit = 0)
      return [] if query.to_s == "nichts"
      [
        { "kind" => "track", "uri" => "spotify:track:1", "name" => "Das Model", "sub" => "Kraftwerk", "duration" => 219_606, "artist_uri" => "spotify:artist:k", "album_uri" => "spotify:album:m" },
        { "kind" => "artist", "uri" => "spotify:artist:k", "name" => "Kraftwerk", "sub" => "", "duration" => 0, "artist_uri" => "", "album_uri" => "" },
        { "kind" => "audiobook", "uri" => "spotify:show:h", "name" => "Hörbuch", "sub" => "Sprecher", "duration" => 0, "artist_uri" => "", "album_uri" => "" }
      ]
    end

    def search(_query, _limit = 0) = TRACKS.dup
    def library(_limit = 0) = TRACKS.dup
    def playlists(_limit = 0) = [{ "uri" => "spotify:playlist:p", "name" => "Lieblinge" }]
    def playlist_tracks(_uri, _limit = 0) = TRACKS.dup
    def track_radio(_uri, _limit = 0) = TRACKS.drop(1)
    def show(uri, _limit = 0) = { "uri" => uri, "name" => "Hörbuch", "artist" => "", "tracks" => EPISODES.dup }
    def album(uri, _limit = 0) = { "uri" => uri, "name" => "Die Mensch-Maschine", "artist" => "Kraftwerk", "tracks" => TRACKS.first(2) }

    def artist(uri, _limit = 0)
      { "uri" => uri, "name" => "Kraftwerk", "biography" => "<a href=\"x\">Kraftwerk</a> aus D&uuml;sseldorf &amp; mehr",
        "top" => TRACKS.first(2), "albums" => [{ "uri" => "spotify:album:m", "name" => "Die Mensch-Maschine" }],
        "related" => [{ "uri" => "spotify:artist:n", "name" => "Neu!" }] }
    end

    def open_track(uri, start_ms = 0)
      @mutex.synchronize do
        @opened << [uri, start_ms]
        return 0 if @unopenable_uris.include?(uri)
        handle = @next_handle
        @next_handle += 1
        state = @unavailable_uris.include?(uri) ? "unavailable" : "ok"
        @handles[handle] = { uri: uri, left: state == "ok" ? @frames_per_track : 0, state: state }
        @now = { "uri" => uri, "position" => start_ms, "duration" => 1_800_000, "state" => "playing" }
        handle
      end
    end

    def read_pcm(handle, buffer)
      @mutex.synchronize do
        stream = @handles[handle]
        return -1 if stream == nil || stream[:left] <= 0
        frames = [buffer.bytesize / 8, stream[:left]].min
        stream[:left] -= frames
        @now["position"] += frames * 1000 / 44_100
        frames
      end
    end

    def stream_finished?(handle) = @mutex.synchronize { (@handles[handle] || { left: 0 })[:left] <= 0 }

    def stream_get(handle, key)
      @mutex.synchronize do
        stream = @handles[handle]
        return "finished" if stream == nil && key == "state"
        return "" if stream == nil
        key == "state" ? (stream[:state] == "ok" && stream[:left] <= 0 ? "finished" : stream[:state]) : ""
      end
    end

    def stream_close(handle)
      @mutex.synchronize do
        @closed << handle
        @handles.delete(handle)
      end
    end

    def control(action, arg = 0)
      @mutex.synchronize { @controls << [action, arg] }
    end

    def now_playing = @mutex.synchronize { @now.dup }

    # Lets a test say where the current episode is.
    def position_ms=(ms)
      @mutex.synchronize { @now["position"] = ms }
    end
  end

  # Counts what the player would have played.
  class Sink
    attr_reader :bytes, :calls
    attr_accessor :volume, :queued, :tempo, :frequency, :pan

    def initialize
      @bytes = 0
      @calls = []
      @volume = 1.0
      @queued = 0
      @tempo = 0.0
      @frequency = 44_100.0
      @pan = 0.0
    end

    def open = (@calls << :open)
    def write(data) = (@bytes += data.bytesize)
    # 0 pretends to play everything at once; a large value holds the player
    # back (a track that keeps playing).
    def queued_bytes = @queued
    def pause = (@calls << :pause)
    def resume = (@calls << :resume)
    def flush = (@calls << :flush)
    def close = (@calls << :close)
  end
end
