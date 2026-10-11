# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# A small web server inside the test process, on a free loopback port - the
# internet for media and HTTP tests. Klangten (Ruby HTTP and BASS URL
# streams alike) reaches it like any other server; nothing else is reachable.
#
#   web = fake_web                                   # FlowTest helper
#   web.file("/song.mp3", bytes, mime: "audio/mpeg") # with Range support
#   web.text("/page.html", "<h1>Hi</h1>", mime: "text/html")
#   web.json("/api/info", { "ok" => true })
#   web.error("/missing", 404)
#   web.redirect("/old", "/new")
#   web.dynamic("/echo") { |req| [200, { "Content-Type" => "text/plain" }, req.body] }
#   web.url("/song.mp3")   # => "http://127.0.0.1:<port>/song.mp3"
#   web.requests           # every request: method, path, query, headers, body

require "socket"
require "json"
require "uri"

module KlangtenTest
  class FakeWeb
    Request = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true)

    STATUS = { 200 => "OK", 206 => "Partial Content", 301 => "Moved Permanently", 302 => "Found",
               400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 416 => "Range Not Satisfiable",
               500 => "Internal Server Error", 503 => "Service Unavailable" }.freeze

    attr_reader :port, :requests

    def self.start
      new.tap(&:start)
    end

    def initialize
      @routes = {}
      @requests = []
      @lock = Mutex.new
    end

    def start
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { accept_loop }
      self
    end

    def stop
      @server&.close rescue nil
      @thread&.kill
    end

    def url(path = "/")
      "http://127.0.0.1:#{@port}#{path}"
    end

    # ------------------------------------------------------------ routes
    def file(path, data, mime: "application/octet-stream", headers: {})
      @routes[path] = { kind: :file, data: data.to_s.b, mime: mime, headers: headers }
      url(path)
    end

    def text(path, body, mime: "text/plain; charset=utf-8", status: 200, headers: {})
      @routes[path] = { kind: :text, body: body.to_s, mime: mime, status: status, headers: headers }
      url(path)
    end

    def json(path, value, status: 200)
      text(path, JSON.generate(value), mime: "application/json", status: status)
    end

    def error(path, status = 404, body = "")
      text(path, body, status: status)
    end

    def redirect(path, target, status: 302)
      @routes[path] = { kind: :redirect, target: target.start_with?("/") ? url(target) : target, status: status }
      url(path)
    end

    # block(request) -> [status, headers, body]
    def dynamic(path, &block)
      @routes[path] = { kind: :dynamic, block: block }
      url(path)
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      end
    rescue IOError, SystemCallError
    end

    def serve(socket)
      request = read_request(socket)
      return if request == nil
      @lock.synchronize { @requests << request }
      status, headers, body = respond(request)
      head = "HTTP/1.1 #{status} #{STATUS[status] || "Status"}\r\n"
      headers = { "Content-Length" => body.bytesize.to_s, "Connection" => "close" }.merge(headers)
      headers.each { |k, v| head << "#{k}: #{v}\r\n" }
      socket.write(head + "\r\n")
      socket.write(body) unless request.method == "HEAD"
    rescue IOError, SystemCallError
    ensure
      socket.close rescue nil
    end

    def read_request(socket)
      line = socket.gets("\r\n")
      return nil if line == nil
      method, target = line.split(" ", 3)
      headers = {}
      while (h = socket.gets("\r\n")) && h != "\r\n"
        key, value = h.split(":", 2)
        headers[key.to_s.strip.downcase] = value.to_s.strip
      end
      body = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""
      uri = URI.parse(target.to_s)
      Request.new(method: method, path: uri.path, query: uri.query.to_s, headers: headers, body: body)
    end

    def respond(request)
      route = @routes[request.path]
      return [404, { "Content-Type" => "text/plain" }, "not found"] if route == nil
      case route[:kind]
      when :file then file_response(route, request)
      when :text then [route[:status], { "Content-Type" => route[:mime] }.merge(route[:headers]), route[:body].b]
      when :redirect then [route[:status], { "Location" => route[:target] }, ""]
      when :dynamic
        status, headers, body = route[:block].call(request)
        [status.to_i, headers || {}, body.to_s.b]
      end
    end

    def file_response(route, request)
      data = route[:data]
      headers = { "Content-Type" => route[:mime], "Accept-Ranges" => "bytes" }.merge(route[:headers])
      range = request.headers["range"].to_s
      if range =~ /\Abytes=(\d*)-(\d*)\z/
        first = $1 == "" ? [data.bytesize - $2.to_i, 0].max : $1.to_i
        last = ($1 == "" || $2 == "") ? data.bytesize - 1 : [$2.to_i, data.bytesize - 1].min
        return [416, { "Content-Range" => "bytes */#{data.bytesize}" }, ""] if first >= data.bytesize
        headers["Content-Range"] = "bytes #{first}-#{last}/#{data.bytesize}"
        return [206, headers, data.byteslice(first..last)]
      end
      [200, headers, data]
    end
  end
end
