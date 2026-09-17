require "fileutils"
require "securerandom"

module FileManagerPlaylist
  PLAYLIST_EXTENSIONS = %w[.m3u .m3u8 .pls].freeze

  class FormatError < StandardError
  end

  class Entry
    attr_accessor :location, :title, :length

    def initialize(location, title: nil, length: nil)
      @location = location.to_s
      @title = title.to_s
      @title = nil if @title == ""
      @length = normalize_length(length)
    end

    def label
      return @title if @title != nil && @title != ""
      value = @location.to_s.sub(/[?#].*\z/, "")
      name = File.basename(value.tr("\\", "/"))
      name == "" ? @location.to_s : name
    end

    def to_h
      data = { "location" => @location.to_s }
      data["title"] = @title if @title != nil && @title != ""
      data["length"] = @length if @length != nil
      data
    end

    def self.from_h(data)
      return nil if !data.is_a?(Hash) || data["location"].to_s.strip == ""
      new(data["location"], title: data["title"], length: data["length"])
    end

    private

    def normalize_length(value)
      return nil if value == nil || value.to_s.strip == ""
      number = Integer(value) rescue nil
      number != nil && number >= -1 ? number : nil
    end
  end

  class Playlist
    attr_accessor :id, :name, :entries, :source_path, :format

    def initialize(name: "", entries: [], id: nil, source_path: nil, format: nil)
      @id = id.to_s
      @id = SecureRandom.uuid if @id == ""
      @name = name.to_s
      @entries = Array(entries).map do |entry|
        entry.is_a?(Entry) ? entry : Entry.from_h(entry)
      end.compact
      @source_path = source_path.to_s
      @source_path = nil if @source_path == ""
      @format = format == nil ? nil : format.to_sym
    end

    def empty?
      @entries.empty?
    end

    def to_h
      data = {
        "id" => @id,
        "name" => @name,
        "entries" => @entries.map(&:to_h)
      }
      data["source_path"] = @source_path if @source_path != nil
      data["format"] = @format.to_s if @format != nil
      data
    end

    def copy(new_id: false)
      self.class.from_h(to_h.merge("id" => (new_id ? SecureRandom.uuid : @id)))
    end

    def self.from_h(data)
      return nil if !data.is_a?(Hash)
      new(
        id: data["id"], name: data["name"], entries: data["entries"],
        source_path: data["source_path"], format: data["format"]
      )
    end
  end

  module Formats
    module_function

    def load(path)
      source = File.binread(path)
      format = format_for(path, source)
      playlist = format == :pls ? parse_pls(source, path: path) : parse_m3u(source, path: path)
      playlist.source_path = File.expand_path(path)
      playlist.format = format
      playlist.name = File.basename(path, File.extname(path)) if playlist.name.to_s == ""
      playlist
    rescue Errno::ENOENT, Errno::EACCES => e
      raise FormatError, e.message
    end

    def save(playlist, path, format: nil)
      format ||= format_for(path)
      content = format == :pls ? dump_pls(playlist, path: path) : dump_m3u(playlist, path: path)
      atomic_write(path, content)
      playlist.source_path = File.expand_path(path)
      playlist.format = format
      path
    end

    def parse_m3u(data, path: nil)
      text = decode_text(data)
      entries = []
      pending_title = nil
      pending_length = nil
      text.each_line do |line|
        value = line.delete_suffix("\n").delete_suffix("\r").strip
        next if value == ""
        if value =~ /\A#EXTINF\s*:\s*([^,]*)(?:,(.*))?\z/i
          pending_length = parse_extinf_length($1)
          pending_title = $2.to_s.strip
          pending_title = nil if pending_title == ""
        elsif value.start_with?("#")
          next
        else
          entries << Entry.new(resolve_location(value, path), title: pending_title, length: pending_length)
          pending_title = nil
          pending_length = nil
        end
      end
      Playlist.new(name: playlist_name(path), entries: entries, source_path: expanded_path(path), format: :m3u)
    end

    def parse_pls(data, path: nil)
      text = decode_text(data)
      values = {}
      section_seen = false
      has_sections = text.match?(/\[[^\]]+\]/)
      text.each_line do |line|
        value = line.delete_suffix("\n").delete_suffix("\r").strip
        next if value == "" || value.start_with?(";", "#")
        if value =~ /\A\[([^\]]+)\]\z/
          section_seen = $1.to_s.strip.casecmp?("playlist")
          next
        end
        next if value !~ /\A([^=]+?)\s*=\s*(.*)\z/
        key = $1.to_s.strip.downcase
        values[key] = $2.to_s.strip if section_seen || !has_sections
      end
      indices = values.keys.filter_map do |key|
        match = /\Afile(\d+)\z/i.match(key)
        match && match[1].to_i
      end.uniq.sort
      entries = indices.filter_map do |index|
        location = values["file#{index}"]
        next if location.to_s == ""
        Entry.new(resolve_location(location, path), title: values["title#{index}"], length: values["length#{index}"])
      end
      Playlist.new(name: playlist_name(path), entries: entries, source_path: expanded_path(path), format: :pls)
    end

    def dump_m3u(playlist, path: nil)
      lines = ["#EXTM3U"]
      playlist.entries.each do |entry|
        if entry.title != nil || entry.length != nil
          length = entry.length == nil ? -1 : entry.length
          lines << "#EXTINF:#{length},#{entry.title}"
        end
        lines << stored_location(entry.location, path)
      end
      lines.join("\r\n") + "\r\n"
    end

    def dump_pls(playlist, path: nil)
      lines = ["[playlist]"]
      playlist.entries.each_with_index do |entry, offset|
        index = offset + 1
        lines << "File#{index}=#{stored_location(entry.location, path)}"
        lines << "Title#{index}=#{entry.title}" if entry.title != nil
        lines << "Length#{index}=#{entry.length}" if entry.length != nil
      end
      lines << "NumberOfEntries=#{playlist.entries.size}"
      lines << "Version=2"
      lines.join("\r\n") + "\r\n"
    end

    def format_for(path, content = nil)
      extension = File.extname(path.to_s).downcase
      return :pls if extension == ".pls"
      return :m3u if extension == ".m3u" || extension == ".m3u8"
      text = decode_text(content.to_s)
      text.lstrip =~ /\A\[playlist\]/i ? :pls : :m3u
    end

    def decode_text(data)
      source = data.to_s.b
      if source.start_with?("\xFF\xFE".b)
        source.byteslice(2..).to_s.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      elsif source.start_with?("\xFE\xFF".b)
        source.byteslice(2..).to_s.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      else
        source.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end

    def resolve_location(location, playlist_path)
      value = location.to_s.strip
      return value if value == "" || remote_location?(value) || absolute_location?(value) || playlist_path.to_s == ""
      File.expand_path(value.tr("/\\", File::SEPARATOR), File.dirname(File.expand_path(playlist_path)))
    end

    def stored_location(location, playlist_path)
      value = location.to_s
      return value if value == "" || remote_location?(value) || playlist_path.to_s == "" || !absolute_location?(value)
      base = File.dirname(File.expand_path(playlist_path))
      relative = relative_path(value, base)
      relative == nil ? value : relative.tr("\\", "/")
    end

    def remote_location?(value)
      text = value.to_s
      return false if text.match?(/\A[A-Za-z]:[\\\/]/)
      text.match?(/\A[a-z][a-z0-9+.-]*:/i)
    end

    def absolute_location?(value)
      text = value.to_s
      text.start_with?("/", "\\\\") || text.match?(/\A[A-Za-z]:[\\\/]/)
    end

    def relative_path(path, base)
      target = File.expand_path(path).tr("\\", "/")
      root = File.expand_path(base).tr("\\", "/").sub(/\/+\z/, "")
      target_drive = target[/\A[A-Za-z]:/].to_s.downcase
      root_drive = root[/\A[A-Za-z]:/].to_s.downcase
      return nil if target_drive != root_drive
      target_parts = target.sub(/\A[A-Za-z]:/, "").split("/").reject(&:empty?)
      root_parts = root.sub(/\A[A-Za-z]:/, "").split("/").reject(&:empty?)
      common = 0
      limit = [target_parts.size, root_parts.size].min
      while common < limit && target_parts[common].casecmp?(root_parts[common])
        common += 1
      end
      (([".."] * (root_parts.size - common)) + target_parts[common..]).join("/")
    rescue StandardError
      nil
    end

    def parse_extinf_length(value)
      match = value.to_s.match(/\A\s*(-?\d+)/)
      match == nil ? nil : match[1].to_i
    end

    def playlist_name(path)
      path.to_s == "" ? "" : File.basename(path, File.extname(path))
    end

    def expanded_path(path)
      path.to_s == "" ? nil : File.expand_path(path)
    end

    def atomic_write(path, content)
      destination = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = destination + ".tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.binwrite(temporary, content.to_s.encode(Encoding::UTF_8))
      FileUtils.mv(temporary, destination, force: true)
    ensure
      File.delete(temporary) if temporary != nil && File.file?(temporary) rescue nil
    end
  end
end
