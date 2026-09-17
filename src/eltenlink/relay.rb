# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: the EltenLink program relay protocol was removed, the Klango server has no relay.
# frozen_string_literal: true

# Interface of Elten's program relay (live sessions of hosted programs,
# EltenAPI::Communication). The Klango server does not run a relay, so the
# protocol implementation was removed. The constants and error classes stay,
# because src/eapi/communication.rb uses them; every connection attempt fails
# with ConnectionError, which programs receive as "connection failed".

module EltenLink
  module Relay
    DEFAULT_HOST = Klangten::Config.relay_host
    DEFAULT_PORT = Klangten::Config.relay_port
    VERSION = 1
    MAX_FRAME = 128 * 1024
    MAX_RELIABLE_DATA = 64 * 1024
    MAX_UNRELIABLE_DATA = 1200
    MAX_DATAGRAM = 1400
    MAX_PARTICIPANTS = 32
    FEATURES = [].freeze
    DEFAULT_LIMITS = {
      max_frame: MAX_FRAME,
      max_reliable_data: MAX_RELIABLE_DATA,
      max_unreliable_data: MAX_UNRELIABLE_DATA,
      max_datagram: MAX_DATAGRAM,
      max_metadata: 8 * 1024,
      max_participants: MAX_PARTICIPANTS,
      fast_path_timeout: 12.0,
      session_timeout: 20.0,
      ping_interval: 5.0
    }.freeze
    MAGIC = "ELR1".b

    DATAGRAM_REGISTER = 1
    DATAGRAM_REGISTERED = 2
    DATAGRAM_MESSAGE = 3
    DATAGRAM_FORWARDED = 4
    DATAGRAM_PING = 5
    DATAGRAM_PONG = 6
    DATAGRAM_READY = 7

    class Error < StandardError; end
    class ConnectionError < Error; end
    class AuthenticationError < Error; end
    class TimeoutError < Error; end
    class MessageTooLarge < Error; end

    class RemoteError < Error
      attr_reader :code

      def initialize(code, message = nil)
        @code = code.to_s
        super(message.to_s.empty? ? @code.tr("_", " ") : message.to_s)
      end
    end

    class Client
      def initialize(**_options)
        raise ConnectionError, "Live sessions of programs are not available: the Klango server has no program relay"
      end
    end
  end
end
