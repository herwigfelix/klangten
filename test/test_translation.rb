# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# EltenLink::Translation (splitting, request shape) and EltenLink::StartupInfo.

require "minitest/autorun"
require_relative "k04_support"
K04Support.load_source "src/eltenlink/translation.rb", "src/eltenlink/startup_info.rb"

class TestTranslation < Minitest::Test
  def test_split_keeps_the_text
    text = (["Erster Satz. Zweiter Satz!"] * 40).join(" ") + "\n\n" + ("Absatz zwei. " * 50) + "\n" + ("x" * 900)
    pieces = EltenLink::Translation.split(text, 300)
    assert_equal text, pieces.join
    assert pieces.all? { |piece| piece.size <= 300 }
    assert pieces.size > 3
    assert_equal ["kurz"], EltenLink::Translation.split("kurz", 300)
  end

  def test_translate_requests_each_piece_and_keeps_breaks
    client = K04Support::FakeClient.new { |_m, _p, params| { "text" => params["text"].upcase, "from" => "de", "to" => params["to"] } }
    text = ("Hallo Welt. " * 30).strip + "\n\n" + ("Noch ein Absatz. " * 30).strip
    result = EltenLink::Translation.translate(client, text, to: "en", from: 0)
    assert_equal text.upcase, result.text
    assert_equal "de", result.from
    assert client.calls.all? { |method, path, params| method == "POST" && path == "/api/v1/translate" && params["to"] == "en" && !params.key?("from") }
    single = K04Support::FakeClient.new { |_m, _p, params| { "text" => "Bonjour", "from" => params["from"] } }
    result = EltenLink::Translation.translate(single, "  Hallo\n", to: "fr", from: "de")
    assert_equal "  Bonjour\n", result.text
    assert_equal({ "text" => "Hallo", "to" => "fr", "from" => "de" }, single.calls[0][2])
  end

  def test_empty_text_makes_no_request
    client = K04Support::FakeClient.new { raise "no request expected" }
    assert_equal "  ", EltenLink::Translation.translate(client, "  ", to: "en").text
  end

  def test_dev_server_answers_with_a_klangten_error_or_a_translation
    skip "KLANGTEN_TEST_API not set" unless K04Support::DevClient.available?
    client = K04Support::DevClient.login(ENV.fetch("KLANGTEN_TEST_USER"), ENV.fetch("KLANGTEN_TEST_PASSWORD"))
    begin
      result = EltenLink::Translation.translate(client, "Guten Morgen", to: "en")
      refute_empty result.text
    rescue EltenLink::Error => e
      # A dev server usually has no Gemini key.
      assert_includes ["translate.unavailable", "translate.failed"], e.code
    end
    error = assert_raises(EltenLink::Error) { EltenLink::Translation.translate(client, "Hallo", to: "english!") }
    assert_equal "translate.invalid_language", error.code
  end

  def test_startup_messages
    client = K04Support::FakeClient.new { { "messages" => [{ "id" => "a1", "type" => "infobox", "text" => "Wartung" }, { "id" => "x", "text" => " " }, "kaputt"] } }
    messages = EltenLink::StartupInfo.messages(client)
    assert_equal 1, messages.size
    assert_equal ["a1", "infobox", "Wartung"], [messages[0].id, messages[0].type, messages[0].text]
    assert_equal [["GET", "/api/v1/startup-info", nil]], client.calls
  end

  def test_startup_messages_on_dev_server
    skip "KLANGTEN_TEST_API not set" unless K04Support::DevClient.available?
    skip "KLANGTEN_TEST_ADMIN not set" if ENV["KLANGTEN_TEST_ADMIN"].to_s == ""
    admin = K04Support::DevClient.login(ENV["KLANGTEN_TEST_ADMIN"], ENV.fetch("KLANGTEN_TEST_ADMIN_PASSWORD"))
    user = K04Support::DevClient.login(ENV.fetch("KLANGTEN_TEST_USER"), ENV.fetch("KLANGTEN_TEST_PASSWORD"))
    admin.api_data("PUT", "/api/v1/startup-info", { "text" => "Heute Abend Wartung.", "type" => "textarea" })
    messages = EltenLink::StartupInfo.messages(user)
    assert_equal "Heute Abend Wartung.", messages[0].text
    assert_equal "textarea", messages[0].type
    admin.api_data("PUT", "/api/v1/startup-info", { "text" => "" })
    assert_empty EltenLink::StartupInfo.messages(user)
  end
end
