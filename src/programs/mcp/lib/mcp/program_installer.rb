# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  # A narrow adapter around Klangten's canonical Programs installer. The
  # package format, staging, rollback, registry and activation logic continue
  # to belong to Klangten; MCP only supplies a validated local package path.
  class ProgramInstaller
    def initialize(workspace)
      @workspace = workspace
    end

    def install(path)
      file = File.expand_path(path.to_s)
      raise InvalidParamsError, "package_path is required" if path.to_s.strip == ""
      raise InvalidParamsError, "Only .eltsetup packages can be installed" if File.extname(file).downcase != ".eltsetup"
      raise ToolError, "Setup package not found" if !File.file?(file)

      info = Programs.setup_package_info(file)
      reject_current_program_update(info)
      manifest = info[:manifest]
      existing = Programs.local_entries.any? { |item| item.id.to_s.casecmp(manifest.id.to_s).zero? }
      entry = Programs.install_package(file, :info => info, :installation_source => "mcp")
      raise ToolError, "Klangten did not return an installed program entry" if entry.to_s == ""

      {
        "package_path" => file,
        "program" => @workspace.inspect_entry(entry, true),
        "installed" => true,
        "loaded" => true,
        "updated_existing_program" => existing
      }
    rescue ToolError, InvalidParamsError
      raise
    rescue StandardError => e
      raise ToolError, e.message
    end

    private

    def reject_current_program_update(info)
      runtime = Programs.current_runtime
      return if runtime == nil || !runtime.respond_to?(:manifest)
      manifest = info[:manifest]
      return if manifest == nil || runtime.manifest.id.to_s.casecmp(manifest.id.to_s) != 0

      raise ToolError, "The program serving this MCP request cannot install an update of itself. Build the package, then install it from Klangten's Programs screen after restarting without this MCP session."
    end
  end
end
