# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klango media catalog (radio stations, podcasts and other entries) through the
# Klangten API extension /api/v1/media/... All requests of the catalog live in
# this module; the scene only uses the value objects below.
#
# Podcast episodes are not served by the API: the server delivers the feed URL
# and the client reads the RSS/Atom feed itself (episodes method).

module EltenLink
  class MediaType
    attr_accessor :id, :key, :name, :items
  end

  class MediaCategory
    attr_accessor :id, :name, :kind, :language, :parent, :categories, :items, :favorite
  end

  class MediaItem
    attr_accessor :id, :title, :type, :type_id, :url, :urls, :stream_url, :feed_url, :description, :keywords,
      :language, :homepage, :bitrate, :rating_average, :rating_count, :rating_mine, :plays, :last_played,
      :added, :added_by, :hidden, :favorite, :extrainfo, :tags

    def stream?
      stream_url.to_s != ""
    end

    def feed?
      feed_url.to_s != ""
    end
  end

  # A page of a category, search or list: sub-categories, items and paging.
  class MediaPage
    attr_accessor :category, :path, :categories, :items, :total, :more, :offset, :limit
  end

  class MediaRating
    attr_accessor :user, :vote, :text, :time
  end

  class MediaEpisode
    attr_accessor :title, :url, :published, :duration, :description, :size, :mime
  end

  module Media
    TYPES = %w[podcast radio audiobook youtube rssfeed webpage mediafile].freeze
    LISTS = %w[popular top_rated newest recently_played random].freeze
    SORTS = %w[title popular rating newest].freeze
    PAGE_SIZE = 100

    class << self
      def types(client)
        data = client.api_data("GET", "/api/v1/media/types")
        Array(data["types"]).map do |row|
          type = MediaType.new
          type.id = row["id"].to_i
          type.key = row["key"].to_s
          type.name = row["name"].to_s
          type.items = row["items"].to_i
          type
        end
      end

      # Top-level categories (parent 0) or the children of one category.
      def categories(client, parent: 0, type: nil)
        data = client.api_data("GET", "/api/v1/media/categories", compact("parent" => parent.to_i, "type" => type))
        page = MediaPage.new
        page.category = data["parent"].is_a?(Hash) ? build_category(data["parent"]) : nil
        page.path = Array(data["path"]).map { |row| [row["id"].to_i, row["name"].to_s] }
        page.categories = Array(data["categories"]).map { |row| build_category(row) }
        page.items = []
        page.total = 0
        page.more = false
        page
      end

      def category(client, id, type: nil, sort: nil, language: nil, offset: 0, limit: PAGE_SIZE)
        params = compact("type" => type, "sort" => sort, "language" => language, "offset" => offset, "limit" => limit)
        build_page(client.api_data("GET", "/api/v1/media/categories/#{id.to_i}", params))
      end

      def search(client, query, type: nil, sort: nil, language: nil, offset: 0, limit: PAGE_SIZE)
        params = compact("q" => query.to_s, "type" => type, "sort" => sort, "language" => language, "offset" => offset, "limit" => limit)
        build_page(client.api_data("GET", "/api/v1/media/search", params))
      end

      def list(client, name, type: nil, sort: nil, language: nil, offset: 0, limit: PAGE_SIZE)
        params = compact("type" => type, "sort" => sort, "language" => language, "offset" => offset, "limit" => limit)
        build_page(client.api_data("GET", "/api/v1/media/lists/#{name.to_s.urlenc}", params))
      end

      def item(client, id)
        build_item(client.api_data("GET", "/api/v1/media/items/#{id.to_i}")["item"] || {})
      end

      def register_play(client, id)
        client.api_data("POST", "/api/v1/media/items/#{id.to_i}/play")
        true
      end

      # [summary hash, [MediaRating]]
      def ratings(client, id)
        data = client.api_data("GET", "/api/v1/media/items/#{id.to_i}/ratings")
        list = Array(data["ratings"]).map do |row|
          rating = MediaRating.new
          rating.user = row["user"].to_s
          rating.vote = row["vote"].to_i
          rating.text = row["text"].to_s
          rating.time = row["time"].to_i
          rating
        end
        [data["rating"].is_a?(Hash) ? data["rating"] : {}, list]
      end

      def rate(client, id, vote, text = "")
        client.api_data("PUT", "/api/v1/media/items/#{id.to_i}/rating", { "vote" => vote.to_i, "text" => text.to_s })["rating"] || {}
      end

      def unrate(client, id)
        client.api_data("DELETE", "/api/v1/media/items/#{id.to_i}/rating")["rating"] || {}
      end

      # [[MediaCategory], [MediaItem]]
      def favorites(client)
        data = client.api_data("GET", "/api/v1/media/favorites")
        [Array(data["categories"]).map { |row| build_category(row) }, Array(data["items"]).map { |row| build_item(row) }]
      end

      def add_favorite(client, id)
        client.api_data("PUT", "/api/v1/media/favorites/items/#{id.to_i}")
        true
      end

      def remove_favorite(client, id)
        client.api_data("DELETE", "/api/v1/media/favorites/items/#{id.to_i}")
        true
      end

      def add_favorite_category(client, id)
        client.api_data("PUT", "/api/v1/media/favorites/categories/#{id.to_i}")
        true
      end

      def remove_favorite_category(client, id)
        client.api_data("DELETE", "/api/v1/media/favorites/categories/#{id.to_i}")
        true
      end

      # Private bookmark (not shown in the public catalog).
      def create_bookmark(client, title:, url:, type: "radio", homepage: "", description: "", language: "")
        params = compact("title" => title.to_s, "url" => url.to_s, "type" => type, "homepage" => homepage, "description" => description, "language" => language)
        build_item(client.api_data("POST", "/api/v1/media/favorites/items", params)["item"] || {})
      end

      # Reads the episodes of a podcast feed (RSS 2.0 or Atom), newest first.
      def episodes(feed_url, cancellation_token: nil)
        require "nokogiri"
        body = read_url(feed_url.to_s, headers: { "User-Agent" => Klangten::Config.user_agent }, cancellation_token: cancellation_token)
        raise Error.new("Cannot read the podcast feed", code: "media.feed_unavailable") if body == nil || body.to_s == ""
        parse_feed(body.to_s)
      end

      def parse_feed(xml)
        require "nokogiri"
        document = Nokogiri::XML(xml)
        document.remove_namespaces!
        entries = document.xpath("//item")
        entries = document.xpath("//entry") if entries.empty?
        entries.map do |node|
          episode = MediaEpisode.new
          episode.title = text_of(node, "title")
          enclosure = node.at_xpath("enclosure")
          link = node.xpath("link").find { |item| item["rel"].to_s == "enclosure" }
          if enclosure != nil
            episode.url = enclosure["url"].to_s
            episode.size = enclosure["length"].to_i
            episode.mime = enclosure["type"].to_s
          elsif link != nil
            episode.url = link["href"].to_s
            episode.size = link["length"].to_i
            episode.mime = link["type"].to_s
          else
            episode.url = ""
          end
          episode.published = parse_time(text_of(node, "pubDate") || text_of(node, "published") || text_of(node, "updated"))
          episode.duration = text_of(node, "duration").to_s
          episode.description = clean_html(text_of(node, "summary") || text_of(node, "description") || text_of(node, "content"))
          episode
        end.reject { |episode| episode.url.to_s == "" }
      end

      private

      def compact(params)
        params.reject { |_key, value| value == nil || value.to_s == "" }
      end

      def build_page(data)
        page = MediaPage.new
        page.category = data["category"].is_a?(Hash) ? build_category(data["category"]) : nil
        page.path = Array(data["path"]).map { |row| [row["id"].to_i, row["name"].to_s] }
        page.categories = Array(data["categories"]).map { |row| build_category(row) }
        page.items = Array(data["items"]).map { |row| build_item(row) }
        page.total = data["total"].to_i
        page.more = data["more"] == true
        page.offset = data["offset"].to_i
        page.limit = data["limit"].to_i
        page
      end

      def build_category(row)
        category = MediaCategory.new
        category.id = row["id"].to_i
        category.name = row["name"].to_s
        category.kind = row["kind"].to_s
        category.language = row["language"].to_s
        category.parent = row["parent"].to_i
        category.categories = row["categories"].to_i
        category.items = row["items"].to_i
        category.favorite = row["favorite"] == true
        category
      end

      def build_item(row)
        rating = row["rating"].is_a?(Hash) ? row["rating"] : {}
        item = MediaItem.new
        item.id = row["id"].to_i
        item.title = row["title"].to_s
        item.type = row["type"].to_s
        item.type_id = row["type_id"].to_i
        item.url = row["url"].to_s
        item.urls = Array(row["urls"]).map(&:to_s)
        item.stream_url = row["stream_url"].to_s
        item.feed_url = row["feed_url"].to_s
        item.description = row["description"].to_s
        item.keywords = row["keywords"].to_s
        item.language = row["language"].to_s
        item.homepage = row["homepage"].to_s
        item.bitrate = row["bitrate"].to_s
        item.rating_average = rating["average"].to_f
        item.rating_count = rating["count"].to_i
        item.rating_mine = rating["mine"].to_i
        item.plays = row["plays"].to_i
        item.last_played = row["last_played"].to_i
        item.added = row["added"].to_i
        item.added_by = row["added_by"].to_s
        item.hidden = row["hidden"] == true
        item.favorite = row["favorite"] == true
        item.extrainfo = row["extrainfo"].to_s
        item.tags = Array(row["tags"]).map { |tag| tag["name"].to_s }
        item
      end

      def text_of(node, name)
        child = node.at_xpath(name)
        return nil if child == nil
        value = child.text.to_s.strip
        value == "" ? nil : value
      end

      def parse_time(value)
        return nil if value.to_s == ""
        require "time"
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def clean_html(value)
        return "" if value.to_s == ""
        Nokogiri::HTML(value.to_s).text.gsub(/[ \t\r\f]+/, " ").gsub(/\n{3,}/, "\n\n").strip
      rescue StandardError
        value.to_s
      end
    end
  end
end
