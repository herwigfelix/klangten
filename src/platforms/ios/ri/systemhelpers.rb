# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS system helpers. Same public contract as the Windows/macOS versions, but
# every OS integration point (open URL, microphone permission, locale) is routed
# through the native Swift host (IOSHostBridge) when present, with safe fallbacks
# so headless tooling and the load phase work without the host attached.

module EltenSystemHelpers
  NATIVE_OPEN_COMMAND = "__elten_native_open__" unless const_defined?(:NATIVE_OPEN_COMMAND)

  class << self
    def current_lcid
      0
    end

    def current_locale_name
      if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:current_locale_name)
        locale = IOSHostBridge.current_locale_name.to_s
        return locale if locale != ""
      end
      (ENV["LANG"].to_s.split(".").first || ENV["ELTEN_IOS_LOCALE"].to_s).to_s
    rescue Exception
      ""
    end

    def logical_drives
      [container_root]
    rescue Exception
      ["/"]
    end

    def appdata_dir
      File.join(home_dir, "Library", "Application Support")
    end

    def user_dir
      home_dir
    end

    def documents_dir
      File.join(home_dir, "Documents")
    end

    def desktop_dir
      documents_dir
    end

    def music_dir
      documents_dir
    end

    def command_line_join(parts)
      require "shellwords"
      Shellwords.join(parts.map(&:to_s))
    end

    def set_dll_directory(_path)
      false
    end

    def readable_memory?(address, length)
      address.to_i != 0 && length.to_i > 0
    end

    # On iOS opening a URL always goes through UIApplication in the host; there
    # is no child-process / shell fallback (see childprocess.rb).
    def open_url(url)
      return false if url.to_s == ""
      return IOSHostBridge.open_url(url.to_s) if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:open_url)
      false
    rescue Exception
      false
    end

    def locale_compare(a, b)
      return a <=> b if !a.is_a?(String) || !b.is_a?(String)
      locale_sort_key(a) <=> locale_sort_key(b)
    rescue Exception
      a.to_s.downcase <=> b.to_s.downcase
    end

    def locale_sort_key(value)
      return value if !value.is_a?(String)
      value.to_s.unicode_normalize(:nfd).downcase
    rescue Exception
      value.to_s.downcase
    end

    def protect_data(_data, _entropy = nil)
      "".b
    end

    def unprotect_data(_data, _entropy = nil)
      nil
    end

    def file_version_info(_file, _verinfo)
      nil
    end

    def platform_os
      "ios"
    end

    def platform_target
      "ios-#{architecture}"
    end

    def runtime_directory_name(_architecture)
      "ios"
    end

    # Native libraries live inside the signed app bundle (Frameworks / bin/ios),
    # never on an arbitrary search path, so there is nothing to configure.
    def configure_library_search(_dirs, _arch_bin)
      true
    end

    def library_candidates(name, root:, bin_root:, arch_bin:, legacy_bin:, dll_directories:)
      raw = name.to_s.tr("\\", "/")
      variants = library_variants(raw)
      candidates = []
      variants.each do |variant|
        if absolute_path?(variant)
          candidates << variant
          next
        end
        if variant.to_s.downcase.start_with?("bin/")
          suffix = variant[4..-1]
          candidates << File.join(arch_bin, suffix)
          candidates << File.join(legacy_bin, suffix)
        end
        candidates << File.join(arch_bin, File.basename(variant))
        candidates << File.expand_path(variant, root)
        base = File.basename(variant)
        frameworks_dirs.each { |dir| candidates << File.join(dir, base) }
        dll_directories.each { |dir| candidates << File.join(dir, base) }
      end
      candidates.uniq
    end

    def library_variants(raw)
      raw = raw.to_s.tr("\\", "/")
      dir = File.dirname(raw)
      base = File.basename(raw)
      stem = base.sub(/\.(dll|dylib|so)\z/i, "")
      names = [base, "#{stem}.dylib"]
      names << "lib#{stem}.dylib" unless stem.start_with?("lib")
      names << stem # bare framework symbol name (e.g. bass.framework/bass)
      names.uniq.map { |candidate| dir == "." ? candidate : File.join(dir, candidate) }
    end

    def library_candidate_available?(root, candidate)
      File.file?(File.join(root, candidate)) || File.file?(candidate)
    end

    def dlopen_library(file, name)
      flags = 0
      flags |= Fiddle::RTLD_NOW if defined?(Fiddle::RTLD_NOW)
      flags |= Fiddle::RTLD_GLOBAL if defined?(Fiddle::RTLD_GLOBAL)
      open = lambda { |target| flags == 0 ? Fiddle::Handle.new(target) : Fiddle::Handle.new(target, flags) }

      # An explicit, existing path wins (rare on iOS).
      return open.call(file) if file.to_s != "" && File.file?(file.to_s)

      # Embedded framework: <PrivateFrameworks>/<name>.framework/<name>.
      base = File.basename(name.to_s.tr("\\", "/")).sub(/\.(dll|dylib|so)\z/i, "")
      base = base[3..-1] if base.start_with?("lib") && base != "lib"
      frameworks_dirs.each do |dir|
        framework = File.join(dir, "#{base}.framework", base)
        return open.call(framework) if File.file?(framework)
      end

      # On iOS the native libraries (BASS + add-ons, Steam Audio, ...) are linked
      # into the app, so their symbols resolve from the main image. Fall back to
      # the process-wide handle instead of dlopen-ing an external dylib (which
      # iOS forbids anyway).
      return Fiddle::Handle::DEFAULT if defined?(Fiddle::Handle::DEFAULT)
      open.call(nil)
    rescue Exception
      defined?(Fiddle::Handle::DEFAULT) ? Fiddle::Handle::DEFAULT : Fiddle.dlopen(nil)
    end

    def native_extension
      ".dylib"
    end

    def opus_library_name
      "opus"
    end

    def speexdsp_library_name
      "libspeexdsp"
    end

    def vst2_extensions
      []
    end

    def obsolete_extra_entries
      []
    end

    def legacy_installation_files
      []
    end

    def legacy_installation_warning
      ["", ""]
    end

    def bass_abi(_architecture)
      Fiddle::Function::DEFAULT
    end

    def os_version
      if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:os_version)
        return IOSHostBridge.os_version.to_s
      end
      "iOS"
    rescue Exception
      ""
    end

    def environment_architecture
      ""
    end

    def original_process_arguments
      []
    end

    def embedded_executable_path(root, _architecture)
      File.expand_path("elten", root)
    end

    # Autostart, background installers and self-update do not exist on iOS: the
    # App Store owns installation and updates. These stay as inert no-ops.
    def autostart_executable_path(default_path)
      default_path.to_s
    end

    def autostart_executable?(_path)
      false
    end

    def autostart_command(path)
      command_line_join([path.to_s])
    end

    def sync_autostart(_enabled, _command)
      false
    end

    def prepare_os_microphone(timeout = 15.0)
      if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:request_microphone_access)
        granted = IOSHostBridge.request_microphone_access(timeout)
        Log.warning("iOS microphone access denied or restricted") if granted == false && defined?(Log)
        return granted != false
      end
      true
    rescue Exception
      true
    end

    def beta_version_creation_supported?
      false
    end

    def autologin_key_encryption_supported?
      false
    end

    def installer_extension
      ""
    end

    def installer_filename
      ""
    end

    def installer_path(_data_dir)
      ""
    end

    # Self-update is not permitted on iOS; the App Store delivers updates.
    def update_install_command(_installer, silent: true)
      [NATIVE_OPEN_COMMAND, "https://apps.apple.com/"]
    end

    def update_supported?
      false
    end

    private

    def architecture
      cpu = defined?(RbConfig) ? RbConfig::CONFIG["host_cpu"].to_s.downcase : ""
      cpu =~ /arm|aarch64/ ? "arm64" : "x64"
    rescue Exception
      "arm64"
    end

    def home_dir
      Dir.home
    rescue Exception
      "."
    end

    def container_root
      home_dir
    rescue Exception
      "/"
    end

    def frameworks_dirs
      dirs = []
      dirs << ENV["ELTEN_IOS_FRAMEWORKS"].to_s if ENV["ELTEN_IOS_FRAMEWORKS"].to_s != ""
      if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:frameworks_path)
        path = IOSHostBridge.frameworks_path.to_s
        dirs << path if path != ""
      end
      dirs.reject(&:empty?).uniq
    rescue Exception
      []
    end

    def absolute_path?(path)
      path.to_s.start_with?("/")
    end
  end
end
