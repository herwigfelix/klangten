# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# No test ever reaches the internet. Every TCP connection the test process
# opens through Ruby (Net::HTTP, Klangten's own HTTP client, Mastodon, the
# GitHub update check) must go to the loopback interface - the test server or
# FakeWeb. Anything else fails at once, as an unreachable network would, and
# is listed in app.blocked_connections. BASS URL streams are checked by the
# same rule (hooks.rb).

require "socket"
require "uri"

module KlangtenTest
  module NetGuard
    LOOPBACK = ["127.0.0.1", "::1", "localhost"].freeze

    class Blocked < SocketError
    end

    class << self
      def blocked
        @blocked ||= []
      end

      def allowed?(host)
        host = host.to_s.delete_prefix("[").delete_suffix("]")
        LOOPBACK.include?(host.downcase) || host.start_with?("127.")
      end

      def check!(host, port = nil)
        return true if allowed?(host)
        blocked << "#{host}:#{port}"
        raise Blocked, "Test harness: network blocked (#{host}:#{port}) - only the test server and FakeWeb are reachable"
      end

      def check_url!(url)
        uri = URI.parse(url.to_s) rescue nil
        return true if uri == nil || uri.host == nil
        check!(uri.host, uri.port)
      end

      def install
        return if @installed
        @installed = true
        TCPSocket.prepend(TCPSocketGuard)
        Socket.singleton_class.prepend(SocketGuard)
        Addrinfo.singleton_class.prepend(AddrinfoGuard)
      end
    end

    module TCPSocketGuard
      def initialize(host = nil, port = nil, *args, **kw)
        NetGuard.check!(host, port)
        super
      end
    end

    module SocketGuard
      def tcp(host, port, *args, **kw, &block)
        NetGuard.check!(host, port)
        super
      end
    end

    module AddrinfoGuard
      def getaddrinfo(host, *args, **kw)
        NetGuard.check!(host) if host != nil
        super
      end
    end
  end
end
