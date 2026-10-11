# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Spotify core without Klangten around it: the C ABI of the real library
# (when it is built: tools/build-spotify.sh), the credential store, the
# client and the player with test doubles. No Spotify account and no network
# are needed.
#
#   ruby test/unit/test_spotify_core.rb
#   KLANGTEN_SPOTIFY_LIB=/path/to/klangten_spotify.dll ruby test/unit/test_spotify_core.rb

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../../src/eapi/spotify"
require_relative "../support/fake_spotify"

module SpotifyTestHelpers
  def wait_until(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise Minitest::Assertion, "condition not met within #{timeout} s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.01)
    end
  end

  def collect_events(player, until_type, timeout = 5)
    events = []
    wait_until(timeout) do
      events.concat(player.events)
      events.any? { |e| e.type == until_type }
    end
    events
  end
end

# The real library, loaded through Fiddle like Klangten does.
class SpotifyLibraryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def library_path
    env = ENV["KLANGTEN_SPOTIFY_LIB"].to_s
    return env if env != ""
    runtime = case RUBY_PLATFORM
              when /darwin/ then "osx"
              when /mingw|mswin/ then [nil].pack("p").bytesize == 8 ? "windows-x64" : "windows-x86"
              when /linux/ then RUBY_PLATFORM.include?("aarch64") ? "linux-arm64" : "linux-x64"
              end
    platform = runtime.to_s.split("-").first
    KlangtenSpotify::Library.candidates(root: ROOT, platform: platform, runtime_dir: runtime).find { |p| File.file?(p) }
  end

  def setup
    path = library_path
    skip("Spotify library not built (tools/build-spotify.sh)") if path == nil
    @@library ||= begin
      library, error = KlangtenSpotify::Library.open([path])
      raise error if library == nil
      library.init(Dir.mktmpdir("klangten-spotify-cache"), "")
      library
    end
    @library = @@library
  end

  def test_abi_and_state_without_login
    assert_equal KlangtenSpotify::ABI_VERSION, @library.abi_version
    assert_includes [KlangtenSpotify::STATE_LOGGED_OUT, KlangtenSpotify::STATE_FAILED], @library.status
    refute @library.has_login?
    assert_equal "", @library.credentials
    assert_equal "", KlangtenSpotify::NowPlaying.from(@library.now_playing).state
  end

  def test_queries_without_login_come_back_empty
    assert_equal [], @library.search_typed("kraftwerk", 3)
    assert_nil @library.album("spotify:album:x")
    assert_equal 0, @library.open_track("spotify:track:2TpxZ7JUBn3uw46aR7qd6V")
    @library.control("stop", 0)
    @library.cancel_login
  end

  def test_json_shapes_parse_into_structs
    shapes = @library.test_shapes
    track = KlangtenSpotify::Track.from(shapes["tracks"].first)
    assert_equal "Kraftwerk - Das Model", track.label
    assert_equal 219_606, track.duration
    assert_equal "spotify:album:b", track.album_uri
    row = KlangtenSpotify::SearchRow.from(shapes["rows"].first)
    assert row.track?
    assert_equal "Das Model", row.to_track.title
    assert_equal "Lieblinge", KlangtenSpotify::Named.from(shapes["playlists"].first).name
    album = KlangtenSpotify::Collection.from(shapes["album"])
    assert_equal 1, album.tracks.size
    artist = KlangtenSpotify::Artist.from(shapes["artist"])
    assert_equal "Kraftwerk aus Düsseldorf", artist.plain_biography
    assert_equal "Neu!", artist.related.first.name
    assert_nil KlangtenSpotify::Collection.from(shapes["none"])
    assert_equal "playing", KlangtenSpotify::NowPlaying.from(shapes["now"]).state
  end

  def test_pcm_stream_reads_frames_then_ends
    handle = @library.test_stream(1000, true)
    assert_operator handle, :>, 0
    buffer = "\0".b * (600 * KlangtenSpotify::BYTES_PER_FRAME)
    assert_equal 600, @library.read_pcm(handle, buffer)
    assert_in_delta 0.001, buffer.byteslice(4, 4).unpack1("e"), 1e-6
    assert_equal 400, @library.read_pcm(handle, buffer)
    assert_equal(-1, @library.read_pcm(handle, buffer))
    assert @library.stream_finished?(handle)
    @library.stream_close(handle)
    assert_equal(-1, @library.read_pcm(handle, buffer))
  end

  def test_seek_gate_gives_silence
    handle = @library.test_stream(1000, false)
    @library.test_gate(handle, true)
    buffer = "\0".b * (100 * KlangtenSpotify::BYTES_PER_FRAME)
    assert_equal 0, @library.read_pcm(handle, buffer)
    @library.stream_close(handle)
  end

  def test_credentials_round_trip
    refute @library.set_credentials("not json")
    json = JSON.generate("username" => "someone", "auth_type" => 1, "auth_data" => "c2VjcmV0")
    assert @library.set_credentials(json)
    assert @library.has_login?
    back = JSON.parse(@library.credentials)
    assert_equal "someone", back["username"]
    assert_equal "c2VjcmV0", back["auth_data"]
    assert @library.set_credentials("")
    refute @library.has_login?
  end

  def test_login_page_can_be_set
    @library.login_page = "<p>ok</p>"
  end
end

class SpotifyCredentialStoreTest < Minitest::Test
  def test_plain_file_only_for_the_user
    Dir.mktmpdir do |dir|
      store = KlangtenSpotify::CredentialStore.new(File.join(dir, "spotify", "login.dat"))
      assert_equal "", store.load
      assert store.save("{\"a\":1}")
      assert_equal "{\"a\":1}", store.load
      assert_equal 0o600, File.stat(store.path).mode & 0o777 unless Gem.win_platform?
      assert store.delete
      assert_equal "", store.load
    end
  end

  def test_protected_file
    Dir.mktmpdir do |dir|
      protect = ->(data) { data.reverse }
      unprotect = ->(data) { data.reverse }
      store = KlangtenSpotify::CredentialStore.new(File.join(dir, "login.dat"), protect: protect, unprotect: unprotect)
      store.save("{\"secret\":\"x\"}")
      refute_includes File.binread(store.path), "secret\""
      assert_equal "{\"secret\":\"x\"}", store.load
      other = KlangtenSpotify::CredentialStore.new(File.join(dir, "login.dat"))
      assert_equal "", other.load, "a protected file needs the protector"
    end
  end

  def test_garbage_is_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, "login.dat")
      File.binwrite(path, "nonsense")
      assert_equal "", KlangtenSpotify::CredentialStore.new(path).load
    end
  end
