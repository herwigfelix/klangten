# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Data that stays on this device: the play history of the media catalog and
# the local notes. Each account has its own folder below the data directory
# (local/<account>/, "guest" without login). Files are JSON arrays, written
# through a temporary file so a crash never leaves half a file behind.

require "json"
require "fileutils"

module Klangten
  module LocalStore
    class << self
      # Overridable root (tests); defaults to <data directory>/local.
      attr_writer :root

      def root
        @root || File.join(Dirs.eltendata, "local")
      end

      def account
        name = defined?(Session) && Session.respond_to?(:logged?) && Session.logged? ? Session.name.to_s : ""
        name = name.downcase.gsub(/[^a-z0-9_.-]/, "_")
        name == "" ? "guest" : name
      end

      def path(name, user = account)
        File.join(root, user, name)
      end

      def read(name, user = account)
        file = path(name, user)
        return [] unless File.file?(file)
        data = JSON.parse(File.read(file, encoding: "UTF-8"))
        data.is_a?(Array) ? data.select { |row| row.is_a?(Hash) } : []
      rescue StandardError => e
        Log.warning("Local store: cannot read #{name}: #{e.class}: #{e.message}") if defined?(Log)
        []
      end

      def write(name, rows, user = account)
        file = path(name, user)
        FileUtils.mkdir_p(File.dirname(file))
        temporary = file + ".tmp"
        File.write(temporary, JSON.pretty_generate(rows.to_a), encoding: "UTF-8")
        File.delete(file) if File.exist?(file) && Gem.win_platform?
        File.rename(temporary, file)
        true
      rescue StandardError => e
        Log.error("Local store: cannot write #{name}: #{e.class}: #{e.message}") if defined?(Log)
        false
      end
    end
  end

  # The media catalog's own play history (like "my history" in Klango):
  # newest first, at most LIMIT entries, one entry per catalog item or address.
  module MediaHistory
    FILE = "media_history.json".freeze
    LIMIT = 100

    Entry = Struct.new(:id, :title, :type, :url, :time, keyword_init: true) do
      def key
        id.to_i > 0 ? "id:#{id.to_i}" : "url:#{url}"
      end

      def to_h
        { "id" => id.to_i, "title" => title.to_s, "type" => type.to_s, "url" => url.to_s, "time" => time.to_i }
      end
    end

    class << self
      def entries
        LocalStore.read(FILE).map do |row|
          Entry.new(id: row["id"].to_i, title: row["title"].to_s, type: row["type"].to_s, url: row["url"].to_s, time: row["time"].to_i)
        end.reject { |entry| entry.id <= 0 && entry.url == "" }
      end

      # item: anything with id/title/type/url (EltenLink::MediaItem) or a Hash.
      def add(item = nil, id: nil, title: nil, type: nil, url: nil)
        if item != nil
          id ||= value(item, :id)
          title ||= value(item, :title)
          type ||= value(item, :type)
          url ||= value(item, :stream_url).to_s != "" ? value(item, :stream_url) : value(item, :url)
        end
        entry = Entry.new(id: id.to_i, title: title.to_s, type: type.to_s, url: url.to_s, time: Time.now.to_i)
        return false if entry.id <= 0 && entry.url == ""
        entry.title = entry.url if entry.title == ""
        rows = entries.reject { |old| old.key == entry.key }
        LocalStore.write(FILE, ([entry] + rows).first(LIMIT).map(&:to_h))
      end

      def remove(entry)
        LocalStore.write(FILE, entries.reject { |old| old.key == entry.key }.map(&:to_h))
      end

      def clear
        LocalStore.write(FILE, [])
      end

      private

      def value(item, key)
        return item[key.to_s] || item[key] if item.is_a?(Hash)
        item.respond_to?(key) ? item.public_send(key) : nil
      end
    end
  end

  # Notes kept only on this device (Klango's local notes), newest first.
  module LocalNotes
    FILE = "notes.json".freeze

    Note = Struct.new(:id, :name, :text, :author, :created, :modified, keyword_init: true) do
      def to_h
        { "id" => id.to_s, "name" => name.to_s, "text" => text.to_s, "author" => author.to_s,
          "created" => created.to_i, "modified" => modified.to_i }
      end
    end

    class << self
      def all
        LocalStore.read(FILE).map do |row|
          Note.new(id: row["id"].to_s, name: row["name"].to_s, text: row["text"].to_s, author: row["author"].to_s,
            created: row["created"].to_i, modified: row["modified"].to_i)
        end.reject { |note| note.id == "" }
      end

      def find(id)
        all.find { |note| note.id == id.to_s }
      end

      def create(name, text, author: "")
        now = Time.now.to_i
        note = Note.new(id: "#{now.to_s(36)}#{rand(36**6).to_s(36)}", name: name.to_s, text: text.to_s,
          author: author.to_s, created: now, modified: now)
        LocalStore.write(FILE, ([note] + all).map(&:to_h)) ? note : nil
      end

      def update(id, name: nil, text: nil)
        found = nil
        notes = all.map do |note|
          if note.id == id.to_s
            note.name = name.to_s if name != nil
            note.text = text.to_s if text != nil
            note.modified = Time.now.to_i
            found = note
          end
          note
        end
        return nil if found == nil
        LocalStore.write(FILE, notes.map(&:to_h)) ? found : nil
      end

      def delete(id)
        notes = all
        left = notes.reject { |note| note.id == id.to_s }
        return false if left.size == notes.size
        LocalStore.write(FILE, left.map(&:to_h))
      end
    end
  end
end
