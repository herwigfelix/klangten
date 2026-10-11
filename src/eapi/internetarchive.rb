# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The Internet Archive (archive.org): an entry - an audio book, a concert, a
# radio show - with its description and its files, and the search for such
# entries.
#
# Entries are read from the public JSON interfaces of archive.org: the
# metadata of one entry (https://archive.org/metadata/<identifier>) and the
# advanced search. Files are played and downloaded from
# https://archive.org/download/<identifier>/<file>. An address like
# archive.org/details/<identifier> anywhere in Klangten (a link in a text, a
# media catalog entry, "Open address") leads to Scene_InternetArchive.

require "json"
require "uri"

module KlangtenArchive
  DEFAULT_BASE = "https://archive.org".freeze
  URL_PATTERN = %r{\bhttps?://(?:www\.)?archive\.org/(?:details|download|embed)/([A-Za-z0-9][A-Za-z0-9._-]*)}i.freeze
  IDENTIFIER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{1,99}\z/.freeze
  AUDIO_EXTENSIONS = %w[.mp3 .ogg .oga .opus .flac .m4a .m4b .aac .wav .aiff .aif .wma .mid .midi .mod .xm .it .s3m .webm .mp4 .m4v .mkv .avi .mpeg .mpg .ogv].freeze
  # Files of the archive itself, not of the entry.
  HIDDEN_PATTERN = /(_meta\.xml|_files\.xml|_meta\.sqlite|_reviews\.xml|\.torrent|_archive\.torrent|__ia_thumb\.jpg|_itemimage\.\w+)\z/i.freeze
  SEARCH_ROWS = 50

  Entry = Struct.new(:identifier, :title, :creator, :description, :date, :mediatype, :files, keyword_init: true)
  ArchiveFile = Struct.new(:name, :title, :format, :length, :size, :source, :track, :url, keyword_init: true) do
    def playable?
      AUDIO_EXTENSIONS.include?(File.extname(name.to_s).downcase)
    end

    # "Title [VBR MP3]" or the file name.
    def label
      text = title.to_s.strip
      text = File.basename(name.to_s) if text == ""
      text
    end
  end
  SearchResult = Struct.new(:identifier, :title, :creator, :mediatype, keyword_init: true)
  SearchPage = Struct.new(:results, :total, :page, keyword_init: true) do
    def more?
      page * SEARCH_ROWS < total
    end
  end

  class Error < StandardError; end

  class << self
    # Other servers in tests.
    attr_writer :base_url, :fetcher

    def base_url
      @base_url || DEFAULT_BASE
    end

    # ---------------------------------------------------------- addresses

    # The identifier in an archive.org address, or the text itself when it
    # looks like one (only with bare: true). nil otherwise.
    def identifier(text, bare: false)
      text = text.to_s.strip
      match = URL_PATTERN.match(text)
      return URI.decode_www_form_component(match[1]) if match != nil
      return text if bare && text.match?(IDENTIFIER_PATTERN)
      nil
    end

    def url?(text)
      URL_PATTERN.match?(text.to_s)
    end

    def details_url(identifier)
      "https://archive.org/details/#{identifier}"
    end

    def file_url(identifier, name)
      path = name.to_s.split("/").map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
      "#{base_url}/download/#{identifier}/#{path}"
    end

    # ---------------------------------------------------------- requests

    # Reads one entry; raises Error when it does not exist.
    def entry(identifier)
      parse_entry(identifier, fetch("#{base_url}/metadata/#{URI.encode_www_form_component(identifier)}"))
    end

    def search(query, page: 1)
      q = "(#{query}) AND mediatype:(audio OR etree)"
      params = [["q", q], ["fl[]", "identifier"], ["fl[]", "title"], ["fl[]", "creator"], ["fl[]", "mediatype"],
        ["rows", SEARCH_ROWS.to_s], ["page", page.to_s], ["output", "json"]]
      parse_search(fetch("#{base_url}/advancedsearch.php?#{URI.encode_www_form(params)}"), page)
    end

    # ------------------------------------------------------------- parsing

    def parse_entry(identifier, body)
      data = JSON.parse(body.to_s)
      raise Error, "No such entry" if !data.is_a?(Hash) || !data["metadata"].is_a?(Hash)
      meta = data["metadata"]
      files = Array(data["files"]).filter_map { |row| build_file(identifier, row) }
      Entry.new(
        identifier: meta["identifier"].to_s == "" ? identifier : meta["identifier"].to_s,
        title: text(meta["title"]).then { |value| value == "" ? identifier : value },
        creator: text(meta["creator"]),
        description: clean(text(meta["description"])),
        date: text(meta["date"]),
        mediatype: text(meta["mediatype"]),
        files: sort_files(files)
      )
    rescue JSON::ParserError
      raise Error, "Invalid answer"
    end

    def parse_search(body, page = 1)
      data = JSON.parse(body.to_s)
      response = data.is_a?(Hash) ? data["response"] : nil
      raise Error, "Invalid answer" if !response.is_a?(Hash)
      results = Array(response["docs"]).filter_map do |row|
        next if !row.is_a?(Hash) || row["identifier"].to_s == ""
        SearchResult.new(identifier: row["identifier"].to_s, title: text(row["title"]).then { |value| value == "" ? row["identifier"].to_s : value }, creator: text(row["creator"]), mediatype: text(row["mediatype"]))
      end
      SearchPage.new(results: results, total: response["numFound"].to_i, page: page)
    rescue JSON::ParserError
      raise Error, "Invalid answer"
    end

    # "1:02:03" from the length field, which is either seconds ("3723.5") or
    # already a clock time ("62:03").
    def length_seconds(value)
      value = value.to_s.strip
      return nil if value == ""
      return value.to_f if value.match?(/\A\d+(\.\d+)?\z/)
      parts = value.split(":")
      return nil if parts.empty? || parts.any? { |part| !part.match?(/\A\d+(\.\d+)?\z/) }
      parts.map(&:to_f).inject(0) { |sum, part| sum * 60 + part }
    end

    private

    def fetch(url)
      body = if @fetcher != nil
        @fetcher.call(url)
      else
        read_url(url, headers: { "User-Agent" => Klangten::Config.user_agent })
      end
      raise Error, "No answer" if body == nil || body.to_s == ""
      body.to_s
    end

    def build_file(identifier, row)
      return nil if !row.is_a?(Hash)
      name = row["name"].to_s
      return nil if name == "" || name.match?(HIDDEN_PATTERN) || row["format"].to_s == "Metadata"
      ArchiveFile.new(
        name: name,
        title: text(row["title"]),
        format: row["format"].to_s,
        length: length_seconds(row["length"]),
        size: row["size"].to_i,
        source: row["source"].to_s,
        track: row["track"].to_s.to_i,
        url: file_url(identifier, name)
      )
    end

    # Playable files first, in track order where the entry has one; the
    # originals before the copies the archive derived from them.
    def sort_files(files)
      files.each_with_index.sort_by do |file, index|
        [file.playable? ? 0 : 1, file.source == "original" ? 0 : 1, file.track > 0 ? file.track : 100_000, index]
      end.map(&:first)
    end

    def text(value)
      value = value.join(", ") if value.is_a?(Array)
      value.to_s.strip
    end

    def clean(html)
      html.to_s.gsub(/<br\s*\/?>/i, "\n").gsub(/<\/p>/i, "\n\n").gsub(/<[^>]+>/, "")
        .gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", "\"").gsub("&#39;", "'").gsub("&nbsp;", " ")
        .gsub(/\n{3,}/, "\n\n").strip
    end
  end

  # archive.org links in any Klangten text become media that opens the entry.
  class Finder < MediaFinder
    class << self
      def possible_media?(text)
        KlangtenArchive.url?(text)
      end

      def get_media(text)
        text.to_s.scan(URL_PATTERN).flatten.uniq.first(10).map { |identifier| Extractor.new(identifier) }
      end
    end
  end

  class Extractor < MediaExtractor
    def initialize(identifier)
      @identifier = identifier
    end

    def title
      p_("Klangten", "Internet Archive: %{name}") % { name: @identifier }
    end

    def proceed
      Scene_InternetArchive.open_identifier(@identifier)
    end
  end
end

MediaFinders.register(KlangtenArchive::Finder) if defined?(MediaFinders)
