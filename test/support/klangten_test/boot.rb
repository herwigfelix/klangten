# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Loads the Klangten core into the test process, the same way elten.rb does
# for users - same filelist, same order - except for a handful of platform
# files that are replaced by the test doubles in platform/ (see
# KlangtenTestBoot.source_for, called by the hook in elten.rb). src/main.rb is
# not run here; KlangtenTest::App#boot starts it on a scene thread.

require "fileutils"

module KlangtenTestBoot
  ROOT = File.expand_path("../../..", __dir__)
  PLATFORM = File.join(__dir__, "platform")

  WINDOW = File.join(PLATFORM, "window.rb")
  SPEECH = File.join(PLATFORM, "speech.rb")
  CLIPBOARD = File.join(PLATFORM, "clipboard.rb")
  SYSTEM = File.join(PLATFORM, "system.rb")

  # filelist entry => replacement (nil = not loaded at all)
  REPLACE = {
    "src/platforms/osx/ri/desktopruntime.rb" => WINDOW,
    "src/platforms/linux/ri/desktopruntime.rb" => WINDOW,
    "src/platforms/linux/eapi/sdl2.rb" => nil,
    "src/platforms/osx/eapi/speech.rb" => SPEECH,
    "src/platforms/osx/eapi/voiceover.rb" => nil,
    "src/platforms/linux/eapi/speechd.rb" => SPEECH,
    "src/platforms/linux/eapi/speech.rb" => nil,
    "src/platforms/osx/eapi/clipboard.rb" => CLIPBOARD,
    "src/platforms/linux/eapi/clipboard.rb" => CLIPBOARD
  }.freeze

  # filelist entry => file loaded right after it
  AFTER = {
    "src/platforms/osx/ri/systemhelpers.rb" => SYSTEM,
    "src/platforms/linux/ri/systemhelpers.rb" => SYSTEM
  }.freeze

  class << self
    attr_reader :main_file

    # Called by elten.rb for every filelist entry: the path(s) to load.
    def source_for(file, path)
      if file.casecmp("src/main.rb") == 0
        @main_file = path
        return nil
      end
      return REPLACE[file] if REPLACE.key?(file)
      return [path, AFTER[file]] if AFTER.key?(file)
      path
    end

    def supported_platform?
      RUBY_PLATFORM =~ /darwin|linux/i ? true : false
    end

    def runtime_library_dir
      if RUBY_PLATFORM =~ /darwin/i
        File.join(ROOT, "bin", "osx")
      else
        arch = RbConfig::CONFIG["host_cpu"].to_s =~ /arm64|aarch64/ ? "arm64" : "x64"
        File.join(ROOT, "bin", "linux-#{arch}")
      end
    end

    # Environment of a test process: everything Klangten could find on the
    # machine (home, temp, XDG directories) points into the test's own
    # directory, and the API points at the test server or at nothing.
    def environment(dir, api_url)
      home = File.join(dir, "home")
      lib = runtime_library_dir
      env = {
        "HOME" => home,
        "TMPDIR" => File.join(dir, "tmp"),
        "XDG_DATA_HOME" => File.join(home, ".local", "share"),
        "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "XDG_CACHE_HOME" => File.join(home, ".cache"),
        "XDG_RUNTIME_DIR" => File.join(dir, "run"),
        "KLANGTEN_API_URL" => api_url,
        "KLANGTEN_HTTP2" => "0",
        "KLANGTEN_UPDATES" => "0",
        "ELTEN_ROOT" => ROOT,
        "ELTEN_OSX_DYLD_BOOTSTRAPPED" => "1",
        "ELTEN_LINUX_LD_BOOTSTRAPPED" => "1"
      }
      if RUBY_PLATFORM =~ /darwin/i
        env["DYLD_LIBRARY_PATH"] = [lib, ENV["DYLD_LIBRARY_PATH"]].compact.reject(&:empty?).join(":")
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [lib, ENV["DYLD_FALLBACK_LIBRARY_PATH"]].compact.reject(&:empty?).join(":")
      else
        env["LD_LIBRARY_PATH"] = [lib, ENV["LD_LIBRARY_PATH"]].compact.reject(&:empty?).join(":")
      end
      env
    end

    def data_dir(dir)
      File.join(dir, "data")
    end

    # A fresh data directory: configured, licence accepted, no welcome wizard.
    def prepare_data_dir(dir, language:, keyboard_scheme:, settings: {})
      %w[home tmp run].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      data = data_dir(dir)
      FileUtils.mkdir_p(data)
      ini = {
        "Elten" => { "ConfigurationVersion" => "5" },
        "Interface" => {
          "Language" => language,
          "KeyboardScheme" => keyboard_scheme.to_s,
          "SoundThemeActivation" => "true"
        },
        "Voice" => { "Voice" => "test:voice" },
        "Updates" => { "CheckAtStartup" => "false" },
        "Privacy" => { "RegisterActivity" => "false" }
      }
      settings.each do |group, values|
        ini[group.to_s] ||= {}
        values.each { |key, value| ini[group.to_s][key.to_s] = value.to_s }
      end
      text = ini.map { |group, values| "[#{group}]\n" + values.map { |k, v| "#{k}=#{v}\n" }.join }.join("\n")
      File.binwrite(File.join(data, "klangten.ini"), text)
      File.binwrite(File.join(data, "license_agreed.dat"), "\002")
      File.binwrite(File.join(data, "appid.dat"), "KlangtenTestAppId" + "0" * 47)
      data
    end

    # Loads the core (elten.rb with the hook) - once per test process.
    def load_core(data_dir)
      raise "Klangten flow tests run on macOS and Linux only" unless supported_platform?
      ARGV.replace(["/datadir", data_dir])
      Dir.chdir(ROOT)
      load File.join(ROOT, "elten.rb")
      raise "src/main.rb was not found in the filelist" if @main_file == nil
      true
    end
  end
end
