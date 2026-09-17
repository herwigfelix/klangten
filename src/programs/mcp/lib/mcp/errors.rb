# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

module EltenMCP
  class Error < StandardError
    attr_reader :code, :data, :http_status

    def initialize(message, code: -32603, data: nil, http_status: 200)
      super(message.to_s)
      @code = code
      @data = data
      @http_status = http_status
    end
  end

  class InvalidRequestError < Error
    def initialize(message = "Invalid request", data: nil)
      super(message, code: -32600, data: data, http_status: 400)
    end
  end

  class InvalidParamsError < Error
    def initialize(message = "Invalid parameters", data: nil)
      super(message, code: -32602, data: data)
    end
  end

  class MethodNotFoundError < Error
    def initialize(method)
      super("Method not found: #{method}", code: -32601)
    end
  end

  class AuthorizationError < Error
    def initialize(message = "MCP access was not authorized", data: nil)
      super(message, code: -32001, data: data, http_status: 403)
    end
  end

  class ToolError < Error
    def initialize(message, data: nil)
      super(message, code: -32002, data: data)
    end
  end

  class HeaderMismatchError < Error
    def initialize(message)
      super(message, :code => -32020, :http_status => 400)
    end
  end

  class UnsupportedProtocolVersionError < Error
    def initialize(version, supported)
      super(
        "Unsupported MCP protocol version: #{version}",
        :code => -32022,
        :data => { "supportedVersions" => supported },
        :http_status => 400
      )
    end
  end
end
