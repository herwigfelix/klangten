# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Central Klangten configuration.
#
# Everything that distinguishes Klangten from a normal Elten installation
# (product identity, server endpoints, data locations and fork-specific feature
# switches) lives here, so that the rest of the client can keep using the
# upstream module names (EltenAPI, EltenLink, ...) unchanged.
#
# The file has no dependencies. elten.rb loads it before anything else, because
# the data directory and the window identity are needed before the filelist is
# processed; the filelist entry then finds it already loaded.
#
# Environment overrides (all optional):
#   KLANGTEN_API_URL          REST API base URL, e.g. http://127.0.0.1:5100
#   KLANGTEN_TCLIB            path of the TeamConference core library (conference host and
#                             ports are delivered by the server with the conference token)
#   KLANGTEN_RELAY_HOST       host of the program relay
#   KLANGTEN_RELAY_PORT       port of the program relay
#   KLANGTEN_HTTP2            "0" disables HTTP/2 for HTTPS API connections
#   KLANGTEN_UPDATES          "0" (or false/no/off) disables the built-in updater

require "uri"

unless defined?(::Klangten::Config)
module Klangten
  module Config
    PRODUCT_NAME = "Klangten".freeze
    # Lower-case identifier used for file, directory and registry names.
    PRODUCT_ID = "klangten".freeze
    VERSION = "0.1.0".freeze
    VENDOR = "sixdotsIT".freeze
    COPYRIGHT = "Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)".freeze
    UPSTREAM_NAME = "Elten".freeze
    UPSTREAM_COPYRIGHT = "Copyright (C) 2014-2026 Dawid Pieper".freeze
    UPSTREAM_SOURCE_URL = "https://github.com/dawidpieper/elten3".freeze
    SERVER_NAME = "Klango".freeze

    DEFAULT_API_URL = "https://ten.klango.online".freeze
    API_URL_ENV = "KLANGTEN_API_URL".freeze

    # Placeholders until the project has its own public pages.
    WEBSITE_URL = "https://klango.online".freeze
    SOURCE_URL = "https://klango.online".freeze
    CONTACT = "https://klango.online".freeze
    SERVER_TERMS_URL = "https://klango.online".freeze

    # Data locations. Klangten never shares a directory with Elten:
    #   Windows: %APPDATA%\sixdotsIT\klangten
    #   macOS:   ~/Library/Application Support/sixdotsIT/klangten
    #   Linux:   $XDG_DATA_HOME/sixdotsIT/klangten (~/.local/share/sixdotsIT/klangten)
    DATA_DIR_VENDOR = VENDOR
    DATA_DIR_NAME = PRODUCT_ID
    PORTABLE_DATA_DIR = "klangtendata".freeze
    # Marker file in the program directory enabling portable mode
    # ([Klangten] Portable=1) and, inside the data directory, the main config file.
    PORTABLE_INI = "klangten.ini".freeze
    PORTABLE_INI_SECTION = PRODUCT_NAME
    CONFIG_FILE_NAME = "klangten.ini".freeze
    LOG_FILE_NAME = "klangten.log".freeze
    OLD_LOG_FILE_NAME = "klangten.old.log".freeze
    TEMP_DIR_NAME = PRODUCT_ID

    # Desktop identity.
    WINDOWS_MAIN_CLASS = "KLANGTENMAINWND".freeze
    WINDOWS_AUTOSTART_VALUE = PRODUCT_ID
    NVDA_ADDON_FILE = "klangten.nvda-addon".freeze

    # Elten's program relay used its own port on relay.elten.link. Klango has
    # no relay, so hosted programs report live sessions as unavailable
    # (src/eltenlink/relay.rb). Conferences use TeamConference instead of
    # Elten's conference server (src/eapi/conference.rb).
    RELAY_PORT = 8244

    # Upstream rewrote short audio links of these hosts to API audio paths.
    # EltenLink hosts are intentionally not listed; Klangten servers do not
    # produce such links.
    LEGACY_AUDIO_SHORT_HOSTS = [].freeze

    # Feature switches for parts that only make sense for EltenLink.
    # Built-in updater, installer download, update prompts. Served by the Klango
    # server (/api/v1/system/build-id, /updates, /installer); see docs/klangten-releases.md.
    UPDATES_ENABLED = true
    UPDATES_ENV = "KLANGTEN_UPDATES".freeze
    PROGRAM_STORE_ENABLED = false      # server program repository offered by the welcome wizard
    SMS_TWO_FACTOR_ENABLED = false     # EltenLink SMS based two-factor authentication
    LAUNCHER_STAMP_ENABLED = false     # EltenLink launcher stamp (get_stamp); never used by Klangten
    PROGRAM_SIGNING_ROOT_RESOURCE = nil # no Klangten signing root yet: packages are treated as unsigned

    class << self
      def product_name
        PRODUCT_NAME
      end

      def version
        VERSION
      end

      def vendor
        VENDOR
      end

      def api_url
        value = ENV[API_URL_ENV].to_s.strip
        value = DEFAULT_API_URL if value == "" || parse_url(value) == nil
        value.sub(/\/+\z/, "")
      end

      # Base URL without trailing slash, e.g. "https://ten.klango.online".
      def api_base_url
        uri = api_uri
        default_port = uri.scheme == "https" ? 443 : 80
        port = uri.port == default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}"
      end

      def api_uri
        parse_url(api_url) || parse_url(DEFAULT_API_URL)
      end

      def api_scheme
        api_uri.scheme
      end

      def api_host
        api_uri.host
      end

      def api_port
        api_uri.port
      end

      def api_tls?
        api_scheme == "https"
      end

      # HTTP/1.1 only for plain HTTP (local development), optional for HTTPS.
      def http2_allowed?
        api_tls? && ENV["KLANGTEN_HTTP2"].to_s != "0"
      end

      # "host:port" as used for the HTTP Host header and the HTTP/2 :authority.
      def api_authority
        "#{api_host}:#{api_port}"
      end

      def relay_host
        env_value("KLANGTEN_RELAY_HOST") || api_host
      end

      def relay_port
        (env_value("KLANGTEN_RELAY_PORT") || RELAY_PORT).to_i
      end

      def updates_enabled?
        return false unless UPDATES_ENABLED == true
        !%w[0 false no off].include?(ENV[UPDATES_ENV].to_s.strip.downcase)
      end

      def program_store_enabled?
        PROGRAM_STORE_ENABLED == true
      end

      def sms_two_factor_enabled?
        SMS_TWO_FACTOR_ENABLED == true
      end

      def launcher_stamp_enabled?
        LAUNCHER_STAMP_ENABLED == true
      end

      # "Klangten/0.1.0 (based on Elten 3.0.3)"
      def user_agent
        upstream = upstream_version
        upstream = "" if upstream == nil
        suffix = upstream == "" ? UPSTREAM_NAME : "#{UPSTREAM_NAME} #{upstream}"
        "#{PRODUCT_NAME}/#{VERSION} (based on #{suffix})"
      end

      def upstream_version
        return nil unless defined?(::Elten) && ::Elten.respond_to?(:upstream_version)
        ::Elten.upstream_version
      rescue Exception
        nil
      end

      # Directory below the platform application data directory.
      def data_dir(appdata_root)
        File.join(appdata_root.to_s, DATA_DIR_VENDOR, DATA_DIR_NAME)
      end

      private

      def parse_url(value)
        uri = URI.parse(value.to_s)
        return nil unless uri.is_a?(URI::HTTP) && uri.host.to_s != ""
        uri
      rescue URI::InvalidURIError
        nil
      end

      def env_value(name)
        value = ENV[name].to_s.strip
        value == "" ? nil : value
      end
    end
  end

  # Klangten's updater identity: installer names, architecture reported to the
  # server, trusted download location and the command that runs a verified
  # installer at exit. Kept free of platform libraries so that it can be used
  # (and tested) on any system; the platform system helpers delegate here.
  module Updates
    # Names of the downloaded installer inside Klangten's own data directory.
    # They match the release packages and never collide with Elten's eltenup.* files.
    INSTALLER_FILENAMES = {
      "windows" => "KlangtenSetup.exe",
      "osx" => "Klangten.dmg",
      "linux" => "klangten-linux.run"
    }.freeze
    ARCHES = %w[x64 x86 arm64].freeze
    LINUX_INSTALL_DIR = "/opt/klangten".freeze

    class << self
      def installer_filename(platform)
        INSTALLER_FILENAMES.fetch(platform.to_s) { "klangten-installer" }
      end

      # Architecture of the running launcher ("x64", "x86", "arm64"). The server
      # falls back to the installer covering it (e.g. Windows arm64 -> x64).
      def arch
        value = ENV["ELTEN_LAUNCHER_ARCH"].to_s.strip.downcase
        return value if ARCHES.include?(value)
        cpu = defined?(RbConfig) ? RbConfig::CONFIG["host_cpu"].to_s.downcase : ""
        return "arm64" if cpu =~ /arm64|aarch64/
        return "x86" if cpu =~ /\A(i[3-6]86|x86)\z/
        "x64"
      end

      # Updater requests go to the configured Klangten API only; a download
      # location on any other scheme, host or port is refused.
      def trusted_url?(url, base_url = Config.api_base_url)
        uri = URI.parse(url.to_s)
        base = URI.parse(base_url.to_s)
        uri.is_a?(URI::HTTP) && base.is_a?(URI::HTTP) &&
          uri.scheme.to_s.downcase == base.scheme.to_s.downcase &&
          uri.host.to_s.downcase == base.host.to_s.downcase &&
          uri.port == base.port
      rescue URI::InvalidURIError
        false
      end

      # Command run after Klangten has exited. Windows: Inno Setup
      # (KlangtenSetup.exe, own AppId); macOS: the app replaces itself from
      # Klangten.dmg (see below); Linux: the self-extracting klangten-linux.run,
      # which elevates itself, followed by a restart of /opt/klangten/elten.
      def install_command(platform, installer, silent: true, open_command: "__elten_native_open__", app_path: nil)
        case platform.to_s
        when "windows"
          command = "\"#{installer}\""
          command += " /tasks=\"\" /silent" if silent
          command
        when "osx"
          # Klangten ships a disk image, so there is no installer to run: the app
          # replaces itself. Klangten has already exited when this runs.
          #
          # The image is mounted read-only and without a Finder window, the app
          # is copied out with ditto (which keeps the signature), and the old
          # bundle is moved aside first so a failed copy can be rolled back. The
          # copy inherits the quarantine flag of the download; it is removed,
          # because the image itself was checked (size, SHA-256) and, in signed
          # builds, is notarized. Whenever a step fails, the image is opened in
          # the Finder so the update can still be installed by hand.
          target = app_path.to_s
          return ["/usr/bin/open", installer.to_s] if target == ""
          script = <<~SH
            sleep 2
            dmg="$1"
            app="$2"
            mnt=$(mktemp -d /tmp/klangten-update.XXXXXX) || exit 1
            cleanup() {
              hdiutil detach "$mnt" -quiet 2>/dev/null || hdiutil detach "$mnt" -force -quiet 2>/dev/null
              rmdir "$mnt" 2>/dev/null
            }
            give_up() {
              rm -rf "$app.update"
              cleanup
              /usr/bin/open "$dmg"
              exit 1
            }
            hdiutil attach "$dmg" -nobrowse -readonly -noverify -mountpoint "$mnt" >/dev/null 2>&1 || give_up
            [ -d "$mnt/Klangten.app" ] || give_up
            rm -rf "$app.update"
            ditto "$mnt/Klangten.app" "$app.update" || give_up
            xattr -dr com.apple.quarantine "$app.update" 2>/dev/null
            rm -rf "$app.old"
            if [ -d "$app" ]; then
              mv "$app" "$app.old" || give_up
            fi
            if ! mv "$app.update" "$app"; then
              [ -d "$app.old" ] && mv "$app.old" "$app" 2>/dev/null
              give_up
            fi
            rm -rf "$app.old"
            cleanup
            /usr/bin/open -a "$app" 2>/dev/null || /usr/bin/open "$app"
          SH
          ["/bin/sh", "-c", script, "klangten-update", installer.to_s, target]
        when "linux"
          script = <<~SH
            sleep 2
            installer="$1"
            chmod 0700 "$installer" || exit 1
            if [ "$2" = "1" ]; then
              "$installer" --silent || exit 1
            else
              "$installer" || exit 1
            fi
            [ -x #{LINUX_INSTALL_DIR}/elten ] && exec #{LINUX_INSTALL_DIR}/elten
          SH
          ["/bin/sh", "-c", script, "klangten-update", installer.to_s, silent ? "1" : "0"]
        else
          raise ArgumentError, "unsupported platform for updates: #{platform}"
        end
      end
    end
  end
end
end
