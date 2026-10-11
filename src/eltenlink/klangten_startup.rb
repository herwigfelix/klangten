# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Running Klangten from another place and against another Klango server.
#
#   Klangten::Startup      the start options --overwrite-config-path,
#                          --overwrite-recordings-path and --srv-host-base-url
#   Klangten::ServerTrust  Klango servers other than the official one the user
#                          agreed to use (asked once per server)
#   Klangten::ServerLock   recognises a Klango server that locked itself
#                          because it has no valid licence
#
# Like klangten_config.rb this file has no dependencies besides the standard
# library: elten.rb loads it right after the configuration, because the data
# directory has to be known before anything else is loaded. The filelist entry
# then finds it already loaded. Nothing here talks to the network or the UI, so
# all of it can be tested on its own (test/klangten_startup_test.rb).

require "fileutils"

unless defined?(::Klangten::Startup)
module Klangten
  # Start options with a value. They are written as "--name value",
  # "--name=value" or "name=value" (the form Klango 4 accepts as well) and act
  # through the environment, so every process Klangten starts - a restart, the
  # updater, the installer - inherits them. Relative paths are taken relative to
  # the program (see base_dir), so a whole installation can live on a USB stick:
  #
  #   --overwrite-config-path DIR       replaces the data directory
  #                                     (…/sixdotsIT/klangten: klangten.ini, the
  #                                     log, caches, sound themes, programs)
  #   --overwrite-recordings-path DIR   where recordings, downloads and documents
  #                                     go (Dirs.documents, .music, .downloads)
  #   --srv-host-base-url URL           another Klango server, e.g.
  #                                     https://example.org (Config.server_url)
  module Startup
    VALUE_SWITCHES = {
      "--overwrite-config-path" => Config::CONFIG_DIR_ENV,
      "--overwrite-recordings-path" => Config::RECORDINGS_DIR_ENV,
      "--srv-host-base-url" => Config::SERVER_URL_ENV
    }.freeze
    PATH_ENVS = [Config::CONFIG_DIR_ENV, Config::RECORDINGS_DIR_ENV].freeze
    LAUNCHER_EXECUTABLE_ENV = "ELTEN_LAUNCHER_EXECUTABLE_PATH".freeze

    class << self
      # {environment variable => value} for the start options in args. Unknown
      # arguments are left alone (elten.rb reads /hidden, /datadir and others
      # itself); a later option wins over an earlier one.
      def parse(args)
        list = args.to_a.map(&:to_s)
        result = {}
        index = 0
        while index < list.size
          arg = list[index]
          if arg.include?("=")
            name, value = arg.split("=", 2)
            env = switch_env(name, allow_bare: true)
            if env != nil
              value = clean_value(value)
              result[env] = value if value != ""
            end
          elsif (env = switch_env(arg)) != nil
            value = list[index + 1]
            if value != nil
              value = clean_value(value)
              result[env] = value if value != ""
              index += 1
            end
          end
          index += 1
        end
        result
      end

      # Puts the start options into the environment and makes both directories
      # absolute (and creates them). Values already in the environment - set by
      # the user or inherited from the Klangten that restarted this one - stay
      # unless an option replaces them. Returns the options that were found.
      def apply!(args, env: ENV, base_dir: nil)
        base_dir ||= self.base_dir(env: env)
        options = parse(args)
        options.each { |name, value| env[name] = value }
        PATH_ENVS.each do |name|
          raw = env[name].to_s.strip
          next if raw == ""
          path = absolute_path(raw, base_dir)
          env[name] = path
          begin
            FileUtils.mkdir_p(path)
          rescue StandardError
            # Reported later, when the directory is used.
          end
        end
        options
      end

      # Relative paths are relative to the program: the folder of the launcher
      # executable (on macOS the folder holding Klangten.app, not the inside of
      # the bundle), or the source tree when Klangten runs from source.
      def base_dir(env: ENV, source_root: nil)
        executable = env[LAUNCHER_EXECUTABLE_ENV].to_s
        if executable != ""
          dir = File.dirname(File.expand_path(executable))
          if (match = dir.match(%r{\A(.*)/[^/]+\.app/Contents/MacOS\z}i)) != nil
            return match[1] == "" ? "/" : match[1]
          end
          return dir
        end
        source_root || File.expand_path("../..", __dir__)
      end

      def absolute_path(path, base_dir)
        File.expand_path(path.to_s, base_dir.to_s)
      end

      # The options in effect, as arguments for a Klangten started later (the
      # autostart entry, the updated program after an update).
      def restart_arguments(env: ENV)
        args = []
        VALUE_SWITCHES.each do |switch, name|
          value = env[name].to_s.strip
          next if value == ""
          args << switch << value
        end
        args
      end

      private

      def switch_env(name, allow_bare: false)
        key = name.to_s.strip.downcase
        return VALUE_SWITCHES[key] if VALUE_SWITCHES.key?(key)
        return VALUE_SWITCHES["--" + key] if allow_bare && !key.start_with?("-") && VALUE_SWITCHES.key?("--" + key)
        nil
      end

      def clean_value(value)
        value.to_s.strip.sub(/\A"(.*)"\z/m, "\\1").strip
      end
    end
  end

  # Klango servers other than the official one that the user agreed to use.
  #
  # The list lives in the standard data directory of this computer account
  # (…/sixdotsIT/klangten/trusted_servers.txt), deliberately NOT in a data
  # directory chosen with --overwrite-config-path or in portable mode: the
  # agreement is a decision of the person at this computer, not a property of a
  # data folder. A prepared folder on a USB stick or a shared drive must not be
  # able to bring its own "yes" along and so skip the warning. Klangten keeps
  # no settings for all accounts of a computer (that would need administrator
  # rights), so the standard data directory is the widest place it has.
  module ServerTrust
    FILE_NAME = "trusted_servers.txt".freeze

    class << self
      def default_path(appdata_root)
        File.join(Config.data_dir(appdata_root), FILE_NAME)
      end

      def normalize(url)
        Config.normalize_server_url(url)
      end

      def list(path)
        return [] unless File.file?(path.to_s)
        File.read(path.to_s, encoding: "UTF-8").scrub.split(/\r?\n/)
            .map { |line| line.strip }
            .reject { |line| line == "" || line.start_with?("#") }
            .map { |line| normalize(line) }
            .compact.uniq
      rescue StandardError
        []
      end

      def trusted?(url, path)
        value = normalize(url)
        value != nil && list(path).include?(value)
      end

      # Adds the server to the list; true when it is stored.
      def remember(url, path)
        value = normalize(url)
        return false if value == nil
        entries = list(path)
        return true if entries.include?(value)
        FileUtils.mkdir_p(File.dirname(path.to_s))
        temporary = "#{path}.tmp"
        File.open(temporary, "wb") do |file|
          file.write("# Klango servers confirmed by the user, one per line.\n")
          (entries + [value]).each { |entry| file.write(entry + "\n") }
        end
        File.rename(temporary, path.to_s)
        true
      rescue StandardError
        begin
          File.delete(temporary) if temporary != nil && File.file?(temporary)
        rescue StandardError
        end
        false
      end
    end
  end

  # A Klango server outside klango.online needs a licence from klango.online.
  # Without one it locks itself: every request apart from Klango 3's KRPC is
  # answered with HTTP 503 and a short plain text (German line, English line,
  # reason in brackets). Klangten reads that text out instead of reporting a
  # network error. The HTTP layer reports what it sees (report/clear); the
  # loading screen, the login and the main loop announce it (take_announcement).
  module ServerLock
    MAX_TEXT_BYTES = 2000

    @mutex = Mutex.new
    @message = nil
    @announced = false

    class << self
      # The lock text when a response of the Klangten API is the licence lock,
      # else nil. Proxies answer 503 with HTML pages and the API itself with
      # JSON envelopes; neither is a lock.
      def message_from_response(status, headers, body)
        return nil unless status.to_i == 503
        type = header_value(headers, "content-type").to_s.downcase
        return nil if type != "" && !type.start_with?("text/plain")
        text = body.to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
        return nil if text == "" || text.bytesize > MAX_TEXT_BYTES
        return nil if text.start_with?("{", "[", "<")
        text
      end

      # The line for the interface language: the server sends a German and an
      # English line followed by a reason code in brackets. Anything else is
      # read as it is.
      def localized(text, language)
        lines = text.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
        lines = lines.reject { |line| line.match?(/\A\(.*\)\z/) }
        return text.to_s.strip if lines.empty?
        return lines.join(" ") unless lines.size == 2
        language.to_s.downcase.start_with?("de") ? lines[0] : lines[1]
      end

      def report(text)
        @mutex.synchronize do
          @announced = false if @message == nil
          @message = text.to_s
        end
      end

      # A normal answer of the server: it is no longer locked.
      def clear
        @mutex.synchronize do
          @message = nil
          @announced = false
        end
      end

      def locked?
        @mutex.synchronize { @message != nil }
      end

      def message
        @mutex.synchronize { @message }
      end

      # The lock text once per lock (nil otherwise), for an announcement.
      def take_announcement
        @mutex.synchronize do
          next nil if @message == nil || @announced
          @announced = true
          @message
        end
      end

      # The lock was already read out (by the loading screen or the login).
      def mark_announced
        @mutex.synchronize { @announced = true if @message != nil }
      end

      private

      def header_value(headers, name)
        return nil unless headers.respond_to?(:each)
        headers.each do |key, value|
          return value.is_a?(Array) ? value.first : value if key.to_s.downcase == name
        end
        nil
      end
    end
  end
end
end
