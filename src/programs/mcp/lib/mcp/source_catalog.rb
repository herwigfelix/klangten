# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded source category.

require "digest"

module EltenMCP
  class SourceCatalog
    MAX_SOURCE_BYTES = 4 * 1024 * 1024
    MAX_LIST_RESULTS = 1000
    MAX_READ_LINES = 1000

    def available?
      defined?(::EltenEmbedded) && EltenEmbedded.respond_to?(:read_rb) &&
        defined?($ELTEN_EMBEDDED_RB) && $ELTEN_EMBEDDED_RB.is_a?(Hash)
    end

    def info
      entries = source_entries
      {
        "available" => available?,
        "launched_by_launcher" => available?,
        "source_count" => entries.size,
        "categories" => entries.values.group_by { |entry| entry[:category] }.transform_values(&:size),
        "filesystem_access" => false
      }
    end

    def list(category: nil, prefix: nil, query: nil, limit: 200)
      require_available!
      maximum = Integer(limit)
      raise InvalidParamsError, "limit must be between 1 and #{MAX_LIST_RESULTS}" if maximum < 1 || maximum > MAX_LIST_RESULTS
      category = category.to_s if category != nil
      raise InvalidParamsError, "category must be klangten or bundled_library" if category != nil && !%w[klangten bundled_library].include?(category)
      normalized_prefix = prefix == nil || prefix.to_s == "" ? nil : normalize_request_path(prefix)
      needle = query.to_s.downcase
      values = source_entries.values.select do |entry|
        (category == nil || entry[:category] == category) &&
          (normalized_prefix == nil || entry[:path].start_with?(normalized_prefix)) &&
          (needle == "" || entry[:path].downcase.include?(needle))
      end.sort_by { |entry| entry[:path] }
      selected = values.first(maximum)
      {
        "available" => true,
        "sources" => selected.map { |entry| public_entry(entry) },
        "count" => selected.size,
        "total_matching" => values.size,
        "truncated" => values.size > selected.size
      }
    rescue ArgumentError, TypeError
      raise InvalidParamsError, "limit must be an integer"
    end

    def read(path, start_line: 1, line_count: 400)
      require_available!
      normalized = normalize_request_path(path)
      entry = source_entries[normalized]
      raise InvalidParamsError, "Unknown bundled Ruby source: #{normalized}" if entry == nil
      first = Integer(start_line)
      count = Integer(line_count)
      raise InvalidParamsError, "start_line must be positive" if first < 1
      raise InvalidParamsError, "line_count must be between 1 and #{MAX_READ_LINES}" if count < 1 || count > MAX_READ_LINES
      source = EltenEmbedded.read_rb(entry[:key])
      raise ToolError, "Bundled source is no longer available" if !source.is_a?(String)
      raise ToolError, "Bundled source exceeds the safe read limit" if source.bytesize > MAX_SOURCE_BYTES
      source = source.dup.force_encoding(Encoding::UTF_8)
      raise ToolError, "Bundled source is not valid UTF-8" if !source.valid_encoding?
      lines = source.lines
      selected = lines.slice(first - 1, count) || []
      {
        "available" => true,
        "path" => entry[:path],
        "category" => entry[:category],
        "start_line" => first,
        "end_line" => selected.empty? ? nil : first + selected.size - 1,
        "total_lines" => lines.size,
        "truncated" => first - 1 + selected.size < lines.size,
        "sha256" => Digest::SHA256.hexdigest(source.b),
        "text" => selected.join
      }
    rescue ArgumentError, TypeError
      raise InvalidParamsError, "start_line and line_count must be integers"
    end

    private

    def source_entries
      return {}.freeze if !available?
      map = $ELTEN_EMBEDDED_RB
      signature = [map.object_id, map.size]
      return @entries if @entries_signature == signature && @entries != nil
      entries = {}
      map.each do |key, raw|
        next if !raw.is_a?(Array) || raw.size < 3
        path = normalize_manifest_path(raw[0])
        next if path == nil || entries.key?(path)
        size = raw[2].is_a?(Integer) && raw[2] >= 0 ? raw[2] : nil
        next if size == nil || size > MAX_SOURCE_BYTES
        entries[path] = { :path => path, :key => key, :size => size, :category => source_category(path) }.freeze
      end
      @entries_signature = signature
      @entries = entries.freeze
    end

    def normalize_manifest_path(path)
      normalize_path(path, false)
    rescue InvalidParamsError
      nil
    end

    def normalize_request_path(path)
      normalize_path(path, true)
    end

    def normalize_path(path, strict)
      raise InvalidParamsError, "source path must be a string" if !path.is_a?(String)
      value = path.dup.force_encoding(Encoding::UTF_8)
      raise InvalidParamsError, "source path is not valid UTF-8" if !value.valid_encoding?
      value = value.tr("\\", "/")
      invalid = value.empty? || value.bytesize > 2048 || value.start_with?("/", "//") ||
        value.match?(/\A[A-Za-z]:/) || value.match?(/[\x00-\x1f\x7f]/)
      parts = value.split("/", -1)
      invalid ||= parts.any? { |part| part.empty? || part == "." || part == ".." || part.include?(":") }
      invalid ||= !value.downcase.end_with?(".rb")
      raise InvalidParamsError, "source path is outside the bundled-source allowlist" if invalid
      strict ? value : value
    end

    def source_category(path)
      normalized = path.downcase
      normalized == "elten.rb" || normalized.start_with?("src/") ? "klangten" : "bundled_library"
    end

    def public_entry(entry)
      { "path" => entry[:path], "category" => entry[:category], "size_bytes" => entry[:size] }
    end

    def require_available!
      raise ToolError, "Bundled Klangten sources are available only when Klangten was started by its launcher" if !available?
    end
  end
end
