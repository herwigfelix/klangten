# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Finding and reading the data of Klango 3 and Klango 4 installations on this
# computer (desktop only), for "Import data from Klango" (Scene_KlangoImport).
#
# Both Klango versions keep their settings in an SQLite key-value table
# (registry.db, table reg(path, value)): Klango 3 in ~/.klango, Klango 4 in
# ~/.klango4 (the same on Windows, under the user profile). Values that are
# tables are stored as Lua table literals. Klango is only ever READ: the
# registry is copied to a temporary folder first and the copy is opened, so
# not even SQLite's journal files are created next to the original.
#
# What has a counterpart in Klangten and is therefore imported:
# - local notes (/user/notes, a list of {title, body}) become notes on the
#   server, which Klangten and Klango share;
# - the Mastodon sign-in (Klango 3 /user/MastodonSettings, Klango 4 the same
#   key or its Mastodon program's settings) becomes Klangten's Mastodon
#   account, with the same access token.
# Everything Klango keeps on the server (messages, forums, server notes,
# media favourites, blogs) is already visible in Klangten without import.

require "fileutils"
require "tmpdir"

module KlangoImport
  REGISTRY_FILE = "registry.db".freeze
  NOTES_KEY = "/user/notes".freeze
  MASTODON_KEYS = [
    "[apps/extservices/kmastodon]/user/app/kmastodon",
    "/user/MastodonSettings",
    "[apps/extservices/kmastodon]/user/app/mastodon_settings"
  ].freeze
  USER_KEYS = ["/mach/lastuser", "/mach/autologinuser"].freeze

  Source = Struct.new(:kind, :directory, keyword_init: true) do
    def registry
      File.join(directory, REGISTRY_FILE)
    end

    def label
      kind == :klango4 ? "Klango 4" : "Klango 3"
    end
  end

  Note = Struct.new(:title, :body, :origin, keyword_init: true)
  MastodonLogin = Struct.new(:instance, :token, :client_id, :client_secret, :account_id, :acct, :display, :origin, keyword_init: true)
  Findings = Struct.new(:sources, :notes, :mastodon, :users, keyword_init: true) do
    def empty?
      notes.empty? && mastodon.empty?
    end
  end

  class << self
    # Klango installations with a registry on this computer (newest first).
    def sources(home: Dir.home, env: ENV)
      candidates = []
      k4 = env["KLANGO4_HOME"].to_s.strip
      candidates << Source.new(kind: :klango4, directory: k4 != "" ? k4 : File.join(home, ".klango4"))
      k3 = ["KLANGO3_HOME", "KLANGO_CONFIG_DIR"].map { |key| env[key].to_s.strip }.find { |value| value != "" }
      candidates << Source.new(kind: :klango3, directory: k3 || File.join(home, ".klango"))
      candidates.select { |source| File.file?(source.registry) }
    rescue StandardError
      []
    end

    def find(home: Dir.home, env: ENV)
      inspect_sources(sources(home: home, env: env))
    end

    def inspect_sources(list)
      notes = []
      mastodon = []
      users = {}
      list.each do |source|
        values = read_registry(source.registry)
        next if values == nil
        user = USER_KEYS.map { |key| values[key].to_s.strip }.find { |value| value != "" }
        users[source.kind] = user if user != nil
        notes.concat(notes_from(values[NOTES_KEY], source.label))
        login = mastodon_from(values, source.label)
        mastodon << login if login != nil
      end
      Findings.new(sources: list, notes: unique_notes(notes), mastodon: unique_logins(mastodon), users: users)
    end

    # All rows of a Klango registry as {path => value}, read from a copy.
    def read_registry(path)
      require "sqlite3"
      Dir.mktmpdir("klangten-klango-import") do |dir|
        copy = File.join(dir, REGISTRY_FILE)
        FileUtils.cp(path, copy)
        ["-wal", "-shm"].each do |suffix|
          FileUtils.cp(path + suffix, copy + suffix) if File.file?(path + suffix)
        end
        database = SQLite3::Database.new(copy, readonly: true)
        begin
          values = {}
          database.execute("SELECT path, value FROM reg") do |row|
            values[text(row[0])] = text(row[1])
          end
          values
        ensure
          database.close
        end
      end
    rescue StandardError, LoadError => e
      Log.warning("Klango registry #{path} could not be read: #{e.class}: #{e.message}") if defined?(Log)
      nil
    end

    def notes_from(raw, origin)
      list = LuaLiteral.parse(raw)
      list = list.values if list.is_a?(Hash)
      return [] unless list.is_a?(Array)
      list.filter_map do |row|
        next nil unless row.is_a?(Hash)
        title = row["title"].to_s.strip
        body = row["body"].to_s
        next nil if title == "" && body.strip == ""
        Note.new(title: title, body: body, origin: origin)
      end
    end

    def mastodon_from(values, origin)
      MASTODON_KEYS.each do |key|
        settings = LuaLiteral.parse(values[key])
        next unless settings.is_a?(Hash)
        token = settings["access_token"].to_s
        instance = settings["instance"].to_s.strip
        next if token == "" || instance == ""
        return MastodonLogin.new(
          instance: instance, token: token,
          client_id: settings["client_id"].to_s, client_secret: settings["client_secret"].to_s,
          account_id: settings["account_id"].to_s, acct: settings["acct"].to_s,
          display: settings["display"].to_s, origin: origin
        )
      end
      nil
    end

    # Name of a note in Klangten: the title, otherwise the first line.
    def note_name(note)
      name = note.title.to_s.strip
      name = note.body.to_s.strip.lines.first.to_s.strip if name == ""
      name = name[0, 200]
      name == "" ? "Klango" : name
    end

    # The notes that are not yet among the existing ones (same name and text).
    def new_notes(notes, existing)
      known = existing.map { |note| [note.name.to_s.strip, normalize(note.text)] }
      notes.reject { |note| known.include?([note_name(note), normalize(note.body)]) }
    end

    private

    def unique_notes(notes)
      seen = {}
      notes.select do |note|
        key = [note_name(note), normalize(note.body)]
        next false if seen[key]
        seen[key] = true
      end
    end

    def unique_logins(logins)
      seen = {}
      logins.select do |login|
        key = [login.instance.downcase.sub(%r{\Ahttps?://}, "").chomp("/"), login.token]
        next false if seen[key]
        seen[key] = true
      end
    end

    def normalize(text)
      text.to_s.gsub("\r\n", "\n").strip
    end

    def text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end

  # A strict reader for Lua table literals as written by Klango (no code is
  # evaluated). Tables with the keys 1..n become arrays, all others hashes;
  # anything malformed gives nil.
  module LuaLiteral
    class ParseError < StandardError; end

    IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/
    NUMBER = /-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/
    ESCAPES = { "n" => "\n", "r" => "\r", "t" => "\t", "a" => "\a", "b" => "\b", "f" => "\f", "v" => "\v" }.freeze

    def self.parse(text)
      return nil if text == nil
      Parser.new(text).document
    rescue ParseError
      nil
    end

    class Parser
      def initialize(text)
        @source = text.to_s.b
        @position = 0
      end

      def document
        value = read_value
        skip_space
        @position == @source.size ? value : nil
      end

      private

      def skip_space
        @position += 1 while @position < @source.size && " \t\r\n".include?(@source[@position])
      end

      def peek
        skip_space
        raise ParseError if @position >= @source.size
        @source[@position]
      end

      def expect(char)
        raise ParseError if peek != char
        @position += 1
      end

      def read_value
        char = peek
        return read_table if char == "{"
        return read_string(char) if char == '"' || char == "'"
        return read_number if char =~ /[\d.\-]/
        word = @source.match(IDENTIFIER, @position)
        raise ParseError if word == nil || word.begin(0) != @position
        @position = word.end(0)
        case word[0]
        when "nil" then nil
        when "true" then true
        when "false" then false
        else raise ParseError
        end
      end

      def read_number
        match = @source.match(NUMBER, @position)
        raise ParseError if match == nil || match.begin(0) != @position
        @position = match.end(0)
        number = match[0]
        return Integer(number.sub(/\A(-?)0[xX]/, '\10x'), 16) if number =~ /\A-?0[xX]/
        number =~ /[.eE]/ ? Float(number) : Integer(number, 10)
      end

      def read_string(quote)
        expect(quote)
        out = "".b
        loop do
          raise ParseError if @position >= @source.size
          char = @source[@position]
          @position += 1
          return out.force_encoding(Encoding::UTF_8).scrub if char == quote
          if char != "\\"
            out << char
            next
          end
          raise ParseError if @position >= @source.size
          escape = @source[@position]
          @position += 1
          if escape =~ /\d/
            digits = escape
            while digits.size < 3 && @position < @source.size && @source[@position] =~ /\d/
              digits << @source[@position]
              @position += 1
            end
            out << (digits.to_i & 0xff).chr
          else
            out << (ESCAPES[escape] || escape)
          end
        end
      end

      def read_table
        expect("{")
        entries = {}
        next_index = 1
        loop do
          char = peek
          if char == "}"
            @position += 1
            return table_value(entries)
          end
          key = nil
          if char == "["
            @position += 1
            key = read_value
            expect("]")
            expect("=")
          else
            word = @source.match(IDENTIFIER, @position)
            if word != nil && word.begin(0) == @position
              after = word.end(0)
              after += 1 while after < @source.size && " \t\r\n".include?(@source[after])
              if @source[after] == "=" && @source[after + 1] != "="
                key = word[0].dup.force_encoding(Encoding::UTF_8)
                @position = after + 1
              end
            end
          end
          if key == nil
            entries[next_index] = read_value
            next_index += 1
          else
            key = key.to_i if key.is_a?(Float) && key == key.floor
            entries[key] = read_value
          end
          @position += 1 if [",", ";"].include?(peek)
        end
      end

      def table_value(entries)
        return [] if entries.empty?
        keys = entries.keys
        if keys.all? { |key| key.is_a?(Integer) } && keys.sort == (1..keys.size).to_a
          keys.sort.map { |key| entries[key] }
        else
          entries
        end
      end
    end
  end
end
