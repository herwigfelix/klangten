# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Tests of the test harness itself: key names, virtual time, the closed
# network, FakeWeb, single controls started with app.start.

require_relative "../test_helper"

class HarnessKeysTest < Minitest::Test
  def test_key_names
    key = KlangtenTest::Keys.parse("down")
    assert_equal [[], 0x28, ""], [key.mods, key.code, key.text]
    key = KlangtenTest::Keys.parse("ctrl+t")
    assert_equal [[0x11, 0xA2], 0x54, ""], [key.mods, key.code, key.text]
    key = KlangtenTest::Keys.parse("A")
    assert_equal [[0x10], 0x41, "A"], [key.mods, key.code, key.text]
    key = KlangtenTest::Keys.parse("<c-s-i>")
    assert_equal [0x11, 0xA2, 0x10], key.mods
    assert_equal 0x5B, KlangtenTest::Keys.parse("cmd+q").mods.first
    assert_equal 0x73, KlangtenTest::Keys.parse("alt+f4").code
    assert_raises(ArgumentError) { KlangtenTest::Keys.parse("hyper+x") }
  end

  def test_ogg_opus_reader_rejects_other_data
    assert_raises(ArgumentError) { KlangtenTest::Media.ogg_opus("RIFF....") }
  end
end

class HarnessTest < KlangtenTest::FlowTest
  def test_start_runs_a_block_as_the_scene
    k = klangten
    k.start { alert("Hallo Welt") }
    k.expect("Hallo Welt", since: 0)
    assert k.finished?
  end

  def test_list_selection_with_keys
    k = klangten
    k.start { selector(["Eins", "Zwei", "Drei"], header: "Auswahl") }
    k.expect("Auswahl", since: 0)
    k.press("down")
    k.expect("Zwei")
    k.press("enter")
    assert_equal 1, k.result
  end

  def test_german_interface
    k = klangten(language: "de-DE")
    k.boot
    k.expect("Anmelden", since: 0)
  end

  def test_call_runs_code_on_the_scene_thread
    k = klangten
    k.boot
    k.call { alert("Von aussen") }
    k.expect("Von aussen")
    k.press("down")
    k.expect("Register")
  end

  def test_holding_a_key_repeats_it
    k = klangten
    k.start { selector((1..20).map { |i| "Punkt #{i}" }, header: "Liste") }
    k.hold("down")
    k.run_for(1)
    k.release("down")
    # 0.45 s until the first repeat, then about 30 per second
    assert_operator k.last_spoken[/\d+/].to_i, :>, 5
  end

  def test_quit_shortcut_asks_and_exits
    k = klangten
    k.boot
    k.close_window
    k.expect("Exit... Cancel")
    k.press("down")
    k.expect("Exit")
    k.press("enter")
    k.expect_sound("logout")
    assert k.finished?
  end

  def test_typing_into_an_edit_box_and_the_clipboard
    k = klangten
    k.start { input_text("Name") }
    k.type("Klangten")
    k.press("ctrl+a")
    k.press("ctrl+c")
    assert_equal "Klangten", k.clipboard.text
    k.press("enter")
    assert_equal "Klangten", k.result
  end

  def test_time_is_virtual
    k = klangten
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    k.start do
      t = Time.now
      delay(30)
      Time.now - t
    end
    assert_operator k.result, :>=, 30
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15, "30 virtual seconds must not take real time"
  end

  def test_network_is_closed
    k = klangten
    k.start do
      Net::HTTP.get(URI("http://example.com/"))
      :reached
    rescue SocketError => e
      e.class.name
    end
    assert_equal "KlangtenTest::NetGuard::Blocked", k.result
    assert_includes k.blocked_connections, "example.com:80"
  end

  def test_fake_web_is_reachable_for_ruby_and_bass
    web = fake_web
    web.text("/hello.txt", "Hallo aus dem Test")
    wav = web.file("/tone.wav", KlangtenTest::Media.wav(seconds: 1.5), mime: "audio/wav")
    web.error("/missing", 404)
    k = klangten
    k.start do
      text = Net::HTTP.get(URI(web.url("/hello.txt"))).force_encoding("UTF-8")
      missing = Net::HTTP.get_response(URI(web.url("/missing"))).code
      channel = Bass.create_url_stream(wav, 0, Bass::BASS_STREAM_DECODE)
      seconds = Bass::BASS_ChannelBytes2Seconds.call(channel, Bass::BASS_ChannelGetLength.call(channel, 0))
      [text, missing, channel != 0, seconds.round(1)]
    end
    assert_equal ["Hallo aus dem Test", "404", true, 1.5], k.result
    assert_equal ["/hello.txt", "/missing", "/tone.wav"], web.requests.map(&:path).sort
  end
end
