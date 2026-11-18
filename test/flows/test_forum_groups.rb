# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Joining groups (src/scenes/forum.rb, context menu of the group list):
# an open group from "Open groups", an invitation from "Awaiting group
# invitations" — against the real server.

require_relative "../test_helper"
require_relative "forum_world"

class ForumGroupsTest < KlangtenTest::FlowTest
  include ForumWorld

  def make_group(name, public:, open:, posts: true)
    gid = server.api("POST", "#{F}/groups", { name: name, description: "Zum Testen", lang: "en", public: public, open: open }, as: "anna")["id"]
    fid = server.api("POST", "#{F}/group/#{gid}/forums", { name: "Plauderecke", type: 0 }, as: "anna")["forumid"]
    server.api("POST", F, { forum: fid, thread_name: "Hallo Welt", text: "Erster Beitrag" }, as: "anna") if posts
    gid
  end

  def test_join_an_open_group
    server.create_user("hans", "anna")
    gid = make_group("Offene Runde", public: 1, open: 1)
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Forum")
    k.move_to("Open groups (1)", key: "down")
    k.press("right")
    k.expect("Offene Runde")
    k.menu("Context menu", "Join")
    k.expect("Are you sure you want to join Offene Runde?")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    k.expect("You've just joined the group")
    assert_equal [["1"]], server.sql("SELECT phug FROM group_members WHERE gid = ? AND klangoid = 'hans'", gid)
  end

  def test_accept_an_invitation
    server.create_user("hans", "anna")
    gid = make_group("Geheim", public: 0, open: 0)
    server.api("POST", "#{F}/group/#{gid}/invitations", { user: "hans" }, as: "anna")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Forum")
    k.move_to("Awaiting group invitation", key: "down")
    k.press("right")
    k.expect("Geheim")
    k.menu("Context menu", "Accept invitation")
    k.expect("Are you sure you want to join Geheim?")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    k.expect("You've just joined the group")
    assert_equal [["1"]], server.sql("SELECT phug FROM group_members WHERE gid = ? AND klangoid = 'hans'", gid)
  end
end
