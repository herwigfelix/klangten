# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Voice posts (OpusRecordButton in src/ui/controls/opus_record_button.rb,
# Scene_Forum_Thread#audiosendupdate). The microphone is the harness's
# generated signal; encoder, Ogg writer and upload are the real code.
#
# Regression: voice posts were recorded at 48 kbit/s with the speech
# profile (OPUS_APPLICATION_VOIP, 2048); the server turns Opus into MP3, and
# together they sounded dull and squashed. Since 0.3.1 they are recorded at
# 64 kbit/s in audio mode (OPUS_APPLICATION_AUDIO, 2049).

require_relative "../test_helper"
require_relative "forum_world"

class ForumVoiceTest < KlangtenTest::FlowTest
  include ForumWorld

  def record_voice_reply(k, seconds)
    k.move_to("Post type")
    k.press("down")
    k.expect("Audio post")
    k.press("tab")
    k.expect("Audio post")
    k.press("enter")
    k.expect("record")
    k.press("enter")
    k.expect_sound("recording_start")
    k.run_for(seconds)
    k.move_to("Stop recording")
    k.press("enter")
    k.expect_sound("recording_stop")
    k.move_to("Ready")
    k.press("enter")
    k.move_to("Send")
    k.press("enter")
  end

  def test_voice_reply_is_uploaded_as_64_kbit_opus_in_audio_mode
    world = forum_world(type: 2, forum: "Sprechecke")
    k = open_thread(forum: "Sprechecke")
    record_voice_reply(k, 3)
    k.expect("The post was created.")

    # The encoder was opened in audio mode at 64 kbit/s ...
    assert_equal [{ application: 2049, channels: 2, bitrate: 64_000 }], k.opus_encoders

    # ... and the file that went to the server shows it: Ogg Opus, stereo,
    # about three seconds, CELT (music) packets only, about 64 kbit/s.
    upload = k.uploads.find { |u| u[:path] == "/api/v1/forum/#{world[:thread]}" }
    refute_nil upload, "no audio upload"
    assert_equal 1, upload[:params]["audio"]
    opus = KlangtenTest::Media.ogg_opus(upload[:body])
    assert_equal 2, opus.channels
    assert_in_delta k.microphone.recordings.last.seconds, opus.seconds, 0.1
    assert_equal 0, opus.modes[:silk] + opus.modes[:hybrid], "speech-mode packets: #{opus.modes.inspect}"
    assert_in_delta 64, opus.kbps, 8

    # The server accepted it as a voice post of hans.
    assert server.requests.any? { |m, path, status| m == "POST" && path.start_with?("/api/v1/forum/#{world[:thread]}?") && status == 200 }
    author, url = server.sql("SELECT author, vfm_body FROM posts WHERE thread_id = ? ORDER BY post_id DESC LIMIT 1", world[:thread]).first
    assert_equal "hans", author
    refute_empty url
  end
end
