# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The menu bar of the main window (src/eapi/mainmenu.rb, Menu control):
# Alt opens it, left/right walk the top level, down opens a submenu.

require_relative "../test_helper"

class MainMenuTest < KlangtenTest::FlowTest
  def logged_in
    server.create_user("hans")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k
  end

  def test_alt_opens_and_closes_the_menu_bar
    k = logged_in
    k.press("alt")
    k.expect_sound("menu_open")
    k.expect("Context menu")
    k.press("alt")
    k.expect_sound("menu_close")
    k.press("down")
    k.expect_not("Community")
  end

  def test_top_level_order
    k = logged_in
    k.press("alt")
    order = 5.times.map do
      k.press("right")
      k.last_spoken.sub(/ \(.*\)\z/, "")
    end
    assert_equal ["Community", "Media", "Files", "Programs", "Tools"], order
  end

  def test_community_submenu
    k = logged_in
    k.press("alt")
    k.press("right")
    k.expect("Community")
    k.press("down")
    k.expect_sound("listbox_treeexpand")
    k.expect("Messages")
    k.press("down")
    k.expect("Blogs")
    k.press("down")
    k.expect("Forum")
    # Escape closes the submenu and returns to the menu bar.
    k.press("esc")
    k.expect_sound("listbox_treecollapse")
  end

  def test_menu_helper_opens_messages
    k = logged_in
    k.menu("Community", "Messages")
    k.expect("Messages: Empty list")
  end
end
