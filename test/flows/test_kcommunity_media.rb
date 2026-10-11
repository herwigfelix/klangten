# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Media catalog (src/scenes/mediacatalog.rb), what Klangten 0.4 added: the
# history on this device, entering an address, favourites of friends, sharing
# my favourites, group favourites and notes to the editors.

require_relative "../test_helper"
require_relative "kcommunity_world"

class KCommunityMediaTest < KlangtenTest::FlowTest
  include KCommunityWorld

  def open_entry_by_number(k, id)
    k.move_to("Enter an address", key: "down")
    k.press("enter")
    k.expect("Address of a stream, feed or web page")
    k.type(id.to_s)
    k.press("enter")
  end

  def test_enter_address_and_history
    server.create_user("hans")
    id = kc_entry("KT Seite", "https://example.org/kt", type: 11)
    k = kc_catalog
    open_entry_by_number(k, id)
    k.expect("KT Seite")
    k.move_to("Open in the web browser", key: "down")
    k.press("enter")
    assert_includes k.opened_urls, "https://example.org/kt"
    assert_equal ["KT Seite"], k.call { Klangten::MediaHistory.entries.map(&:title) }
    k.move_to("My history", key: "up")
    k.press("enter")
    k.expect("KT Seite")
  end

  def test_enter_unknown_number
    server.create_user("hans")
    k = kc_catalog
    open_entry_by_number(k, 987654)
    k.expect("There is no entry with this number in the catalog.")
  end

  def test_favourites_of_friends
    server.create_user("hans", "anna")
    id = kc_entry("KT Radio", "http://radio.example.org/kt")
    server.api("PUT", "/api/v1/media/favorites/items/#{id}", {}, as: "anna")
    server.api("PUT", "/api/v1/media/favorites/shares/hans", {}, as: "anna")
    k = kc_catalog
    k.move_to("Favourites of friends", key: "down")
    k.press("enter")
    k.expect("anna, 1 favourite")
    k.press("enter")
    k.expect("Favourites of anna")
    k.expect("KT Radio")
  end

  def test_share_my_favourites
    server.create_user("hans", "anna")
    k = kc_catalog
    k.move_to("Share my favourites", key: "down")
    k.press("enter")
    k.expect("People who can see your favourites")
    k.move_to("Share with a user")
    k.press("enter")
    k.expect("Who should see your favourites?")
    k.type("anna")
    k.press("enter")
    k.expect("anna can now see your favourites.")
    assert_equal [["hans", "anna"]], server.sql("SELECT klangoid, kid FROM catalog_shared")
    k.move_to("Publish my favourites for everyone", key: "shift+tab")
    k.press("space")
    k.expect("Everyone can now see your favourites.")
    assert_includes server.sql("SELECT kid FROM catalog_shared WHERE klangoid = 'hans'").flatten, "___k_psc"
  end

  def test_group_favourites
    server.create_user("hans", "anna")
    gid = kc_group
    id = kc_entry("KT Radio", "http://radio.example.org/kt")
    server.api("PUT", "/api/v1/media/groups/#{gid}/favorites/items/#{id}", {}, as: "anna")
    k = kc_catalog
    k.move_to("Group favourites", key: "down")
    k.press("enter")
    k.expect("Runde, 1 entry")
    k.press("enter")
    k.expect("KT Radio")
  end

  def test_note_to_the_editors
    server.create_user("hans")
    id = kc_entry("KT Radio", "http://radio.example.org/kt")
    k = kc_catalog
    open_entry_by_number(k, id)
    k.expect("KT Radio")
    k.move_to("Send a correction or note to the editors", key: "down")
    k.press("enter")
    k.expect("Your correction or note for the editors of the catalog about KT Radio")
    k.type("Der Stream ist tot")
    k.press("ctrl+enter")
    k.expect("Your note has been sent to the editors.")
    assert_equal [["hans", "Der Stream ist tot"]], server.sql("SELECT klangoid, text FROM catalog_editor_msgs")
  end
end
