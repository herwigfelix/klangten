# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Helpers for the Klangten 0.4 unit tests (mail settings, translation,
# message of the day, import from Klango): loads single source files without
# the application, a fake API client and a minimal real client for a local
# Klangten dev server.
#
# Online tests run when KLANGTEN_TEST_API points to a dev server, e.g.
#   KLANGTEN_TEST_API=http://127.0.0.1:5110 KLANGTEN_TEST_USER=ktester \
#   KLANGTEN_TEST_PASSWORD=geheim123 ruby -Itest test/test_mail_accounts.rb
# (admin tests additionally KLANGTEN_TEST_ADMIN / KLANGTEN_TEST_ADMIN_PASSWORD).

require "json"
require "net/http"
require "uri"

module K04Support
  ROOT = File.expand_path("..", __dir__)

  def self.load_source(*paths)
    paths.each { |path| require File.join(ROOT, path) }
  end

  load_source "src/eltenlink/error.rb", "src/eltenlink/client.rb"

  # Records calls and answers them from a block: ->(method, path, params) { data }.
  class FakeClient
    attr_reader :calls

    def initialize(&responder)
      @responder = responder
      @calls = []
    end

    def api_data(method, path, params = nil, timeout: nil, headers: nil, cancellation_token: nil)
      @calls << [method, path, params]
      @responder.call(method, path, params)
    end
  end

  # Speaks the Klangten API like EltenLink::Client (name and token in the
  # query, GET/DELETE parameters in the query, others as JSON) over Net::HTTP.
  class DevClient
    def self.base
      ENV["KLANGTEN_TEST_API"].to_s.chomp("/")
    end

    def self.available?
      base != ""
    end

    def self.login(name, password)
      client = new(nil, nil)
      data = client.api_data("POST", "/api/v1/session", { "name" => name, "password" => password })
      new(data["name"], data["token"])
    end

    def initialize(name, token)
      @name = name
      @token = token
    end

    def api_data(method, path, params = nil, timeout: 60, headers: nil, cancellation_token: nil)
      method = method.to_s.upcase
      query = @name ? { "name" => @name, "token" => @token } : {}
      body = nil
      if ["GET", "DELETE"].include?(method)
        query = query.merge(params || {})
      else
        body = JSON.generate(params || {})
      end
      uri = URI(self.class.base + path)
      uri.query = URI.encode_www_form(query) if !query.empty?
      request = Net::HTTPGenericRequest.new(method, body != nil, true, uri.request_uri, { "Content-Type" => "application/json" })
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, read_timeout: timeout) { |http| http.request(request) }
      payload = JSON.parse(response.body)
      unless payload["success"] == true
        error = payload["error"] || {}
        raise EltenLink::Error.new(error["message"], code: error["code"], response: payload)
      end
      payload["data"] || {}
    end
  end
end
