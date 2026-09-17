# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: configurable API URL, TLS verification, no payload encryption or realtime stream.

require "base64"
require "http/2"
require "io/wait"
require "json"
require "monitor"
require "openssl"
require "securerandom"
require "timeout"
require "uri"

module EltenAPI
  class ERDownloadProgress
    attr_reader :downloaded, :total, :percent

    def initialize(downloaded, total)
      @downloaded = downloaded.to_i
      @total = total.to_i
      @percent = @total > 0 ? (@downloaded.to_f / @total.to_f * 100.0).floor : 0
    end
  end

  module HTTPClient
    # Klangten: scheme, host and port come from Klangten::Config (KLANGTEN_API_URL).
    HTTP2_ALPN = "h2".freeze
    CONNECT_TIMEOUT = 8
    READ_TIMEOUT = 20
    STALE_AFTER = 20
    ACTIVE_STALE_AFTER = 45
    MAX_REDIRECTS = 5

    @conn_mutex = Mutex.new
    @http_mutex = Monitor.new
    @ssl_mutex = Mutex.new
    @pending_mutex = Mutex.new

    class << self
      def init(force=false)
        connect_http2(force: force, reconnect_if_stale: false)
      end

      def close
        close_http2(true)
      end

      def ejrequest(method, path, params, data=nil, headers: nil, cancellation_token: nil, protocol: nil, &block)
        # Klangten: HTTP/1.1 is also used for plain HTTP servers (local
        # development) and when the server does not negotiate HTTP/2.
        if protocol == :http1 || disable_http2?
          return ejrequest_http1(
            method, path, params, data,
            headers: headers,
            cancellation_token: cancellation_token,
            &block
          )
        end
        params = {} unless params.is_a?(Hash)
        headers = headers.is_a?(Hash) ? headers : {}
        Thread.new do
          Thread.current.report_on_exception = false
          attempts = 0
          pending_token = nil
          request_generation = nil
          begin
            attempts += 1
            raise_if_cancelled!(cancellation_token, data)
            pending_token = nil
            request_generation = nil
            unless ensure_http2_connection
              if disable_http2?
                ejrequest_http1(method, path, params, data, headers: headers, cancellation_token: cancellation_token, &block)
                next
              end
              raise "HTTP/2 unavailable"
            end
            json = json_request_body(params)
            body = "".b
            response_headers = {}
            http_mutex.synchronize do
              stream = nil
              connection_mutex.synchronize do
                request_generation = @connection_generation
                http = @http
                ssl = @ssl
                raise "HTTP/2 connection changed" unless connection_current?(request_generation, ssl, http)

                stream = http.new_stream
                pending_token = register_pending_request(request_generation, stream, cancellation_token) do
                  safe_call(block, :error, data)
                end
              end
              if cancelled?(data, cancellation_token)
                fail_pending_request(pending_token)
                next
              end
              head = {
                ":scheme" => "https",
                ":authority" => Klangten::Config.api_authority,
                ":path" => path,
                ":method" => method.to_s.upcase,
                "user-agent" => user_agent,
                "accept-encoding" => "zstd, identity",
                "content-type" => "application/json",
                "content-length" => json.bytesize.to_s
              }
              headers.each do |key, value|
                next if key.to_s.empty? || value == nil
                head[key.to_s.downcase] = value.to_s
              end
              stream.on(:headers) do |h|
                response_headers = h.to_h
                data["headers"] = h if data.is_a?(Hash)
              end
              stream.on(:data) { |chunk| body << chunk.to_s.b }
              stream.on(:close) do
                next unless take_pending_request(pending_token)

                begin
                  @last_response = Time.now.to_i
                  touch_connection_activity(request_generation)
                  safe_call(block, decode_body(body, response_headers), data)
                rescue Exception => e
                  log_error("JSON body error: #{format_exception(e)}")
                  safe_call(block, :error, data)
                end
              end
              stream.headers(head, end_stream: false)
              until json.empty?
                chunk = json.slice!(0...4096)
                stream.data(chunk, end_stream: json.empty?)
              end
            end
          rescue Exception => e
            if cancelled?(data, cancellation_token)
              if pending_token != nil
                fail_pending_request(pending_token)
              else
                safe_call(block, :error, data)
              end
              next
            end
            log_error("JSON request error: #{format_exception(e)}")
            close_http2(false, request_generation) if request_generation != nil
            if pending_token != nil
              fail_pending_request(pending_token)
            elsif attempts < 2
              retry
            else
              safe_call(block, :error, data)
            end
          end
        end
      end

      def ejrequest_http1(method, path, params, data=nil, headers: nil, cancellation_token: nil, &block)
        params = {} unless params.is_a?(Hash)
        headers = headers.is_a?(Hash) ? headers : {}
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            raise_if_cancelled!(cancellation_token, data)
            json = json_request_body(params)
            request_headers = {
              "Content-Type" => "application/json",
              "Accept-Encoding" => "zstd, identity"
            }.merge(headers)
            response = readurl_sync(
              "#{Klangten::Config.api_base_url}#{path}",
              method,
              json,
              request_headers,
              data,
              cancellation_token: cancellation_token,
              accept_any_status: true
            )
            body = response.is_a?(Hash) ? response[:body] : :error
            if body == :error
              safe_call(block, :error, data)
              next
            end
            data["headers"] = response[:headers] if data.is_a?(Hash)
            safe_call(block, body, data)
          rescue Exception => e
            log_error("HTTP/1.1 JSON request error: #{format_exception(e)}") unless cancelled?(data, cancellation_token)
            safe_call(block, :error, data)
          end
        end
      end

      # Klangten: the realtime stream (encrypted HTTP/2 NDJSON bound to an
      # EltenLink transport session) is not supported. Realtime state is
      # received through the long-poll only, so this always fails immediately.
      def ejstream(path, params, data=nil, cancellation_token: nil, &block)
        Thread.new do
          Thread.current.report_on_exception = false
          set_realtime_stream_error(data, "realtime stream is not supported by Klangten")
          safe_call(block, :error, data)
        end
      end

      def downloadfile(source, destination, data=nil, redirects=0, cancellation_token: nil, &block)
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            result = downloadfile_sync(source, destination, data, redirects, cancellation_token: cancellation_token, &block)
            safe_call(block, result, data) if result.is_a?(Integer)
          rescue Exception => e
            log_error("downloadfile worker error: #{format_exception(e)}") unless cancelled?(data, cancellation_token)
            safe_call(block, :error, data)
          end
        end
      end

      def readurl(url, method="get", body="", headers={}, data=nil, redirects=0, cancellation_token: nil, &block)
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            response = readurl_sync(url, method, body, headers, data, redirects, cancellation_token: cancellation_token)
            safe_call(block, response[:body], data, response[:headers])
          rescue Exception => e
            log_error("readurl worker error: #{format_exception(e)}") unless cancelled?(data, cancellation_token)
            safe_call(block, :error, data, {})
          end
        end
      end

      def http2_enabled?
        !disable_http2?
      end

      private

      def connection_mutex
        @conn_mutex ||= Mutex.new
      end

      def http_mutex
        @http_mutex ||= Monitor.new
      end

      def ssl_mutex
        @ssl_mutex ||= Mutex.new
      end

      def pending_mutex
        @pending_mutex ||= Mutex.new
      end

      def ensure_http2_connection
        connect_http2(force: false, reconnect_if_stale: true)
      end

      def connect_http2(force:, reconnect_if_stale:)
        detached = nil
        socket = nil
        ssl = nil
        generation = nil

        connection_mutex.synchronize do
          if connected?
            return true if !force && (!reconnect_if_stale || !stale?)
          end

          detached = detach_http2_locked
          close_io(detached[:ssl]) if detached != nil

          host = Klangten::Config.api_host
          socket = connect_socket(host, Klangten::Config.api_port)
          ctx = EltenAPI::TLS.client_context
          ctx.alpn_protocols = [HTTP2_ALPN]
          ctx.options |= OpenSSL::SSL::OP_IGNORE_UNEXPECTED_EOF
          ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          ssl.sync_close = true
          ssl.hostname = host if ssl.respond_to?(:hostname=)
          Timeout.timeout(CONNECT_TIMEOUT) { ssl.connect }
          ssl.post_connection_check(host)
          if ssl.respond_to?(:alpn_protocol) && ssl.alpn_protocol.to_s != HTTP2_ALPN
            # Klangten: the server does not speak HTTP/2; all further requests use HTTP/1.1.
            @http2_unsupported = true
            raise "server did not negotiate HTTP/2 (ALPN #{ssl.alpn_protocol.inspect}), switching to HTTP/1.1"
          end

          http = HTTP2::Client.new(settings_max_frame_size: 131072)
          @connection_sequence = @connection_sequence.to_i + 1
          generation = @connection_sequence
          @connection_generation = generation
          @ssl = ssl
          @http = http
          @last_response = Time.now.to_i
          @last_activity = monotonic_time
          http.on(:frame) { |bytes| write_http2_frame(bytes, generation, ssl) }
          http.on(:error) do |error|
            log_warning("HTTP/2 connection error: #{error}")
            close_http2(false, generation)
          end
          start_reader(generation, ssl, http)
        end

        finalize_detached_connection(detached, false)
        true
      rescue Exception => e
        finalize_detached_connection(detached, false)
        if generation != nil
          close_http2(false, generation)
        else
          close_io(ssl || socket)
        end
        log_error("HTTP/2 init error: #{format_exception(e)}")
        false
      end

      def connected?
        http = @http
        http != nil &&
          @ssl != nil &&
          !@ssl.closed? &&
          (!http.respond_to?(:closed?) || !http.closed?) &&
          @reader_thread != nil &&
          @reader_thread.alive?
      end

      def stale?
        last_activity = @last_activity
        return false if last_activity == nil

        now = monotonic_time
        pending_started_at = oldest_pending_request_started_at(@connection_generation)
        return pending_started_at < now - ACTIVE_STALE_AFTER if pending_started_at != nil

        last_activity < now - STALE_AFTER
      end

      def disable_http2?
        return true unless Klangten::Config.http2_allowed?
        return true if @http2_unsupported == true
        Configuration.disablehttp2 == true
      end

      def user_agent
        Klangten::Config.user_agent
      end

      def connect_socket(host, port)
        Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
      end

      def start_reader(generation, ssl, http)
        @reader_thread = Thread.new do
          Thread.current.report_on_exception = false
          loop do
            break unless connection_current?(generation, ssl, http)
            begin
              chunk = ssl.read_nonblock(16_384)
              if chunk != nil && chunk.bytesize > 0
                break unless connection_current?(generation, ssl, http)

                touch_connection_activity(generation)
                http_mutex.synchronize { http << chunk }
              end
            rescue IO::WaitReadable
              IO.select([ssl], nil, nil, 0.5)
            rescue EOFError, IOError
              break
            rescue Exception => e
              log_error("HTTP reader error: #{format_exception(e)}")
              break
            end
          end
          close_http2(false, generation)
        end
      end

      def close_http2(kill_reader, generation=nil)
        detached = connection_mutex.synchronize do
          detach_http2_locked(generation)
        end
        return false if detached == nil

        finalize_detached_connection(detached, kill_reader)
        true
      rescue Exception
        false
      end

      def write_http2_frame(bytes, generation, ssl)
        ssl_mutex.synchronize do
          return unless connection_current?(generation, ssl)
          return if ssl.closed?

          ssl.write(bytes)
          ssl.flush
          touch_connection_activity(generation)
        end
      rescue Exception => e
        log_error("HTTP frame write error: #{format_exception(e)}")
        close_http2(false, generation)
      end

      def connection_current?(generation, ssl=nil, http=nil)
        generation != nil &&
          @connection_generation == generation &&
          (ssl == nil || @ssl.equal?(ssl)) &&
          (http == nil || @http.equal?(http))
      end

      def detach_http2_locked(expected_generation=nil)
        return nil if expected_generation != nil && @connection_generation != expected_generation
        return nil if @http == nil && @ssl == nil && @reader_thread == nil

        detached = {
          generation: @connection_generation,
          http: @http,
          ssl: @ssl,
          reader: @reader_thread
        }
        @connection_generation = nil
        @reader_thread = nil
        @http = nil
        @ssl = nil
        @last_activity = nil
        detached
      end

      def finalize_detached_connection(detached, kill_reader)
        return if detached == nil

        close_io(detached[:ssl])
        reader = detached[:reader]
        begin
          reader.kill if kill_reader && reader != nil && reader != Thread.current && reader.alive?
        rescue Exception
        end
        fail_pending_requests_for_generation(detached[:generation])
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue Exception
        Time.now.to_f
      end

      def touch_connection_activity(generation)
        @last_activity = monotonic_time if @connection_generation == generation
      end

      def register_pending_request(generation, stream, cancellation_token=nil, persistent: false, &failure)
        token = Object.new
        entry = {
          generation: generation,
          started_at: monotonic_time,
          failure: failure,
          stream: stream,
          persistent: persistent,
          cancellation_registration: nil
        }
        pending_mutex.synchronize do
          @pending_requests ||= {}
          @pending_requests[token] = entry
        end
        registration = register_cancellation(cancellation_token) { cancel_pending_request(token) }
        if registration != nil
          attached = pending_mutex.synchronize do
            current = @pending_requests == nil ? nil : @pending_requests[token]
            current[:cancellation_registration] = registration if current.equal?(entry)
            current.equal?(entry)
          end
          registration.unregister unless attached
        end
        token
      end

      def take_pending_request(token)
        entry = pending_mutex.synchronize do
          @pending_requests == nil ? nil : @pending_requests.delete(token)
        end
        dispose_cancellation(entry)
        entry
      end

      def fail_pending_request(token)
        entry = detach_pending_request(token)
        return false if entry == nil

        entry[:failure].call if entry[:failure] != nil
        true
      rescue Exception
        false
      end

      def fail_pending_requests_for_generation(generation)
        return if generation == nil

        entries = pending_mutex.synchronize do
          requests = @pending_requests || {}
          selected = requests.select { |_token, entry| entry[:generation] == generation }
          selected.each_key { |token| requests.delete(token) }
          selected.values
        end
        entries.each do |entry|
          dispose_cancellation(entry)
          begin
            entry[:failure].call if entry[:failure] != nil
          rescue Exception
          end
        end
      end

      def cancel_pending_request(token)
        entry = detach_pending_request(token)
        return false if entry == nil

        cancel_http2_stream(entry[:stream])
        entry[:failure].call if entry[:failure] != nil
        true
      rescue Exception
        false
      end

      def detach_pending_request(token)
        entry = pending_mutex.synchronize do
          @pending_requests == nil ? nil : @pending_requests.delete(token)
        end
        dispose_cancellation(entry)
        entry
      end

      def dispose_cancellation(entry)
        registration = entry.is_a?(Hash) ? entry[:cancellation_registration] : nil
        registration.unregister if registration != nil
      rescue Exception
      end

      def cancel_http2_stream(stream)
        return if stream == nil
        http_mutex.synchronize do
          stream.cancel unless stream.respond_to?(:closed?) && stream.closed?
        end
      rescue Exception
      end

      def oldest_pending_request_started_at(generation)
        return nil if generation == nil

        pending_mutex.synchronize do
          (@pending_requests || {}).values
            .select { |entry| entry[:generation] == generation && entry[:persistent] != true }
            .map { |entry| entry[:started_at] }
            .compact
            .min
        end
      end

      def write_http1_request(io, method, path, host, headers, body, cancellation_token=nil)
        request = "#{method} #{path} HTTP/1.1\r\nHost: #{host}\r\n".b
        headers.each { |key, value| request << "#{key}: #{value}\r\n".b }
        request << "\r\n".b
        io.write(request)
        if body.respond_to?(:read)
          body.rewind if body.respond_to?(:rewind)
          while (chunk = body.read(64 * 1024))
            break if chunk.empty?
            raise_if_cancelled!(cancellation_token)
            io.write(chunk)
          end
        elsif body != nil && !body.empty?
          io.write(body)
        end
        io.flush if io.respond_to?(:flush)
      end

      def read_http1_response(io)
        response = read_http1_head(io)
        response[:body] = read_http_body(io, response[:headers])
        response
      end

      def read_http1_head(io)
        header = "".b
        line = "".b
        until line == "\r\n"
          line = read_line(io)
          header << line
        end
        lines = header.split("\r\n")
        status_line = lines.shift.to_s
        raise "Invalid HTTP response: #{status_line}" unless status_line.start_with?("HTTP/")
        headers = {}
        lines.each do |entry|
          index = entry.index(":")
          next if index == nil
          headers[entry[0...index]] = entry[index + 1..-1].to_s.strip
        end
        { status: status_line.split(" ")[1].to_i, headers: headers }
      end

      def read_http_body(io, headers)
        transfer = header_value(headers, "Transfer-Encoding").to_s.downcase
        length = header_value(headers, "Content-Length")
        if transfer.include?("chunked")
          read_chunked_body(io)
        elsif length != nil
          read_exact_body(io, length.to_i)
        else
          read_until_eof(io)
        end
      end

      def read_chunked_body(io)
        body = "".b
        loop do
          line = read_line(io)
          size = line.split(";", 2)[0].to_i(16)
          break if size == 0
          body << read_exact_body(io, size)
          read_exact_body(io, 2)
        end
        body
      end

      def read_exact_body(io, size)
        body = "".b
        while body.bytesize < size
          chunk = read_partial(io, size - body.bytesize)
          break if chunk == nil || chunk.empty?
          body << chunk
        end
        body
      end

      def read_until_eof(io)
        body = "".b
        loop do
          chunk = read_partial(io, 16_384)
          break if chunk == nil || chunk.empty?
          body << chunk
        end
        body
      end

      def read_line(io)
        wait_readable(io)
        io.readline
      end

      def read_partial(io, size)
        wait_readable(io)
        io.readpartial([size, 16_384].min)
      rescue EOFError
        nil
      end

      def wait_readable(io)
        ready = IO.select([io], nil, nil, READ_TIMEOUT)
        raise Timeout::Error, "network read timeout" if ready == nil
      end

      def decode_body(body, headers)
        data = body.to_s.b
        encoding = header_value(headers, "content-encoding").to_s.downcase
        transfer = header_value(headers, "transfer-encoding").to_s.downcase
        if (encoding == "gzip" || transfer == "gzip") && data.getbyte(0) == 0x1f && data.getbyte(1) == 0x8b
          Zlib::GzipReader.new(StringIO.new(data)).read
        elsif transfer == "deflate" || encoding == "deflate"
          Zlib::Inflate.inflate(data)
        elsif encoding == "zstd"
          require "zstd-ruby" unless defined?(Zstd)
          Zstd.decompress(data)
        else
          data
        end
      end

      # Klangten: plain JSON over TLS. Elten's "elten_encryption" payload
      # envelope (RSA-OAEP/AES-GCM against EltenLink's server key) is not used.
      def json_request_body(params)
        JSON.generate(params).b
      end

      def http_host_header(uri)
        uri.port == uri.default_port ? uri.host.to_s : "#{uri.host}:#{uri.port}"
      end

      def set_realtime_stream_error(data, reason)
        return unless data.is_a?(Hash)

        value = reason.to_s.gsub(/\s+/, " ").strip
        data["stream_error"] = value[0, 240] unless value.empty?
      end

      def normalize_headers(headers)
        result = {}
        return result unless headers.is_a?(Hash)
        headers.each { |key, value| result[key.to_s] = value.to_s }
        result
      end

      def header_value(headers, name)
        return nil unless headers.is_a?(Hash)
        name = name.to_s.downcase
        headers.each { |key, value| return value if key.to_s.downcase == name }
        nil
      end

      def downloadfile_sync(source, destination, data=nil, redirects=0, cancellation_token: nil, &block)
        raise "Too many redirects" if redirects > MAX_REDIRECTS
        raise_if_cancelled!(cancellation_token)
        uri = URI.parse(source)
        socket = connect_socket(uri.host, uri.port || (uri.scheme == "https" ? 443 : 80))
        io = socket
        cancellation_registration = register_cancellation(cancellation_token) do
          close_io(io)
          close_io(socket)
        end
        raise_if_cancelled!(cancellation_token)
        if uri.scheme == "https"
          ctx = EltenAPI::TLS.client_context
          ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          ssl.sync_close = true
          ssl.hostname = uri.host if ssl.respond_to?(:hostname=)
          Timeout.timeout(CONNECT_TIMEOUT) { ssl.connect }
          ssl.post_connection_check(uri.host)
          io = ssl
        end
        write_http1_request(io, "GET", uri.request_uri, http_host_header(uri), {
          "User-Agent" => user_agent,
          "Connection" => "close",
          "Accept-Encoding" => "identity, chunked, *;q=0"
        }, nil)
        response = read_http1_head(io)
        location = header_value(response[:headers], "Location")
        return downloadfile_sync(uri.merge(location).to_s, destination, data, redirects + 1, cancellation_token: cancellation_token, &block) if location != nil
        status = response[:status].to_i
        return :error if status < 200 || status >= 300
        File.open(destination, "wb") do |file|
          stream_http_body(io, response[:headers], file, data, block, cancellation_token)
        end
      ensure
        cancellation_registration.unregister if defined?(cancellation_registration) && cancellation_registration != nil
        close_io(io) if defined?(io)
        close_io(socket) if defined?(socket)
      end

      # accept_any_status: Klangten API calls pass error envelopes through even
      # when the server answers with a non-2xx status, as long as the body is JSON.
      def readurl_sync(url, method="get", body="", headers={}, data=nil, redirects=0, cancellation_token: nil, accept_any_status: false)
        raise "Too many redirects" if redirects > MAX_REDIRECTS
        raise_if_cancelled!(cancellation_token)
        uri = URI.parse(url)
        body_data = if body.nil?
                      nil
                    elsif body.respond_to?(:read)
                      body.rewind if body.respond_to?(:rewind)
                      body
                    else
                      body.to_s.b
                    end
        request_headers = {
          "User-Agent" => user_agent,
          "Connection" => "close",
          "Accept-Encoding" => "identity, chunked, *;q=0"
        }.merge(normalize_headers(headers))
        if body_data != nil
          body_size = body_data.respond_to?(:size) ? body_data.size : body_data.bytesize
          request_headers["Content-Length"] = body_size.to_i.to_s
        end
        response = http1_request_uri(uri, method.to_s.upcase, body_data, request_headers, data, cancellation_token)
        if response[:redirect] != nil
          return readurl_sync(uri.merge(response[:redirect]).to_s, method, body, headers, data, redirects + 1, cancellation_token: cancellation_token, accept_any_status: accept_any_status)
        end
        status = response[:status].to_i
        if status < 200 || status >= 300
          decoded = accept_any_status ? (decode_body(response[:body], response[:headers]) rescue "") : ""
          return { body: :error, headers: response[:headers] } unless decoded.to_s.lstrip.start_with?("{")
          return { body: decoded, headers: response[:headers] }
        end
        { body: decode_body(response[:body], response[:headers]), headers: response[:headers] }
      end

      def http1_request_uri(uri, method, body, headers, data=nil, cancellation_token=nil)
        raise_if_cancelled!(cancellation_token)
        socket = connect_socket(uri.host, uri.port || (uri.scheme == "https" ? 443 : 80))
        io = socket
        cancellation_registration = register_cancellation(cancellation_token) do
          close_io(io)
          close_io(socket)
        end
        raise_if_cancelled!(cancellation_token)
        if uri.scheme == "https"
          ctx = EltenAPI::TLS.client_context
          ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          ssl.sync_close = true
          ssl.hostname = uri.host if ssl.respond_to?(:hostname=)
          Timeout.timeout(CONNECT_TIMEOUT) { ssl.connect }
          ssl.post_connection_check(uri.host)
          io = ssl
        end
        write_http1_request(io, method, uri.request_uri, http_host_header(uri), headers, body, cancellation_token)
        response = read_http1_response(io)
        location = header_value(response[:headers], "Location")
        response[:redirect] = location if location != nil
        response
      ensure
        cancellation_registration.unregister if defined?(cancellation_registration) && cancellation_registration != nil
        close_io(io) if defined?(io)
        close_io(socket) if defined?(socket)
      end

      def stream_http_body(io, headers, file, data=nil, block=nil, cancellation_token=nil)
        transfer = header_value(headers, "Transfer-Encoding").to_s.downcase
        total = header_value(headers, "Content-Length").to_i
        downloaded = 0
        last_progress = Time.now.to_f
        if transfer.include?("chunked")
          loop do
            raise_if_cancelled!(cancellation_token, data)
            size = read_line(io).split(";", 2)[0].to_i(16)
            break if size == 0
            chunk = read_exact_body(io, size)
            file.write(chunk)
            downloaded += chunk.bytesize
            read_exact_body(io, 2)
            if total > 0 && Time.now.to_f - last_progress > 5
              last_progress = Time.now.to_f
              safe_call(block, ERDownloadProgress.new(downloaded, total), data)
            end
          end
        elsif total > 0
          while downloaded < total
            raise_if_cancelled!(cancellation_token, data)
            chunk = read_partial(io, [16_384, total - downloaded].min)
            break if chunk == nil || chunk.empty?
            file.write(chunk)
            downloaded += chunk.bytesize
            if Time.now.to_f - last_progress > 5
              last_progress = Time.now.to_f
              safe_call(block, ERDownloadProgress.new(downloaded, total), data)
            end
          end
        else
          loop do
            raise_if_cancelled!(cancellation_token, data)
            chunk = read_partial(io, 16_384)
            break if chunk == nil || chunk.empty?
            file.write(chunk)
            downloaded += chunk.bytesize
          end
        end
        downloaded
      end

      def cancelled?(data=nil, cancellation_token=nil)
        (data.is_a?(Hash) && data[:cancelled] == true) ||
          (cancellation_token != nil && cancellation_token.respond_to?(:cancelled?) && cancellation_token.cancelled?)
      end

      def raise_if_cancelled!(cancellation_token=nil, data=nil)
        cancellation_token.raise_if_cancelled! if cancellation_token != nil && cancellation_token.respond_to?(:raise_if_cancelled!)
        raise "cancelled" if data.is_a?(Hash) && data[:cancelled] == true
      end

      def register_cancellation(cancellation_token, &callback)
        return nil if cancellation_token == nil || !cancellation_token.respond_to?(:on_cancel)
        cancellation_token.on_cancel(&callback)
      end


      def safe_call(block, *args)
        block.call(*args) if block != nil
      rescue Exception => e
        log_error("HTTP callback error: #{format_exception(e)}")
      end

      def close_io(io)
        io.close if io != nil && io.respond_to?(:close) && !io.closed?
      rescue Exception
      end

      def format_exception(error)
        "#{error.class}: #{error.message} #{Array(error.backtrace).join(" ")}"
      end

      def log_error(message)
          Log.error(message)
      rescue Exception
      end

      def log_warning(message)
          Log.warning(message)
      rescue Exception
      end
    end
  end

  module HTTP
    private

    def ejrequest(method, path, params, data=nil, headers: nil, cancellation_token: nil, &block)
      elten_link.e_json_request(method, path, params, data, headers: headers, cancellation_token: cancellation_token, &block)
    end

    def readurl(url, method="get", body="", headers={}, data=nil, cancellation_token: nil, &block)
      elten_link.e_read_url(url, method, body, headers, data, cancellation_token: cancellation_token, &block)
    end

    def downloadfile(source, destination, data=nil, cancellation_token: nil, &block)
      elten_link.e_download_file(source, destination, data, cancellation_token: cancellation_token, &block)
    end
  end

  include HTTP
end
