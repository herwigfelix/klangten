# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The Spotify screens with a double of the library (test/support/fake_spotify.rb):
# sign-in, search, lists in Klangten's playlist, artist page, audiobooks and
# signing out. Neither the real library nor a Spotify account is needed (the real
# library's C ABI is covered by test/unit/test_spotify_core.rb); the sign-in
# in a real browser and real playback need an account with Spotify Premium.

require_relative "../test_helper"
require_relative "../support/fake_spotify"

class SpotifyFlowTest < KlangtenTest::FlowTest
  ENGINE = 3600
  # Starts Scene_Spotify on the fake library. long: tracks that keep playing
  # (otherwise the fake plays each track in a moment).
  def spotify(library = FakeSpotify::Library.new, long: false)
    @library = library
    library.frames_per_track = 44_100 * 600 if long
    k = klangten
    KlangtenSpotify.library_override = library
    # The player's worker thread and the playlist's engine are services, not
    # work the interface waits for. They run in real time: waits for what
    # they do get a long virtual timeout (ENGINE), the real one stays.
    KlangtenTest::Runtime.add_frame_hook do
      thread = KlangtenSpotify.player? ? KlangtenSpotify.player.instance_variable_get(:@thread) : nil
      KlangtenTest::Runtime.register(thread, :bg) if thread != nil && KlangtenTest::Runtime.kind(thread) != :bg
      Thread.list.each do |t|
        KlangtenTest::Runtime.register(t, :bg) if t.name == "klangten-playlist" && KlangtenTest::Runtime.kind(t) != :bg
      end
    end
    k.start do
      $scene = Scene_Spotify.new
      $scene.main
    end
    k.settle
    k
  end

  def login_file(k)
    File.join(k.data_dir, "spotify", "login.dat")
  end

  def test_sign_in_through_the_browser_stores_the_login
    k = spotify
    k.expect("sign in with your Spotify account")
    k.press("enter")
    k.wait_for("Connected to Spotify.")
    k.expect("Search")
    assert_includes File.binread(login_file(k)), "auth_data"
  end

  def test_declining_the_sign_in_leaves_spotify
    k = spotify
    k.press("escape")
    assert k.finished?
    refute File.file?(login_file(k))
  end

  def test_account_without_premium_is_explained
    k = spotify(FakeSpotify::Library.new(login_result: "nopremium"))
    k.press("enter")
    k.wait_for("no Premium subscription")
  end

  def test_failed_sign_in
    k = spotify(FakeSpotify::Library.new(login_result: "failed"))
    k.press("enter")
    k.wait_for("Signing in to Spotify failed")
  end

  def test_search_plays_a_track_with_similar_ones
    k = spotify(FakeSpotify::Library.new(stored: true), long: true)
    k.wait_for("Connected to Spotify.")
    k.press("enter")
    k.expect("Search Spotify")
    k.type("kraftwerk")
    k.press("enter")
    k.wait_for("Results for kraftwerk")
    k.expect("Track: Das Model - Kraftwerk")
    k.press("enter")
    # like in Klango: the list opens in Klangten's playlist, on the track that plays
    k.wait_for("Similar to Kraftwerk - Das Model")
    k.expect("Kraftwerk - Das Model")
    k.wait_until(timeout: ENGINE) { @library.opened.first == ["spotify:track:1", 0] }
    k.press("space")
    k.wait_for("Paused")
    assert_equal :paused, k.call { KlangtenSpotify.player.state }
    k.press("space")
    k.wait_until(timeout: ENGINE) { KlangtenSpotify.player.state == :playing }
    k.press("down")
    k.expect("Kraftwerk - Neonlicht")
    k.press("enter")
    k.wait_until(timeout: ENGINE) { @library.opened.last.first == "spotify:track:2" }
    k.press("right")
    k.wait_until(timeout: ENGINE) { @library.controls.any? { |c| c[0] == "seekrel" && c[1].between?(4900, 5000) } }
    # tempo, pitch and balance like in Klangten's player
    k.press("ctrl+up")
    k.press("ctrl+up")
    assert_equal 4.0, k.call { KlangtenSpotify.player.tempo }
    k.press("shift+up")
    assert_in_delta 44_100 + 176.4, k.call { KlangtenSpotify.player.frequency }, 0.01
    k.press("shift+right")
    assert_in_delta 0.02, k.call { KlangtenSpotify.player.pan }, 0.001
    k.press("backspace")
    assert_equal [0.0, 44_100.0, 0.0], k.call { [KlangtenSpotify.player.tempo, KlangtenSpotify.player.frequency, KlangtenSpotify.player.pan] }
    # Alt (Option) with the arrows moves the item, Shift is pitch now
    k.press("alt+up")
    assert_equal "spotify:track:2", k.call { KlangtenPlaylist.current_list.entries.first.location }
    # Spotify's lists are not saved
    refute k.call { KlangtenPlaylist.current_list.internal? }
    assert k.call { KlangtenPlaylist.current_list.unsaveable }
    k.press("escape")
    k.wait_for("Results for kraftwerk")
    assert KlangtenSpotify.player.active?, "playback continues in the lists"
    k.press("escape", "escape", "escape")
    k.wait_until { k.finished? }
    assert KlangtenSpotify.player.active?, "playback continues in the background, like in Klango"
    k.call { KlangtenPlaylist.stop }
  end

  def test_nothing_found
    k = spotify(FakeSpotify::Library.new(stored: true))
    k.wait_for("Connected to Spotify.")
    k.press("enter")
    k.type("nichts")
    k.press("enter")
    k.wait_for("Nothing was found.")
  end

  def test_liked_songs_play_to_the_end
    k = spotify(FakeSpotify::Library.new(stored: true))
    k.wait_for("Connected to Spotify.")
    k.press("down")
    k.expect("Liked songs")
    k.press("enter")
    k.wait_for("Liked songs: Kraftwerk - Das Model")
    k.press("down")
    k.press("enter")
    k.wait_for("Liked songs")
    k.call { KlangtenPlaylist.repeat = false }
    k.wait_until(timeout: ENGINE) { @library.opened.size >= 2 && KlangtenPlaylist.current_entry == nil }
    assert_equal %w[spotify:track:2 spotify:track:3], @library.opened.map(&:first)
  end

  def test_artist_page
    k = spotify(FakeSpotify::Library.new(stored: true))
    k.wait_for("Connected to Spotify.")
    k.press("enter")
    k.type("kraftwerk")
    k.press("enter")
    k.wait_for("Results for kraftwerk")
    k.press("down")
    k.expect("Artist: Kraftwerk")
    k.press("enter")
    k.wait_for("Popular tracks")
    k.press("tab")
    k.expect("Albums")
    k.press("tab")
    k.expect("Related artists")
    k.press("tab")
    k.expect("Biography")
  end

  def test_audiobook_resumes_where_it_was_left
    k = spotify(FakeSpotify::Library.new(stored: true), long: true)
    k.wait_for("Connected to Spotify.")
    k.press("enter")
    k.type("hoerbuch")
    k.press("enter")
    k.wait_for("Results for hoerbuch")
    k.press("down", "down")
    k.expect("Audiobook: Hörbuch - Sprecher")
    k.press("enter")
    k.wait_for("Kapitel 1")
    k.press("down")
    k.press("enter")
    k.wait_for("Kapitel 2")
    @library.position_ms = 600_000
    k.press("escape")
    k.press("escape")
    k.wait_for("Results for hoerbuch")
    k.press("enter")
    k.wait_for("Resume: Kapitel 2")
    k.press("enter")
    k.wait_for("Kapitel 2")
    k.wait_until(timeout: ENGINE) { @library.opened.size >= 2 }
    assert_operator @library.opened.last[1], :>=, 600_000, @library.opened.inspect
  end

  def test_track_that_spotify_does_not_play
    library = FakeSpotify::Library.new(stored: true)
    library.unavailable_uris << "spotify:track:1"
    k = spotify(library)
    k.wait_for("Connected to Spotify.")
    k.press("down")
    k.press("enter")
    k.wait_for("Liked songs")
    k.press("enter")
    k.wait_for("Spotify does not play this track", timeout: ENGINE)
  end

  def test_sign_out_forgets_the_login
    k = spotify(FakeSpotify::Library.new(stored: true))
    k.wait_for("Connected to Spotify.")
    k.press("down", "down", "down")
    k.expect("Sign out of Spotify")
    k.press("enter")
    k.expect("Do you want to sign out of Spotify?")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    k.wait_for("You have signed out of Spotify.")
    refute File.file?(login_file(k))
  end

  # The BASS push stream the real player writes to (BASS runs on its "no
  # sound" device in tests).
  def test_bass_sink_queues_and_flushes_float_pcm
    k = klangten
    result = nil
    k.start do
      sink = KlangtenSpotify::BassSink.new(volume_scale: -> { 1.0 })
      sink.open
      sink.volume = 0.5
      sink.pause
      sink.write("\x00".b * (KlangtenSpotify::SAMPLE_RATE * KlangtenSpotify::BYTES_PER_FRAME / 2))
      queued = sink.queued_bytes
      sink.flush
      after_flush = sink.queued_bytes
      sink.close
      result = [queued, after_flush]
    end
    k.settle
    queued, after_flush = result
    assert_operator queued, :>, 0
    assert_equal 0, after_flush
  end
end
