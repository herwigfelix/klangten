# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Klangten: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# The exit guard (src/eapi/exit_guard.rb): the report names the threads that
# still run at exit, and off Windows nothing is armed. The Windows timer
# itself (TerminateProcess through CreateTimerQueueTimer) cannot run here.
#
#   ruby test/unit/test_exit_guard.rb

require "minitest/autorun"
require_relative "../../src/eapi/exit_guard"

class TestExitGuard < Minitest::Test
  def setup
    KlangtenExitGuard.reset
  end

  def teardown
    KlangtenExitGuard.reset
  end

  def test_report_names_other_threads_and_where_they_wait
    queue = Queue.new
    worker = Thread.new { queue.pop }
    worker.name = "spotify-wait"
    sleep 0.05 until worker.status == "sleep"
    report = KlangtenExitGuard.thread_report([Thread.current, worker], Thread.current)
    assert_equal 1, report.size
    assert_match(/\Aspotify-wait \(sleep\): /, report.first)
    assert_match(/test_exit_guard\.rb/, report.first)
  ensure
    queue << :go
    worker&.join(1)
  end

  def test_finished_threads_are_left_out
    done = Thread.new {}
    done.join
    assert_empty KlangtenExitGuard.thread_report([Thread.current, done], Thread.current)
  end

  def test_nothing_is_armed_off_windows
    KlangtenExitGuard.windows = false
    refute KlangtenExitGuard.arm(1)
    refute KlangtenExitGuard.armed?
  end
end
