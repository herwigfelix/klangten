# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Starting without a network: the start message, the connection error and
# the start menu (src/scenes/loading.rb).

require_relative "../test_helper"

class StartupTest < KlangtenTest::FlowTest
  def test_start_without_network_ends_in_start_menu
    k = klangten
    k.boot
    k.expect("Klangten", since: 0)
    k.expect("Error", since: 0)
    assert_equal "Log in", k.last_spoken
    assert_includes k.sounds(since: 0), "listbox_marker"
  end

  def test_start_menu_items
    k = klangten
    k.boot
    items = ["Log in"]
    5.times do
      k.press("down")
      items << k.last_spoken
    end
    # No "Reinstall": the updater is off when running from source.
    assert_equal ["Log in", "Register", "Password reset", "Use guest account", "Settings", "Exit"], items
  end

  def test_offline_start_reaches_nothing_outside
    k = klangten
    k.boot
    assert_empty k.blocked_connections
  end

  def test_guest_account_opens_main_window
    k = klangten
    k.boot
    k.move_to("Use guest account", key: "down")
    k.press("enter")
    assert_kind_of Scene_Main, k.scene
  end
end
