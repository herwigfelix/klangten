# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klango e-mail addresses through the Klangten API extension /api/v1/mail.
#
# Every Klango account has a mailbox with up to three addresses at the
# server's mail domains. The settings returned here are the same ones Klango
# shows under "My e-mail settings": the addresses (one main address, one
# sender address), the sender name, the mailbox password and whether a mail
# program and the webmail may sign in with it.

module EltenLink
  MailAddress = Struct.new(:address, :main, :default, keyword_init: true) do
    def main?
      main == true
    end

    def default?
      default == true
    end
  end

  MailSettings = Struct.new(:addresses, :domains, :display, :has_password, :imap, :webmail,
    :max_addresses, :can_add, :login, :imap_server, :imap_port, :smtp_server, :smtp_port,
    :webmail_url, keyword_init: true) do
    def password?
      has_password == true
    end

    def can_add?
      can_add == true
    end

    def sender
      addresses.find(&:default?) || addresses.first
    end
  end

  MailCheck = Struct.new(:available, :address, :reason, keyword_init: true)

  module MailAccounts
    # Error keys of the server (error codes mail.<key>).
    ERROR_KEYS = %w[taken reserved invalid empty toolong toomany baddomain unknown ismain tooshort nopassword unavailable].freeze
    MIN_PASSWORD_LENGTH = 8

    class << self
      def settings(client)
        build_settings(client.api_data("GET", "/api/v1/mail/settings"))
      end

      # Changes the sender name and/or the two sign-in switches; nil leaves a
      # value unchanged.
      def update(client, display: nil, imap: nil, webmail: nil)
        params = {}
        params["display"] = display.to_s if display != nil
        params["imap"] = imap ? 1 : 0 if imap != nil
        params["webmail"] = webmail ? 1 : 0 if webmail != nil
        build_settings(client.api_data("PATCH", "/api/v1/mail/settings", params))
      end

      def check(client, local, domain = nil)
        params = { "local" => local.to_s }
        params["domain"] = domain.to_s if domain.to_s != ""
        data = client.api_data("GET", "/api/v1/mail/check", params)
        MailCheck.new(available: data["available"] == true, address: data["address"].to_s, reason: data["reason"].to_s)
      end

      # Returns [the created address (as normalized by the server), settings].
      def add(client, local, domain = nil)
        params = { "local" => local.to_s }
        params["domain"] = domain.to_s if domain.to_s != ""
        data = client.api_data("POST", "/api/v1/mail/addresses", params)
        [data["address"].to_s, build_settings(data["settings"])]
      end

      def delete(client, address)
        build_settings(client.api_data("DELETE", "/api/v1/mail/addresses/#{escape(address)}")["settings"])
      end

      def set_default(client, address)
        build_settings(client.api_data("POST", "/api/v1/mail/addresses/#{escape(address)}/default")["settings"])
      end

      # An empty password removes it (and switches both sign-ins off).
      def set_password(client, password)
        build_settings(client.api_data("PUT", "/api/v1/mail/password", { "password" => password.to_s }))
      end

      # "taken" for the error code "mail.taken", nil for any other error.
      def error_key(error)
        code = error.respond_to?(:code) ? error.code.to_s : ""
        return nil unless code.start_with?("mail.")
        key = code.sub("mail.", "")
        ERROR_KEYS.include?(key) ? key : nil
      end

      def build_settings(data)
        data = {} unless data.is_a?(Hash)
        addresses = data["addresses"].to_a.select { |row| row.is_a?(Hash) }.map do |row|
          MailAddress.new(address: row["address"].to_s, main: truthy(row["main"]), default: truthy(row["default"]))
        end
        MailSettings.new(
          addresses: addresses,
          domains: data["domains"].to_a.map(&:to_s),
          display: data["display"].to_s,
          has_password: truthy(data["has_password"]),
          imap: truthy(data["imap"]),
          webmail: truthy(data["webmail"]),
          max_addresses: data["max_addresses"].to_i,
          can_add: truthy(data["can_add"]),
          login: data["login"].to_s,
          imap_server: data["imap_server"].to_s,
          imap_port: data["imap_port"].to_i,
          smtp_server: data["smtp_server"].to_s,
          smtp_port: data["smtp_port"].to_i,
          webmail_url: data["webmail_url"].to_s
        )
      end

      private

      def escape(address)
        Client.url_encode(address.to_s.strip.downcase)
      end

      def truthy(value)
        value == true || value.to_s == "1" || value.to_s.downcase == "true"
      end
    end
  end
end
