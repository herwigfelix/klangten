# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The harness keeps every test away from real sound cards and microphones
# (hooks.rb, forbid_real_audio_devices). Test runs on a developer's Mac once
# drove coreaudiod into an overload loop through the conference library;
# this test fails when one of the locks stops working.

require_relative "../test_helper"

class NoAudioDevicesTest < KlangtenTest::FlowTest
  def test_logged_in_klangten_touches_no_audio_device
    k = klangten(server: server)
    server.create_user("hans")
    k.boot_logged_in("hans")
    k.run_for(3)
    result = k.call do
      Bass.setdevice(-1)
      {
        conference: EltenAPI::Conference.client,
        reason: EltenAPI::Conference.unavailable_reason.to_s,
        device: Bass.class_variable_get(:@@device),
        record: Bass.record_prepare,
        chrome: (begin; KlangtenWeb::Chrome.browser; :started; rescue KlangtenTest::HarnessError; :refused; end)
      }
    end
    assert_nil result[:conference], "the conference library must not load in tests"
    assert_includes result[:reason], "disabled in tests"
    assert_equal 0, result[:device], "BASS must stay on its no-sound device"
    assert_equal false, result[:record], "BASS must never open a microphone"
    assert_equal :refused, result[:chrome]
    loaded = ObjectSpace.each_object(TeamConference::Library).to_a
    assert_empty loaded, "a conference library object was created"
  end
end
