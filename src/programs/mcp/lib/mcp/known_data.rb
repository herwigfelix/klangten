# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3.

require "time"

module EltenMCP
  module KnownData
    # Only instances of this type may carry constructed objects across the
    # non-developer safety boundary. Model definitions and presenters live in
    # human_data.rb, which is the single source of truth for public fields.
    class ObjectValue < Hash
    end

    class << self
      def object(values = {})
        raise ToolError, "Internal MCP response must be an object" if !values.is_a?(Hash)
        values.each_with_object(ObjectValue.new) { |(key, value), result| result[key.to_s] = encode(value) }
      end

      def encode(value)
        case value
        when ObjectValue
          value.each_with_object(ObjectValue.new) { |(key, item), result| result[key.to_s] = encode(item) }
        when nil, true, false, Integer, Float then value
        when String then clean_string(value)
        when Symbol then value.to_s
        when Time then value.iso8601
        when Array then value.map { |item| encode(item) }
        when Hash then raise ToolError, "Raw JSON objects are not permitted in MCP domain responses"
        else raise ToolError, "Unmapped MCP response type: #{value.class.name}"
        end
      end

      private

      def clean_string(value)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        raise ToolError, "MCP response string is too large" if text.bytesize > 2_000_000
        text
      end
    end
  end
end
