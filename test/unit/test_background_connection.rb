# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Klangten: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# Android's background connection (src/eapi/background_connection.rb): when
# the foreground service starts and stops, and when a notification goes to
# the system instead of being spoken. A double stands in for the Android
# host; no device, no network, virtual time.
#
#   ruby test/unit/test_background_connection.rb

require "minitest/autorun"
require_relative "../../src/eapi/background_connection"

class FakeAndroidHost
  attr_reader :calls, :posted
  attr_accessor :start_ok, :may_post, :exempt

  def initialize
    @calls = []
    @posted = []
    @start_ok = true
    @may_post = true
    @exempt = false
  end

  def connection_service(text, on)
    @calls << [:service, on, text]
    on ? @start_ok : true
  end

  def post_notification(title, text)
    @posted << [title, text]
    @may_post
  end

  def request_notification_permission(_timeout)
    @calls << [:notifications_permission]
    true
  end

  def battery_exempt?
    @exempt
  end

  def battery_exemption(_request = true)
    @calls << [:battery_question]
    true
  end
end

class TestBackgroundConnection < Minitest::Test
  BC = KlangtenBackgroundConnection

  def setup
    BC.reset
    @host = FakeAndroidHost.new
    @time = 100.0
    @settings = {}
    @spoken = []
    settings = @settings
    spoken = @spoken
    BC.bridge = @host
    BC.android = true
    BC.foreground = true
    BC.clock = -> { @time }
    BC.define_singleton_method(:read_setting) { |key, default| settings.fetch(key, default) }
    BC.define_singleton_method(:write_setting) { |key, value| settings[key] = value }
    BC.define_singleton_method(:say) { |text| spoken << text }
  end

  def teardown
    BC.asking&.join(1)
    %i[read_setting write_setting say].each { |m| BC.singleton_class.send(:remove_method, m) }
    BC.reset
  end

  def service_calls
    @host.calls.select { |c| c[0] == :service }.map { |c| c[1] }
  end

  def test_starts_once_when_signed_in_and_stops_on_sign_out
    BC.tick(logged_in: false)
    assert_empty service_calls
    BC.tick(logged_in: true)
    BC.tick(logged_in: true)
    assert_equal [true], service_calls
    assert BC.running?
    BC.tick(logged_in: false)
    assert_equal [true, false], service_calls
    refute BC.running?
  end

  def test_nothing_happens_off_android
    BC.android = false
    BC.tick(logged_in: true)
    assert_empty @host.calls
    BC.foreground = false
    refute BC.deliver("alert" => "New message from Ben")
    assert_empty @host.posted
  end

  def test_setting_off_stops_the_service
    BC.tick(logged_in: true)
    @settings["BackgroundConnection"] = "false"
    @time += 3                                   # the setting is re-read every 2 s
    BC.tick(logged_in: true)
    assert_equal [true, false], service_calls
    BC.foreground = false
    refute BC.deliver("alert" => "x")
  end

  def test_waits_until_klangten_is_in_front_to_start
    BC.foreground = false
    BC.tick(logged_in: true)
    assert_empty service_calls                   # Android forbids it from the background
    BC.foreground = true
    BC.tick(logged_in: true)
    assert_equal [true], service_calls
  end

  def test_refused_start_is_retried_later_not_every_frame
    @host.start_ok = false
    BC.tick(logged_in: true)
    BC.tick(logged_in: true)
    assert_equal [true], service_calls
    @time += 31
    @host.start_ok = true
    BC.tick(logged_in: true)
    assert_equal [true, true], service_calls
    assert BC.running?
  end

  def test_in_the_background_notifications_go_to_android
    BC.tick(logged_in: true)
    BC.foreground = false
    assert BC.deliver("alert" => "New message from Ben", "sound" => "message")
    assert_equal [["Klangten", "New message from Ben"]], @host.posted
  end

  def test_in_front_klangten_announces_itself
    BC.tick(logged_in: true)
    refute BC.deliver("alert" => "New message from Ben")
    assert_empty @host.posted
  end

  def test_without_permission_klangten_still_announces
    BC.foreground = false
    @host.may_post = false
    refute BC.deliver("alert" => "New message from Ben")
    refute BC.deliver("sound" => "message")      # nothing to show: no notification
  end

  def test_asks_both_questions_once_per_installation
    BC.tick(logged_in: true)
    BC.asking.join(1)
    assert_includes @host.calls, [:notifications_permission]
    assert_includes @host.calls, [:battery_question]
    assert_equal 1, @spoken.size
    assert_equal "true", @settings["BackgroundConnectionAsked"]
    BC.tick(logged_in: false)
    BC.tick(logged_in: true)
    assert_equal 1, @host.calls.count { |c| c == [:battery_question] }
    assert_equal 1, @spoken.size
  end

  def test_battery_question_skipped_when_already_exempt
    @host.exempt = true
    BC.tick(logged_in: true)
    BC.asking.join(1)
    refute_includes @host.calls, [:battery_question]
  end
end
