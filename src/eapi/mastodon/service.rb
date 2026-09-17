# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Storage of the connected Mastodon account and the background poller that
# replaces Elten's feed fetch. No UI dependencies: the notification service
# calls Service.tick from its worker thread and turns the returned events into
# sounds and UI refreshes.

module Klangten
  module Mastodon
    # One connected account. Secrets are kept decrypted only in memory.
    Account_Record = Struct.new(:user, :instance, :client_id, :client_secret, :token, :account_id, :acct,
      :display_name, :protection, :max_characters, keyword_init: true) do
      def usable?
        instance.to_s != "" && token.to_s != ""
      end

      def label
        acct.to_s == "" ? instance.to_s : "@#{acct}@#{host}"
      end

      def host
        instance.to_s.sub(%r{\Ahttps?://}, "")
      end
    end

    # Accounts are stored per Klangten user in the local configuration
    # (local.json, key MastodonAccounts). The client secret and the access
    # token are encrypted with the same platform mechanism as the auto-login
    # key (DPAPI on Windows). Where that mechanism is unavailable they are
    # stored base64 encoded, which is only an encoding, not a protection.
    module AccountStore
      CONFIG_KEY = "MastodonAccounts".freeze
      ENTROPY = "Klangten Mastodon account".freeze

      class DefaultProtector
        def available?
          defined?(::EltenSystemHelpers) &&
            ::EltenSystemHelpers.respond_to?(:autologin_key_encryption_supported?) &&
            ::EltenSystemHelpers.autologin_key_encryption_supported? == true
        rescue StandardError
          false
        end

        def protect(bytes)
          ::EltenSystemHelpers.protect_data(bytes, ENTROPY).to_s.b
        end

        def unprotect(bytes)
          ::EltenSystemHelpers.unprotect_data(bytes, ENTROPY)
        end
      end

      class << self
        attr_writer :backend, :protector

        def backend
          @backend || (defined?(::EltenAPI::LocalConfig) ? ::EltenAPI::LocalConfig : nil)
        end

        def protector
          @protector ||= DefaultProtector.new
        end

        # Increases whenever an account is saved or removed.
        def revision
          @revision.to_i
        end

        def load(user)
          key = user_key(user)
          return nil if key == "" || backend == nil
          row = accounts[key]
          return nil unless row.is_a?(Hash)
          Account_Record.new(
            user: key,
            instance: row["instance"].to_s,
            client_id: row["client_id"].to_s,
            client_secret: decode_secret(row["client_secret"]),
            token: decode_secret(row["token"]),
            account_id: row["account_id"].to_s,
            acct: row["acct"].to_s,
            display_name: row["display_name"].to_s,
            protection: row["token"].to_s.split(":", 2).first.to_s,
            max_characters: row["max_characters"].to_i
          )
        rescue StandardError => e
          warn_log("Mastodon account could not be read: #{e.class}")
          nil
        end

        def save(user, record)
          key = user_key(user)
          raise ArgumentError, "no user" if key == "" || backend == nil
          values = accounts
          values[key] = {
            "instance" => record.instance.to_s,
            "client_id" => record.client_id.to_s,
            "client_secret" => encode_secret(record.client_secret),
            "token" => encode_secret(record.token),
            "account_id" => record.account_id.to_s,
            "acct" => record.acct.to_s,
            "display_name" => record.display_name.to_s,
            "max_characters" => record.max_characters.to_i
          }
          backend[CONFIG_KEY] = values
          @revision = revision + 1
          true
        end

        def delete(user)
          key = user_key(user)
          return false if key == "" || backend == nil
          values = accounts
          removed = values.delete(key) != nil
          backend[CONFIG_KEY] = values
          @revision = revision + 1
          removed
        end

        def encode_secret(secret)
          value = secret.to_s
          return "" if value == ""
          if protector.available?
            protected_bytes = protector.protect(value.b)
            return "dpapi:" + [protected_bytes].pack("m0") if protected_bytes.to_s != ""
          end
          "plain:" + [value.b].pack("m0")
        end

        def decode_secret(stored)
          kind, payload = stored.to_s.split(":", 2)
          return "" if payload.to_s == ""
          bytes = payload.unpack1("m0")
          value = case kind
          when "dpapi" then protector.available? ? protector.unprotect(bytes) : nil
          when "plain" then bytes
          end
          return "" if value == nil
          value.to_s.dup.force_encoding(Encoding::UTF_8)
        rescue ArgumentError
          ""
        end

        private

        def accounts
          values = backend[CONFIG_KEY, {}, type: :hash]
          values.is_a?(Hash) ? values : {}
        rescue ArgumentError
          values = backend[CONFIG_KEY]
          values.is_a?(Hash) ? values.dup : {}
        end

        def user_key(user)
          user.to_s.strip.downcase
        end

        def warn_log(text)
          ::Log.warning(text) if defined?(::Log)
        end
      end
    end

    # Background polling of the home timeline and the notifications of the
    # connected account.
    module Service
      POLL_INTERVAL = 90.0
      RATE_LIMIT_RESERVE = 15
      MAX_BACKOFF = 900.0
      HOME_LIMIT = 40
      NOTIFICATION_LIMIT = 30
      HOME_CACHE_LIMIT = 400
      NOTIFICATION_CACHE_LIMIT = 200

      class << self
        attr_writer :client_factory

        def client_factory
          @client_factory ||= ->(record) { Client.new(record.instance, token: record.token) }
        end

        # Called periodically (from the notification worker thread). Returns
        # events: {"func" => "notif", "sound" => ...}, {"func" => "feeds"} and
        # {"func" => "notifications"}.
        def tick(user, now = monotonic_time)
          events = []
          mutex.synchronize do
            user_key = user.to_s.strip.downcase
            if user_key != @user.to_s || AccountStore.revision != @account_revision
              reset_unlocked(user_key)
              @account = user_key == "" ? nil : AccountStore.load(user_key)
              @account_revision = AccountStore.revision
              events << { "func" => "feeds" } << { "func" => "notifications" }
            end
            return events if @account == nil || !@account.usable?
            if @thread != nil && !@thread.alive?
              result = begin
                @thread.value
              rescue Exception => e
                { error: :failed, message: "#{e.class}: #{e.message}" }
              end
              @thread = nil
              events.concat(process_unlocked(result, now)) if result.is_a?(Hash) && result[:generation] == @generation
            end
            start_poll_unlocked if @thread == nil && now >= @next_poll_at.to_f && @status != :unauthorized
          end
          events
        end

        def account
          mutex.synchronize { @account }
        end

        def connected?
          record = account
          record != nil && record.usable?
        end

        def status
          mutex.synchronize { @status }
        end

        def primed?
          mutex.synchronize { @primed_home == true }
        end

        def last_error
          mutex.synchronize { @last_error }
        end

        # Increases whenever the cached home timeline changes.
        def revision
          mutex.synchronize { @revision.to_i }
        end

        def home_statuses
          mutex.synchronize { @home.to_a.dup }
        end

        def notifications
          mutex.synchronize { @notifications.to_a.dup }
        end

        def unread_mentions
          mutex.synchronize { @unread_mentions.to_a.dup }
        end

        def mark_mentions_read
          mutex.synchronize { @unread_mentions = [] }
        end

        def refresh
          mutex.synchronize do
            @next_poll_at = 0.0
            @status = nil if @status == :unauthorized
          end
        end

        # Replaces a cached status (and boosts of it) after an action.
        def update_status(status)
          return if status == nil
          mutex.synchronize do
            changed = false
            @home = @home.to_a.map do |item|
              if item.id == status.id
                changed = true
                status
              elsif item.reblog != nil && item.reblog.id == status.target.id
                changed = true
                item.reblog = status.target
                item
              else
                item
              end
            end
            @revision = @revision.to_i + 1 if changed
          end
        end

        def remove_status(id)
          mutex.synchronize do
            before = @home.to_a.size
            @home = @home.to_a.reject { |item| item.id == id.to_s || item.target.id == id.to_s }
            @revision = @revision.to_i + 1 if before != @home.size
          end
        end

        def reset
          mutex.synchronize { reset_unlocked(nil) }
        end

        private

        def mutex
          @mutex ||= Mutex.new
        end

        def reset_unlocked(user_key)
          @generation = @generation.to_i + 1
          @thread = nil
          @user = user_key
          @account = nil
          @account_revision = nil
          @home = []
          @notifications = []
          @unread_mentions = []
          @primed_home = false
          @primed_notifications = false
          @next_poll_at = 0.0
          @failures = 0
          @status = nil
          @last_error = nil
          @revision = @revision.to_i + 1
        end

        def start_poll_unlocked
          record = @account
          generation = @generation
          home_since = @primed_home ? @home.first&.id : nil
          notification_since = @primed_notifications ? @notifications.first&.id : nil
          factory = client_factory
          @thread = Thread.new do
            Thread.current.report_on_exception = false
            begin
              client = factory.call(record)
              home = client.home_timeline(since_id: home_since, limit: HOME_LIMIT)
              notes = client.notifications(since_id: notification_since, limit: NOTIFICATION_LIMIT)
              {
                generation: generation,
                home: home.items,
                notifications: notes.items,
                remaining: client.rate_limit_remaining,
                reset: client.rate_limit_reset
              }
            rescue Unauthorized => e
              { generation: generation, error: :unauthorized, message: e.message }
            rescue RateLimited => e
              { generation: generation, error: :rate_limited, retry_at: e.retry_at, message: e.message }
            rescue Error => e
              { generation: generation, error: :failed, message: e.message }
            rescue StandardError => e
              { generation: generation, error: :failed, message: "#{e.class}: #{e.message}" }
            end
          end
          # Guards against a hanging request: the next attempt waits at least one interval.
          @next_poll_at = monotonic_time + POLL_INTERVAL
        end

        def process_unlocked(result, now)
          events = []
          case result[:error]
          when :unauthorized
            @status = :unauthorized
            @last_error = result[:message].to_s
            log_warning("Mastodon account is no longer authorized")
            return events
          when :rate_limited
            wait = result[:retry_at].is_a?(Time) ? result[:retry_at] - Time.now : POLL_INTERVAL * 2
            @next_poll_at = now + [[wait, POLL_INTERVAL].max, MAX_BACKOFF * 4].min
            @status = :rate_limited
            @last_error = result[:message].to_s
            log_warning("Mastodon rate limit reached; polling paused")
            return events
          when :failed
            @failures = @failures.to_i + 1
            @next_poll_at = now + [POLL_INTERVAL * (2**[@failures - 1, 4].min), MAX_BACKOFF].min
            @status = :failed
            @last_error = result[:message].to_s
            log_warning("Mastodon poll failed (#{@failures}): #{result[:message]}")
            return events
          end
          @failures = 0
          @status = :ok
          @last_error = nil
          @next_poll_at = now + POLL_INTERVAL
          if result[:remaining].is_a?(Integer) && result[:remaining] < RATE_LIMIT_RESERVE && result[:reset].is_a?(Time)
            @next_poll_at = [@next_poll_at, now + [result[:reset] - Time.now, MAX_BACKOFF].min].max
          end
          mention_ids = merge_notifications_unlocked(result[:notifications].to_a, events)
          merge_home_unlocked(result[:home].to_a, mention_ids, events)
          events
        end

        def merge_notifications_unlocked(items, events)
          if @primed_notifications != true
            @notifications = items.first(NOTIFICATION_CACHE_LIMIT)
            @primed_notifications = true
            return []
          end
          known = @notifications.map(&:id)
          fresh = items.reject { |item| known.include?(item.id) }
          return [] if fresh.empty?
          @notifications = (fresh + @notifications).first(NOTIFICATION_CACHE_LIMIT)
          mentions = fresh.select(&:mention?)
          if !mentions.empty?
            @unread_mentions = (mentions + @unread_mentions.to_a).first(NOTIFICATION_CACHE_LIMIT)
            events << { "func" => "notif", "sound" => "feed_mention", "mastodon" => "mention" }
            events << { "func" => "notifications" }
          end
          mentions.filter_map { |item| item.status&.id }
        end

        def merge_home_unlocked(items, mention_ids, events)
          if @primed_home != true
            @home = items.first(HOME_CACHE_LIMIT)
            @primed_home = true
            @revision = @revision.to_i + 1
            events << { "func" => "feeds" }
            return
          end
          known = @home.map(&:id)
          fresh = items.reject { |item| known.include?(item.id) }
          return if fresh.empty?
          # A full page may leave a gap to the cached statuses; start over then.
          @home = (items.size >= HOME_LIMIT ? items : fresh + @home).first(HOME_CACHE_LIMIT)
          @revision = @revision.to_i + 1
          own = @account.account_id.to_s
          audible = fresh.reject { |item| item.account.id.to_s == own || mention_ids.include?(item.id) }
          events << { "func" => "notif", "sound" => "feed_update", "mastodon" => "home" } if !audible.empty?
          events << { "func" => "feeds" }
        end

        def log_warning(text)
          ::Log.warning(text) if defined?(::Log)
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
