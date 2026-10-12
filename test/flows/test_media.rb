# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Media features of Klangten 0.4 in the real Klangten, offline: a player
# hands its sound to the background (B), the player of what plays in the
# background (F7) and the player quick actions, recording what plays (R),
# podcast bookmarks, and recording from the microphone (Control+F11).
# The audio is a generated WAV file; BASS plays on its silent device, and
# archive.org is a local server. Needs the test harness (test/support,
# branch k04-tests); the unit tests of the same features are in test/media.

require_relative "../test_helper"
require "socket"
require "json"

class MediaFlowTest < KlangtenTest::FlowTest
  SERVICE_THREADS = %w[klangten-background-player klangten-playlist].freeze

  # A minute of a quiet 440 Hz tone, 16 bit stereo.
  def tone_file
    path = File.join(work_dir, "tone.wav")
    rate = 22_050
    samples = (0...rate * 60).map { |index| (Math.sin(2 * Math::PI * 440 * index / rate) * 3000).to_i }
    data = samples.flat_map { |sample| [sample, sample] }.pack("s<*")
    header = ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 2, rate, rate * 4, 4, 16, "data", data.bytesize].pack("a4Va4a4VvvVVvva4V")
    File.binwrite(path, header + data)
    path
  end

  # The engines of the background player and the playlist are services that
  # run as long as something plays; for the harness they are background work,
  # not something the interface waits for.
  def mark_service_threads
    Thread.list.each do |thread|
      KlangtenTest::Runtime.register(thread, :bg) if SERVICE_THREADS.include?(thread.name)
    end
  end

  def start(k)
    k.boot
    k.expect("Log in", since: 0)
    k.call do
      KlangtenRecordings.folder = File.join(work_dir, "recordings")
      KlangtenMedia.ensure_default_hotkeys
    end
  end

  def open_player(k, file, **options)
    k.call(settle: false) { player(file, label: "Tone", background: { title: "Tone", kind: :file }, **options) }
    k.settle
  end

  def test_continue_in_the_background_and_come_back_with_f7
    k = klangten
    start(k)
    file = tone_file
    open_player(k, file)
    k.expect("Tone")
    k.press("b", settle: false)
    mark_service_threads
    k.settle
    k.expect("Playing in the background")
    assert KlangtenBackgroundPlayer.playing?
    assert_equal file, KlangtenBackgroundPlayer.item.location
    k.press("shift+f7", settle: false)
    mark_service_threads
    k.settle
    k.expect("Paused")
    assert KlangtenBackgroundPlayer.paused?
    k.press("f7")
    k.expect("Paused: Tone")
    k.press("space")
    assert KlangtenBackgroundPlayer.playing?
    k.press("esc")
    assert KlangtenBackgroundPlayer.playing?, "Escape in the player of the background stops it"
    mark = k.mark
    k.press("shift+f6")
    assert_equal 85, KlangtenBackgroundPlayer.volume_percent
    k.expect_not("85", since: mark)
    k.call { KlangtenMedia.quick_action(:stop) }
    k.expect("Stopped: Tone")
    refute KlangtenBackgroundPlayer.active?
  end

  def test_record_what_plays_with_r
    k = klangten
    start(k)
    open_player(k, tone_file)
    k.press("r")
    k.expect("Recording 001")
    k.run_for(1)
    sleep(2)
    k.press("r")
    k.expect("Recording 001 saved")
    path = File.join(work_dir, "recordings", "Tone", "recording 001.mp3")
    assert File.file?(path), "no recording in #{path}"
    assert File.size(path) > 1000, "the recording is empty"
    k.press("esc")
  end

  def test_a_podcast_bookmark_is_kept_and_continued
    k = klangten
    start(k)
    file = tone_file
    open_player(k, file, bookmark: "http://podcast.invalid/episode.mp3")
    6.times { k.press("right") }
    k.press("esc")
    position = KlangtenBookmarks.position("http://podcast.invalid/episode.mp3")
    assert position != nil && position >= 25, "bookmark at #{position.inspect}"
    k.call(settle: false) { player(file, label: "Tone", bookmark: "http://podcast.invalid/episode.mp3", position: position) }
    k.settle
    k.press("p")
    k.expect("00:00:3")
    k.press("esc")
  end

  # archive.org on a local port: the metadata of one entry and its files.
  def start_archive(files)
    server = TCPServer.new("127.0.0.1", 0)
    entry = {
      "metadata" => { "identifier" => "test_item", "title" => "Test recordings", "creator" => "Klangten", "description" => "Two <b>tones</b>." },
      "files" => files.keys.map.with_index { |name, index| { "name" => name, "format" => "WAVE", "title" => "Tone #{index + 1}", "track" => (index + 1).to_s, "source" => "original" } } +
        [{ "name" => "test_item_meta.xml", "format" => "Metadata" }]
    }
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |connection|
          path = connection.gets.to_s.split(" ")[1].to_s
          nil while (line = connection.gets) && line != "\r\n"
          body, type = if path.start_with?("/metadata/test_item")
            [JSON.generate(entry), "application/json"]
          elsif (name = files.keys.find { |file| path == "/download/test_item/#{file}" })
            [File.binread(files[name]), "audio/wav"]
          end
          if body == nil
            connection.write("HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
          else
            connection.write("HTTP/1.0 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n\r\n")
            connection.write(body)
          end
        rescue StandardError
          nil
        ensure
          connection.close rescue nil
        end
      end
    rescue IOError
      nil
    end
    [server, thread]
  end

  def test_internet_archive_entry_plays_in_the_background
    k = klangten
    start(k)
    tone = tone_file
    server, thread = start_archive("tone1.wav" => tone, "tone2.wav" => tone)
    k.call { KlangtenArchive.base_url = "http://127.0.0.1:#{server.addr[1]}" }
    k.call(settle: false) { Scene_InternetArchive.open_identifier("test_item") }
    k.settle
    k.expect("Test recordings")
    k.press("down")
    k.expect("Tone 1")
    k.press("enter")
    k.expect("Tone 1: Play")
    k.press("down")
    k.expect("Play in the background")
    k.press("enter", settle: false)
    mark_service_threads
    k.settle
    k.expect("Playing in the background")
    k.wait_until { KlangtenBackgroundPlayer.sound != nil }
    mark_service_threads
    assert_equal "http://127.0.0.1:#{server.addr[1]}/download/test_item/tone1.wav", KlangtenBackgroundPlayer.item.location
    assert KlangtenBackgroundPlayer.playing?
  ensure
    server&.close
    thread&.kill
  end

  # Control+F11 is quick action key 23. The harness presses the generic
  # Control key, which Klangten on macOS does not count as Control (it reads
  # the left and right keys), so there the key's actions are run directly.
  def press_control_f11(k)
    if RUBY_PLATFORM.include?("darwin")
      k.call { EltenAPI::QuickActions.hotkey_actions(23).each(&:call) }
    else
      k.press("ctrl+f11")
    end
  end

  def test_record_from_the_microphone_with_control_f11
    k = klangten
    start(k)
    press_control_f11(k)
    k.expect("Recording 001")
    k.run_for(2)
    press_control_f11(k)
    k.expect("Recording 001 saved")
    path = File.join(work_dir, "recordings", "Microphone", "recording 001.mp3")
    assert File.file?(path), "no recording in #{path}"
    assert File.size(path) > 1000, "the recording is empty"
  end
end
