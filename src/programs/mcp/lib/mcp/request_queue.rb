# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  class PendingRequest
    attr_reader :payload, :protocol_version, :context

    def initialize(payload, protocol_version, context = {})
      @payload = payload
      @protocol_version = protocol_version
      @context = context.freeze
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @completed = false
      @cancelled = false
    end

    def complete(value)
      @mutex.synchronize do
        return if @cancelled
        @value = value
        @completed = true
        @condition.broadcast
      end
    end

    def wait(timeout = 300)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      @mutex.synchronize do
        while !@completed
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            @cancelled = true
            raise EltenMCP::Error.new("MCP request timed out while waiting for Klangten", code: -32003, http_status: 504)
          end
          @condition.wait(@mutex, remaining)
        end
        @value
      end
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end
  end

  class RequestQueue
    def initialize
      @queue = Queue.new
    end

    def submit(payload, protocol_version, context = {}, timeout: 300)
      request = PendingRequest.new(payload, protocol_version, context)
      @queue << request
      request.wait(timeout)
    end

    def push(request)
      @queue << request
      request
    end

    def pop(non_block = true)
      @queue.pop(non_block)
    rescue ThreadError
      nil
    end

    def drain
      while (request = pop) != nil
        yield request
      end
    end
  end
end
