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

    # The file manager browses this. Documents is the one directory iOS shows in
    # the Files app (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace),
    # so it is the only sensible root: everything the user can reach from outside
    # the app is here, and nothing above it is writable anyway.
    #
    # Android has no such directory: HOME is the app's private files directory,
    # where nothing can be seen or put from outside, and HOME/Documents does
    # not even exist - so the file manager and every file dialog started in a
    # directory that was not there and could not open anything. Android lists
    # the shared storage and Klangten's own folder on it instead (see
    # android_storage below).
    def logical_drives
      return android_logical_drives if android?
      [documents_dir]
    rescue Exception
      [container_root]
    end

    # Name a files tree shows for one of logical_drives; nil keeps the path.
    def drive_label(path)
      # iOS: the one drive is the app's Documents folder ("On My iPhone >
      # Klangten" in the Files app); its path means nothing to the user.
      return p_("Klangten", "Klangten folder") if !android? && same_path?(path, documents_dir)
      return nil if !android?
      storage = android_storage
      return p_("Klangten", "Internal storage") if same_path?(path, storage[:shared])
      return p_("Klangten", "Klangten folder") if same_path?(path, storage[:app])
      nil
    rescue Exception
      nil
    end

    # Shortcuts a files tree lists after the drives, as [label, path]; nil
    # keeps the default (Desktop, Documents, Music). On Android these are the
    # shared folders other apps use too; folders that do not exist are left out.
    def file_shortcuts
      # iOS: Desktop, Documents and Music would all be the same folder again.
      return [] if !android?
      shared = android_storage[:shared]
      return [] if shared == ""
      [
        [p_("Klangten", "Downloads"), "Download"],
        [p_("EAPI_Form", "Documents"), "Documents"],
        [p_("EAPI_Form", "Music"), "Music"]
      ].map { |label, name| [label, File.join(shared, name)] }.select { |_label, path| File.directory?(path) }
    rescue Exception
      nil
    end

    # Android only: true while Klangten sees just its own files in the shared
    # storage and the user could grant more (see request_storage_access).
    def storage_access_missing?
      return false if !android?
      storage = android_storage
      storage[:shared] != "" && storage[:access] != true
    rescue Exception
      false
    end

    # Android only: opens the system page (or dialog) that grants access to all
    # files. :granted, :opened or :failed; see IOSHostBridge.request_storage_access.
    def request_storage_access
      return :failed if !android? || !defined?(IOSHostBridge) || !IOSHostBridge.respond_to?(:request_storage_access)
      IOSHostBridge.request_storage_access
    rescue Exception
      :failed
    end

    def appdata_dir
      File.join(home_dir, "Library", "Application Support")
    end

    def user_dir
      home_dir
    end

    # On Android file dialogs start here: the shared folder when Klangten may
    # use it, otherwise Klangten's own folder.
    def documents_dir
      return android_shared_dir("Documents") if android?
      File.join(home_dir, "Documents")
    end

    def desktop_dir
      return android_shared_dir("Download") if android?
      documents_dir
    end

    def music_dir
      return android_shared_dir("Music") if android?
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
      android? ? "android" : "ios"
    end

    def platform_target
      "#{platform_os}-#{architecture}"
    end

    def runtime_directory_name(_architecture)
      platform_os
    end

    # Android shares this layer; see EltenBoot.platform_tags.
    def android?
      defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) && EltenBoot.platform?(:android)
    rescue Exception
      false
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

      # Android keeps native libraries inside the APK: there is no file to
      # point at, but the app's linker namespace finds them by name.
      if android?
        stem = File.basename(name.to_s.tr("\\", "/")).sub(/\.(dll|dylib|so)\z/i, "")
        stem = "lib#{stem}" unless stem.start_with?("lib")
        return open.call("#{stem}.so")
      end

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
      android? ? ".so" : ".dylib"
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

    # Android updates itself from the GitHub releases (Klangten.apk); on iOS
    # self-update is not permitted, the App Store delivers updates.
    def installer_filename
      android? ? Klangten::Updates.installer_filename("android") : ""
    end

    def installer_path(data_dir)
      android? ? File.join(data_dir.to_s, installer_filename) : ""
    end

    # Never used on Android: the APK is handed to the package installer right
    # after the download (android_update_check), not after Klangten exits.
    def update_install_command(_installer, silent: true)
      [NATIVE_OPEN_COMMAND, "https://apps.apple.com/"]
    end

    def update_supported?
      android?
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

    # Android: { shared:, app:, access: } from the host. Without a host (tools,
    # an older APK) the app folder falls back to HOME/Documents.
    def android_storage
      info = defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:storage_info) ? IOSHostBridge.storage_info : nil
      info ||= { shared: "", app: "", access: false }
      if info[:app] == "" || !File.directory?(info[:app])
        fallback = File.join(home_dir, "Documents")
        Dir.mkdir(fallback) rescue nil
        info = info.merge(app: fallback)
      end
      info = info.merge(shared: "") if info[:shared] != "" && !File.directory?(info[:shared])
      info
    end

    def android_logical_drives
      storage = android_storage
      [storage[:shared], storage[:app]].reject { |path| path.to_s == "" }
    end

    def android_shared_dir(name)
      storage = android_storage
      if storage[:access] && storage[:shared] != ""
        path = File.join(storage[:shared], name)
        return path if File.directory?(path)
      end
      storage[:app]
    end

    def same_path?(a, b)
      return false if a.to_s == "" || b.to_s == ""
      a.to_s.tr("\\", "/").chomp("/") == b.to_s.tr("\\", "/").chomp("/")
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
