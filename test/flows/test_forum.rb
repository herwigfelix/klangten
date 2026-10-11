# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The forum (src/scenes/forum.rb) against the real server: groups, forums,
# threads and posts are created through the same JSON API the client uses
# (as user anna), then hans browses and answers with the keyboard.

require_relative "../test_helper"

require_relative "forum_world"

class ForumTest < KlangtenTest::FlowTest
  include ForumWorld

  def test_browse_groups_forums_and_threads
    world = forum_world
    server.api("POST", "#{F}/#{world[:thread]}", { text: "Antwort von Hans" }, as: "hans")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Forum")
    k.expect("Forum: Testgruppe, Forums: 2, Threads: 1, posts: 2")
    k.press("right")
    k.expect("Select forum: Plauderecke, Threads: 1, posts: 2")
    k.press("right")
    k.expect("Select thread: Hallo Welt, Author: anna, posts: 2")
    k.press("left")
    k.expect("Plauderecke")
  end

  def test_read_a_thread
    world = forum_world
    server.api("POST", "#{F}/#{world[:thread]}", { text: "Antwort von Hans" }, as: "hans")
    k = open_thread
    k.expect("anna")
    k.expect("Erster Beitrag")
    k.expect("1/2")
    k.press("tab")
    k.expect("hans")
    k.expect("Antwort von Hans")
    k.expect("2/2")
    k.press("tab")
    k.expect("Your reply")
    k.press("esc")
    k.expect("Select thread: Hallo Welt")
  end

  def test_write_a_reply
    world = forum_world
    k = open_thread
    k.move_to("Your reply")
    k.type("Danke, Anna!")
    k.move_to("Send")
    k.press("enter")
    k.expect("The post was created.")
    rows = server.sql("SELECT author, body FROM posts WHERE thread_id = ? ORDER BY post_id", world[:thread])
    assert_equal ["hans", "Danke, Anna!"], rows.last
  end
end
