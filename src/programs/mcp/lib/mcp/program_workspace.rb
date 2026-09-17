# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

require "base64"
require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module EltenMCP
  class ProgramWorkspace
    MAX_FILE_BYTES = 8 * 1024 * 1024

    def initialize(storage = nil)
      @storage = storage
    end

    def data_path(path)
      return @storage.data_path(path) if @storage != nil
      EltenPath.join(Dirs.eltendata, "mcp", path)
    end

    def entries(include_errors = false)
      Programs.local_entries.map { |entry| entry_hash(entry, include_errors) }
    end

    def inspect_entry(identifier, include_error = false)
      entry_hash(resolve_entry(identifier), include_error)
    end

    def source_entry(identifier)
      entry = resolve_entry(identifier)
      declared_root = EltenPath.join(Dirs.apps, entry.realpath)
      raise ToolError, "Program #{identifier} is not an editable source directory" if !File.directory?(declared_root)
      raise ToolError, "Symbolic program roots are not editable through MCP" if File.symlink?(declared_root)
      root = File.realpath(declared_root)
      apps_root = File.realpath(Dirs.apps)
      root_key = path_key(root)
      apps_key = path_key(apps_root)
      raise ToolError, "Program source resolves outside the Klangten apps directory" if !root_key.start_with?(apps_key + "/")
      [entry, root]
    end

    def list_files(identifier, path = "", recursive = true)
      entry, root = source_entry(identifier)
      base = resolve_path(root, path, :allow_root => true)
      raise ToolError, "Path is not a directory: #{path}" if !File.directory?(base)
      pattern = recursive == false ? File.join(base, "*") : File.join(base, "**", "*")
      files = Dir.glob(pattern, File::FNM_DOTMATCH).reject do |file|
        [".", ".."].include?(File.basename(file)) || File.symlink?(file)
      end
      root_key = path_key(File.realpath(root))
      files.select! do |file|
        resolved = path_key(File.realpath(file))
        resolved == root_key || resolved.start_with?(root_key + "/")
      rescue Exception
        false
      end
      result = files.sort.map do |file|
        relative = relative_path(file, root)
        if File.directory?(file)
          { "path" => relative, "type" => "directory" }
        else
          {
            "path" => relative,
            "type" => "file",
            "size" => File.size(file).to_i,
            "sha256" => Digest::SHA256.file(file).hexdigest
          }
        end
      end
      { "program" => entry.realpath, "path" => normalize_relative(path), "files" => result }
    end

    def read_file(identifier, path, encoding = "utf8")
      entry, root = source_entry(identifier)
      file = resolve_path(root, path)
      raise ToolError, "File not found: #{path}" if !File.file?(file)
      size = File.size(file).to_i
      raise ToolError, "File exceeds the #{MAX_FILE_BYTES}-byte MCP limit" if size > MAX_FILE_BYTES
      data = File.binread(file)
      content = encoding.to_s == "base64" ? Base64.strict_encode64(data) : data.force_encoding(Encoding::UTF_8).scrub
      {
        "program" => entry.realpath,
        "path" => relative_path(file, root),
        "encoding" => encoding.to_s == "base64" ? "base64" : "utf8",
        "size" => data.bytesize,
        "sha256" => Digest::SHA256.hexdigest(data),
        "content" => content
      }
    end

    def write_file(identifier, path, content, encoding = "utf8", base_hash = nil)
      entry, root = source_entry(identifier)
      file = resolve_path(root, path, :may_not_exist => true)
      data = encoding.to_s == "base64" ? Base64.strict_decode64(content.to_s) : content.to_s.encode(Encoding::UTF_8)
      raise ToolError, "File exceeds the #{MAX_FILE_BYTES}-byte MCP limit" if data.bytesize > MAX_FILE_BYTES
      verify_base_hash(file, base_hash)
      backup(entry.realpath, root, file)
      FileUtils.mkdir_p(File.dirname(file))
      atomic_write(file, data)
      audit("program_file_write", entry.realpath, relative_path(file, root), data.bytesize)
      { "program" => entry.realpath, "path" => relative_path(file, root), "size" => data.bytesize, "sha256" => Digest::SHA256.hexdigest(data) }
    rescue ArgumentError, EncodingError => e
      raise InvalidParamsError, "Invalid #{encoding} content: #{e.message}"
    end

    def apply_edits(identifier, path, edits, base_hash = nil)
      raise InvalidParamsError, "edits must be a non-empty array" if !edits.is_a?(Array) || edits.empty?
      current = read_file(identifier, path, "utf8")
      if base_hash.to_s != "" && current["sha256"] != base_hash.to_s.downcase
        raise ToolError.new("File changed since it was read", :data => { "current_sha256" => current["sha256"] })
      end
      text = current["content"]
      edits.each_with_index do |edit, index|
        raise InvalidParamsError, "Edit #{index} must be an object" if !edit.is_a?(Hash)
        old_text = edit["old_text"].to_s
        new_text = edit["new_text"].to_s
        raise InvalidParamsError, "Edit #{index} has empty old_text" if old_text == ""
        count = text.scan(Regexp.new(Regexp.escape(old_text))).size
        raise ToolError, "Edit #{index} expected exactly one match, found #{count}" if count != 1
        text = text.sub(old_text, new_text)
      end
      write_file(identifier, path, text, "utf8", current["sha256"])
    end

    def move_file(identifier, from, to, base_hash = nil)
      entry, root = source_entry(identifier)
      source = resolve_path(root, from)
      target = resolve_path(root, to, :may_not_exist => true)
      raise ToolError, "Source does not exist: #{from}" if !File.exist?(source)
      raise ToolError, "Destination already exists: #{to}" if File.exist?(target)
      verify_base_hash(source, base_hash) if File.file?(source)
      backup(entry.realpath, root, source)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.mv(source, target)
      audit("program_file_move", entry.realpath, "#{relative_path(source, root)} -> #{relative_path(target, root)}", 0)
      { "program" => entry.realpath, "from" => normalize_relative(from), "to" => normalize_relative(to) }
    end

    def delete_file(identifier, path, recursive = false, base_hash = nil)
      entry, root = source_entry(identifier)
      target = resolve_path(root, path)
      raise ToolError, "Path does not exist: #{path}" if !File.exist?(target)
      verify_base_hash(target, base_hash) if File.file?(target)
      if File.directory?(target) && recursive != true && !Dir.empty?(target)
        raise ToolError, "Directory is not empty; pass recursive=true to delete it"
      end
      backup(entry.realpath, root, target)
      File.directory?(target) ? FileUtils.rm_r(target) : File.delete(target)
      audit("program_file_delete", entry.realpath, normalize_relative(path), 0)
      { "program" => entry.realpath, "path" => normalize_relative(path), "deleted" => true }
    end

    def create_program(folder:, name:, author:, main_language:, supported_languages: nil, id: nil, version: "0.1.0")
      created = false
      folder = folder.to_s.downcase
      raise InvalidParamsError, "folder must use lowercase letters, numbers and underscores" if folder !~ /\A[a-z][a-z0-9_]{0,63}\z/
      root = File.expand_path(EltenPath.join(Dirs.apps, folder))
      raise ToolError, "Program folder already exists: #{folder}" if File.exist?(root)
      id = id.to_s == "" ? SecureRandom.uuid : id.to_s
      raise InvalidParamsError, "Invalid program UUID" if id !~ Programs::UUID_PATTERN
      raise InvalidParamsError, "name and author are required" if name.to_s.strip == "" || author.to_s.strip == ""
      begin
        main_language = Programs::ProgramPackageMetadata.normalize_language!(main_language, "main_language")
        supported_languages = Programs::ProgramPackageMetadata.normalize_languages(supported_languages || [main_language], "supported_languages")
      rescue Programs::ProgramError => e
        raise InvalidParamsError, e.message
      end
      supported_languages << main_language if !supported_languages.include?(main_language)
      supported_languages.sort!
      class_name = folder.split("_").map(&:capitalize).join
      class_name = "EltenApp" if class_name !~ /\A[A-Z][A-Za-z0-9]*\z/
      manifest = {
        "id" => id,
        "name" => name.to_s,
        "version" => version.to_s,
        "build_id" => 1,
        "EltenAPIVersion" => Programs::ELTEN_API_VERSION,
        "author" => author.to_s,
        "main_language" => main_language,
        "supported_languages" => supported_languages,
        "main" => "__app.rb",
        "main_class" => class_name,
        "platforms" => ["all"],
        "menu" => { "main" => name.to_s },
        "description" => "A voice-driven Klangten application."
      }
      code = <<~RUBY
        =begin Elten3AppInfo
        #{JSON.pretty_generate(manifest)}
        =end Elten3AppInfo

        class #{class_name} < Program
          def program_main
            information = EditBox.new(
              _(#{name.to_s.dump}),
              :type => EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine,
              :text => _("This application is ready for development.")
            )
            close = Button.new(_("Close"))
            form = Form.new([information, close], :quiet => true)
            form.accept_button = close
            form.cancel_button = close
            close.on(:press) { form.resume }
            form.wait
          end
        end
      RUBY
      FileUtils.mkdir_p(root)
      created = true
      File.binwrite(File.join(root, "__app.rb"), code)
      audit("program_create", folder, "__app.rb", code.bytesize)
      inspect_entry(folder)
    rescue Exception
      FileUtils.rm_r(root) if created && defined?(root) && File.directory?(root) && Dir.children(root).all? { |child| child == "__app.rb" }
      raise
    end

    def uninstall(identifier, remove_data = false)
      entry = resolve_entry(identifier)
      reject_current_program_uninstall(entry)
      snapshot = entry_hash(entry, true)
      Programs.set_entry_loaded(entry.realpath, false)
      removed_from_runtime = Programs.delete(entry.realpath, :reason => :uninstall)
      uninstalled = Programs.cleanup_uninstalled_program(
        entry.storage_id,
        :entry => entry.realpath,
        :remove_data => remove_data == true
      )
      raise ToolError, "Klangten could not finish uninstalling the program" if !uninstalled
      audit("program_uninstall", entry.realpath, "", 0)
      {
        "program" => snapshot,
        "uninstalled" => true,
        "removed_from_runtime" => removed_from_runtime == true,
        "program_data_removed" => remove_data == true,
        "program_data_preserved" => remove_data != true
      }
    rescue ToolError, InvalidParamsError
      raise
    rescue StandardError => e
      raise ToolError, e.message
    end

    private

    def reject_current_program_uninstall(entry)
      runtime = Programs.current_runtime
      return if runtime == nil
      current_id = runtime.respond_to?(:manifest) ? runtime.manifest.id.to_s : ""
      current_entry = runtime.respond_to?(:entry_id) ? runtime.entry_id.to_s : ""
      return if current_id.casecmp(entry.id.to_s) != 0 && current_entry.casecmp(entry.realpath.to_s) != 0

      raise ToolError, "The program serving this MCP request cannot uninstall itself. Stop MCP and uninstall it from Klangten's Programs screen."
    end

    def resolve_entry(identifier)
      identifier = identifier.to_s
      matches = Programs.local_entries.select do |entry|
        entry.realpath.to_s.casecmp(identifier).zero? || entry.id.to_s.casecmp(identifier).zero? || entry.storage_id.to_s.casecmp(identifier).zero?
      end
      raise ToolError, "Program not found: #{identifier}" if matches.empty?
      raise ToolError, "Program identifier is ambiguous: #{identifier}" if matches.size > 1
      matches[0]
    end

    def entry_hash(entry, include_error = false)
      value = {
        "entry" => entry.realpath.to_s,
        "id" => entry.id.to_s,
        "name" => entry.name.to_s,
        "description" => entry_value(entry, :description).to_s,
        "raw_name" => entry_value(entry, :raw_name).to_s,
        "raw_description" => entry_value(entry, :raw_description).to_s,
        "name_languages" => Array(entry_value(entry, :name_languages)).map(&:to_s),
        "description_languages" => Array(entry_value(entry, :description_languages)).map(&:to_s),
        "main_language" => entry_value(entry, :main_language).to_s,
        "supported_languages" => Array(entry_value(entry, :supported_languages)).map(&:to_s),
        "version" => entry.version.to_s,
        "build_id" => entry.build_id,
        "author" => entry.author.to_s,
        "status" => entry.status.to_s,
        "loaded" => entry.loaded == true,
        "install_type" => entry_value(entry, :install_type).to_s,
        "installation_source" => entry_value(entry, :installation_source).to_s,
        "signature_verified" => entry_value(entry, :signature_info) != nil,
        "source_type" => entry.source_type.to_s,
        "main" => entry.main.to_s,
        "elten_api_version" => entry.elten_api_version.to_s,
        "platforms" => Array(entry.platforms),
        "size" => entry.size.to_i
      }
      value["error"] = safe_entry_error(entry.error) if include_error
      value
    end

    def entry_value(entry, name)
      entry.respond_to?(name) ? entry.public_send(name) : nil
    end

    def safe_entry_error(error)
      text = error.to_s
      apps_root = Dirs.apps.to_s
      text = text.gsub(apps_root, "[apps]") if apps_root != ""
      text
    end

    def normalize_relative(path)
      path.to_s.tr("\\", "/").sub(/\A\.\//, "")
    end

    def resolve_path(root, path, may_not_exist: false, allow_root: false)
      relative = normalize_relative(path)
      raise InvalidParamsError, "Path is required" if relative == "" && !allow_root
      parts = relative.split("/")
      unsafe = relative.start_with?("/") || relative.include?("\0") || relative.match?(/\A[A-Za-z]:/) || parts.any? { |part| part == ".." || part == "." || part == "" }
      raise InvalidParamsError, "Unsafe program path: #{path}" if unsafe && !(allow_root && relative == "")
      candidate = File.expand_path(File.join(root, *parts))
      root_key = path_key(File.expand_path(root))
      candidate_key = path_key(candidate)
      raise InvalidParamsError, "Path escapes the program directory" if candidate_key != root_key && !candidate_key.start_with?(root_key + "/")
      check_symlinks(root, candidate, may_not_exist)
      candidate
    end

    def path_key(path)
      key = path.to_s.tr("\\", "/")
      RUBY_PLATFORM.match?(/mswin|mingw|cygwin/i) ? key.downcase : key
    end

    def check_symlinks(root, candidate, may_not_exist)
      current = root
      root_key = path_key(File.realpath(root))
      relative_path(candidate, root).split("/").each do |part|
        current = File.join(current, part)
        break if may_not_exist && !File.exist?(current)
        raise ToolError, "Symbolic links are not allowed in MCP program paths" if File.symlink?(current)
        resolved = path_key(File.realpath(current))
        if resolved != root_key && !resolved.start_with?(root_key + "/")
          raise ToolError, "Program path resolves outside the program directory"
        end
      end
    end

    def relative_path(path, root)
      expanded = File.expand_path(path).tr("\\", "/")
      root_expanded = File.expand_path(root).tr("\\", "/")
      expanded == root_expanded ? "" : expanded.byteslice(root_expanded.bytesize + 1..-1).to_s
    end

    def verify_base_hash(file, expected)
      return if expected.to_s == ""
      actual = File.file?(file) ? Digest::SHA256.file(file).hexdigest : Digest::SHA256.hexdigest("")
      raise ToolError.new("File changed since it was read", :data => { "current_sha256" => actual }) if actual != expected.to_s.downcase
    end

    def atomic_write(file, data)
      temporary = "#{file}.mcp_tmp_#{SecureRandom.hex(6)}"
      File.binwrite(temporary, data)
      File.rename(temporary, file)
    rescue Errno::EEXIST, Errno::EACCES
      File.delete(file) if File.file?(file)
      File.rename(temporary, file)
    ensure
      File.delete(temporary) if defined?(temporary) && File.file?(temporary)
    end

    def backup(entry, root, path)
      return if !File.exist?(path)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ") + "_#{SecureRandom.hex(3)}"
      target_root = data_path(File.join("backups", stamp, entry.gsub(/[^a-zA-Z0-9_.-]/, "_")))
      target = File.join(target_root, relative_path(path, root))
      FileUtils.mkdir_p(File.dirname(target))
      File.directory?(path) ? FileUtils.cp_r(path, target) : FileUtils.cp(path, target)
    end

    def audit(action, program, path, bytes)
      record = { "time" => Time.now.utc.iso8601(6), "action" => action, "program" => program, "path" => path, "bytes" => bytes.to_i }
      File.open(data_path("audit.jsonl"), "ab") { |file| file.write(JSON.generate(record) + "\n") }
    rescue Exception => e
      Log.warning("Cannot write MCP audit record: #{e.class}: #{e.message}") if defined?(Log)
    end

  end
end
