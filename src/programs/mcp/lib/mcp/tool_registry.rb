# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: klangten permission metadata; notes aspect.

module EltenMCP
  Tool = Struct.new(:name, :title, :description, :permission, :input_schema, :output_schema, :annotations, :execution, :handler, keyword_init: true) do
    def protocol_definition
      value = {
        "name" => name,
        "title" => title,
        "description" => description,
        "inputSchema" => input_schema || { "type" => "object", "additionalProperties" => false },
        "_meta" => {
          "klangten/permission" => {
            "aspect" => permission[:aspect].to_s,
            "level" => permission[:level].to_s,
            "developerOverride" => true
          }
        }
      }
      if [:forum, :messages].include?(permission[:aspect].to_sym) && permission[:level].to_sym == :scope
        value["_meta"]["klangten/permission"]["scopeDiscovery"] = true
        value["_meta"]["klangten/permission"]["selectiveSupported"] = false
        value["_meta"]["klangten/permission"]["generalGrantStillSupported"] = true
      elsif [:forum, :messages, :notes, :blogs].include?(permission[:aspect].to_sym)
        value["_meta"]["klangten/permission"]["selectiveSupported"] = true
        value["_meta"]["klangten/permission"]["generalGrantStillSupported"] = true
      end
      value["outputSchema"] = output_schema if output_schema != nil
      value["annotations"] = annotations if annotations != nil
      value
    end
  end

  class ToolRegistry
    def initialize
      @tools = {}
    end

    def register(name, title:, description:, permission: nil, input_schema: nil, output_schema: nil, annotations: nil, execution: :main, &handler)
      raise ArgumentError, "Invalid MCP tool name #{name}" if name.to_s !~ /^[a-z][a-z0-9_]*$/
      raise ArgumentError, "Invalid MCP tool execution context" if ![:main, :worker].include?(execution.to_sym)
      required = Authorization.requirement(permission || :basic)
      @tools[name.to_s] = Tool.new(
        :name => name.to_s, :title => title.to_s, :description => description.to_s,
        :permission => required, :input_schema => input_schema, :output_schema => output_schema,
        :annotations => annotations, :execution => execution.to_sym, :handler => handler
      )
    end

    def find(name)
      @tools[name.to_s]
    end

    def list(developer_mode: false)
      @tools.values.select { |tool| developer_mode || tool.permission[:aspect] != :developer }.map(&:protocol_definition)
    end

    def call(tool, arguments, context = nil)
      validate_arguments(tool, arguments)
      tool.handler.arity == 1 ? tool.handler.call(arguments) : tool.handler.call(arguments, context)
    end

    def validate_arguments(tool, arguments)
      raise InvalidParamsError, "Tool arguments must be an object" if !arguments.is_a?(Hash)
      validate_schema!(arguments, tool.input_schema || { "type" => "object" })
      true
    end

    private

    def validate_schema!(value, schema, path = "arguments")
      return true if !schema.is_a?(Hash)
      if schema["oneOf"].is_a?(Array)
        matches = schema["oneOf"].count do |candidate|
          begin
            validate_schema!(value, candidate, path)
            true
          rescue InvalidParamsError
            false
          end
        end
        raise InvalidParamsError, "#{path} does not match exactly one documented input variant" if matches != 1
        return true
      end
      expected = schema["type"]
      valid = case expected
      when nil then true
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value == nil
      else false
      end
      raise InvalidParamsError, "#{path} must be #{expected}" if !valid
      if schema["enum"].is_a?(Array) && !schema["enum"].include?(value)
        raise InvalidParamsError, "#{path} must be one of #{schema["enum"].join(", ")}"
      end
      if value.is_a?(String)
        length = value.each_char.count
        raise InvalidParamsError, "#{path} is too short" if schema["minLength"] != nil && length < schema["minLength"].to_i
        raise InvalidParamsError, "#{path} is too long" if schema["maxLength"] != nil && length > schema["maxLength"].to_i
        if schema["pattern"] != nil
          pattern = Regexp.new(schema["pattern"].to_s)
          raise InvalidParamsError, "#{path} has an invalid format" if !pattern.match?(value)
        end
      end
      if value.is_a?(Hash)
        required = Array(schema["required"])
        missing = required.reject { |name| value.key?(name) }
        raise InvalidParamsError, "Missing required #{path} fields: #{missing.join(", ")}" if !missing.empty?
        properties = schema["properties"].is_a?(Hash) ? schema["properties"] : {}
        if schema["additionalProperties"] == false
          unknown = value.keys.map(&:to_s) - properties.keys
          raise InvalidParamsError, "Unknown #{path} fields: #{unknown.join(", ")}" if !unknown.empty?
        end
        minimum = schema["minProperties"]
        maximum = schema["maxProperties"]
        raise InvalidParamsError, "#{path} has too few fields" if minimum != nil && value.size < minimum.to_i
        raise InvalidParamsError, "#{path} has too many fields" if maximum != nil && value.size > maximum.to_i
        value.each do |key, item|
          child = properties[key.to_s]
          validate_schema!(item, child, "#{path}.#{key}") if child != nil
        end
      elsif value.is_a?(Array)
        minimum = schema["minItems"]
        maximum = schema["maxItems"]
        raise InvalidParamsError, "#{path} has too few items" if minimum != nil && value.size < minimum.to_i
        raise InvalidParamsError, "#{path} has too many items" if maximum != nil && value.size > maximum.to_i
        raise InvalidParamsError, "#{path} must contain unique items" if schema["uniqueItems"] == true && value.uniq.size != value.size
        value.each_with_index { |item, index| validate_schema!(item, schema["items"], "#{path}[#{index}]") } if schema["items"].is_a?(Hash)
      elsif value.is_a?(Numeric)
        raise InvalidParamsError, "#{path} is below #{schema["minimum"]}" if schema["minimum"] != nil && value < schema["minimum"]
        raise InvalidParamsError, "#{path} is above #{schema["maximum"]}" if schema["maximum"] != nil && value > schema["maximum"]
      end
      true
    end
  end
end
