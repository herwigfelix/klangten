# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  class Runtime
    CONFIG_INTERVAL = 1.0
    MAX_REQUESTS_PER_TICK = 2
    QUICK_REQUEST_TIMEOUTS = {
      "klangten_network_info" => 35.0,
      "klangten_sources_info" => 5.0
    }.freeze

    attr_reader :authorization, :config

    def initialize(storage)
      @bridge = Bridge.new
      @config = Config.new(storage)
      @authorization = Authorization.new(@bridge, @config, proc { current_session_identity })
      @queue = RequestQueue.new
      workspace = ProgramWorkspace.new(storage)
      source_catalog = SourceCatalog.new
      registry = ToolRegistry.new
      ToolCatalog.new(registry, @bridge, workspace, @authorization, source_catalog).register_all
      @dispatcher = Dispatcher.new(@authorization, registry, ResourceCatalog.new(registry, @bridge), PromptCatalog.new, source_catalog)
      @worker_queue = Queue.new
      @worker_thread = Thread.new { worker_loop }
      @worker_thread.name = "klangten_mcp_worker" if @worker_thread.respond_to?(:name=)
      @server = nil
      @accepting_requests = false
      @ticking = false
      @stopping = false
      @next_config_check = 0.0
      @next_start_attempt = 0.0
      @last_error = nil
      @session_identity = current_session_identity
    end

    def tick
      return if @ticking || @stopping
      @ticking = true
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      refresh_session_identity
      refresh_server(now) if now >= @next_config_check
      MAX_REQUESTS_PER_TICK.times do
        request = @queue.pop
        break if request == nil
        next if request.cancelled?
        dispatched = @dispatcher.dispatch(request.payload, request.protocol_version, request.context)
        if dispatched.is_a?(DeferredDispatch)
          @worker_queue << [request, dispatched]
        else
          request.complete(dispatched)
        end
      rescue Exception => e
        Log.error("MCP queued request failed: #{e.class}: #{e.message}") if defined?(Log)
        id = request.payload.is_a?(Hash) ? request.payload["id"] : nil
        request.complete({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32603, "message" => "Internal MCP server error" } })
      end
    ensure
      @ticking = false
    end

    def submit(payload, protocol_version, context = {})
      if @stopping || !@accepting_requests
        raise Error.new("MCP server is stopping", :code => -32005, :http_status => 503)
      end
      @queue.submit(payload, protocol_version, context, :timeout => request_timeout(payload))
    end

    def shutdown(_reason = :unload)
      @stopping = true
      stop_server
      revoke_security_state
      @worker_queue << nil
      @worker_thread.join(1) rescue nil
      true
    end

    def revoke_permissions
      revoke_security_state(:forget => true)
    end

    def permission_clients
      @authorization.permission_clients
    end

    def manage_permissions(client_id = nil)
      @authorization.manage(client_id)
    end

    def configure_permission_memory(enabled)
      @authorization.configure_permission_memory(enabled)
    end

    def rotate_client_key
      key = @config.rotate_client_key
      revoke_security_state
      key
    end

    def status
      network = @config.network_configuration
      {
        "enabled" => @config.enabled?,
        "listening" => @server != nil,
        "host" => network["bind_address"],
        "port" => @config.port,
        "allowed_subnets" => network["allowed_subnets"],
        "loopback_only" => network["loopback_only"],
        "remember_permissions" => @config.remember_permissions?,
        "default_permissions" => @config.default_permissions,
        "developer_mode" => @bridge.developer_mode?,
        "authorization" => @authorization.summary,
        "last_error" => @last_error.to_s
      }
    end

    private

    def request_timeout(payload)
      return 300.0 if !payload.is_a?(Hash) || payload["method"] != "tools/call"
      params = payload["params"]
      return 300.0 if !params.is_a?(Hash)
      QUICK_REQUEST_TIMEOUTS.fetch(params["name"].to_s, 300.0)
    end

    def worker_loop
      loop do
        item = @worker_queue.pop
        break if item == nil
        request, deferred = item
        next if request.cancelled?
        request.complete(deferred.callable.call)
      rescue Exception => e
        Log.error("MCP worker request failed: #{e.class}: #{e.message}") if defined?(Log)
        if defined?(request) && request != nil
          id = request.payload.is_a?(Hash) ? request.payload["id"] : nil
          request.complete({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32603, "message" => "Internal MCP server error" } })
        end
      end
    end

    def revoke_security_state(forget: false)
      @authorization.revoke_all(:forget => forget)
      @dispatcher.clear_sessions
      true
    end

    def refresh_server(now)
      @next_config_check = now + CONFIG_INTERVAL
      enabled = @config.enabled?
      port = @config.port
      network = @config.network_configuration
      if !enabled
        if @server != nil
          stop_server
          revoke_security_state
        end
        return
      end
      if @server != nil && (@server.port != port || @server.bind_address != network["bind_address"] || @server.allowed_subnets != network["allowed_subnets"])
        stop_server
        revoke_security_state
      end
      return if @server != nil || now < @next_start_attempt
      start_server(network, port, now)
    end

    def refresh_session_identity
      identity = current_session_identity
      if identity != @session_identity
        revoke_security_state
        @session_identity = identity
        Log.info("MCP permissions revoked after Klangten session identity changed") if defined?(Log)
      end
    end

    def current_session_identity
      return nil if !defined?(Session) || !Session.logged?
      Session.name.to_s
    rescue Exception
      nil
    end

    def start_server(network, port, now)
      bind_address = network["bind_address"]
      allowed_subnets = network["allowed_subnets"]
      server = HttpServer.new(bind_address, port, allowed_subnets, proc { @config.client_key }) { |payload, version, context| submit(payload, version, context) }
      @accepting_requests = true
      server.start
      @server = server
      @last_error = nil
      Log.info("MCP server listening on #{bind_address}:#{port}; accepted subnets: #{allowed_subnets.join(", ")}") if defined?(Log)
    rescue Exception => e
      @accepting_requests = false
      server.stop rescue nil if defined?(server) && server != nil
      @last_error = "#{e.class}: #{e.message}"
      @next_start_attempt = now + 5.0
      Log.error("Cannot start MCP server on #{bind_address}:#{port}: #{@last_error}") if defined?(Log)
    end

    def stop_server
      server = @server
      @server = nil
      @accepting_requests = false
      @queue.drain do |request|
        id = request.payload.is_a?(Hash) ? request.payload["id"] : nil
        request.complete({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32005, "message" => "MCP server stopped" } })
      end
      loop do
        item = @worker_queue.pop(true)
        break if item == nil
        request = item[0]
        id = request.payload.is_a?(Hash) ? request.payload["id"] : nil
        request.complete({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32005, "message" => "MCP server stopped" } })
      rescue ThreadError
        break
      end
      server.stop if server != nil
      Log.info("MCP server stopped") if defined?(Log) && server != nil
    end
  end
end
