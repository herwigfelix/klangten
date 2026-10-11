# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Persons (src/scenes/users_klango.rb, user menu, contacts): status history
# (Control+F9), special users, the user menu entries, comments on contacts,
# contacts of a user and recently changed audio avatars.

require_relative "../test_helper"
require_relative "kcommunity_world"

class KCommunityPersonsTest < KlangtenTest::FlowTest
  include KCommunityWorld

  def logged_in(user = "hans")
    k = klangten(server: server)
    k.boot_logged_in(user)
    k
  end

  def test_own_status_history_on_control_f9
    server.create_user("hans")
    server.api("PATCH", "/api/v1/users/me/status", { text: "Im Urlaub" }, as: "hans")
    server.api("PATCH", "/api/v1/users/me/status", { text: "Wieder da" }, as: "hans")
    k = logged_in
    k.press("ctrl+f9")
    k.expect("My status history")
    k.expect("Wieder da")
    k.press("down")
    k.expect("Im Urlaub")
    k.press("delete")
    k.expect("Do you want to delete this status from your history?")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    assert_equal [["Wieder da"]], server.sql("SELECT status FROM status_history WHERE klangoid = 'hans'")
  end

  def test_special_users_and_user_menu
    server.create_user("hans")
    server.create_user("anna", admin: true)
    server.api("PATCH", "/api/v1/users/me/status", { text: "Annas Status" }, as: "anna")
    k = logged_in
    k.menu("Community", "Users", "Special users")
    k.move_to("anna: Administrator", key: "down")
    k.press("enter")
    k.move_to("Status history", key: "down")
    k.press("enter")
    k.expect("Status history of anna")
    k.expect("Annas Status")
  end

  def test_comment_on_a_contact_and_contacts_of_a_user
    server.create_user("hans", "anna", "grete")
    server.api("POST", "/api/v1/contacts", { user: "anna" }, as: "hans")
    k = logged_in
    k.menu("Community", "Users", "My contacts")
    k.expect("anna")
    k.menu("Context menu", "Comment on this contact")
    k.expect("Comment on anna")
    k.type("Nachbarin")
    k.move_to("Others may see this comment")
    k.press("space")
    k.move_to("Save")
    k.press("enter")
    k.expect("The comment has been saved.")
    k.expect("anna (Nachbarin)")
    assert_equal [["anna", "Nachbarin", 1]], server.sql("SELECT contact, comment, public_comment FROM buddies WHERE owner = 'hans'")
    # grete sees the public part of hans's contacts
    rows = server.api("GET", "/api/v1/users/hans/contacts", {}, as: "grete")["contacts"]
    assert_equal ["anna"], rows.map { |r| r["user"] }
  end

  def test_recently_changed_avatars
    server.create_user("hans", "anna")
    server.sql("INSERT INTO avatars (klangoid, url, updated) VALUES ('anna', 'https://example.org/a', 1700000000)")
    k = logged_in
    k.menu("Community", "Users", "Recently changed audio avatars")
    k.expect("anna, ")
  end
end
