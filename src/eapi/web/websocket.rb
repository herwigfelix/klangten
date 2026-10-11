# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# A small WebSocket client (RFC 6455) for the Klangten browser.
#
# It speaks plain ws:// only: its one job is the DevTools connection to the
# Chrome that Klangten starts on 127.0.0.1. No Origin header is sent, so Chrome
# accepts the connection without --remote-allow-origins. Messages are text
# frames; fragmented messages are joined, pings are answered, and a close frame
# or a broken socket ends the connection (receive returns nil from then on).
#
# send_text may be called from any thread. receive belongs to one reader
# thread (the DevTools connection has exactly one).

require "socket"
require "securerandom"
require "base64"
require "digest"

module KlangtenWeb
  class WebSocket
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11".freeze
    MAX_MESSAGE = 512 * 1024 * 1024

    class Error < StandardError; end

    def initialize(host, port, path, timeout: 5)
      @socket = Socket.tcp(host, port, connect_timeout: timeout)
      @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil
      @write_mutex = Mutex.new
      @open = true
      handshake(host, port, path, timeout)
    rescue SystemCallError, SocketError, IOError => e
      close
      raise Error, "WebSocket connection failed: #{e.message}"
    end

    def open?
      @open == true
    end

    def send_text(text)
      send_frame(0x1, text.to_s.dup.force_encoding(Encoding::BINARY))
    end

    # The next text message as a UTF-8 String, or nil when the connection ended.
    def receive
      message = nil
      opcode = nil
      while @open
        fin, op, payload = read_frame
        return nil if fin == nil
        case op
        when 0x0
          next if message == nil
          message << payload
        when 0x1, 0x2
          message = payload
          opcode = op
        when 0x8
          close_quietly(payload)
          return nil
        when 0x9
          send_frame(0xA, payload) rescue nil
          next
        when 0xA
          next
        else
          next
        end
        raise Error, "message too large" if message != nil && message.bytesize > MAX_MESSAGE
        if fin && message != nil
          return opcode == 0x1 ? message.force_encoding(Encoding::UTF_8) : message
        end
      end
      nil
    rescue IOError, SystemCallError, Error
      @open = false
      nil
    end

    def close
      was_open = @open
      @open = false
      if was_open && @socket != nil
        send_frame(0x8, [1000].pack("n"), force: true) rescue nil
      end
      @socket.close if @socket != nil && !@socket.closed?
    rescue IOError, SystemCallError
      nil
    end

    private

    def handshake(host, port, path, timeout)
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      request = +"GET #{path} HTTP/1.1\r\n"
      request << "Host: #{host}:#{port}\r\n"
      request << "Upgrade: websocket\r\n"
      request << "Connection: Upgrade\r\n"
      request << "Sec-WebSocket-Key: #{key}\r\n"
      request << "Sec-WebSocket-Version: 13\r\n\r\n"
      @socket.write(request)
      head = +"".b
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until head.end_with?("\r\n\r\n")
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "no handshake answer" if remaining <= 0 || !@socket.wait_readable(remaining)
        chunk = @socket.read(1)
        raise Error, "connection closed during the handshake" if chunk == nil
        head << chunk
        raise Error, "handshake answer too long" if head.bytesize > 16_384
      end
      lines = head.split("\r\n")
      raise Error, "handshake refused: #{lines.first}" unless lines.first.to_s =~ /\AHTTP\/1\.[01] 101\b/
      headers = {}
      lines.drop(1).each do |line|
        name, value = line.split(":", 2)
        headers[name.to_s.strip.downcase] = value.to_s.strip if value != nil
      end
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      raise Error, "wrong Sec-WebSocket-Accept" if headers["sec-websocket-accept"] != expected
    end

    # Client frames are always masked.
    def send_frame(opcode, payload, force: false)
      raise Error, "connection closed" if !@open && !force
      payload = payload.to_s.b
      frame = +"".b
      frame << (0x80 | opcode).chr
      length = payload.bytesize
      if length < 126
        frame << (0x80 | length).chr
      elsif length < 65_536
        frame << (0x80 | 126).chr << [length].pack("n")
      else
        frame << (0x80 | 127).chr << [length].pack("Q>")
      end
      mask = SecureRandom.random_bytes(4)
      frame << mask
      frame << mask_payload(payload, mask)
      @write_mutex.synchronize { @socket.write(frame) }
      true
    rescue IOError, SystemCallError => e
      @open = false
      raise Error, e.message
    end

    def mask_payload(payload, mask)
      return payload if payload.empty?
      key = mask.unpack("N").first
      words = payload.bytesize / 4
      out = payload[0, words * 4].unpack("N*").map! { |word| word ^ key }.pack("N*")
      tail = payload.byteslice(words * 4, payload.bytesize - words * 4).to_s
      tail.bytes.each_with_index { |byte, index| out << (byte ^ mask.getbyte(index)).chr }
      out
    end

    def read_frame
      head = read_exact(2)
      return [nil, nil, nil] if head == nil
      b0 = head.getbyte(0)
      b1 = head.getbyte(1)
      fin = (b0 & 0x80) != 0
      opcode = b0 & 0x0f
      masked = (b1 & 0x80) != 0
      length = b1 & 0x7f
      if length == 126
        length = read_exact(2).to_s.unpack("n").first
      elsif length == 127
        length = read_exact(8).to_s.unpack("Q>").first
      end
      return [nil, nil, nil] if length == nil
      raise Error, "frame too large" if length > MAX_MESSAGE
      mask = masked ? read_exact(4) : nil
      payload = length > 0 ? read_exact(length) : +"".b
      return [nil, nil, nil] if payload == nil
      payload = mask_payload(payload, mask) if mask != nil
      [fin, opcode, payload]
    end

    def read_exact(size)
      data = @socket.read(size)
      return nil if data == nil || data.bytesize < size
      data
    end

    def close_quietly(payload)
      @open = false
      @write_mutex.synchronize { @socket.write([0x88, 0x80 | [payload.to_s.bytesize, 125].min].pack("CC") + "\0\0\0\0" + payload.to_s.b[0, 125]) } rescue nil
      @socket.close rescue nil
    end
  end
end
