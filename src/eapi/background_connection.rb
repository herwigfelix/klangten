# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Klangten: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# Android: Klangten stays connected in the background - push without Google.
#
# Android 15 and newer cut the network of an app in the background and freeze
# its process. A foreground service (android/.../ConnectionService.java, type
# remote messaging, a silent permanent notification) keeps both alive, so the
# notification service (src/eapi/notifications.rb) keeps its long poll to the
# Klango server open. What arrives while Klangten is not in front becomes a
# system notification, which TalkBack reads; in front Klangten announces it
# itself, as before.
#
# The service runs while someone is signed in and the setting "Stay connected
# in the background" (System/BackgroundConnection, on by default) is on. It
# can only be started while Klangten is in front (Android 12 and newer), so
# #tick tries again whenever it is. Once per installation Klangten asks for
# the permission to post notifications (Android 13 and newer) and for the
# exemption from battery optimisation (otherwise the network still sleeps in
# Doze).
#
# Everything is a no-op off Android. The host is IOSHostBridge (the Android
# host exports the same elten_host_* functions as the iOS one); tests put a
# double in `bridge`.
module KlangtenBackgroundConnection
  CONFIG_SECTION = "System".freeze
  CONFIG_KEY = "BackgroundConnection".freeze
  ASKED_KEY = "BackgroundConnectionAsked".freeze
  RETRY_SECONDS = 30.0

  class << self
    attr_writer :bridge, :android, :foreground, :clock

    def reset
      @bridge = @android = @foreground = @clock = nil
      @wanted = nil
      @running = false
      @next_try = 0.0
      @asking = nil
      @enabled = nil
      @enabled_at = nil
    end

    def android?
      return @android unless @android == nil
      defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:android?) && EltenSystemHelpers.android? ? true : false
    rescue Exception
      false
    end

    def bridge
      return @bridge if @bridge != nil
      defined?(IOSHostBridge) ? IOSHostBridge : nil
    end

    def foreground?
      return @foreground unless @foreground == nil
      return IOSWindowNative.active? if defined?(IOSWindowNative) && IOSWindowNative.respond_to?(:active?)
      true
    rescue Exception
      true
    end

    # Read from the configuration at most every 2 s (tick runs every frame).
    def enabled?
      now = monotonic
      if @enabled == nil || now >= (@enabled_at || 0.0) + 2.0
        @enabled = read_setting(CONFIG_KEY, "true").to_s != "false"
        @enabled_at = now
      end
      @enabled
    end

    def running?
      @running == true
    end

    # Called from loop_update on the main thread: starts or stops the service
    # to match the setting and the sign-in.
    def tick(logged_in: (defined?(Session) && Session.respond_to?(:logged?) && Session.logged?))
      return unless android?
      b = bridge
      return if b == nil
      wanted = enabled? && logged_in == true
      now = monotonic
      if !wanted
        if @running || @wanted
          b.connection_service("", false)
          log(:info, "Background connection stopped")
        end
        @running = false
        @wanted = false
        return
      end
      @wanted = true
      return if @running
      # Android only lets an app in front start the service.
      return unless foreground?
      return if now < (@next_try || 0.0)
      if b.connection_service(service_text, true)
        @running = true
        log(:info, "Background connection started")
        ask_once
      else
        @next_try = now + RETRY_SECONDS
        log(:warning, "Background connection could not be started")
      end
    rescue Exception => e
      log(:error, "Background connection: #{e.class}: #{e.message}")
    end

    # From dispatch_notification: true when the notification was handed to
    # Android (Klangten is in the background), so Klangten neither speaks it
    # nor plays its sound.
    def deliver(event)
      return false unless android? && enabled? && !foreground?
      text = event.is_a?(Hash) ? event["alert"].to_s.strip : ""
      return false if text == ""
      b = bridge
      return false if b == nil
      b.post_notification("Klangten", text)
    rescue Exception => e
      log(:error, "Background notification: #{e.class}: #{e.message}")
      false
    end

    def service_text
      tr("Connected. New messages and notifications arrive in the background.")
    end

    # Seams for the tests (test/unit/test_background_connection.rb).
    def read_setting(key, default)
      readconfig(CONFIG_SECTION, key, default)
    rescue Exception
      default
    end

    def write_setting(key, value)
      writeconfig(CONFIG_SECTION, key, value)
    rescue Exception
      nil
    end

    def say(text)
      speak(text)
    rescue Exception
      nil
    end

    def tr(text)
      respond_to?(:p_, true) ? p_("Klangten", text) : text
    rescue Exception
      text
    end

    # Once per installation, after the service runs for the first time: the
    # two system questions, announced first so that they do not come out of
    # nowhere. In a thread: the permission request waits for the answer.
    def ask_once
      return if read_setting(ASKED_KEY, "false").to_s == "true"
      write_setting(ASKED_KEY, "true")
      b = bridge
      say(tr("So that Klangten can tell you about new messages while it is in the background, Android now asks whether Klangten may show notifications and may run without battery optimisation. Please allow both."))
      @asking = Thread.new do
        begin
          b.request_notification_permission(120)
          b.battery_exemption(true) unless b.battery_exempt?
        rescue Exception => e
          log(:warning, "Background connection questions: #{e.class}: #{e.message}")
        end
      end
    end

    attr_reader :asking

    def log(level, text)
      return unless defined?(::Log) && ::Log.respond_to?(level)
      ::Log.public_send(level, text)
    rescue Exception
      nil
    end

    def monotonic
      return @clock.call if @clock != nil
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  reset
end
