# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Unit tests of the media features of Klangten 0.4: background player and its
# interplay with the playlist, quick actions, bookmarks, recordings folder and
# numbering, microphone recording, Internet Archive and the global player
# keys. Run directly (ruby test/media/units.rb) or through test/test_media.rb.

require "minitest/autorun"
require "net/http"
require "socket"
require_relative "support"

class Scene_NowPlaying; end
class Scene_Playlist
  attr_reader :file

  def initialize(file = nil)
    @file = file
  end
end
module GlobalMenu
  def self.opened?
    false
  end
end

module MediaTestReset
  def setup
    super
    Spoken.clear
    KlangtenBackgroundPlayer.stop
    KlangtenPlaylist.stop
    Sound.reset
    $test_config.clear
    $inserted_scenes.clear
    KlangtenBookmarks.path = File.join(TEST_DATA, "bookmarks-#{name}.json")
    KlangtenBookmarks.reload
    KlangtenBackgroundPlayer.take_events
  end

  def item(kind: :podcast, location: "http://media.invalid/episode.mp3", bookmark: false, title: "Episode")
    KlangtenBackgroundPlayer::Item.new(title: title, location: location, kind: kind, bookmark: bookmark)
  end

  def opened_sound
    assert wait_until { KlangtenBackgroundPlayer.sound != nil }, "the background player opened nothing"
    KlangtenBackgroundPlayer.sound
  end
end

