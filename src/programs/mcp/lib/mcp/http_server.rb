# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

require "base64"
require "ipaddr"
require "json"
require "securerandom"
require "socket"
require "timeout"
require "uri"

module EltenMCP
  class HttpServer
    MAX_HEADER_BYTES = 65_536
    MAX_BODY_BYTES = 12 * 1024 * 1024
    MAX_CONNECTIONS = 8

    attr_reader :allowed_subnets, :bind_address, :port

    def initialize(bind_address, port, allowed_subnets, key_provider, &handler)
      @bind_address = IPAddr.new(bind_address.to_s).to_s
      @port = port
      @allowed_subnets = Array(allowed_subnets).map { |entry| canonical_network(entry) }.freeze
      raise ArgumentError, "At least one accepted MCP subnet is required" if @allowed_subnets.empty?
      @allowed_networks = @allowed_subnets.map { |entry| IPAddr.new(entry) }.freeze
      @bind_ip = IPAddr.new(@bind_address)
      @key_provider = key_provider
      @handler = handler
      @mutex = Mutex.new
      @connections = []
      @stopping = false
    end

    def start
      @tcp_server = TCPServer.new(@bind_address, @port)
      @thread = Thread.new { accept_loop }
      @thread.name = "klangten_mcp_http" if @thread.respond_to?(:name=)
      true
    end

    def stop
      @stopping = true
      @tcp_server.close rescue nil
      @thread.join(1) rescue nil
      connections = @mutex.synchronize { @connections.dup }
      connections.each { |thread| thread.join(0.05) rescue nil }
      true
    end

    private

    def accept_loop
      while !@stopping
        socket = @tcp_server.accept
        if connection_count >= MAX_CONNECTIONS
          write_http(socket, 503, json_error(nil, -32004, "Too many MCP connections"))
          socket.close rescue nil
          next
        end
        thread = Thread.new(socket) { |client| handle_connection(client) }
        thread.name = "klangten_mcp_connection" if thread.respond_to?(:name=)
        @mutex.synchronize { @connections << thread }
      end
    rescue IOError, Errno::EBADF
    rescue Exception => e
      Log.error("MCP accept loop failed: #{e.class}: #{e.message}") if defined?(Log) && !@stopping
    end

    def connection_count
      @mutex.synchronize do
        @connections.delete_if { |thread| !thread.alive? }
        @connections.size
      end
    end

    def handle_connection(socket)
      peer_address = validate_peer!(socket)
      request = Timeout.timeout(10) { read_request(socket) }
      validate_request!(request)
      if request[:method] == "OPTIONS"
        write_http(socket, 204, nil)
        return
      end
      if request[:method] != "POST"
        write_http(socket, 405, json_error(nil, -32600, "Only POST is supported"), { "Allow" => "POST, OPTIONS" })
        return
      end
      payload = JSON.parse(request[:body])
      raise InvalidRequestError, "JSON-RPC batches are not supported" if payload.is_a?(Array)
      validate_protocol_headers!(request, payload)
      session_id = request[:headers]["mcp-session-id"].to_s.downcase
      if session_id != "" && !session_id.match?(/\A[0-9a-f]{64}\z/)
        raise AuthorizationError, "Invalid MCP session identifier"
      end
      initializing = payload.is_a?(Hash) && payload["method"] == "initialize"
      new_session_id = initializing ? SecureRandom.hex(32) : nil
      context = { :session_id => session_id, :new_session_id => new_session_id, :remote_address => peer_address }.freeze
      result = @handler.call(payload, request[:headers]["mcp-protocol-version"], context)
      if !payload.is_a?(Hash) || !payload.key?("id")
        write_http(socket, 202, nil)
      else
        status = request[:headers]["mcp-protocol-version"] == Dispatcher::CURRENT_PROTOCOL_VERSION && result.dig("error", "code") == -32601 ? 404 : 200
        response_headers = {}
        response_headers["Mcp-Session-Id"] = new_session_id if initializing && !result.key?("error")
        write_http(socket, status, JSON.generate(result), response_headers)
      end
    rescue JSON::ParserError => e
      write_http(socket, 400, json_error(nil, -32700, "Parse error", { "message" => e.message }))
    rescue Timeout::Error
      write_http(socket, 408, json_error(nil, -32006, "HTTP request timed out"))
    rescue EltenMCP::Error => e
      id = defined?(payload) && payload.is_a?(Hash) ? payload["id"] : nil
      write_http(socket, e.http_status, json_error(id, e.code, e.message, e.data))
    rescue Exception => e
      Log.error("MCP HTTP request failed: #{e.class}: #{e.message}") if defined?(Log)
      id = defined?(payload) && payload.is_a?(Hash) ? payload["id"] : nil
      write_http(socket, 500, json_error(id, -32603, "Internal MCP server error"))
    ensure
      socket.close rescue nil
      @mutex.synchronize { @connections.delete(Thread.current) }
    end

    def read_request(socket)
      data = +"".b
      header_end = nil
      while header_end == nil
        chunk = socket.readpartial(4096)
        data << chunk
        raise InvalidRequestError, "HTTP headers are too large" if data.bytesize > MAX_HEADER_BYTES
        header_end = data.index("\r\n\r\n")
      end
      header_data = data.byteslice(0, header_end)
      remainder = data.byteslice(header_end + 4..-1).to_s.b
      lines = header_data.split("\r\n")
      request_line = lines.shift.to_s.split(" ")
      raise InvalidRequestError, "Malformed HTTP request line" if request_line.size != 3
      headers = {}
      lines.each do |line|
        name, value = line.split(":", 2)
        raise InvalidRequestError, "Malformed HTTP header" if value == nil
        headers[name.to_s.downcase.strip] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      length = 0 if request_line[0] == "OPTIONS"
      raise InvalidRequestError, "Content-Length is required" if request_line[0] == "POST" && !headers.key?("content-length")
      raise InvalidRequestError, "Transfer-Encoding is not supported" if headers.key?("transfer-encoding")
      raise InvalidRequestError, "Request body is too large" if length < 0 || length > MAX_BODY_BYTES
      body = remainder
      while body.bytesize < length
        chunk = socket.read(length - body.bytesize)
        break if chunk == nil || chunk == ""
        body << chunk
      end
      raise InvalidRequestError, "Incomplete request body" if body.bytesize < length
      {
        :method => request_line[0].upcase,
        :target => request_line[1],
        :version => request_line[2],
        :headers => headers,
        :body => body.byteslice(0, length).to_s
      }
    rescue EOFError
      raise InvalidRequestError, "Incomplete HTTP request"
    end

    def validate_request!(request)
      path = request[:target].to_s.split("?", 2)[0]
      raise InvalidRequestError, "Unknown MCP endpoint" if path != "/mcp"
      host = parse_host_header(request[:headers]["host"])
      raise AuthorizationError, "Invalid Host header" if !host_allowed?(host)
      validate_origin!(request[:headers]["origin"])
      auth = request[:headers]["authorization"].to_s
      scheme, candidate, extra = auth.split(" ", 3)
      valid_candidate = extra == nil && scheme.to_s.casecmp("Bearer").zero? && candidate.to_s.bytesize == 64
      valid_candidate &&= candidate.to_s.delete("0123456789abcdefABCDEF") == ""
      supplied = valid_candidate ? candidate.downcase : ""
      raise AuthorizationError, "Invalid MCP client key" if !secure_compare(supplied, @key_provider.call.to_s)
      content_type = request[:headers]["content-type"].to_s.downcase
      if request[:method] == "POST" && !content_type.start_with?("application/json")
        raise InvalidRequestError, "Content-Type must be application/json"
      end
    end

    def validate_protocol_headers!(request, payload)
      return if request[:method] != "POST"
      version = request[:headers]["mcp-protocol-version"].to_s
      params = payload.is_a?(Hash) && payload["params"].is_a?(Hash) ? payload["params"] : {}
      meta = params["_meta"].is_a?(Hash) ? params["_meta"] : {}
      body_version = meta["io.modelcontextprotocol/protocolVersion"].to_s
      if version == ""
        if body_version == Dispatcher::CURRENT_PROTOCOL_VERSION
          raise HeaderMismatchError, "MCP-Protocol-Version header is required for current MCP requests"
        end
        if body_version != "" && !Dispatcher::SUPPORTED_PROTOCOL_VERSIONS.include?(body_version)
          raise UnsupportedProtocolVersionError.new(body_version, Dispatcher::SUPPORTED_PROTOCOL_VERSIONS)
        end
        return
      end
      supported = Dispatcher::SUPPORTED_PROTOCOL_VERSIONS
      raise UnsupportedProtocolVersionError.new(version, supported) if !supported.include?(version)
      if version != Dispatcher::CURRENT_PROTOCOL_VERSION
        raise HeaderMismatchError, "MCP-Protocol-Version does not match request _meta" if body_version != "" && body_version != version
        return
      end
      raise HeaderMismatchError, "MCP request body must be a JSON-RPC object" if !payload.is_a?(Hash)
      raise HeaderMismatchError, "MCP-Protocol-Version does not match request _meta" if body_version != version
      method = payload["method"].to_s
      header_method = request[:headers]["mcp-method"].to_s
      raise HeaderMismatchError, "Mcp-Method is missing or does not match the request method" if header_method == "" || header_method != method
      name_key = method == "resources/read" ? "uri" : "name"
      if ["tools/call", "resources/read", "prompts/get"].include?(method)
        header_name = decode_header_value(request[:headers]["mcp-name"].to_s)
        body_name = params[name_key].to_s
        raise HeaderMismatchError, "Mcp-Name is missing or does not match the request body" if header_name == "" || header_name != body_name
      end
      capabilities = meta["io.modelcontextprotocol/clientCapabilities"]
      if !capabilities.is_a?(Hash)
        raise Error.new("Current MCP requests require clientCapabilities in _meta", :code => -32602, :http_status => 400)
      end
    end

    def decode_header_value(value)
      if value.start_with?("=?base64?") && value.end_with?("?=")
        encoded = value.byteslice(9...-2).to_s
        decoded = Base64.strict_decode64(encoded).force_encoding(Encoding::UTF_8)
        raise HeaderMismatchError, "Invalid base64 MCP header value" if !decoded.valid_encoding?
        decoded
      else
        raise HeaderMismatchError, "Invalid MCP header value" if !value.ascii_only? || value.match?(/[\x00-\x1f\x7f]/)
        value
      end
    rescue ArgumentError
      raise HeaderMismatchError, "Invalid base64 MCP header value"
    end

    def validate_origin!(origin)
      return if origin.to_s == ""
      uri = URI.parse(origin)
      allowed = ["http", "https"].include?(uri.scheme.to_s.downcase)
      allowed &&= host_allowed?(uri.host.to_s)
      allowed &&= uri.port == @port
      allowed &&= uri.userinfo == nil && uri.query == nil && uri.fragment == nil
      allowed &&= uri.path.to_s == "" || uri.path.to_s == "/"
      raise AuthorizationError, "Cross-origin MCP requests are not allowed" if !allowed
    rescue URI::InvalidURIError
      raise AuthorizationError, "Invalid Origin header"
    end

    def validate_peer!(socket)
      raw = socket.peeraddr(false)[3].to_s
      address = normalized_ip(raw)
      allowed = @allowed_networks.any? { |network| same_family?(network, address) && network.include?(address) }
      raise AuthorizationError, "MCP connection is outside the configured accepted subnets" if !allowed
      address.to_s
    rescue SocketError, SystemCallError, IPAddr::InvalidAddressError
      raise AuthorizationError, "Cannot verify MCP peer address"
    end

    def parse_host_header(value)
      text = value.to_s.strip
      raise AuthorizationError, "Host header is required" if text == "" || text.include?(",")
      uri = URI.parse("http://#{text}")
      raise AuthorizationError, "Invalid Host header" if uri.host.to_s == "" || uri.userinfo != nil || uri.path.to_s != "" || uri.query != nil || uri.fragment != nil
      uri.host.to_s
    rescue URI::InvalidURIError
      raise AuthorizationError, "Invalid Host header"
    end

    def host_allowed?(host)
      value = host.to_s.downcase
      if value == "localhost"
        return @allowed_networks.any? { |network| loopback_network?(network) }
      end
      address = normalized_ip(value)
      return true if address == @bind_ip
      unspecified?(@bind_ip) && same_family?(@bind_ip, address)
    rescue IPAddr::InvalidAddressError
      false
    end

    def normalized_ip(value)
      address = IPAddr.new(value.to_s)
      if address.ipv6? && address.respond_to?(:ipv4_mapped?) && address.ipv4_mapped?
        address = address.native
      end
      address
    end

    def same_family?(left, right)
      (left.ipv4? && right.ipv4?) || (left.ipv6? && right.ipv6?)
    end

    def unspecified?(address)
      address.to_i == 0
    end

    def loopback_network?(network)
      container = network.ipv4? ? IPAddr.new("127.0.0.0/8") : IPAddr.new("::1/128")
      container.include?(network.to_range.begin) && container.include?(network.to_range.end)
    end

    def canonical_network(value)
      network = IPAddr.new(value.to_s)
      "#{network}/#{network.prefix}"
    end

    def secure_compare(left, right)
      return false if left.bytesize != right.bytesize || left.bytesize == 0
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
      difference == 0
    end

    def json_error(id, code, message, data = nil)
      error = { "code" => code, "message" => message.to_s }
      error["data"] = data if data != nil
      JSON.generate({ "jsonrpc" => "2.0", "id" => id, "error" => error })
    end

    def write_http(socket, status, body, extra_headers = {})
      reason = {
        200 => "OK", 202 => "Accepted", 204 => "No Content", 400 => "Bad Request", 408 => "Request Timeout",
        403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 500 => "Internal Server Error",
        503 => "Service Unavailable", 504 => "Gateway Timeout"
      }[status] || "Error"
      body = body.to_s
      headers = {
        "Content-Type" => "application/json; charset=utf-8",
        "Content-Length" => body.bytesize.to_s,
        "Connection" => "close",
        "Cache-Control" => "no-store",
        "X-Content-Type-Options" => "nosniff"
      }.merge(extra_headers)
      response = +"HTTP/1.1 #{status} #{reason}\r\n"
      headers.each { |name, value| response << "#{name}: #{value}\r\n" }
      response << "\r\n"
      response << body
      socket.write(response)
    rescue IOError, SystemCallError
    end
  end
end
