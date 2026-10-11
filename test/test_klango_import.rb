# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# KlangoImport: finding Klango 3/4, reading their registries (read-only, from
# a copy) and the Lua literal reader. Uses throw-away registries in a
# temporary home folder.

require "minitest/autorun"
require "tmpdir"
require "sqlite3"
require "digest"
require_relative "k04_support"
K04Support.load_source "src/eapi/klango_import.rb"

class TestKlangoImport < Minitest::Test
  Existing = Struct.new(:name, :text)

  def setup
    @home = Dir.mktmpdir("k04-import-home")
  end

  def teardown
    FileUtils.remove_entry(@home) if @home && File.directory?(@home)
  end

  def make_registry(dir, rows)
    path = File.join(@home, dir)
    FileUtils.mkdir_p(path)
    database = SQLite3::Database.new(File.join(path, "registry.db"))
    database.execute("CREATE TABLE reg (path TEXT PRIMARY KEY, value TEXT)")
    rows.each { |key, value| database.execute("INSERT INTO reg VALUES (?, ?)", [key, value]) }
    database.close
    File.join(path, "registry.db")
  end

  def test_lua_literal
    lua = KlangoImport::LuaLiteral
    assert_equal [{ "title" => "A", "body" => "x\n\"y\"" }], lua.parse(%q({{title="A",body="x\n\"y\""}}))
    assert_equal({ "a" => 1, "b" => -2.5, "c d" => true, 3 => nil, "l" => [1, 2], "h" => 16 }, lua.parse(%q({a=1,b=-2.5,["c d"]=true,[3]=nil,l={1,2},h=0x10})))
    assert_equal "Ä", lua.parse(%q("\195\132"))
    assert_equal [], lua.parse("{}")
    assert_nil lua.parse("{a=1")
    assert_nil lua.parse("os.execute('x')")
    assert_nil lua.parse("{a=1} trailing")
    assert_nil lua.parse(nil)
  end

  def test_nothing_found
    assert_empty KlangoImport.sources(home: @home, env: {})
    assert KlangoImport.find(home: @home, env: {}).sources.empty?
  end

  def test_reads_both_versions_without_changing_them
    k3 = make_registry(".klango", {
      "/user/notes" => %q({{title="Einkauf",body="Milch"},{title="",body="Nur Text\nzweite Zeile"},{title="",body=""}}),
      "/user/MastodonSettings" => %q({instance="https://example.social",access_token="tok3",client_id="c",client_secret="s",acct="alice",account_id="7"}),
      "/mach/lastuser" => "alice"
    })
    k4 = make_registry(".klango4", {
      "/user/notes" => %q({{title="Einkauf",body="Milch"},{title="Neu",body="Nur in K4"}}),
      "[apps/extservices/kmastodon]/user/app/kmastodon" => %q({instance="example.social",access_token="tok4",acct="alice"})
    })
    before = [k3, k4].map { |path| [Digest::SHA256.file(path).hexdigest, File.mtime(path)] }
    found = KlangoImport.find(home: @home, env: {})
    assert_equal ["Klango 4", "Klango 3"], found.sources.map(&:label)
    assert_equal "alice", found.users[:klango3]
    assert_equal ["Einkauf", "Neu", "Nur Text"], found.notes.map { |note| KlangoImport.note_name(note) }
    assert_equal ["tok4", "tok3"], found.mastodon.map(&:token)
    assert_equal "Klango 4", found.mastodon.first.origin
    refute found.empty?
    # Klango's files are untouched and no journal files appeared next to them.
    assert_equal before, [k3, k4].map { |path| [Digest::SHA256.file(path).hexdigest, File.mtime(path)] }
    assert_equal ["registry.db"], Dir.children(File.dirname(k3))
    # Already in Klangten: same name and text.
    fresh = KlangoImport.new_notes(found.notes, [Existing.new("Einkauf", "Milch\n")])
    assert_equal ["Neu", "Nur Text"], fresh.map { |note| KlangoImport.note_name(note) }
  end

  def test_environment_overrides_and_broken_values
    make_registry("anderswo", { "/user/notes" => "{kaputt", "/user/MastodonSettings" => %q({instance="x.social"}) })
    found = KlangoImport.find(home: @home, env: { "KLANGO3_HOME" => File.join(@home, "anderswo") })
    assert_equal ["Klango 3"], found.sources.map(&:label)
    assert found.empty?
  end
end