class BackgroundPlayerTest < Minitest::Test
  include MediaTestReset

  def test_play_opens_and_plays_in_the_background
    KlangtenBackgroundPlayer.play(item)
    sound = opened_sound
    assert_equal "http://media.invalid/episode.mp3", sound.file
    assert wait_until { sound.playing? }
    assert KlangtenBackgroundPlayer.playing?
    assert_match(/Playing in the background: Episode/, KlangtenBackgroundPlayer.status_text)
  end

  def test_adopt_keeps_the_sound_and_its_position
    sound = Sound.new("http://media.invalid/radio")
    sound.play
    sound.position = 42
    KlangtenBackgroundPlayer.adopt(sound, item(kind: :radio, location: "http://media.invalid/radio"))
    assert_same sound, KlangtenBackgroundPlayer.sound
    assert_equal 42, KlangtenBackgroundPlayer.position
    assert KlangtenBackgroundPlayer.playing?
    assert_equal 1, Sound.opened.size, "no second connection"
  end

  def test_adopt_a_paused_player_stays_paused
    sound = Sound.new("a.mp3")
    KlangtenBackgroundPlayer.adopt(sound, item(kind: :file, location: "a.mp3"), paused: true)
    assert KlangtenBackgroundPlayer.paused?
    assert_equal :playing, KlangtenBackgroundPlayer.toggle_pause
    assert sound.playing?
  end

  def test_pause_resume_and_stop
    KlangtenBackgroundPlayer.play(item)
    sound = opened_sound
    assert wait_until { sound.playing? }
    assert_equal :paused, KlangtenBackgroundPlayer.toggle_pause
    assert_equal :paused, sound.status
    assert_equal :playing, KlangtenBackgroundPlayer.toggle_pause
    assert_equal :playing, sound.status
    KlangtenBackgroundPlayer.stop
    assert sound.closed?
    refute KlangtenBackgroundPlayer.active?
  end

  def test_a_new_entry_replaces_the_old_one
    KlangtenBackgroundPlayer.play(item(location: "http://media.invalid/one.mp3"))
    first = opened_sound
    KlangtenBackgroundPlayer.play(item(location: "http://media.invalid/two.mp3"))
    assert wait_until { KlangtenBackgroundPlayer.sound != nil && !KlangtenBackgroundPlayer.sound.equal?(first) }
    assert first.closed?
    assert_equal "http://media.invalid/two.mp3", KlangtenBackgroundPlayer.sound.file
  end

  def test_the_end_of_an_episode_is_announced_and_forgets_the_bookmark
    KlangtenBookmarks.remember("http://media.invalid/episode.mp3", 300, length: 600)
    KlangtenBackgroundPlayer.play(item(bookmark: true))
    sound = opened_sound
    sleep(KlangtenBackgroundPlayer::START_GRACE_SECONDS + 0.1)
    sound.finished = true
    assert wait_until { !KlangtenBackgroundPlayer.active? }
    events = KlangtenBackgroundPlayer.take_events
    assert_includes events, [:finished, "Episode"]
    assert_nil KlangtenBookmarks.position("http://media.invalid/episode.mp3")
  end

  def test_a_broken_radio_stream_is_opened_again
    KlangtenBackgroundPlayer.play(item(kind: :radio, location: "http://radio.invalid/live"))
    sound = opened_sound
    sleep(KlangtenBackgroundPlayer::START_GRACE_SECONDS + 0.1)
    sound.finished = true
    assert wait_until { Sound.opened.size == 2 }, "no reconnect"
    assert KlangtenBackgroundPlayer.active?
    assert_equal "http://radio.invalid/live", Sound.opened.last.file
  end

  def test_an_address_that_cannot_be_opened_is_reported
    Sound.fail << "http://media.invalid/missing.mp3"
    KlangtenBackgroundPlayer.play(item(location: "http://media.invalid/missing.mp3", title: "Missing"))
    assert wait_until { !KlangtenBackgroundPlayer.active? }
    assert_includes KlangtenBackgroundPlayer.take_events, [:failed, "Missing"]
  end

  def test_a_bookmark_beyond_the_download_waits_until_it_can_be_reached
    Sound.default_downloaded = 100
    KlangtenBackgroundPlayer.play(item(bookmark: true), position: 300)
    sound = opened_sound
    sleep(0.4)
    refute sound.playing?, "plays from the beginning instead of waiting"
    assert KlangtenBackgroundPlayer.opening?
    sound.downloaded = 600
    assert wait_until { sound.playing? }
    assert_equal 300, sound.position
  end

  def test_pausing_saves_the_bookmark
    KlangtenBackgroundPlayer.play(item(bookmark: true))
    sound = opened_sound
    sound.position = 125
    KlangtenBackgroundPlayer.pause
    assert_equal 125, KlangtenBookmarks.position("http://media.invalid/episode.mp3")
  end

  def test_volume_steps_stay_in_range
    KlangtenBackgroundPlayer.play(item)
    sound = opened_sound
    before = KlangtenBackgroundPlayer.volume_percent
    assert_equal before + 5, KlangtenBackgroundPlayer.change_volume(0.05)
    assert_in_delta (before + 5) / 100.0, sound.volume
    50.times { KlangtenBackgroundPlayer.change_volume(-0.05) }
    assert_equal 5, KlangtenBackgroundPlayer.volume_percent
  end

  def test_seeking_is_refused_for_radio
    KlangtenBackgroundPlayer.play(item(kind: :radio))
    opened_sound
    refute KlangtenBackgroundPlayer.seek(5)
  end

  def test_audio_focus_lost_for_a_moment_pauses_and_comes_back
    focus = :focused
    KlangtenAudioFocus.singleton_class.class_eval do
      alias_method :real_supported?, :supported?
      alias_method :real_state, :state
    end
    KlangtenAudioFocus.define_singleton_method(:supported?) { true }
    KlangtenAudioFocus.define_singleton_method(:state) { focus }
    begin
      KlangtenBackgroundPlayer.play(item)
      sound = opened_sound
      assert wait_until { sound.playing? }
      focus = :transient
      assert wait_until { sound.status == :paused }
      focus = :focused
      assert wait_until { sound.status == :playing }
      focus = :lost
      assert wait_until { sound.status == :paused }
      focus = :focused
      sleep(0.5)
      assert_equal :paused, sound.status, "another player took the focus for good"
    ensure
      KlangtenAudioFocus.singleton_class.class_eval do
        alias_method :supported?, :real_supported?
        alias_method :state, :real_state
      end
    end
  end
end