end

class SpotifyClientTest < Minitest::Test
  include SpotifyTestHelpers

  def store(dir)
    KlangtenSpotify::CredentialStore.new(File.join(dir, "login.dat"))
  end

  def test_login_stores_credentials_and_logout_removes_them
    Dir.mktmpdir do |dir|
      library = FakeSpotify::Library.new
      client = KlangtenSpotify::Client.new(library: library, store: store(dir))
      refute client.stored_login?
      client.start_login
      assert_equal KlangtenSpotify::STATE_OK, client.wait_for_login(timeout: 5)
      assert client.logged_in?
      assert_includes store(dir).load, "auth_data"
      client.logout
      assert_equal "", store(dir).load
      refute client.stored_login?
    end
  end

  def test_stored_login_is_handed_to_the_library
    Dir.mktmpdir do |dir|
      store(dir).save(JSON.generate("username" => "u", "auth_type" => 1, "auth_data" => "eA=="))
      library = FakeSpotify::Library.new
      client = KlangtenSpotify::Client.new(library: library, store: store(dir))
      assert client.stored_login?
    end
  end

  def test_unreadable_stored_login_is_discarded
    Dir.mktmpdir do |dir|
      store(dir).save("garbage")
      library = FakeSpotify::Library.new
      KlangtenSpotify::Client.new(library: library, store: store(dir))
      assert_equal "", store(dir).load
    end
  end

  def test_no_premium_and_failure_are_final
    library = FakeSpotify::Library.new(login_result: "nopremium")
    client = KlangtenSpotify::Client.new(library: library)
    client.start_login
    assert_equal KlangtenSpotify::STATE_NO_PREMIUM, client.wait_for_login(timeout: 5)
    library.login_result = "failed"
    client.start_login
    assert_equal KlangtenSpotify::STATE_FAILED, client.wait_for_login(timeout: 5)
  end

  def test_waiting_can_be_cancelled
    library = FakeSpotify::Library.new
    library.login_delay = 10
    client = KlangtenSpotify::Client.new(library: library)
    client.start_login
    assert_equal :cancelled, client.wait_for_login(timeout: 5) { :cancel }
    assert_equal KlangtenSpotify::STATE_FAILED, library.status
  end

  def test_queries_return_structs
    client = KlangtenSpotify::Client.new(library: FakeSpotify::Library.new)
    rows = client.search_typed("kraftwerk")
    assert_equal %w[track artist audiobook], rows.map(&:kind)
    assert_equal "Lieblinge", client.playlists.first.name
    assert_equal 3, client.library_tracks.size
    assert_equal 2, client.show("spotify:show:h").tracks.size
    assert client.show("spotify:show:h").tracks.first.episode?
    assert_equal "Kraftwerk", client.artist("spotify:artist:k").name
  end

  class Token
    def initialize
      @cancelled = false
    end

    def cancel!
      @cancelled = true
    end

    def raise_if_cancelled!
      raise Interrupt, "cancelled" if @cancelled
    end
  end

  def test_call_async_returns_value_and_can_be_abandoned
    client = KlangtenSpotify::Client.new(library: FakeSpotify::Library.new)
    assert_equal 42, client.call_async(nil) { 42 }
    assert_raises(ArgumentError) { client.call_async(nil) { raise ArgumentError, "x" } }
    token = Token.new
    Thread.new { sleep(0.1); token.cancel! }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Interrupt) { client.call_async(token) { sleep(5); 1 } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end
end

class SpotifyPlayerTest < Minitest::Test
  include SpotifyTestHelpers

  def setup
    @library = FakeSpotify::Library.new
    @sink = FakeSpotify::Sink.new
    @tracks = FakeSpotify::TRACKS.map { |t| KlangtenSpotify::Track.from(t) }
  end

  def teardown
    @player&.close
  end

  def player(positions: nil)
    @player ||= KlangtenSpotify::Player.new(library: @library, sink: @sink, positions: positions)
  end

  def test_plays_the_list_to_the_end
    player.play(@tracks, 1)
    events = collect_events(player, :finished)
    assert_equal [:started, :started, :finished], events.map(&:type)
    assert_equal ["Neonlicht", "Hallogallo"], events.first(2).map { |e| e.track.title }
    assert_equal [1, 2], events.first(2).map(&:index)
    assert_equal %w[spotify:track:2 spotify:track:3], @library.opened.map(&:first)
    assert_equal 2 * @library.frames_per_track * KlangtenSpotify::BYTES_PER_FRAME, @sink.bytes
    assert_equal :stopped, player.state
  end

  def test_pause_resume_seek_and_stop
    @library.frames_per_track = 44_100 * 60
    player.play(@tracks, 0)
    collect_events(player, :started)
    assert player.playing?
    assert player.pause
    assert player.paused?
    assert_includes @sink.calls, :pause
    assert player.seek(5)
    assert player.resume
    assert player.playing?
    assert player.seek(-5)
    player.volume = 0.5
    assert_in_delta 0.5, @sink.volume
    player.stop
    refute player.active?
    actions = @library.controls.map(&:first)
    assert_equal %w[pause seekrel play seekrel stop], actions
    assert_equal [5000, -5000], @library.controls.select { |c| c[0] == "seekrel" }.map(&:last)
  end

  def test_next_and_previous
    @library.frames_per_track = 44_100 * 60
    player.play(@tracks, 0)
    collect_events(player, :started)
    assert player.next_track
    events = collect_events(player, :started)
    assert_equal "Neonlicht", events.last.track.title
    assert player.previous_track
    events = collect_events(player, :started)
    assert_equal "Das Model", events.last.track.title
    refute player.previous_track
    player.jump(2)
    collect_events(player, :started)
    refute player.next_track
  end

  def test_unavailable_track_stops_with_an_event
    @library.unavailable_uris << "spotify:track:1"
    player.play(@tracks, 0)
    events = collect_events(player, :unavailable)
    assert_equal "Das Model", events.last.track.title
    refute player.active?
  end

  def test_track_that_cannot_be_opened
    @library.unopenable_uris << "spotify:track:1"
    player.play(@tracks, 0)
    events = collect_events(player, :failed)
    assert_equal "Das Model", events.last.track.title
  end

  class MemoryPositions
    attr_reader :data, :last

    def initialize
      @data = {}
    end

    def get(uri) = @data[uri].to_i
    def set(uri, ms) = (@data[uri] = ms)
    def delete(uri) = @data.delete(uri)
    def set_last_episode(uri) = (@last = uri)
  end

  def test_episodes_remember_and_resume_their_position
    positions = MemoryPositions.new
    episodes = FakeSpotify::EPISODES.map { |t| KlangtenSpotify::Track.from(t) }
    @library.frames_per_track = 44_100 * 600
    player(positions: positions).play(episodes, 0)
    collect_events(player, :started)
    assert_equal "spotify:episode:a", positions.last
    @library.position_ms = 120_000
    player.stop
    assert_equal 120_000, positions.get("spotify:episode:a")
    player.play(episodes, 0)
    collect_events(player, :started)
    assert_equal ["spotify:episode:a", 120_000], @library.opened.last
    @library.position_ms = 5_000
    player.stop
    assert_equal 0, positions.get("spotify:episode:a"), "the first half minute is not remembered"
  end

  def test_music_starts_from_the_beginning
    positions = MemoryPositions.new
    positions.set("spotify:track:1", 50_000)
    player(positions: positions).play(@tracks, 0)
    collect_events(player, :started)
    assert_equal ["spotify:track:1", 0], @library.opened.last
  end
end
