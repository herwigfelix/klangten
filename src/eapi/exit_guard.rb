# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Klangten: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# Klangten must end when it is closed. On Windows it sometimes stayed for
# days after "Exiting Elten" - visible in the Task Manager and, with its
# sound device still open, in the volume mixer. Ruby's own cleanup waits for
# every thread, and a thread inside a native call (sound engine, Spotify,
# conferences, NVDA pipe ...) cannot be interrupted, so the wait never ends.
#
# Two things, from src/main.rb when Klangten begins to shut down:
# - arm: a timer of the system's thread pool calls TerminateProcess on
#   Klangten itself after `seconds`, unless the process has ended by then.
#   It runs outside Ruby, so a stuck Ruby cleanup cannot hold it up.
#   (CreateTimerQueueTimer calls Callback(Parameter, TimerOrWaitFired); with
#   TerminateProcess as the callback and the pseudo handle of the current
#   process as the parameter that is TerminateProcess(self, 1). Both are
#   WINAPI functions with two arguments, on x86 and x64.)
# - log_threads: which threads are still running and where, so the log names
#   the culprit the next time.
module KlangtenExitGuard
  DEFAULT_SECONDS = 20
  CURRENT_PROCESS = -1            # GetCurrentProcess() pseudo handle
  WT_EXECUTEONLYONCE = 0x00000008

  class << self
    attr_reader :armed_at

    def armed?
      @armed == true
    end

    def arm(seconds = DEFAULT_SECONDS)
      return true if @armed
      return false unless windows?
      require "fiddle"
      kernel32 = Fiddle.dlopen("kernel32.dll")
      abi = defined?(Fiddle::Function::STDCALL) ? Fiddle::Function::STDCALL : Fiddle::Function::DEFAULT
      create = Fiddle::Function.new(kernel32["CreateTimerQueueTimer"],
                                    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                     Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT],
                                    Fiddle::TYPE_INT, abi)
      handle = ("\0" * Fiddle::SIZEOF_VOIDP).b
      ok = create.call(handle, nil, kernel32["TerminateProcess"], CURRENT_PROCESS,
                       (seconds.to_f * 1000).to_i, 0, WT_EXECUTEONLYONCE)
      @armed = ok.to_i != 0
      @armed_at = Time.now if @armed
      log(@armed ? :info : :warning,
          @armed ? "Exit guard armed: Klangten ends at the latest in #{seconds} s" : "Exit guard could not be armed")
      @armed
    rescue Exception => e
      log(:warning, "Exit guard: #{e.class}: #{e.message}")
      false
    end

    # Lines naming the threads besides the current one, with where they are.
    def thread_report(threads = Thread.list, current = Thread.current)
      threads.reject { |t| t == current || !t.alive? }.map do |t|
        where = Array(t.backtrace).first(4).map { |line| line.to_s.sub(/\A.*?(src\/|elten\.rb)/, '\1') }
        name = t.name.to_s == "" ? "thread #{t.object_id}" : t.name
        "#{name} (#{t.status}): #{where.empty? ? "-" : where.join(" < ")}"
      end
    end

    def log_threads
      report = thread_report
      return if report.empty?
      log(:info, "Threads still running at exit (#{report.size}):")
      report.each { |line| log(:info, "  " + line) }
    rescue Exception => e
      log(:warning, "Exit guard thread report: #{e.class}: #{e.message}")
    end

    def windows?
      return @windows unless @windows == nil
      defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) ? EltenBoot.platform?(:windows) == true : !!(RUBY_PLATFORM =~ /mswin|mingw|cygwin/i)
    rescue Exception
      false
    end
    attr_writer :windows

    def reset
      @armed = false
      @armed_at = nil
      @windows = nil
    end

    private

    def log(level, text)
      return unless defined?(::Log) && ::Log.respond_to?(level)
      ::Log.public_send(level, text)
    rescue Exception
      nil
    end
  end
end