class MediaCoordinationTest < Minitest::Test
  include MediaTestReset

  def setup
    super
    list = KlangtenPlaylist.internal
    list.clear
    list.add([KlangtenPlaylist::Entry.new(File.join(TEST_DATA, "song1.mp3")), KlangtenPlaylist::Entry.new(File.join(TEST_DATA, "song2.mp3"))])
    FileUtils.touch(File.join(TEST_DATA, "song1.mp3"))
    FileUtils.touch(File.join(TEST_DATA, "song2.mp3"))
  end

  def playlist_sound
    assert wait_until { KlangtenPlaylist.instance_variable_get(:@sound) != nil }
    KlangtenPlaylist.instance_variable_get(:@sound)
  end

  def test_the_background_player_pauses_the_playlist_and_the_other_way_round
    KlangtenPlaylist.play
    song = playlist_sound
    assert wait_until { song.playing? }
    KlangtenBackgroundPlayer.play(item(kind: :radio))
    radio = opened_sound
    assert KlangtenPlaylist.paused?
    assert_equal :paused, song.status
    assert_equal :background, KlangtenMedia.source
    KlangtenPlaylist.toggle_pause
    assert_equal :paused, radio.status
    assert KlangtenBackgroundPlayer.paused?
    assert_equal :playlist, KlangtenMedia.source
  end

  # The keys of Klangten's player in the playlist: tempo, pitch and balance
  # hold for the next entry too, Backspace puts them back.
  def test_tempo_pitch_and_balance_carry_over_to_the_next_entry
    KlangtenPlaylist.play
    song = playlist_sound
    assert_equal 2, KlangtenPlaylist.change_tempo(KlangtenPlaylist::TEMPO_STEP)
    value, base = KlangtenPlaylist.change_frequency(1)
    assert_in_delta base + base / 250.0, value, 0.01
    assert_in_delta 0.02, KlangtenPlaylist.change_pan(KlangtenPlaylist::PAN_STEP), 0.001
    assert_equal [2.0, value, 0.02], [song.tempo, song.frequency, song.pan]
    assert_equal 100, KlangtenPlaylist.change_tempo(500), "tempo stops at 100"
    KlangtenPlaylist.change_tempo(-98)
    KlangtenPlaylist.next
    assert wait_until { (sound = KlangtenPlaylist.instance_variable_get(:@sound)) != nil && !sound.equal?(song) }
    following = KlangtenPlaylist.instance_variable_get(:@sound)
    assert_equal [2.0, value, 0.02], [following.tempo, following.frequency, following.pan]
    KlangtenPlaylist.reset_sound
    sound = KlangtenPlaylist.instance_variable_get(:@sound)
    assert_equal [0.0, 44_100.0, 0.0], [sound.tempo, sound.frequency, sound.pan]
  end

  def test_when_the_background_entry_stops_the_actions_go_to_the_playlist
    KlangtenPlaylist.play
    playlist_sound
    KlangtenBackgroundPlayer.play(item)
    opened_sound
    KlangtenBackgroundPlayer.stop
    assert_equal :playlist, KlangtenMedia.source
    KlangtenMedia.quick_action(:toggle)
    assert KlangtenPlaylist.playing?
  end

  def test_suspend_pauses_both_and_resumes_what_played
    KlangtenBackgroundPlayer.play(item)
    sound = opened_sound
    assert wait_until { sound.playing? }
    KlangtenMedia.suspend do
      assert_equal :paused, sound.status
    end
    assert_equal :playing, sound.status
  end

  def test_suspend_does_not_resume_when_a_player_screen_sent_its_sound_to_the_background
    KlangtenPlaylist.play
    song = playlist_sound
    assert wait_until { song.playing? }
    foreground = Sound.new("http://media.invalid/radio")
    KlangtenMedia.suspend do
      assert_equal :paused, song.status
      foreground.play
      KlangtenBackgroundPlayer.adopt(foreground, item(kind: :radio, location: "http://media.invalid/radio"))
    end
    assert_equal :paused, song.status
    assert_equal :playing, foreground.status
  end
end

