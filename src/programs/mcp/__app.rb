=begin Elten3AppInfo
{
  "id": "bf4dbbd4-cadc-4ab2-8738-7340677de1e2",
  "name": "MCP",
  "version": "1.1.2",
  "build_id": 20260908001,
  "EltenAPIVersion": "3.0.3",
  "EltenLinkContractVersion": "3.0",
  "author": "Dawid Pieper",
  "main_language": "en",
  "supported_languages": ["en"],
  "main_class": "ProgramMCP",
  "platforms": ["windows", "osx", "linux"],
  "menu": {
    "hidden": true
  },
  "localized_names": { "en": "Klangten MCP Server" },
  "localized_descriptions": { "en": "A local Model Context Protocol server that gives compatible AI tools controlled access to Klangten." },
  "description": "Local Model Context Protocol server for Klangten"
}
=end Elten3AppInfo
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded as Klangten MCP; calendar/task domain removed.

require_relative "lib/mcp/errors"
require_relative "lib/mcp/client_config_installer"
require_relative "lib/mcp/bridge"
require_relative "lib/mcp/config"
require_relative "lib/mcp/request_queue"
require_relative "lib/mcp/selective_permissions"
require_relative "lib/mcp/authorization"
require_relative "lib/mcp/http_server"
require_relative "lib/mcp/tool_registry"
require_relative "lib/mcp/domain_contracts"
require_relative "lib/mcp/known_data"
require_relative "lib/mcp/human_data"
require_relative "lib/mcp/domain_account"
require_relative "lib/mcp/domain_forum"
require_relative "lib/mcp/domain_communication"
require_relative "lib/mcp/domain_social"
require_relative "lib/mcp/domain_organizer"
require_relative "lib/mcp/domain_settings"
require_relative "lib/mcp/domain_tools"
require_relative "lib/mcp/program_workspace"
require_relative "lib/mcp/package_builder"
require_relative "lib/mcp/program_installer"
require_relative "lib/mcp/source_catalog"
require_relative "lib/mcp/programming_guide"
require_relative "lib/mcp/api_overview"
require_relative "lib/mcp/documentation"
require_relative "lib/mcp/tool_catalog"
require_relative "lib/mcp/resource_catalog"
require_relative "lib/mcp/dispatcher"
require_relative "lib/mcp/runtime"
require_relative "lib/mcp/settings"
require_relative "lib/mcp/__mcp"

class ProgramMCP < Program
  def self.activate
    EltenMCP.bind(self)
    extension(:mcp) do |service|
      service.start { EltenMCP.start }
      service.tick(:interval => 0) { EltenMCP.tick }
      service.settings { |settings| EltenMCP.add_settings(settings) }
      service.stop { |reason| EltenMCP.shutdown(reason) }
    end
  end
end
