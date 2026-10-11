# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Bookmarks for long media: where a podcast episode or an Internet Archive
# file was left, so the next time it can continue there.
#
# The address of the media is the key. A bookmark is kept only for a position
# worth returning to: not in the first seconds, and not at the very end - an
# episode heard to its end loses its bookmark. The list lives in
# media_bookmarks.json in the data directory and holds the most recent
# MAX_ENTRIES places.

require "json"
require "monitor"

module KlangtenBookmarks
  FILE_NAME = "media_bookmarks.json".freeze
  VERSION = 1
  MAX_ENTRIES = 300
  # Positions before this are not worth a bookmark.
  MIN_POSITION = 10
  # Closer than this to the end counts as heard to the end.
  END_MARGIN = 20

  Bookmark = Struct.new(:location, :position, :length, :title, :saved, keyword_init: true)

  @lock = Monitor.new
  @entries = nil
  @path = nil

  class << self
    # Where the bookmarks are kept (tests point it elsewhere).
    attr_writer :path

    def path
      @path || File.join(Dirs.eltendata, FILE_NAME)
    end

    def get(location)
      @lock.synchronize { entries[location.to_s] }
    end

    def position(location)
      bookmark = get(location)
      bookmark == nil ? nil : bookmark.position
    end

    # Remembers position for location, or forgets it when the position is not
    # worth one (see MIN_POSITION and END_MARGIN). Returns the Bookmark or nil.
    def remember(location, position, length: nil, title: nil)
      location = location.to_s
      return nil if location == ""
      position = position.to_f
      length = length.to_f > 0 ? length.to_f : nil
      if finished?(position, length) || position < MIN_POSITION
        forget(location)
        return nil
      end
      bookmark = Bookmark.new(location: location, position: position.round(1), length: length&.round(1), title: title.to_s == "" ? nil : title.to_s, saved: Time.now.to_i)
      @lock.synchronize do
        entries[location] = bookmark
        prune
        save
      end
      bookmark
    end

    def forget(location)
      @lock.synchronize do
        next false if entries.delete(location.to_s) == nil
        save
        true
      end
    end

    # A position this close to the end means the media was heard completely.
    def finished?(position, length)
      length = length.to_f
      length > 0 && position.to_f >= length - [END_MARGIN, length * 0.02].min
    end

    # Records what became of a sound that played location: its position, or
    # nothing when it reached the end (also when it stopped by itself).
    def update_from_sound(location, sound, title: nil, completed: false)
      return nil if location.to_s == "" || sound == nil
      length = sound.length.to_f rescue 0
      position = sound.position.to_f rescue 0
      if completed || finished?(position, length)
        forget(location)
        return nil
      end
      remember(location, position, length: length, title: title)
    end

    def all
      @lock.synchronize { entries.values.sort_by { |bookmark| -bookmark.saved.to_i } }
    end

    # Drops the cached list (tests, another data directory).
    def reload
      @lock.synchronize { @entries = nil }
    end

    private

    def entries
      @entries ||= load
    end

    def load
      data = File.file?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
      list = data.is_a?(Hash) && data["entries"].is_a?(Hash) ? data["entries"] : {}
      list.each_with_object({}) do |(location, row), result|
        next if !row.is_a?(Hash) || location.to_s == ""
        result[location.to_s] = Bookmark.new(
          location: location.to_s,
          position: row["position"].to_f,
          length: row["length"].is_a?(Numeric) ? row["length"].to_f : nil,
          title: row["title"].to_s == "" ? nil : row["title"].to_s,
          saved: row["saved"].to_i
        )
      end
    rescue StandardError => e
      Log.warning("Media bookmarks could not be read: #{e.class}: #{e.message}") if defined?(Log)
      {}
    end

    def prune
      return if @entries.size <= MAX_ENTRIES
      @entries.values.sort_by { |bookmark| bookmark.saved.to_i }.first(@entries.size - MAX_ENTRIES).each do |bookmark|
        @entries.delete(bookmark.location)
      end
    end

    def save
      data = {
        "version" => VERSION,
        "entries" => @entries.transform_values do |bookmark|
          { "position" => bookmark.position, "length" => bookmark.length, "title" => bookmark.title, "saved" => bookmark.saved }
        end
      }
      KlangtenPlaylist.atomic_write(path, JSON.generate(data))
    rescue StandardError => e
      Log.warning("Media bookmarks could not be saved: #{e.class}: #{e.message}") if defined?(Log)
    end
  end
end
