# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The real Klango server as the partner of online tests. Its code is not part
# of this repository (it is a separate, private project); this file only
# starts it:
#
#   KLANGTEN_SERVER_DIR=<checkout>/klango_server   (required, else skipped)
#   KLANGTEN_SERVER_PYTHON=<python>                (default: <dir>/.venv/bin/python)
#
# Each test gets its own server process on a free loopback port with an empty
# database in the test directory:
#
#   python -m klango.klangten --port <port>
#
#   server.create_user("hans")                    # password KlangtenTest::PASSWORD
#   server.sql("SELECT ... WHERE x = ?", 1)       # rows of the server database
#   server.requests                               # [[method, path, status], ...]
#   server.api("GET", "/api/v1/...", {..}, as: "hans") # raw API call (data part)
#   server.file(path) / server.storage_dir         # files the server stored

require "json"
require "net/http"
require "socket"
require "uri"

module KlangtenTest
  class Server
    ENV_DIR = "KLANGTEN_SERVER_DIR"
    ENV_PYTHON = "KLANGTEN_SERVER_PYTHON"

    class << self
      def server_dir
        ENV[ENV_DIR].to_s
      end

      def python
        ENV[ENV_PYTHON].to_s != "" ? ENV[ENV_PYTHON] : File.join(server_dir, ".venv", "bin", "python")
      end

      # nil when a server can be started, otherwise why not.
      def unavailable_reason
        return "Klango server not configured (set #{ENV_DIR} to run online tests)" if server_dir == ""
        return "Klango server not found in #{server_dir}" unless File.directory?(File.join(server_dir, "klango", "klangten"))
        return "Python for the Klango server not found (#{python})" unless File.executable?(python)
        nil
      end

      def start(dir)
        new(dir).tap(&:start)
      end
    end

    attr_reader :dir, :port, :db_path, :storage_dir

    def initialize(dir)
      @dir = dir
      FileUtils.mkdir_p(dir)
      @db_path = File.join(dir, "klangten.sqlite3")
      @storage_dir = File.join(dir, "storage")
      @log_path = File.join(dir, "server.log")
      @tokens = {}
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def env
      {
        "KLANGO_DB" => @db_path,
        "KLANGO_DOWNLOAD_DIR" => File.join(@dir, "downloads"),
        "KLANGO_STORAGE_DIR" => @storage_dir,
        "KLANGO_THEMES_DIR" => File.join(@dir, "themes"),
        "KLANGO_SECRET_KEY" => "klangten-test-secret",
        "KLANGTEN_PUBLIC_URL" => url,
        "KLANGO_BASE_URL" => url,
        "KLANGTEN_REALTIME_POLL_MS" => "50",
        "KLANGTEN_REALTIME_MAX_WAIT_MS" => "500",
        "PYTHONDONTWRITEBYTECODE" => "1",
        "PYTHONUNBUFFERED" => "1"
      }
    end

    def start
      %w[downloads storage themes].each { |d| FileUtils.mkdir_p(File.join(@dir, d)) }
      @port = free_port
      @pid = Process.spawn(env, self.class.python, "-m", "klango.klangten", "--port", @port.to_s,
                           chdir: self.class.server_dir, in: File::NULL, [:out, :err] => [@log_path, "w"])
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      until reachable?
        if Process.waitpid(@pid, Process::WNOHANG)
          raise HarnessError, "The Klango server did not start:\n#{log_tail}"
        end
        raise HarnessError, "The Klango server did not answer within 60s:\n#{log_tail}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.05)
      end
      self
    end

    def stop
      return if @pid == nil
      Process.kill("TERM", @pid) rescue nil
      Process.wait(@pid) rescue nil
      @pid = nil
    end

    # ------------------------------------------------------------ data

    # Creates accounts the way the server's own tests do (password hash,
    # terms accepted). Several names at once are cheaper (one Python start).
    def create_user(*names, password: PASSWORD, email: "", admin: false)
      script = <<~PY
        import json, sys
        from klango.klangten import create_klangten_app
        from klango import db
        args = json.loads(sys.argv[1])
        app = create_klangten_app()
        with app.app_context():
            for name in args["names"]:
                assert db.create_user(name, args["password"], args["email"]), name
                conn = db.get_db()
                conn.execute("UPDATE users SET is_admin = ?, tos_accepted = 1 WHERE klangoid = ?", (int(args["admin"]), name))
                conn.commit()
      PY
      python!(script, { names: names, password: password, email: email, admin: admin })
      names.size == 1 ? names[0] : names
    end
    alias create_users create_user

    # Runs SQL in the server database; returns the rows (arrays).
    def sql(query, *args)
      require "sqlite3"
      db = SQLite3::Database.new(@db_path)
      db.busy_timeout = 5000
      db.execute(query, args)
    ensure
      db&.close
    end

    # Raw API call with Klangten's conventions (name/token in the query, JSON
    # body for POST/PUT/PATCH). Returns the "data" part; raises on failure.
    def api(method, path, params = {}, as: nil)
      method = method.to_s.upcase
      query = {}
      query.merge!("name" => as, "token" => session_token(as)) if as
      body = nil
      if %w[GET DELETE].include?(method)
        query.merge!(params.transform_keys(&:to_s))
      else
        body = JSON.generate(params)
      end
      uri = URI(url + path)
      uri.query = URI.encode_www_form(query) unless query.empty?
      request = Net::HTTPGenericRequest.new(method, body != nil, true, uri.request_uri, "Content-Type" => "application/json")
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      payload = JSON.parse(response.body)
      raise HarnessError, "#{method} #{path} failed: #{payload.inspect}" unless payload["success"] == true
      payload["data"]
    end

    # A session for API calls made by the test itself.
    def session_token(name, password = PASSWORD)
      @tokens[name] ||= api("POST", "/api/v1/session", { "name" => name, "password" => password, "appid" => "klangten-test" })["token"]
    end

    # The key Klangten stores for "log in automatically".
    def autologin_token(name, password = PASSWORD)
      api("POST", "/api/v1/session/auto-login-token", {
        "name" => name, "password" => password, "computer" => "test", "appid" => "KlangtenTestAppId" + "0" * 47
      })["token"].to_s
    end

    # Requests the server answered so far: [[method, path, status], ...].
    def requests
      return [] unless File.file?(@log_path)
      File.readlines(@log_path).filter_map do |line|
        next unless line =~ /"([A-Z]+) (\S+) HTTP\/[\d.]+" (\d{3})/
        [$1, $2, $3.to_i]
      end
    end

    def log
      File.file?(@log_path) ? File.read(@log_path) : ""
    end

    private

    def python!(script, args)
      out = IO.popen(env, [self.class.python, "-c", script, JSON.generate(args)], chdir: self.class.server_dir, err: [:child, :out], &:read)
      raise HarnessError, "Server helper failed:\n#{out}" unless $?.success?
      out
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def reachable?
      Socket.tcp("127.0.0.1", @port, connect_timeout: 0.2).close
      true
    rescue SystemCallError, IOError, SocketError
      false
    end

    def log_tail
      log.lines.last(30).join
    end
  end
end
