# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Loaded right after the platform's systemhelpers.rb. The real helpers stay
# (library loading, paths); only what asks the operating system something
# that would differ between machines, or would open something on the desktop,
# is pinned down for tests.

module EltenSystemHelpers
  class << self
    def current_locale_name
      "en_GB"
    end

    def first_day_of_week
      1
    end

    # Recorded instead of opening a browser (app.opened_urls).
    def open_url(url)
      KlangtenTest.record(:open_url, url.to_s)
      true
    end

    def prepare_os_microphone(*_args)
      true
    end

    # Same everywhere: no keychain or DPAPI, auto-login keys stay plain.
    def autologin_key_encryption_supported?
      false
    end

    def sync_autostart(_enabled, _command)
      true
    end
  end
end
