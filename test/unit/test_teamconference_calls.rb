# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The call events of the conference client reach the interface. The interface
# (EltenAPI::Conference) listens only for "klangten_call"; before 0.4 an
# incoming call was reported as "call_incoming" alone and never rang.

require "minitest/autorun"
require_relative "../../src/eapi/teamconference"

class TeamConferenceCallEventsTest < Minitest::Test
  def client
    c = TeamConference::Client.new(library: Object.new, token_provider: -> { nil })
    @events = []
    c.on_event { |type, data, _info| @events << [type, data] }
    c
  end

  def call_events
    @events.select { |type, _| type == "klangten_call" }.map { |_, data| data["call"] }
  end

  def test_incoming_call_rings
    c = client
    c.simulate_event("call_incoming", "room_id" => 7, "from_user_id" => 3, "from_username" => "anna", "from_nickname" => "Anna")
    assert_equal 1, call_events.size
    call = call_events.first
    assert_equal :incoming, call[:direction]
    assert_equal :ringing, call[:state]
    assert_equal "Anna", call[:nickname]
  end

  def test_a_second_call_is_declined_without_ringing
    c = client
    c.simulate_event("call_incoming", "room_id" => 7, "from_username" => "anna")
    def c.send_raw(*) = nil
    c.simulate_event("call_incoming", "room_id" => 8, "from_username" => "bert")
    assert_equal 1, call_events.size
  end
end