class QuickActionTest < Minitest::Test
  include MediaTestReset

  def test_player_quick_actions_are_registered
    names = EltenAPI::QuickActions.procs.map { |entry| entry[1] }
    %i[open toggle stop volume_down volume_up status record microphone].each do |action|
      assert_includes names, :"klangten_player__#{action}"
    end
  end

  def test_actions_without_anything_playing_say_so
    EltenAPI::QuickActions.call(:klangten_player__toggle)
    assert_includes Spoken.lines, "Nothing is playing in the background."
  end

  def test_status_volume_and_stop_of_the_background_player
    KlangtenBackgroundPlayer.play(item(title: "Radio Eins", kind: :radio))
    opened_sound
    EltenAPI::QuickActions.call(:klangten_player__status)
    assert_match(/Radio Eins/, Spoken.lines.last)
    spoken = Spoken.lines.size
    before = KlangtenBackgroundPlayer.volume_percent
    EltenAPI::QuickActions.call(:klangten_player__volume_up)
    # the volume keys say nothing, like the player's own
    assert_equal before + 5, KlangtenBackgroundPlayer.volume_percent
    assert_equal spoken, Spoken.lines.size
    EltenAPI::QuickActions.call(:klangten_player__stop)
    assert_equal "Stopped: Radio Eins", Spoken.lines.last
    refute KlangtenBackgroundPlayer.active?
  end

  def test_open_shows_the_player_of_what_plays
    KlangtenBackgroundPlayer.play(item)
    opened_sound
    EltenAPI::QuickActions.call(:klangten_player__open)
    assert_kind_of Scene_NowPlaying, $inserted_scenes.last
  end

  def test_default_keys_are_given_once_and_only_where_free
    LocalConfig.clear
    EltenAPI::QuickActions.actions.clear
    EltenAPI::QuickActions.actions << EltenAPI::QuickActions::Action.new(:something, "Taken", 7)
    KlangtenMedia.ensure_default_hotkeys
    keys = EltenAPI::QuickActions.actions.map(&:key)
    refute_equal 2, keys.count(7), "F7 was taken already"
    assert_includes keys, 23
    assert_includes EltenAPI::QuickActions.actions.map(&:action), :klangten_player__microphone
    count = EltenAPI::QuickActions.actions.size
    KlangtenMedia.ensure_default_hotkeys
    assert_equal count, EltenAPI::QuickActions.actions.size, "given twice"
  end

  def test_events_of_the_engine_are_spoken_by_tick
    Sound.fail << "http://media.invalid/broken.mp3"
    KlangtenBackgroundPlayer.play(item(location: "http://media.invalid/broken.mp3", title: "Broken"))
    assert wait_until { KlangtenBackgroundPlayer.events_pending? }
    KlangtenMedia.tick
    assert_includes Spoken.lines, "Broken cannot be played."
  end
end

