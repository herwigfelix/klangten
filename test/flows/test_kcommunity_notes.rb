# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Notes (src/scenes/notes.rb, notes_klango.rb): notes on this device, copying
# them to the server, and notes shared with a Klango group.

require_relative "../test_helper"
require_relative "kcommunity_world"

class KCommunityNotesTest < KlangtenTest::FlowTest
  include KCommunityWorld

  def notes(user = "hans")
    k = klangten(server: server)
    k.boot_logged_in(user)
    k.menu("Community", "Notes")
    k
  end

  def test_note_on_this_device_and_on_the_server
    server.create_user("hans")
    k = notes
    k.press("ctrl+l")
    k.expect("Notes on this device")
    k.press("ctrl+n")
    k.expect("note title")
    k.type("Einkauf")
    k.press("tab")
    k.type("Brot und Milch")
    k.move_to("Save")
    k.press("enter")
    k.expect("The note has been created")
    k.expect("Einkauf")
    note = k.call { Klangten::LocalNotes.all.map { |n| [n.name, n.text] } }
    assert_equal [["Einkauf", "Brot und Milch"]], note
    assert_equal [], server.sql("SELECT title FROM notes")
    k.menu("Context menu", "Save on the server")
    k.expect("The note has been saved on the server.")
    assert_equal [["hans", "Einkauf", "Brot und Milch"]], server.sql("SELECT owner, title, body FROM notes")
  end

  def test_group_notes
    server.create_user("hans", "anna")
    gid = kc_group
    nid = server.api("POST", "/api/v1/notes", { name: "Treffpunkt", text: "Am Bahnhof" }, as: "anna")["id"]
    server.api("PUT", "/api/v1/notes/#{nid}/groups/#{gid}", {}, as: "anna")
    k = notes
    k.press("ctrl+g")
    k.expect("Notes of which group?")
    k.expect("Runde")
    k.press("enter")
    k.expect("Notes of Runde")
    k.expect("Treffpunkt")
    k.press("enter")
    k.expect("Am Bahnhof")
  end

  def test_share_own_note_with_a_group
    server.create_user("hans", "anna")
    gid = kc_group
    server.api("POST", "/api/v1/notes", { name: "Liste", text: "Zelt" }, as: "hans")
    k = notes
    k.expect("Liste")
    k.press("enter")
    k.menu("Context menu", "Share with a group")
    k.expect("Share the note with which group?")
    k.press("enter")
    k.expect("The members of Runde can now read this note.")
    assert_equal [[gid, "note"]], server.sql("SELECT gid, obj_type FROM group_shares")
  end
end
