# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

module EltenAPI
  module Common
    private

    # Fork and copyright notice shown at the licence agreement step, in the
    # welcome wizard, the licence document and the version screen.
    # It names Elten and EltenLink literally, so it is not branded.
    # The msgid is plain ASCII on purpose: the .mo loader compares msgids as
    # binary strings, so non-ASCII characters in a msgid prevent translation.
    def klangten_fork_notice
      unbranded do
        p_("Klangten", "Klangten - modified version of Elten. Elten: Copyright (C) 2014-2026 Dawid Pieper, GPLv3. Modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT). Klangten is not an official product of Dawid Pieper, the Prowadnica Foundation or EltenLink and is not endorsed by them. Server: Klango (klango.online).")
      end
    end

    # Replaces EltenLink's terms and conditions and privacy policy, which do not
    # apply to Klangten.
    def klangten_server_terms_text
      unbranded do
        p_("Klangten", "Klangten connects to the Klango server at %{server}. The terms of use and the privacy policy of this server are published by its operator at %{url}. The terms and conditions and the privacy policy of EltenLink do not apply to Klangten.") % {
          server: Klangten::Config.api_base_url,
          url: Klangten::Config::SERVER_TERMS_URL
        }
      end
    end

    # Returns the canonical spelling of a user name, or the name unchanged.
    # Unlike finduser, a failing or missing user search is silent, so logging
    # in and resetting a password keep working while the server lacks it.
    def klangten_canonical_user_name(name)
      found = EltenLink::Users.search(elten_link, name.to_s).first.to_s
      found.casecmp(name.to_s) == 0 ? found : name
    rescue StandardError => e
      Log.warning("User name lookup skipped: #{e.class}: #{e.message}") if defined?(Log)
      name
    end

    TOO_MANY_ATTEMPTS_CODES = %w[session.too_many_attempts accounts.too_many_attempts].freeze

    # Address of the Klango terms of service: the given address, else the one the
    # server reports (GET /api/v1/session/tos), else Klangten::Config::SERVER_TERMS_URL.
    def klangten_server_terms_url(preferred = nil)
      return preferred.to_s if preferred.to_s.match?(/\Ahttps?:\/\//i)
      language = defined?(Configuration) ? Configuration.language.to_s : ""
      url = EltenLink::Authentication.tos_url(elten_link, language: language)
      url.match?(/\Ahttps?:\/\//i) ? url : Klangten::Config::SERVER_TERMS_URL
    rescue StandardError => e
      Log.warning("Klango terms address unavailable: #{e.class}: #{e.message}") if defined?(Log)
      Klangten::Config::SERVER_TERMS_URL
    end

    # Shows the address of the Klango terms (with an option to open them in the
    # browser) and asks for consent. Used when the server answers
    # session.tos_required, also for logins with an auto-login key.
    def klangten_ask_server_terms(url = nil)
      url = klangten_server_terms_url(url)
      header = p_("Klangten", "Before you can log in, the Klango server asks you to accept its terms of use. You can read them at %{url}. Accept the Klango server terms?") % { url: url }
      loop do
        choice = selector([p_("Klangten", "Open the terms in the browser"), p_("Klangten", "Accept the terms"), p_("Klangten", "Decline")], header: header, start_index: 0, cancel_index: 2, flags: 1)
        return true if choice == 1
        return false if choice == nil || choice == 2
        platform_open_url(url)
      end
    end

    def klangten_too_many_attempts?(error)
      error.respond_to?(:code) && TOO_MANY_ATTEMPTS_CODES.include?(error.code.to_s)
    end

    # Message for session.too_many_attempts / accounts.too_many_attempts
    # (retry_after seconds, details.scope user or ip).
    def klangten_too_many_attempts_message(error)
      minutes = error.respond_to?(:retry_after_minutes) ? error.retry_after_minutes : nil
      return p_("Klangten", "Too many failed attempts. Please wait a while before trying again.") if minutes == nil
      scope = error.respond_to?(:detail) ? error.detail("scope").to_s : ""
      # Two plain strings instead of np_: the plural rule comes from the loaded
      # catalogue and is missing for the English source texts.
      text = if scope == "ip"
               minutes == 1 ? p_("Klangten", "Too many failed attempts from your network connection. For security reasons, please try again in 1 minute.") : p_("Klangten", "Too many failed attempts from your network connection. For security reasons, please try again in %{minutes} minutes.")
             else
               minutes == 1 ? p_("Klangten", "Too many failed attempts for this account. For security reasons, please try again in 1 minute.") : p_("Klangten", "Too many failed attempts for this account. For security reasons, please try again in %{minutes} minutes.")
             end
      text % { minutes: minutes }
    end

    # Message for session.account_banned; details.totime is the end of a
    # temporary ban in Unix seconds, 0 for an indefinite ban.
    def klangten_account_banned_message(error)
      details = error.respond_to?(:details) ? error.details : nil
      totime = details.is_a?(Hash) ? details["totime"].to_i : 0
      if totime > Time.now.to_i
        p_("Klangten", "This account is banned until %{date}.") % { date: format_date(Time.at(totime), false, false) }
      elsif details.is_a?(Hash) && details.key?("totime") && totime == 0
        p_("Klangten", "This account is banned indefinitely.")
      else
        p_("Klangten", "This account is banned.")
      end
    end

    # Shows a message and returns true when the built-in updater is disabled.
    def klangten_updates_unavailable?
      return false if Klangten::Config.updates_enabled?
      alert(p_("Klangten", "The built-in installer and updater are not available in this version of Klangten."))
      true
    end
  end
end