# Headset and media buttons (src/eapi/mediabuttons.rb) with a backend that
# hands over the pressed buttons the test gives it.
class MediaButtonsTest < Minitest::Test
  include MediaTestReset

  module FakeBackend
    class << self
      attr_accessor :enabled, :pressed, :playing

      def supported?
        true
      end

      def enable(on)
        @enabled = on
      end

      def poll
        @pressed.to_a.shift.to_i
      end

      def now_playing(title, state)
        @playing = [title, state]
      end
    end
  end

  def setup
    super
    FakeBackend.enabled = nil
    FakeBackend.pressed = []
    FakeBackend.playing = nil
    KlangtenMediaButtons.instance_variable_set(:@backend, FakeBackend)
    KlangtenMediaButtons.instance_variable_set(:@wanted, nil)
    KlangtenMediaButtons.instance_variable_set(:@checked_at, nil)
    KlangtenMediaButtons.instance_variable_set(:@announced, nil)
    KlangtenMediaButtons.instance_variable_set(:@setting, nil)
  end

  def teardown
    KlangtenMediaButtons.remove_instance_variable(:@backend)
    super
  end

  def test_off_on_computers_unless_switched_on
    KlangtenBackgroundPlayer.play(item(title: "Radio Eins", kind: :radio))
    opened_sound
    KlangtenMediaButtons.tick
    assert_equal false, FakeBackend.enabled
    KlangtenMediaButtons.enabled = true
    KlangtenMediaButtons.tick
    assert_equal true, FakeBackend.enabled
  end

  # Idling in the menus the buttons stay with the other apps.
  def test_taken_only_while_something_plays
    KlangtenMediaButtons.enabled = true
    KlangtenMediaButtons.tick
    assert_equal false, FakeBackend.enabled
    KlangtenBackgroundPlayer.play(item(title: "Radio Eins", kind: :radio))
    opened_sound
    KlangtenMediaButtons.tick
    assert_equal true, FakeBackend.enabled
    KlangtenBackgroundPlayer.pause
    KlangtenMediaButtons.tick
    assert_equal true, FakeBackend.enabled, "paused, play must still reach Klangten"
    KlangtenBackgroundPlayer.stop
    KlangtenMediaButtons.tick
    assert_equal false, FakeBackend.enabled
  end

  def test_buttons_pause_resume_and_say_what_plays
    KlangtenMediaButtons.enabled = true
    KlangtenBackgroundPlayer.play(item(title: "Radio Eins", kind: :radio))
    opened_sound
    FakeBackend.pressed = [KlangtenMediaButtons::TOGGLE]
    KlangtenMediaButtons.tick
    assert KlangtenBackgroundPlayer.paused?
    assert_equal ["Radio Eins", 2], FakeBackend.playing
    FakeBackend.pressed = [KlangtenMediaButtons::PAUSE]
    KlangtenMediaButtons.tick
    assert KlangtenBackgroundPlayer.paused?, "pause on a paused player changes nothing"
    FakeBackend.pressed = [KlangtenMediaButtons::PLAY]
    KlangtenMediaButtons.tick
    assert KlangtenBackgroundPlayer.playing?
    assert_equal ["Radio Eins", 1], FakeBackend.playing
  end

  # What a player on the screen needs for the buttons (src/ui/controls/player.rb).
  class ScreenPlayer
    attr_reader :sound
    attr_accessor :attended

    def initialize(title)
      @title = title
      @sound = Sound.new("http://media.invalid/video.webm")
      @paused = false
      @attended = true
    end

    def attended?
      @attended
    end

    def paused?
      @paused
    end

    def completed
      false
    end

    def play
      @paused = false
    end

    def pause
      @paused = true
    end

    def recording_title
      @title
    end
  end

  # One file or a video on the screen takes the buttons too, not only the
  # playlist and the background player.
  def test_a_player_on_the_screen_takes_the_buttons
    KlangtenMediaButtons.enabled = true
    player = ScreenPlayer.new("Ein Video")
    KlangtenMedia.player_started(player)
    KlangtenMediaButtons.tick
    assert_equal true, FakeBackend.enabled
    assert_equal ["Ein Video", 1], FakeBackend.playing
    FakeBackend.pressed = [KlangtenMediaButtons::TOGGLE]
    KlangtenMediaButtons.tick
    assert player.paused?
    assert_equal ["Ein Video", 2], FakeBackend.playing
    FakeBackend.pressed = [KlangtenMediaButtons::PLAY]
    KlangtenMediaButtons.tick
    refute player.paused?
    KlangtenMedia.player_closed(player)
    KlangtenMediaButtons.tick
    assert_equal false, FakeBackend.enabled
  ensure
    KlangtenMedia.player_closed(player)
  end

  # A paused player left behind in a form does not keep the buttons.
  def test_a_paused_player_nobody_uses_lets_go
    KlangtenMediaButtons.enabled = true
    player = ScreenPlayer.new("Anhang")
    KlangtenMedia.player_started(player)
    KlangtenMediaButtons.tick
    assert_equal true, FakeBackend.enabled
    player.attended = false
    KlangtenMediaButtons.tick
    assert_equal false, FakeBackend.enabled
    assert_nil KlangtenMedia.source
  ensure
    KlangtenMedia.player_closed(player)
  end

  def test_buttons_are_ignored_while_switched_off
    KlangtenBackgroundPlayer.play(item(title: "Radio Eins", kind: :radio))
    opened_sound
    FakeBackend.pressed = [KlangtenMediaButtons::TOGGLE]
    KlangtenMediaButtons.tick
    assert KlangtenBackgroundPlayer.playing?
  end
