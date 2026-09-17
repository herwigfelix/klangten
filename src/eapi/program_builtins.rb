# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Built-in programs.
#
# Klangten ships four former Elten programs (YouTube, FileManager, the FFmpeg
# encoders and MCP) as part of the client instead of installing them from a
# program repository. Their unpacked sources live in src/programs/<directory>/
# and their gettext catalogues in locale/programs/<directory>/<LANG>.mo.
#
# Packaging needs no extra step: the launcher embeds every src/**/*.rb file and
# every locale/**/*.mo file. In an embedded build the sources are read from the
# launcher payload; when Klangten runs from a source checkout they are read from
# disk. Built-in programs are trusted like the rest of the client code, so they
# are loaded without package signature and without developer mode.
#
# Built-ins keep their original program UUIDs (settings, data and translation
# contexts depend on them) but use entry ids of the form "builtin-<key>". Their
# data and cache directories therefore live below Klangten's own data directory
# (apps/data/builtin-<key>), separate from a normal Elten installation. A
# package with the UUID of a built-in program is never loaded from the
# programs directory, so a stray installed copy cannot shadow the built-in one.

module Programs
  module BuiltIns
    Definition = Struct.new(:key, :uuid, :directory, :main, keyword_init: true) do
      def entry
        "builtin-#{key}"
      end
    end

    DEFINITIONS = [
      Definition.new(key: :youtube, uuid: "7c8e3f91-40a7-45af-8758-99d67a602e41", directory: "youtube", main: "__app.rb"),
      Definition.new(key: :ffmpeg, uuid: "f2e2661b-f6b2-4b32-8c38-62e890a13c41", directory: "ffmpeg", main: "ffmpeg.rb"),
      Definition.new(key: :filemanager, uuid: "8c8d86ce-dc24-453f-a388-e9b5e8626c5c", directory: "filemanager", main: "__app.rb"),
      Definition.new(key: :mcp, uuid: "bf4dbbd4-cadc-4ab2-8738-7340677de1e2", directory: "mcp", main: "__app.rb")
    ].freeze

    SOURCE_PREFIX = "src/programs".freeze
    LOCALE_PREFIX = "locale/programs".freeze

    class << self
      def definitions
        DEFINITIONS
      end

      def definition(key)
        DEFINITIONS.find { |item| item.key == key.to_s.to_sym }
      end

      def uuids
        DEFINITIONS.map(&:uuid)
      end

      def uuid?(uuid)
        value = uuid.to_s.downcase
        value != "" && uuids.include?(value)
      end

      def entry?(entry)
        DEFINITIONS.any? { |item| item.entry == entry.to_s }
      end

      # Loads every built-in program which supports the current platform.
      def load_all
        DEFINITIONS.each { |item| load(item.key) }
      end

      def load(key)
        item = definition(key)
        return false if item == nil
        Programs.load_builtin(item)
      end

      def loaded?(key)
        program_class(key) != nil
      end

      # The launched Program class of a built-in, or nil when it is not loaded
      # (for example on an unsupported platform or after a load error).
      def program_class(key)
        item = definition(key)
        return nil if item == nil
        Programs.list.find do |cls|
          runtime = Programs.runtime_for(cls) rescue nil
          runtime != nil && runtime.entry_id == item.entry
        end
      rescue Exception
        nil
      end

      # Ruby sources of a built-in program as { logical path => code }.
      def source_files(item)
        files = embedded_source_files(item)
        files = disk_source_files(item) if files.empty?
        files
      end

      # Gettext catalogues as { language code => data }.
      def language_files(item)
        prefix = "#{LOCALE_PREFIX}/#{item.directory}"
        result = {}
        EltenAPI::Resources.keys(prefix, base: ".").each do |key|
          next if File.extname(key).downcase != ".mo"
          code = File.basename(key, File.extname(key)).to_s[0, 2].downcase
          next if code == ""
          data = EltenAPI::Resources.read(key, base: ".")
          result[code] = data.to_s.b if data != nil && data.to_s != ""
        end
        result
      rescue Exception => e
        Log.warning("Cannot read translations of built-in program #{item.key}: #{e.class}: #{e.message}")
        {}
      end

      # Physical source directory in a source checkout, nil in embedded builds.
      def physical_root(item)
        return nil if embedded?
        root = File.join(EltenRuntimePaths.root, *SOURCE_PREFIX.split("/"), item.directory)
        File.directory?(root) ? root : nil
      rescue Exception
        nil
      end

      private

      def embedded?
        defined?(::EltenEmbedded) && defined?($ELTEN_EMBEDDED_RB) && $ELTEN_EMBEDDED_RB.respond_to?(:each)
      end

      def embedded_source_files(item)
        return {} if !embedded?
        prefix = "#{SOURCE_PREFIX}/#{item.directory}/"
        files = {}
        $ELTEN_EMBEDDED_RB.each do |key, entry|
          normalized = key.to_s.tr("\\", "/").downcase
          next if !normalized.start_with?(prefix)
          logical = original_logical_name(entry, prefix) || normalized[prefix.size..-1]
          code = ::EltenEmbedded.read_rb(key)
          files[logical] = code.to_s if code != nil
        end
        files
      rescue Exception => e
        Log.warning("Cannot read embedded built-in program #{item.key}: #{e.class}: #{e.message}")
        {}
      end

      # Embedded keys are lower-case; the first element of an entry keeps the
      # original file name, which gem load paths such as Ascii85/ depend on.
      def original_logical_name(entry, prefix)
        name = entry.is_a?(Array) ? entry[0].to_s.tr("\\", "/") : ""
        index = name.downcase.rindex(prefix)
        return nil if index == nil
        value = name[(index + prefix.size)..-1].to_s
        value == "" ? nil : value
      end

      def disk_source_files(item)
        root = physical_root(item)
        return {} if root == nil
        files = {}
        Dir.glob(File.join(root, "**", "*.rb")).sort.each do |file|
          files[EltenPath.relative_from(file, root).tr("\\", "/")] = File.binread(file)
        end
        files
      end
    end
  end

  class << self
    # Loads one built-in program. Mirrors load_sig, without package discovery,
    # signature policy, developer-mode restriction and apps registry.
    def load_builtin(item)
      entry = item.entry
      return true if @@runtimes.key?(entry)
      runtime = nil
      files = BuiltIns.source_files(item)
      main_code = files[item.main]
      raise ProgramError, "Built-in program #{item.key} has no #{item.main}" if main_code == nil
      manifest = CodeManifestParser.parse(main_code, "#{BuiltIns::SOURCE_PREFIX}/#{item.directory}/#{item.main}")
      manifest.instance_variable_set(:@main, item.main)
      raise ProgramError, "Built-in program #{item.key} has unexpected UUID #{manifest.id}" if manifest.id.downcase != item.uuid
      if !manifest.supports_current_platform?
        Log.info("Skipping built-in program #{manifest.name}: unsupported platform #{platform_target}")
        return false
      end
      @@configs[entry] = manifest.to_config(item.main)
      runtime = Runtime.new(
        :entry_id => entry,
        :root => BuiltIns.physical_root(item),
        :manifest => manifest,
        :virtual_files => files,
        :language_files => BuiltIns.language_files(item)
      )
      load_runtime_locale(runtime)
      runtime.validate_required_assets!
      runtime.load_main
      main_class = resolve_main_class(runtime)
      bind_manifest(main_class, runtime)
      register(main_class, entry, true, :initialize_class => false)
      initialize_program_class(main_class)
      Log.info("Loaded built-in program #{manifest.raw_name}")
      true
    rescue Exception => e
      rollback_program_load(entry, runtime) if entry != nil
      Log.error("Failed to load built-in program #{item.key}: #{e.class}: #{e.message}, #{e.backtrace}")
      false
    end
  end
end
