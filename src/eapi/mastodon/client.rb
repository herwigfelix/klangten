# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Client for the REST API of Mastodon servers, used by Klangten in place of
# Elten's feed. Written for Klangten after the public API documentation
# (https://docs.joinmastodon.org); it contains no third-party code.
#
# The file has no UI dependencies (only net/http, json and the Ruby standard
# library), so it can be exercised headless. "Mastodon" is a trademark of
# Mastodon gGmbH and is used here only to describe the protocol.

require "json"
require "net/http"
require "uri"
require "cgi"
require "securerandom"
require "time"

module Klangten
  module Mastodon
    # Out-of-band redirect: the server shows the authorization code, the user
    # copies it into Klangten.
    REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob".freeze
    SCOPES = "read write follow".freeze
    CLIENT_NAME = "Klangten".freeze
    DEFAULT_TIMEOUT = 20
    DEFAULT_MAX_CHARACTERS = 500

    class Error < StandardError
      attr_reader :status, :retry_at, :body

      def initialize(message, status: nil, retry_at: nil, body: nil)
        super(message)
        @status = status
        @retry_at = retry_at
        @body = body
      end
    end

    # HTTP 401: the token is invalid or was revoked.
    class Unauthorized < Error
    end

    # HTTP 429: retry_at is a Time (or nil when the server did not say).
    class RateLimited < Error
    end

    # Network level failure (DNS, TLS, timeout, connection refused).
    class ConnectionFailed < Error
    end

    # One page of a paginated list. next_max_id continues with older items,
    # prev_min_id with newer ones.
    Page = Struct.new(:items, :next_max_id, :prev_min_id)

    module Util
      module_function

      def string(value)
        return "" if value == nil
        str = value.to_s.dup
        str.force_encoding(Encoding::UTF_8) if str.encoding != Encoding::UTF_8
        str.valid_encoding? ? str : str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end

      def id(value)
        value == nil ? nil : value.to_s
      end

      def time(value)
        return nil if value == nil || value.to_s == ""
        Time.iso8601(value.to_s)
      rescue ArgumentError
        begin
          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end
      end

      def bool(value)
        value == true || value.to_s == "true" || value.to_s == "1"
      end
    end

    # Converts the HTML of statuses and profiles to plain, readable text.
    module Text
      module_function

      BLOCK_END = %r{</(p|div|blockquote|h[1-6]|pre|ul|ol)\s*>}i
      LINE_BREAK = %r{<br\s*/?>}i
      LIST_ITEM = %r{<li[^>]*>}i
      TAG = %r{<[^>]*>}m
      COMMENT = %r{<!--.*?-->}m
      SCRIPT = %r{<(script|style)[^>]*>.*?</\1\s*>}mi
      ANCHOR = %r{<a\s([^>]*)>(.*?)</a\s*>}mi
      HREF = %r{href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))}i
      CLASS = %r{class\s*=\s*(?:"([^"]*)"|'([^']*)')}i

      def html_to_text(html)
        text = Util.string(html)
        return "" if text == ""
        text = text.gsub(COMMENT, "").gsub(SCRIPT, "")
        text = text.gsub(/\r\n?/, "\n").gsub(/\n/, " ")
        text = text.gsub(LINE_BREAK, "\n")
        text = text.gsub(LIST_ITEM, "\n- ")
        text = text.gsub(BLOCK_END, "\n\n")
        text = text.gsub(TAG, "")
        text = decode_entities(text)
        text = text.tr(" ", " ")
        lines = text.split("\n", -1).map { |line| line.gsub(/[ \t]+/, " ").strip }
        lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
      end

      def decode_entities(text)
        text = text.gsub("&nbsp;", " ")
        CGI.unescapeHTML(text)
      rescue StandardError
        text
      end

      # Links of an HTML fragment: [{text:, url:, kind: :link|:mention|:hashtag}].
      def links(html)
        Util.string(html).scan(ANCHOR).filter_map do |attributes, inner|
          href = attributes.match(HREF)
          next if href == nil
          url = decode_entities(href.captures.compact.first.to_s)
          next if url == "" || url !~ /\Ahttps?:\/\//i
          classes = attributes.match(CLASS)&.captures&.compact&.first.to_s.split
          label = html_to_text(inner)
          kind = if classes.include?("mention") && label.start_with?("#")
            :hashtag
          elsif classes.include?("hashtag") || label.start_with?("#")
            :hashtag
          elsif classes.include?("mention") || classes.include?("u-url") || label.start_with?("@")
            :mention
          else
            :link
          end
          { text: label == "" ? url : label, url: url, kind: kind }
        end
      end
    end

    class Account
      attr_accessor :id, :username, :acct, :display_name, :note, :url, :locked, :bot,
        :followers_count, :following_count, :statuses_count, :fields, :created_at, :privacy, :language

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        account = new
        account.id = Util.id(data["id"])
        account.username = Util.string(data["username"])
        account.acct = Util.string(data["acct"])
        account.display_name = Util.string(data["display_name"])
        account.note = Util.string(data["note"])
        account.url = Util.string(data["url"])
        account.locked = Util.bool(data["locked"])
        account.bot = Util.bool(data["bot"])
        account.followers_count = data["followers_count"].to_i
        account.following_count = data["following_count"].to_i
        account.statuses_count = data["statuses_count"].to_i
        account.fields = data["fields"].to_a.select { |field| field.is_a?(Hash) }.map do |field|
          [Util.string(field["name"]), Text.html_to_text(field["value"])]
        end
        account.created_at = Util.time(data["created_at"])
        source = data["source"].is_a?(Hash) ? data["source"] : {}
        account.privacy = Util.string(source["privacy"])
        account.language = Util.string(source["language"])
        account
      end

      def name
        display_name.to_s.strip == "" ? username.to_s : display_name.to_s.strip
      end

      def note_text
        Text.html_to_text(note)
      end

      # "Display name (@user@host)"
      def label
        "#{name} (@#{acct})"
      end
    end

    class MediaAttachment
      attr_accessor :id, :type, :url, :preview_url, :remote_url, :description, :duration

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        media = new
        media.id = Util.id(data["id"])
        media.type = Util.string(data["type"])
        media.url = data["url"] == nil ? nil : Util.string(data["url"])
        media.preview_url = data["preview_url"] == nil ? nil : Util.string(data["preview_url"])
        media.remote_url = data["remote_url"] == nil ? nil : Util.string(data["remote_url"])
        media.description = Util.string(data["description"])
        meta = data["meta"].is_a?(Hash) ? data["meta"] : {}
        original = meta["original"].is_a?(Hash) ? meta["original"] : {}
        media.duration = original["duration"] == nil ? nil : original["duration"].to_f
        media
      end

      def audio?
        type == "audio"
      end

      def processed?
        url.to_s != ""
      end

      def playable_url
        [url, remote_url].map(&:to_s).find { |value| value != "" }.to_s
      end
    end

    class Poll
      attr_accessor :id, :expires_at, :expired, :multiple, :votes_count, :voters_count, :options, :voted, :own_votes

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        poll = new
        poll.id = Util.id(data["id"])
        poll.expires_at = Util.time(data["expires_at"])
        poll.expired = Util.bool(data["expired"])
        poll.multiple = Util.bool(data["multiple"])
        poll.votes_count = data["votes_count"].to_i
        poll.voters_count = data["voters_count"] == nil ? nil : data["voters_count"].to_i
        poll.options = data["options"].to_a.select { |option| option.is_a?(Hash) }.map do |option|
          [Util.string(option["title"]), option["votes_count"] == nil ? nil : option["votes_count"].to_i]
        end
        poll.voted = Util.bool(data["voted"])
        poll.own_votes = data["own_votes"].to_a.map(&:to_i)
        poll
      end
    end

    class Status
      attr_accessor :id, :created_at, :edited_at, :in_reply_to_id, :in_reply_to_account_id, :sensitive,
        :spoiler_text, :visibility, :language, :uri, :url, :replies_count, :reblogs_count, :favourites_count,
        :favourited, :reblogged, :bookmarked, :muted, :content, :account, :reblog, :media_attachments,
        :mentions, :tags, :poll, :card, :application

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        status = new
        status.id = Util.id(data["id"])
        status.created_at = Util.time(data["created_at"])
        status.edited_at = Util.time(data["edited_at"])
        status.in_reply_to_id = Util.id(data["in_reply_to_id"])
        status.in_reply_to_account_id = Util.id(data["in_reply_to_account_id"])
        status.sensitive = Util.bool(data["sensitive"])
        status.spoiler_text = Util.string(data["spoiler_text"])
        status.visibility = Util.string(data["visibility"])
        status.language = data["language"] == nil ? nil : Util.string(data["language"])
        status.uri = Util.string(data["uri"])
        status.url = data["url"] == nil ? nil : Util.string(data["url"])
        status.replies_count = data["replies_count"].to_i
        status.reblogs_count = data["reblogs_count"].to_i
        status.favourites_count = data["favourites_count"].to_i
        status.favourited = Util.bool(data["favourited"])
        status.reblogged = Util.bool(data["reblogged"])
        status.bookmarked = Util.bool(data["bookmarked"])
        status.muted = Util.bool(data["muted"])
        status.content = Util.string(data["content"])
        status.account = Account.from_json(data["account"]) || Account.new
        status.reblog = data["reblog"].is_a?(Hash) ? Status.from_json(data["reblog"]) : nil
        status.media_attachments = data["media_attachments"].to_a.filter_map { |media| MediaAttachment.from_json(media) }
        status.mentions = data["mentions"].to_a.select { |mention| mention.is_a?(Hash) }.map do |mention|
          { id: Util.id(mention["id"]), username: Util.string(mention["username"]), acct: Util.string(mention["acct"]), url: Util.string(mention["url"]) }
        end
        status.tags = data["tags"].to_a.select { |tag| tag.is_a?(Hash) }.map { |tag| Util.string(tag["name"]) }
        status.poll = Poll.from_json(data["poll"])
        card = data["card"]
        status.card = card.is_a?(Hash) ? { title: Util.string(card["title"]), url: Util.string(card["url"]), description: Util.string(card["description"]) } : nil
        application = data["application"]
        status.application = application.is_a?(Hash) ? Util.string(application["name"]) : nil
        status
      end

      def boost?
        reblog != nil
      end

      # The status that carries the content (the boosted one for boosts).
      def target
        reblog || self
      end

      def text
        Text.html_to_text(target.content)
      end

      def links
        Text.links(target.content)
      end

      def audio_attachments
        target.media_attachments.to_a.select { |media| media.audio? && media.playable_url != "" }
      end

      # Accessors in the shape of Elten's FeedMessage, so code written for the
      # feed (list audio, the Invisible Interface) keeps working.
      def user
        target.account.acct.to_s
      end

      def message
        spoiler = target.spoiler_text.to_s
        spoiler == "" ? text : "#{spoiler}: #{text}"
      end

      def time
        (target.created_at || created_at).to_i
      end

      def liked
        target.favourited
      end

      def liked=(value)
        target.favourited = value == true
      end

      def likes
        target.favourites_count
      end

      def likes=(value)
        target.favourites_count = value.to_i
      end

      def responses
        target.replies_count
      end

      def response
        target.in_reply_to_id
      end

      def audio_url
        audio_attachments.first&.playable_url.to_s
      end
    end

    class Notification
      attr_accessor :id, :type, :created_at, :account, :status

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        notification = new
        notification.id = Util.id(data["id"])
        notification.type = Util.string(data["type"])
        notification.created_at = Util.time(data["created_at"])
        notification.account = Account.from_json(data["account"]) || Account.new
        notification.status = Status.from_json(data["status"])
        notification
      end

      def mention?
        type == "mention"
      end
    end

    class Relationship
      attr_accessor :id, :following, :followed_by, :requested, :muting, :blocking

      def self.from_json(data)
        return nil unless data.is_a?(Hash)
        relationship = new
        relationship.id = Util.id(data["id"])
        relationship.following = Util.bool(data["following"])
        relationship.followed_by = Util.bool(data["followed_by"])
        relationship.requested = Util.bool(data["requested"])
        relationship.muting = Util.bool(data["muting"])
        relationship.blocking = Util.bool(data["blocking"])
        relationship
      end
    end

    class Client
      Response = Struct.new(:status, :headers, :body, :data)

      attr_reader :base_url, :rate_limit_remaining, :rate_limit_reset
      attr_accessor :token, :user_agent, :timeout, :cert_store, :sleeper

      # Accepts "example.social", "https://example.social/", "@user@example.social"
      # or "user@example.social" and returns "https://example.social".
      # Plain HTTP is accepted only for loopback addresses (development and tests).
      def self.normalize_instance(value)
        input = Util.string(value).strip
        raise ArgumentError, "empty instance" if input == ""
        scheme = "https"
        if (match = input.match(%r{\A(https?)://}i))
          scheme = match[1].downcase
          input = input[match[0].size..-1]
        end
        input = input.split(%r{[/?#]}, 2).first.to_s
        input = input.split("@").last.to_s if input.include?("@")
        input = input.downcase.sub(/\.\z/, "")
        raise ArgumentError, "invalid instance" unless input =~ /\A[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)*(:\d{1,5})?\z/
        host = input.sub(/:\d+\z/, "")
        raise ArgumentError, "invalid instance" if !host.include?(".") && host != "localhost"
        scheme = "https" if scheme == "http" && !["localhost", "127.0.0.1"].include?(host)
        "#{scheme}://#{input}"
      end

      def initialize(instance, token: nil, user_agent: nil, timeout: DEFAULT_TIMEOUT, cert_store: nil)
        @base_url = self.class.normalize_instance(instance)
        @token = token
        @user_agent = user_agent || default_user_agent
        @timeout = timeout
        @cert_store = cert_store
        @sleeper = ->(seconds) { sleep(seconds) }
        @rate_limit_remaining = nil
        @rate_limit_reset = nil
      end

      def host
        URI.parse(@base_url).host
      end

      # --- Authorization -----------------------------------------------------

      # POST /api/v1/apps. Returns {"client_id" => ..., "client_secret" => ...}.
      def register_app(client_name: CLIENT_NAME, website: nil, scopes: SCOPES, redirect_uri: REDIRECT_URI)
        form = { "client_name" => client_name, "redirect_uris" => redirect_uri, "scopes" => scopes }
        form["website"] = website if website.to_s != ""
        data = request("POST", "/api/v1/apps", form: form, auth: false).data
        raise Error.new("The server did not return client credentials") unless data.is_a?(Hash) && data["client_id"].to_s != "" && data["client_secret"].to_s != ""
        { "client_id" => data["client_id"].to_s, "client_secret" => data["client_secret"].to_s }
      end

      def authorize_url(client_id, scopes: SCOPES, redirect_uri: REDIRECT_URI, language: nil)
        params = { "response_type" => "code", "client_id" => client_id, "redirect_uri" => redirect_uri, "scope" => scopes }
        params["lang"] = language if language.to_s != ""
        "#{@base_url}/oauth/authorize?#{encode_params(params)}"
      end

      # POST /oauth/token with the authorization code. Stores and returns the token.
      def obtain_token(client_id:, client_secret:, code:, scopes: SCOPES, redirect_uri: REDIRECT_URI)
        form = {
          "grant_type" => "authorization_code",
          "code" => code.to_s.strip,
          "client_id" => client_id,
          "client_secret" => client_secret,
          "redirect_uri" => redirect_uri,
          "scope" => scopes
        }
        data = request("POST", "/oauth/token", form: form, auth: false).data
        token = data.is_a?(Hash) ? data["access_token"].to_s : ""
        raise Error.new("The server did not return an access token") if token == ""
        @token = token
      end

      # POST /oauth/revoke. Missing support or an already invalid token are not errors.
      def revoke_token(client_id:, client_secret:, token: @token)
        return true if token.to_s == ""
        request("POST", "/oauth/revoke", form: { "client_id" => client_id, "client_secret" => client_secret, "token" => token }, auth: false)
        true
      rescue Unauthorized
        true
      rescue Error => e
        raise if e.status == nil || e.status >= 500
        true
      end

      def verify_credentials
        Account.from_json(get("/api/v1/accounts/verify_credentials"))
      end

      # --- Instance ----------------------------------------------------------

      # Returns {"title", "max_characters", "max_media_attachments", "supported_mime_types"}.
      def instance_info
        data = begin
          get("/api/v2/instance")
        rescue Error => e
          raise if e.is_a?(ConnectionFailed) || e.is_a?(RateLimited)
          get("/api/v1/instance")
        end
        data = {} unless data.is_a?(Hash)
        configuration = data["configuration"].is_a?(Hash) ? data["configuration"] : {}
        statuses = configuration["statuses"].is_a?(Hash) ? configuration["statuses"] : {}
        media = configuration["media_attachments"].is_a?(Hash) ? configuration["media_attachments"] : {}
        max_characters = (statuses["max_characters"] || data["max_toot_chars"]).to_i
        {
          "title" => Util.string(data["title"]),
          "max_characters" => max_characters > 0 ? max_characters : DEFAULT_MAX_CHARACTERS,
          "max_media_attachments" => [statuses["max_media_attachments"].to_i, 0].max,
          "supported_mime_types" => media["supported_mime_types"].to_a.map(&:to_s)
        }
      end

      # --- Timelines ---------------------------------------------------------

      def home_timeline(max_id: nil, since_id: nil, min_id: nil, limit: 40)
        status_page("/api/v1/timelines/home", max_id: max_id, since_id: since_id, min_id: min_id, limit: limit)
      end

      def public_timeline(local: false, max_id: nil, limit: 40)
        status_page("/api/v1/timelines/public", max_id: max_id, limit: limit, extra: { "local" => local ? "true" : nil })
      end

      def hashtag_timeline(tag, max_id: nil, limit: 40)
        name = tag.to_s.sub(/\A#/, "").strip
        raise ArgumentError, "empty hashtag" if name == ""
        status_page("/api/v1/timelines/tag/#{escape_path(name)}", max_id: max_id, limit: limit)
      end

      def account_statuses(account_id, max_id: nil, limit: 40, exclude_replies: false)
        status_page("/api/v1/accounts/#{escape_path(account_id)}/statuses", max_id: max_id, limit: limit, extra: { "exclude_replies" => exclude_replies ? "true" : nil })
      end

      def bookmarks(max_id: nil, limit: 40)
        status_page("/api/v1/bookmarks", max_id: max_id, limit: limit)
      end

      def favourites(max_id: nil, limit: 40)
        status_page("/api/v1/favourites", max_id: max_id, limit: limit)
      end

      def notifications(max_id: nil, since_id: nil, limit: 30, types: nil)
        query = { "max_id" => max_id, "since_id" => since_id, "limit" => limit, "types" => types }
        response = request("GET", "/api/v1/notifications", query: query)
        page_from(response) { |row| Notification.from_json(row) }
      end

      # --- Statuses ----------------------------------------------------------

      def status(id)
        Status.from_json(get("/api/v1/statuses/#{escape_path(id)}"))
      end

      # Returns {ancestors: [Status], descendants: [Status]}.
      def context(id)
        data = get("/api/v1/statuses/#{escape_path(id)}/context")
        data = {} unless data.is_a?(Hash)
        {
          ancestors: data["ancestors"].to_a.filter_map { |row| Status.from_json(row) },
          descendants: data["descendants"].to_a.filter_map { |row| Status.from_json(row) }
        }
      end

      def post_status(text, in_reply_to_id: nil, visibility: nil, spoiler_text: nil, sensitive: nil, language: nil, media_ids: [], idempotency_key: nil)
        body = { "status" => text.to_s }
        body["in_reply_to_id"] = in_reply_to_id.to_s if in_reply_to_id.to_s != ""
        body["visibility"] = visibility.to_s if visibility.to_s != ""
        body["spoiler_text"] = spoiler_text.to_s if spoiler_text.to_s != ""
        body["sensitive"] = sensitive == true if sensitive != nil
        body["language"] = language.to_s if language.to_s != ""
        ids = Array(media_ids).map(&:to_s).reject(&:empty?)
        body["media_ids"] = ids if !ids.empty?
        headers = { "Idempotency-Key" => (idempotency_key || SecureRandom.hex(16)) }
        Status.from_json(request("POST", "/api/v1/statuses", json: body, headers: headers).data)
      end

      def delete_status(id)
        request("DELETE", "/api/v1/statuses/#{escape_path(id)}")
        true
      end

      def favourite(id, on = true)
        status_action(id, on ? "favourite" : "unfavourite")
      end

      def reblog(id, on = true)
        status_action(id, on ? "reblog" : "unreblog")
      end

      def bookmark(id, on = true)
        status_action(id, on ? "bookmark" : "unbookmark")
      end

      def favourited_by(id, limit: 80)
        get("/api/v1/statuses/#{escape_path(id)}/favourited_by", "limit" => limit).to_a.filter_map { |row| Account.from_json(row) }
      end

      def reblogged_by(id, limit: 80)
        get("/api/v1/statuses/#{escape_path(id)}/reblogged_by", "limit" => limit).to_a.filter_map { |row| Account.from_json(row) }
      end

      # --- Accounts ----------------------------------------------------------

      def account(id)
        Account.from_json(get("/api/v1/accounts/#{escape_path(id)}"))
      end

      def lookup_account(acct)
        Account.from_json(get("/api/v1/accounts/lookup", "acct" => acct.to_s.sub(/\A@/, "")))
      end

      def search_accounts(query, limit: 20, resolve: true)
        data = get("/api/v2/search", "q" => query.to_s, "type" => "accounts", "limit" => limit, "resolve" => resolve ? "true" : "false")
        data = {} unless data.is_a?(Hash)
        data["accounts"].to_a.filter_map { |row| Account.from_json(row) }
      end

      def relationship(account_id)
        Relationship.from_json(get("/api/v1/accounts/relationships", "id" => [account_id.to_s]).to_a.first)
      end

      def follow(account_id, on = true)
        account_action(account_id, on ? "follow" : "unfollow")
      end

      def mute(account_id, on = true)
        account_action(account_id, on ? "mute" : "unmute")
      end

      def block(account_id, on = true)
        account_action(account_id, on ? "block" : "unblock")
      end

      # --- Media -------------------------------------------------------------

      # POST /api/v2/media, then GET /api/v1/media/:id until the server has
      # processed the file (HTTP 202/206 or a missing url mean "still processing").
      def upload_media(data, filename:, content_type:, description: nil, wait: true, max_wait: 120)
        parts = [["file", data.to_s.b, filename.to_s, content_type.to_s]]
        parts << ["description", Util.string(description), nil, nil] if description.to_s != ""
        response = request("POST", "/api/v2/media", multipart: parts, timeout: [@timeout.to_i, 120].max)
        media = MediaAttachment.from_json(response.data)
        raise Error.new("The server did not accept the media file") if media == nil || media.id.to_s == ""
        return media if !wait || (response.status == 200 && media.processed?)
        deadline = monotonic_time + max_wait.to_f
        delay = 1.0
        loop do
          raise Error.new("The server did not finish processing the media file in time") if monotonic_time > deadline
          @sleeper.call(delay)
          delay = [delay * 1.5, 5.0].min
          current = request("GET", "/api/v1/media/#{escape_path(media.id)}")
          attachment = MediaAttachment.from_json(current.data)
          return attachment if current.status == 200 && attachment != nil && attachment.processed?
        end
      end

      # --- Transport ---------------------------------------------------------

      def get(path, query = nil)
        request("GET", path, query: query).data
      end

      def request(method, path, query: nil, form: nil, json: nil, multipart: nil, headers: {}, auth: true, timeout: nil)
        uri = URI.parse(@base_url + path)
        encoded = encode_params(query || {})
        uri.query = encoded if encoded != ""
        request = build_request(method, uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = @user_agent
        request["Authorization"] = "Bearer #{@token}" if auth && @token.to_s != ""
        headers.each { |key, value| request[key] = value }
        if form != nil
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.body = encode_params(form)
        elsif json != nil
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(json)
        elsif multipart != nil
          boundary = "KlangtenBoundary#{SecureRandom.hex(12)}"
          request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          request.body = multipart_body(multipart, boundary)
        end
        response = perform(uri, request, timeout || @timeout)
        handle_response(response)
      end

      private

      def default_user_agent
        if defined?(::Klangten::Config) && ::Klangten::Config.respond_to?(:user_agent)
          ::Klangten::Config.user_agent
        else
          "Klangten"
        end
      rescue StandardError
        "Klangten"
      end

      def status_page(path, max_id: nil, since_id: nil, min_id: nil, limit: 40, extra: {})
        query = { "max_id" => max_id, "since_id" => since_id, "min_id" => min_id, "limit" => limit }.merge(extra)
        response = request("GET", path, query: query)
        page_from(response) { |row| Status.from_json(row) }
      end

      def page_from(response)
        items = response.data.to_a.filter_map { |row| yield(row) }
        links = parse_link_header(response.headers["link"])
        next_max_id = links["next"] ? query_value(links["next"], "max_id") : nil
        prev_min_id = links["prev"] ? (query_value(links["prev"], "min_id") || query_value(links["prev"], "since_id")) : nil
        next_max_id ||= items.last.id if items.size > 0 && !links.key?("next") && response.headers["link"].to_s == ""
        Page.new(items, next_max_id, prev_min_id)
      end

      def parse_link_header(value)
        value.to_s.split(",").each_with_object({}) do |part, result|
          match = part.match(/<([^>]+)>\s*;\s*rel="?([a-z]+)"?/i)
          result[match[2].downcase] = match[1] if match
        end
      end

      def query_value(url, name)
        query = URI.parse(url).query.to_s
        pair = URI.decode_www_form(query).find { |key, _| key == name }
        pair == nil ? nil : pair[1]
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def status_action(id, action)
        Status.from_json(request("POST", "/api/v1/statuses/#{escape_path(id)}/#{action}").data)
      end

      def account_action(account_id, action)
        Relationship.from_json(request("POST", "/api/v1/accounts/#{escape_path(account_id)}/#{action}").data)
      end

      def build_request(method, uri)
        case method.to_s.upcase
        when "GET" then Net::HTTP::Get.new(uri)
        when "POST" then Net::HTTP::Post.new(uri)
        when "PUT" then Net::HTTP::Put.new(uri)
        when "PATCH" then Net::HTTP::Patch.new(uri)
        when "DELETE" then Net::HTTP::Delete.new(uri)
        else raise ArgumentError, "unsupported method #{method}"
        end
      end

      def perform(uri, request, timeout)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          store = @cert_store || default_cert_store
          http.cert_store = store if store != nil
        end
        http.start { |connection| connection.request(request) }
      rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, EOFError => e
        raise ConnectionFailed.new("#{uri.host}: #{e.class}: #{e.message}")
      end

      def default_cert_store
        return nil unless defined?(::EltenAPI::TLS)
        ::EltenAPI::TLS.certificate_store
      rescue StandardError
        nil
      end

      def handle_response(response)
        status = response.code.to_i
        headers = {}
        response.each_header { |key, value| headers[key.downcase] = value }
        remember_rate_limit(headers)
        body = Util.string(response.body)
        data = nil
        if body.strip != ""
          begin
            data = JSON.parse(body)
          rescue JSON::ParserError
            data = nil
          end
        end
        return Response.new(status, headers, body, data) if status >= 200 && status < 300
        message = error_message(data, status)
        case status
        when 401
          raise Unauthorized.new(message, status: status, body: body)
        when 429
          raise RateLimited.new(message, status: status, retry_at: retry_time(headers), body: body)
        else
          raise Error.new(message, status: status, body: body)
        end
      end

      def error_message(data, status)
        if data.is_a?(Hash)
          text = data["error_description"].to_s
          text = data["error"].to_s if text == ""
          return text if text != ""
        end
        "HTTP #{status}"
      end

      def remember_rate_limit(headers)
        @rate_limit_remaining = headers["x-ratelimit-remaining"].to_i if headers["x-ratelimit-remaining"].to_s != ""
        reset = Util.time(headers["x-ratelimit-reset"])
        @rate_limit_reset = reset if reset != nil
      end

      def retry_time(headers)
        if headers["retry-after"].to_s =~ /\A\d+\z/
          return Time.now + headers["retry-after"].to_i
        end
        Util.time(headers["x-ratelimit-reset"]) || @rate_limit_reset
      end

      def encode_params(params)
        pairs = []
        params.each do |key, value|
          next if value == nil
          if value.is_a?(Array)
            name = key.to_s.end_with?("[]") ? key.to_s : "#{key}[]"
            value.each { |item| pairs << [name, item.to_s] }
          else
            pairs << [key.to_s, value.to_s]
          end
        end
        URI.encode_www_form(pairs)
      end

      def escape_path(value)
        URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      end

      def multipart_body(parts, boundary)
        body = "".b
        parts.each do |name, value, filename, content_type|
          body << "--#{boundary}\r\n".b
          disposition = "Content-Disposition: form-data; name=\"#{name}\""
          disposition += "; filename=\"#{filename.to_s.gsub(/["\r\n]/, "_")}\"" if filename != nil
          body << "#{disposition}\r\n".b
          body << "Content-Type: #{content_type}\r\n".b if content_type != nil
          body << "\r\n".b
          body << value.to_s.b
          body << "\r\n".b
        end
        body << "--#{boundary}--\r\n".b
        body
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
