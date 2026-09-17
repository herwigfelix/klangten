# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

require "time"

module EltenMCP
  class << self
    def bind(program_class)
      @program_class = program_class
      true
    end

    def start
      runtime
      true
    end

    def tick
      runtime.tick
    rescue Exception => e
      Log.error("MCP tick failed: #{e.class}: #{e.message}") if defined?(Log)
    end

    def shutdown(reason = :unload)
      @runtime.shutdown(reason) if @runtime != nil
    rescue Exception => e
      Log.error("MCP shutdown failed: #{e.class}: #{e.message}") if defined?(Log)
    ensure
      @runtime = nil
    end

    def add_settings(builder)
      Settings.new(runtime, Bridge.new).add_to(builder)
    end

    def revoke_permissions
      @runtime.revoke_permissions if @runtime != nil
      true
    end

    def status
      runtime.status
    end

    private

    def runtime
      raise Error, "MCP program is not bound to its Klangten runtime" if @program_class == nil
      @runtime ||= Runtime.new(@program_class)
    end
  end
end
