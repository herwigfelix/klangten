# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Polls (src/scenes/polls.rb), what Klangten 0.4 added: drafts, My polls and
# drafts (publish in a group, withdraw), browsing by author and answers saved
# for later.

require "json"
require_relative "../test_helper"
require_relative "kcommunity_world"

class KCommunityPollsTest < KlangtenTest::FlowTest
  include KCommunityWorld

  QUESTIONS = [["Wohin?", 0, "Wald", "See"]].freeze

  def polls(user = "hans")
    k = klangten(server: server)
    k.boot_logged_in(user)
    k.menu("Community", "Polls")
    k
  end

  def test_save_a_new_poll_as_draft
    server.create_user("hans")
    k = polls
    k.press("ctrl+n")
    k.expect("Poll name")
    k.type("Ausflug")
    k.move_to("Save as draft")
    k.press("enter")
    k.expect("The poll has been saved as a draft.")
    assert_equal [["Ausflug", 0]], server.sql("SELECT title, public FROM polls")
  end

  def test_publish_a_draft_in_a_group
    server.create_user("hans", "anna")
    gid = kc_group(name: "Runde", members: ["hans"])
    server.api("POST", "/api/v1/polls", { name: "Ausflug", language: "de", description: "", questions: JSON.generate(QUESTIONS), draft: 1 }, as: "hans")
    k = polls
    k.press("ctrl+m")
    k.expect("My polls and drafts")
    k.expect("Ausflug")
    k.expect("draft")
    k.press("enter")
    k.move_to("Publish", key: "down")
    k.press("enter")
    k.expect("Publish Ausflug")
    k.move_to("For the members of Runde", key: "down")
    k.press("enter")
    k.expect("The poll has been published.")
    assert_equal [[2, gid]], server.sql("SELECT public, gid FROM polls")
    k.expect("in a group")
  end

  def test_incomplete_draft_cannot_be_published
    server.create_user("hans")
    server.api("POST", "/api/v1/polls", { name: "Leer", language: "de", description: "", questions: "[]", draft: 1 }, as: "hans")
    k = polls
    k.press("ctrl+m")
    k.expect("Leer")
    k.press("enter")
    k.move_to("Publish", key: "down")
    k.press("enter")
    k.expect("For everyone")
    k.press("enter")
    k.expect("The poll has no questions.")
    assert_equal [[0]], server.sql("SELECT public FROM polls")
  end

  def test_browse_by_author
    server.create_user("hans", "anna")
    server.api("POST", "/api/v1/polls", { name: "Annas Frage", language: "de", description: "", questions: JSON.generate(QUESTIONS) }, as: "anna")
    k = polls
    k.menu("Context menu", "Browse polls", "By author")
    k.expect("anna, 1 poll")
    k.press("enter")
    k.expect("Polls: anna")
    k.expect("Annas Frage")
  end

  def test_answers_saved_for_later
    server.create_user("hans", "anna")
    pid = server.api("POST", "/api/v1/polls", { name: "Annas Frage", language: "de", description: "", questions: JSON.generate(QUESTIONS) }, as: "anna")["id"]
    k = polls
    k.expect("Annas Frage")
    k.press("enter")
    k.expect("Vote")
    k.press("enter")
    k.move_to("Wohin?")
    k.press("down")
    k.expect("See")
    k.move_to("Save my answers for later")
    k.press("enter")
    k.expect("Your answers have been saved.")
    assert_equal [[1, "2"]], server.sql("SELECT ppid, vote FROM poll_drafts WHERE poll_id = ? AND klangoid = 'hans'", pid)
    k.expect("Annas Frage")
    k.press("enter")
    k.press("enter")
    k.expect("Your saved answers have been filled in.")
  end
end