end

class BookmarksTest < Minitest::Test
  include MediaTestReset

  def test_remember_and_forget
    KlangtenBookmarks.remember("http://a.invalid/1.mp3", 61.24, length: 3600, title: "One")
    assert_equal 61.2, KlangtenBookmarks.position("http://a.invalid/1.mp3")
    KlangtenBookmarks.reload
    assert_equal "One", KlangtenBookmarks.get("http://a.invalid/1.mp3").title, "not saved to disk"
    KlangtenBookmarks.forget("http://a.invalid/1.mp3")
    assert_nil KlangtenBookmarks.position("http://a.invalid/1.mp3")
  end

  def test_no_bookmark_at_the_start_or_at_the_end
    assert_nil KlangtenBookmarks.remember("x", 3, length: 3600)
    KlangtenBookmarks.remember("x", 100, length: 3600)
    assert_nil KlangtenBookmarks.remember("x", 3590, length: 3600)
    assert_nil KlangtenBookmarks.position("x"), "heard to the end keeps a bookmark"
  end

  def test_the_list_is_kept_short
    (KlangtenBookmarks::MAX_ENTRIES + 5).times { |index| KlangtenBookmarks.remember("u#{index}", 50) }
    assert_equal KlangtenBookmarks::MAX_ENTRIES, KlangtenBookmarks.all.size
  end

  def test_update_from_a_finished_sound_forgets
    KlangtenBookmarks.remember("y", 100, length: 600)
    sound = Sound.new("y")
    sound.position = 599
    KlangtenBookmarks.update_from_sound("y", sound)
    assert_nil KlangtenBookmarks.position("y")
  end
end

class RecordingsTest < Minitest::Test
  include MediaTestReset

  def test_default_folder_and_custom_folder
    assert_equal File.join(Dirs.documents, "Klangten", "Recordings"), KlangtenRecordings.folder
    KlangtenRecordings.folder = "/somewhere/else"
    assert_equal "/somewhere/else", KlangtenRecordings.folder
    assert KlangtenRecordings.custom_folder?
    KlangtenRecordings.folder = ""
    refute KlangtenRecordings.custom_folder?
  end

  def test_phones_keep_recordings_in_their_documents
    EltenSystemHelpers.platform_os = "ios"
    assert_equal File.join(Dirs.documents, "Recordings"), KlangtenRecordings.folder
  ensure
    EltenSystemHelpers.platform_os = nil
  end

  def test_numbers_continue_after_the_highest_one
    dir = File.join(TEST_DATA, "numbers")
    FileUtils.mkdir_p(dir)
    path, number = KlangtenRecordings.next_numbered(dir, "recording ", ".mp3")
    assert_equal "001", number
    assert_equal File.join(dir, "recording 001.mp3"), path
    FileUtils.touch(File.join(dir, "recording 007.mp3"))
    FileUtils.touch(File.join(dir, "recording 010.ogg"))
    FileUtils.touch(File.join(dir, "recording x.mp3"))
    _, number = KlangtenRecordings.next_numbered(dir, "recording ", ".mp3")
    assert_equal "008", number
  end

  def test_safe_names
    assert_equal "AC_DC_ Live", KlangtenRecordings.safe_name("AC/DC: Live")
    assert_equal "Unknown", KlangtenRecordings.safe_name("  ")
    assert_equal "x", KlangtenRecordings.safe_name("...x. ")
  end

  def test_recording_is_refused_without_the_encoder
    refute KlangtenRecordings.available?
    KlangtenRecordings.toggle_stream(Sound.new("a"), "Radio")
    assert_includes Spoken.lines, "Recording is not available on this system."
  end

  class FakeRecorder
    attr_reader :path, :stopped

    def initialize(path)
      @path = path
      File.binwrite(path, "data")
    end

    def stop
      @stopped = true
    end
  end

  def test_the_microphone_records_into_numbered_files
    recorders = []
    recorder_class = Class.new
    recorder_class.define_singleton_method(:vorbis_recording) do |path, _bitrate|
      recorder = FakeRecorder.new(path)
      recorders << recorder
      recorder
    end
    Object.const_set(:Recorder, recorder_class) if !defined?(::Recorder)
    KlangtenRecordings.folder = File.join(TEST_DATA, "mic")
    assert KlangtenRecordings.toggle_microphone
    assert KlangtenRecordings.microphone_recording?
    assert_equal "Recording 001", Spoken.lines.last
    KlangtenRecordings.toggle_microphone
    refute KlangtenRecordings.microphone_recording?
    assert_equal "Recording 001 saved", Spoken.lines.last
    assert File.file?(File.join(TEST_DATA, "mic", "Microphone", "recording 001.ogg"))
    KlangtenRecordings.toggle_microphone
    assert_equal "Recording 002", Spoken.lines.last
    KlangtenRecordings.toggle_microphone
    assert recorders.all?(&:stopped)
  end
