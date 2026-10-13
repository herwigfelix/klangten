# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The playlist like in Klango: one playlist - the list that played last (a
# Spotify list too), otherwise the internal one - in a tab of the main window
# and under Files, Playlist. The entries point to files that do not exist, so
# the playlist skips them and stops without opening a sound.

require_relative "../test_helper"

class PlaylistTabFlowTest < KlangtenTest::FlowTest
  def logged_in
    server.create_user("grete")
    k = klangten(server: server)
    KlangtenTest::Runtime.add_frame_hook do
      Thread.list.each do |t|
        KlangtenTest::Runtime.register(t, :bg) if t.name == "klangten-playlist" && KlangtenTest::Runtime.kind(t) != :bg
      end
    end
    k.boot_logged_in("grete")
    k.expect("Quick actions", since: 0)
    k
  end

  # A list made elsewhere, as Spotify makes one, played from its first entry.
  def play_made_list(k)
    k.call do
      list = KlangtenPlaylist::List.new([
        KlangtenPlaylist::Entry.new(File.join(work_dir, "missing", "alpha.mp3"), "Alpha"),
        KlangtenPlaylist::Entry.new(File.join(work_dir, "missing", "beta.mp3"), "Beta")
      ])
      list.title = "Made list"
      list.unsaveable = true
      KlangtenPlaylist.play(list, 0)
    end
    k.wait_until { KlangtenPlaylist.current_entry == nil }
  end

  # Like the notifications, the tab is only there while the playlist has
  # entries; it follows a new list, and leaves when the last entry is removed.
  def test_the_tab_appears_with_entries_and_follows_a_new_list
    k = logged_in
    mark = k.mark
    4.times { k.press("tab") }
    k.expect_not("My playlist", since: mark)
    k.expect_not("Playlist: Made", since: mark)
    play_made_list(k)
    k.move_to("Playlist: Made list")
    k.expect("Alpha")
    assert_equal "Made list", k.call { KlangtenPlaylist.shown_list.title }
    k.press("delete")
    k.expect("Beta")
    k.press("delete")
    k.expect("Quick actions")
    assert_equal :actions, k.call { k.scene.current_main_section }
  end

  # A list played after the own playlist does not hide it once it is empty:
  # the tab stays and shows "My playlist" again.
  def test_an_emptied_list_gives_way_to_my_playlist
    k = logged_in
    k.call { KlangtenPlaylist.internal.add(KlangtenPlaylist::Entry.new(File.join(work_dir, "missing", "gamma.mp3"), "Gamma")) }
    play_made_list(k)
    k.move_to("Playlist: Made list")
    k.press("delete")
    k.expect("Beta")
    k.press("delete")
    k.expect("My playlist")
    k.expect("Gamma")
    assert_equal :playlist, k.call { k.scene.current_main_section }
    assert k.call { KlangtenPlaylist.shown_list.internal? }
  end

  def test_volume_and_moving_with_alt
    k = logged_in
    play_made_list(k)
    k.move_to("Playlist: Made list")
    volume = KlangtenPlaylist.volume
    mark = k.mark
    k.press("alt+up")
    assert_equal volume + KlangtenPlaylist::KEY_VOLUME_STEP, KlangtenPlaylist.volume
    k.press("alt+down", "alt+down")
    assert_equal volume - KlangtenPlaylist::KEY_VOLUME_STEP, KlangtenPlaylist.volume
    k.expect_not(volume.to_s, since: mark)
    k.press("down")
    k.press("alt+shift+up")
    k.expect("Beta")
    assert_equal %w[Beta Alpha], KlangtenPlaylist.shown_list.entries.map(&:title)
  end

  def test_the_menu_opens_the_list_that_played_last
    k = logged_in
    play_made_list(k)
    k.menu("Files", "Playlist")
    k.expect("Made list")
    k.expect("Alpha")
    k.menu("Context menu", "Show my playlist")
    k.expect("My playlist")
  end
end
