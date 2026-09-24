# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: premium packages and sponsors removed, former premium features available to everyone; two-factor authentication via Telegram or text message.

module EltenLink
  class LoginResult
    attr_reader :name, :token, :moderator, :fullname, :gender, :languages, :greeting, :auto_login_token, :issued_at

    def initialize(data)
      @name = data["name"].to_s
      @token = data["token"].to_s
      @moderator = data["moderator"] ? 1 : 0
      @fullname = data["fullname"].to_s
      @gender = data["gender"].to_i
      @languages = data["languages"].to_s
      @greeting = data["greeting"].to_s
      @auto_login_token = data["auto_login_token"].to_s
      @issued_at = data["issued_at"].to_i
    end

    def success?
      true
    end
  end

  # Klangten: state of two-factor authentication of the logged-in account.
  class TwoFactorStatus
    attr_reader :method, :phone, :backup_left, :devices

    def initialize(data)
      data = {} unless data.is_a?(Hash)
      @enabled = truthy?(data.key?("enabled") ? data["enabled"] : data["state"])
      @method = data["method"].to_s
      @method = "sms" if @method == "" && @enabled
      @phone = data["phone"].to_s
      @backup_left = data.key?("backup_left") && data["backup_left"] != nil ? data["backup_left"].to_i : nil
      @devices = data.key?("devices") && data["devices"] != nil ? data["devices"].to_i : nil
    end

    def enabled?
      @enabled
    end

    def telegram?
      @method == "telegram"
    end

    private

    def truthy?(value)
      value == true || %w[1 true yes].include?(value.to_s.downcase)
    end
  end

  module Authentication
    class << self
      # Klangten: accept_tos: true agrees to the Klango terms of service with this
      # login (answer to session.tos_required, whose details carry the terms url).
      def login(client, name:, password: nil, token: nil, version_string:, version_isdevelopment:, version_islauncher:, appid:, language:, os:, authmethod:, stamp: nil, accept_tos: false)
        params = {
          "name" => name,
          "version_string" => version_string.to_s.upcase,
          "version_isdevelopment" => version_isdevelopment ? 1 : 0,
          "version_islauncher" => version_islauncher ? 1 : 0,
          "appid" => appid,
          "lang" => language,
          "language" => language,
          "os" => os,
          "authmethod" => authmethod
        }
        if stamp != nil
          params["stamp_timestamp"] = stamp["timestamp"]
          params["stamp_key_sha256"] = stamp["key_sha256"]
          params["stamp_hwid"] = stamp["hwid"]
          params["stamp_hmac"] = stamp["hmac"]
        end
        if token != nil && token != ""
          params["token"] = token
        else
          params["password"] = password
        end
        params["accept_tos"] = 1 if accept_tos
        LoginResult.new(client.api_data("POST", "/api/v1/session", params))
      end

      # Klangten: address of the Klango terms of service (no login needed).
      def tos_url(client, language: nil)
        params = {}
        params["lang"] = language if language.to_s != ""
        client.api_data("GET", "/api/v1/session/tos", params)["url"].to_s
      end

      # Klangten: accepts the Klango terms of service without logging in.
      def accept_tos(client, name:, password:, language: nil)
        params = { "name" => name, "password" => password }
        params["lang"] = language if language.to_s != ""
        data = client.api_data("POST", "/api/v1/session/tos", params)
        data["accepted"] == true || data["accepted"].to_s == "1" || data["accepted"].to_s.downcase == "true"
      end

      def auto_login_token(client, name:, password:, computer:, appid:)
        data = client.api_data("POST", "/api/v1/session/auto-login-token", {
          "name" => name,
          "password" => password,
          "computer" => computer,
          "appid" => appid
        })
        data["token"].to_s
      end

      # Klangten: GET /authentication answers {enabled, method ("sms"|"telegram"|nil),
      # phone (masked), telegram, backup_left, devices}. Elten's {state} is still read.
      def status(client)
        TwoFactorStatus.new(client.api_data("GET", "/api/v1/authentication"))
      end

      def state(client)
        status(client).enabled? ? 1 : 0
      end

      # Klangten: method is "sms" (phone required, the code goes out by text
      # message) or "telegram" (answer {link, start} for linking the bot).
      def enable(client, password:, method: "sms", phone: nil, language:)
        params = { "password" => password, "method" => method.to_s, "lang" => language, "language" => language }
        params["phone"] = phone if phone.to_s != ""
        data = client.api_data("PUT", "/api/v1/authentication", params)
        data.is_a?(Hash) ? data : {}
      end

      # Klangten: returns the first backup codes ({codes: [...]}), may be empty.
      def verify(client, code:, appid:)
        data = client.api_data("POST", "/api/v1/authentication/verification", { "code" => code, "appid" => appid })
        data.is_a?(Hash) ? data["codes"].to_a.map(&:to_s) : []
      end

      def disable(client, password:)
        client.api_data("DELETE", "/api/v1/authentication", { "password" => password })
        true
      end

      def backup_codes(client, password:)
        data = client.api_data("POST", "/api/v1/authentication/backup-codes", { "password" => password })
        data["codes"].to_a.map(&:to_s)
      end

      def authenticate(client, appid:, name:, code:)
        client.api_data("POST", "/api/v1/authentication/authorizations", { "appid" => appid, "name" => name, "code" => code })
        true
      end
    end
  end
end
