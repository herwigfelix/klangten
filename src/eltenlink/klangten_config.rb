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
#   KLANGO_SRV_HOST_BASE_URL  base address of another Klango server, e.g.
#                             https://example.org (also the start option
#                             --srv-host-base-url, see Klangten::Startup); the
#                             Klangten API is then expected at ten.<host>
#   KLANGTEN_CONFIG_DIR       replaces the data directory (--overwrite-config-path)
#   KLANGTEN_RECORDINGS_DIR   where recordings, downloads and documents go
#                             (--overwrite-recordings-path)
#   KLANGTEN_API_URL          developer switch: REST API base URL, e.g.
#                             http://127.0.0.1:5100; wins over everything above
#                             and is also used for updates and error reports
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
    VERSION = "0.3.0".freeze
    VENDOR = "sixdotsIT".freeze
    COPYRIGHT = "Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)".freeze
    UPSTREAM_NAME = "Elten".freeze
    UPSTREAM_COPYRIGHT = "Copyright (C) 2014-2026 Dawid Pieper".freeze
    UPSTREAM_SOURCE_URL = "https://github.com/dawidpieper/elten3".freeze
    SERVER_NAME = "Klango".freeze

    # The official Klango server. Another one can be chosen at startup
    # (--srv-host-base-url, Klangten::Startup); updates, error reports and
    # everything else that belongs to the software itself still come from the
    # official one (software_api_base_url).
    OFFICIAL_SERVER_URL = "https://klango.online".freeze
    DEFAULT_API_URL = "https://ten.klango.online".freeze
    API_URL_ENV = "KLANGTEN_API_URL".freeze
    SERVER_URL_ENV = "KLANGO_SRV_HOST_BASE_URL".freeze
    CONFIG_DIR_ENV = "KLANGTEN_CONFIG_DIR".freeze
    RECORDINGS_DIR_ENV = "KLANGTEN_RECORDINGS_DIR".freeze
    # The Klango server answers the Klangten API on this subdomain; the other
    # service subdomains of a server name are replaced by it.
    API_SUBDOMAIN = "ten".freeze
    SERVICE_SUBDOMAINS = %w[www web chat].freeze

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
    # Two-factor authentication (Konto > Manage Two-Factor authentication and the
    # login prompt). The Klango server delivers codes via Telegram or text message
    # and answers the Elten endpoints under /api/v1/authentication.
    TWO_FACTOR_ENABLED = true
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

      # Klangten API in use: the developer switch KLANGTEN_API_URL, else the API
      # of the chosen Klango server, else ten.klango.online.
      def api_url
        developer_api_url || api_url_for_server(server_url) || DEFAULT_API_URL
      end

      # KLANGTEN_API_URL when it holds a usable address, else nil.
      def developer_api_url
        value = env_value(API_URL_ENV)
        return nil if value == nil || parse_url(value) == nil
        value.sub(/\/+\z/, "")
      end

      # Base address of the chosen Klango server ("https://example.org"),
      # the official one when none (or an unusable one) was given.
      def server_url
        normalize_server_url(ENV[SERVER_URL_ENV]) || OFFICIAL_SERVER_URL
      end

      # "example.org", "https://Moradio.online/" -> "https://example.org".
      # Without a scheme https is assumed; a path is dropped. nil if unusable.
      def normalize_server_url(value)
        text = value.to_s.strip.sub(/\A["']+/, "").sub(/["']+\z/, "").strip
        return nil if text == ""
        text = "https://" + text unless text.include?("://")
        uri = parse_url(text)
        return nil if uri == nil
        format_url(uri.scheme, uri.host, uri.port)
      end

      # Klangten API of a Klango server: https://example.org ->
      # https://ten.example.org. A ten. host is kept, www./web./chat. are
      # replaced by ten. IP addresses and localhost cannot carry a subdomain and
      # are used as given (a local development server answers the Klangten API
      # directly, python -m klango.klangten).
      def api_url_for_server(value)
        base = normalize_server_url(value)
        return nil if base == nil
        uri = parse_url(base)
        host = uri.host.to_s.downcase
        unless host_without_subdomain?(host)
          labels = host.split(".")
          if labels.first == API_SUBDOMAIN
            # already the Klangten API host
          elsif SERVICE_SUBDOMAINS.include?(labels.first) && labels.size > 2
            host = ([API_SUBDOMAIN] + labels.drop(1)).join(".")
          else
            host = "#{API_SUBDOMAIN}.#{host}"
          end
        end
        format_url(uri.scheme, host, uri.port)
      end

      # True when Klangten talks to the official server (ten.klango.online).
      def official_server?
        same_base_url?(api_url, DEFAULT_API_URL)
      end

      # The server chosen with --srv-host-base-url is not the official one and
      # has to be confirmed by the user before anything goes over the network.
      # The developer switch KLANGTEN_API_URL is exempt.
      def server_confirmation_required?
        developer_api_url == nil && !official_server?
      end

      # Where updates, installers, extras and error reports come from: always the
      # official server; only the developer switch redirects them as well.
      def software_api_base_url
        return api_base_url if developer_api_url != nil
        base_url_of(DEFAULT_API_URL)
      end

      # Web address of the server in use, for its terms and its operator.
      def server_web_url
        return OFFICIAL_SERVER_URL if official_server?
        return api_base_url if developer_api_url != nil
        server_url
      end

      # Fallback address of the server terms when the server names none.
      def server_terms_url
        official_server? ? SERVER_TERMS_URL : server_web_url
      end

      # Data directory and recordings directory chosen at startup (absolute,
      # see Klangten::Startup), nil when not chosen.
      def config_dir_override
        env_value(CONFIG_DIR_ENV)
      end

      def recordings_dir_override
        env_value(RECORDINGS_DIR_ENV)
      end

      # Base URL without trailing slash, e.g. "https://ten.klango.online".
      def api_base_url
        uri = api_uri
        format_url(uri.scheme, uri.host, uri.port)
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

      def two_factor_enabled?
        TWO_FACTOR_ENABLED == true
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

      def format_url(scheme, host, port)
        scheme = scheme.to_s.downcase
        default_port = scheme == "https" ? 443 : 80
        port_text = port == nil || port.to_i == default_port ? "" : ":#{port}"
        "#{scheme}://#{host.to_s.downcase}#{port_text}"
      end

      def base_url_of(url)
        uri = parse_url(url)
        uri == nil ? nil : format_url(uri.scheme, uri.host, uri.port)
      end

      def same_base_url?(a, b)
        x = base_url_of(a)
        x != nil && x == base_url_of(b)
      end

      def host_without_subdomain?(host)
        name = host.to_s.downcase.sub(/\A\[/, "").sub(/\]\z/, "")
        return true if name == "localhost" || name.end_with?(".localhost")
        return true if name.include?(":") # IPv6
        return true if name.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
        !name.include?(".")
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
      "linux" => "klangten-linux.run",
      "android" => "Klangten.apk"
    }.freeze
    ARCHES = %w[x64 x86 arm64].freeze
    LINUX_INSTALL_DIR = "/opt/klangten".freeze
    # Program started again after a Linux update. Up to 0.3 it was
    # /opt/klangten/elten; the 0.4 package keeps that name as a small script
    # that starts klangten, because a running 0.3 restarts exactly that path
    # (docs/klangten-releases.md, "Executable names").
    LINUX_EXECUTABLE = "klangten".freeze

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

      # Updater requests go to the official server only (the developer switch
      # KLANGTEN_API_URL aside), never to a Klango server chosen with
      # --srv-host-base-url; a download location on any other scheme, host or
      # port is refused.
      def trusted_url?(url, base_url = Config.software_api_base_url)
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
      # which elevates itself, followed by a restart of /opt/klangten/klangten.
      # The installers start nothing by a fixed program name except these
      # restarts: Windows' Inno Setup restarts Klangten itself ([Run] entry).
      #
      # restart_args are the start options of the running Klangten (data
      # directory, recordings directory, server; Klangten::Startup) handed to
      # the updated program on macOS and Linux. On Windows the installer starts
      # Klangten itself; it inherits them from the environment.
      def install_command(platform, installer, silent: true, open_command: "__elten_native_open__", app_path: nil, restart_args: nil)
        restart_args = default_restart_args if restart_args == nil
        restart_args = restart_args.to_a.map(&:to_s)
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
            shift 2
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
            if [ "$#" -gt 0 ]; then
              /usr/bin/open -a "$app" --args "$@" 2>/dev/null || /usr/bin/open "$app"
            else
              /usr/bin/open -a "$app" 2>/dev/null || /usr/bin/open "$app"
            fi
          SH
          ["/bin/sh", "-c", script, "klangten-update", installer.to_s, target] + restart_args
        when "linux"
          script = <<~SH
            sleep 2
            installer="$1"
            silent="$2"
            shift 2
            chmod 0700 "$installer" || exit 1
            if [ "$silent" = "1" ]; then
              "$installer" --silent || exit 1
            else
              "$installer" || exit 1
            fi
            dir=#{LINUX_INSTALL_DIR}
            # A package up to 0.3 (a rollback) installs the program itself as
            # "elten" and leaves the newer "klangten" behind; since 0.4 "elten"
            # is only a script that starts "klangten".
            if [ -x "$dir/elten" ] && [ "$(head -c 2 "$dir/elten" 2>/dev/null)" != "#!" ]; then
              exec "$dir/elten" "$@"
            fi
            [ -x "$dir/#{LINUX_EXECUTABLE}" ] && exec "$dir/#{LINUX_EXECUTABLE}" "$@"
          SH
          ["/bin/sh", "-c", script, "klangten-update", installer.to_s, silent ? "1" : "0"] + restart_args
        else
          raise ArgumentError, "unsupported platform for updates: #{platform}"
        end
      end

      def default_restart_args
        defined?(::Klangten::Startup) ? ::Klangten::Startup.restart_arguments : []
      rescue StandardError
        []
      end
    end
  end
end
end