end

class ArchiveTest < Minitest::Test
  ENTRY = {
    "metadata" => {
      "identifier" => "oldtimeradio_test",
      "title" => "Old Time Radio",
      "creator" => ["Station A", "Station B"],
      "description" => "<p>Two shows &amp; more.</p><br/>Second line",
      "date" => "1950",
      "mediatype" => "audio"
    },
    "files" => [
      { "name" => "oldtimeradio_test_meta.xml", "format" => "Metadata" },
      { "name" => "cover.jpg", "format" => "JPEG", "source" => "original", "size" => "2048" },
      { "name" => "show 2.mp3", "format" => "VBR MP3", "title" => "Second show", "length" => "29:30", "source" => "derivative", "track" => "2" },
      { "name" => "show 1.mp3", "format" => "VBR MP3", "title" => "First show", "length" => "1800.5", "source" => "derivative", "track" => "1" },
      { "name" => "oldtimeradio_test_archive.torrent", "format" => "Archive BitTorrent" }
    ]
  }.freeze

  def test_identifiers_from_addresses
    assert_equal "old_radio", KlangtenArchive.identifier("https://archive.org/details/old_radio")
    assert_equal "old_radio", KlangtenArchive.identifier("see http://www.archive.org/download/old_radio/file.mp3 here")
    assert_nil KlangtenArchive.identifier("old_radio")
    assert_equal "old_radio", KlangtenArchive.identifier("old_radio", bare: true)
    assert_nil KlangtenArchive.identifier("https://example.org/details/old_radio")
  end

  def test_entry_files_description_and_order
    entry = KlangtenArchive.parse_entry("oldtimeradio_test", JSON.generate(ENTRY))
    assert_equal "Old Time Radio", entry.title
    assert_equal "Station A, Station B", entry.creator
    assert_equal "Two shows & more.\n\nSecond line", entry.description
    assert_equal ["First show", "Second show", "cover.jpg"], entry.files.map(&:label)
    first = entry.files.first
    assert_in_delta 1800.5, first.length
    assert_equal 1770, entry.files[1].length
    assert first.playable?
    refute entry.files.last.playable?
    assert_equal "https://archive.org/download/oldtimeradio_test/show%201.mp3", first.url
  end

  def test_unknown_entry
    assert_raises(KlangtenArchive::Error) { KlangtenArchive.parse_entry("nothing", "{}") }
  end

  def test_search_results
    body = JSON.generate("response" => { "numFound" => 120, "start" => 0, "docs" => [{ "identifier" => "a", "title" => "A title", "creator" => "Someone" }, { "identifier" => "b" }] })
    page = KlangtenArchive.parse_search(body, 1)
    assert_equal ["A title", "b"], page.results.map(&:title)
    assert page.more?
  end

  def test_links_in_texts_become_media
    assert_includes MediaFinders.list, KlangtenArchive::Finder
    assert KlangtenArchive::Finder.possible_media?("listen: https://archive.org/details/x_y")
    assert_equal 1, KlangtenArchive::Finder.get_media("https://archive.org/details/x_y and https://archive.org/details/x_y").size
  end

  # The whole way over HTTP, against a local server instead of archive.org.
  def test_entry_and_search_over_http
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new do
      loop do
        client = server.accept
        line = client.gets.to_s
        requests << line.split(" ")[1]
        nil while (header = client.gets) && header != "\r\n"
        body = if line.include?("/metadata/")
          JSON.generate(ENTRY)
        else
          JSON.generate("response" => { "numFound" => 1, "docs" => [{ "identifier" => "oldtimeradio_test", "title" => "Old Time Radio" }] })
        end
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    rescue IOError
      nil
    end
    KlangtenArchive.base_url = "http://127.0.0.1:#{port}"
    KlangtenArchive.fetcher = ->(url) { Net::HTTP.get(URI(url)) }
    entry = KlangtenArchive.entry("oldtimeradio_test")
    assert_equal 3, entry.files.size
    assert_equal "http://127.0.0.1:#{port}/download/oldtimeradio_test/show%201.mp3", entry.files.first.url
    page = KlangtenArchive.search("radio")
    assert_equal "oldtimeradio_test", page.results.first.identifier
    assert_match(/advancedsearch\.php\?q=%28radio%29\+AND\+mediatype/, requests.last)
  ensure
    KlangtenArchive.base_url = nil
    KlangtenArchive.fetcher = nil
    server&.close
    thread&.kill
  end
end

class GlobalKeysTest < Minitest::Test
  include MediaTestReset

  module FakeBackend
    class << self
      attr_reader :started, :stopped

      def start(bindings, queue)
        @started = bindings
        @queue = queue
        true
      end

      def stop
        @stopped = true
      end

      def press(action)
        @queue << action
      end
    end
  end

  def setup
    super
    KlangtenGlobalKeys.stop if KlangtenGlobalKeys.supported?
    KlangtenGlobalKeys.send(:remove_const, :Backend) if KlangtenGlobalKeys.const_defined?(:Backend, false)
    KlangtenGlobalKeys.const_set(:Backend, FakeBackend)
    KlangtenGlobalKeys.instance_variable_set(:@checked_at, nil)
    KlangtenGlobalKeys.instance_variable_set(:@wanted, nil)
  end

  def test_keys_start_with_the_setting_and_run_player_actions
    KlangtenGlobalKeys.tick
    assert KlangtenGlobalKeys.running?
    assert_equal KlangtenGlobalKeys::BINDINGS, FakeBackend.started
    KlangtenBackgroundPlayer.play(item(title: "Jazz", kind: :radio))
    opened_sound
    FakeBackend.press(:status)
    KlangtenGlobalKeys.tick
    assert_match(/Jazz/, Spoken.lines.last)
  end

  def test_switched_off_in_the_settings
    writeconfig("Media", "GlobalPlayerKeys", "false")
    KlangtenGlobalKeys.tick
    refute KlangtenGlobalKeys.running?
  end

  def test_the_mac_mapping_of_the_modifiers
    KlangtenGlobalKeys.send(:remove_const, :Backend)
    load File.join(ROOT, "src/platforms/osx/eapi/globalkeys.rb")
    mac = KlangtenGlobalKeys::Backend
    assert_equal mac::OPTION, mac.mac_modifiers(KlangtenGlobalKeys::MOD_WIN, KlangtenGlobalKeys::VK_X)
    assert_equal mac::OPTION | mac::CMD, mac.mac_modifiers(KlangtenGlobalKeys::MOD_WIN | KlangtenGlobalKeys::MOD_CONTROL, KlangtenGlobalKeys::VK_X)
    assert_nil mac.mac_modifiers(KlangtenGlobalKeys::MOD_WIN | KlangtenGlobalKeys::MOD_CONTROL, KlangtenGlobalKeys::VK_F5), "VoiceOver's key"
    assert_nil mac.mac_modifiers(KlangtenGlobalKeys::MOD_WIN | KlangtenGlobalKeys::MOD_CONTROL, KlangtenGlobalKeys::VK_SPACE)
  end
end
