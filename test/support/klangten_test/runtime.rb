# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The engine room of the test harness: virtual time, thread roles and the
# frame lockstep. Everything here runs inside the per-test child process
# (see isolation.rb) and is installed before Klangten is loaded.
#
# Thread roles
#   :scene   threads that own Klangten's interaction: the thread running
#            src/main.rb and the parallel scene threads insert_scene creates.
#            They see virtual time, and the owner's sleep advances it.
#   :ticker  service loops that sleep between rounds: the scene controller
#            ($thr2) and the notification service. They see virtual time
#            and their sleep ends at the frame where the virtual clock has
#            moved on far enough, so they run in step with the test and
#            inserting a scene or polling the server is deterministic.
#   :fg      work started by a scene thread (Tasks workers, HTTP requests).
#            While one is alive Klangten counts as busy and the virtual
#            clock stands still, so no timeout or "please wait" fires only
#            because the machine is slow.
#   :bg      long-running services (notification service, NVDA poller) and
#            everything the test itself starts. Real time, never "busy".
#
# Lockstep: a scene thread stops at the start of every loop_update (in the
# test window's begin_input_frame) until the test releases exactly one frame.

require "monitor"

module KlangtenTest
  # Virtual clock: monotonic seconds and a wall clock that starts at the real
  # time the test began (or at Runtime.wall_start) and moves with it.
  class Clock
    attr_reader :elapsed
    attr_accessor :wall_start

    MONO_BASE = 1000.0

    def initialize
      @elapsed = 0.0
      @wall_start = Time.__kt_real_now.to_f
      @lock = Mutex.new
    end

    def advance(seconds)
      @lock.synchronize { @elapsed += seconds.to_f }
    end

    def monotonic
      MONO_BASE + @elapsed
    end

    def wall
      @wall_start + @elapsed
    end
  end

  module Runtime
    STEP_TIMEOUT = 20.0 # real seconds a single frame may take

    class << self
      attr_reader :clock, :lock, :cond

      def setup
        @clock = Clock.new
        @lock = Monitor.new
        @cond = @lock.new_cond
        @waiting = {}
        @permit = nil
        @tickers = {}
        @frames = 0
        @frame_hooks = []
        @boot_thread = nil
      end

      def frames
        @frames
      end

      # ------------------------------------------------------------ roles
      def kind(thread = Thread.current)
        thread.thread_variable_get(:klangten_test_kind)
      end

      def register(thread, kind)
        thread.thread_variable_set(:klangten_test_kind, kind)
      end

      def scene_thread?(thread = Thread.current)
        kind(thread) == :scene
      end

      def child_kind(parent)
        return :bg if parent[:klangten_test_spawn_bg]
        case kind(parent)
        when :scene then :fg
        when :ticker then parent.thread_variable_get(:klangten_test_spawns) || :fg
        when :fg then :fg
        else :bg
        end
      end

      # Threads started inside the block count as background services.
      def background
        old = Thread.current[:klangten_test_spawn_bg]
        Thread.current[:klangten_test_spawn_bg] = true
        yield
      ensure
        Thread.current[:klangten_test_spawn_bg] = old
      end

      def boot_thread=(thread)
        @boot_thread = thread
        register(thread, :scene)
      end

      def boot_thread
        @boot_thread
      end

      def owner
        current = $currentthread if defined?($currentthread)
        current ||= ($mainthread if defined?($mainthread))
        current || @boot_thread
      end

      def owner?(thread = Thread.current)
        owner.equal?(thread)
      end

      def fg_threads
        Thread.list.select { |t| t.alive? && kind(t) == :fg }
      end

      def busy_threads
        fg_threads
      end

      # Marks a wait for time (delay) on a scene thread: Klangten is not
      # waiting for the user meanwhile.
      def timed_wait
        @timed_waits = @timed_waits.to_i + 1
        yield
      ensure
        @timed_waits -= 1
      end

      def timed_wait?
        @timed_waits.to_i > 0
      end

      def frozen?
        !busy_threads.empty?
      end

      # ------------------------------------------------------------ time
      def virtual_time?
        @clock != nil && (k = kind) != nil && (k == :scene || k == :ticker)
      end

      # Kernel#sleep of a harness-aware thread; nil = sleep for real.
      def virtual_sleep(seconds)
        return nil if @clock == nil
        case kind
        when :ticker
          ticker_wait(seconds)
          seconds.round
        when :scene
          if owner?
            if frozen?
              Kernel.__kt_real_sleep([seconds, 0.002].min)
            else
              @clock.advance(seconds)
              Thread.pass
            end
          else
            Kernel.__kt_real_sleep([seconds, 0.005].min)
          end
          seconds.round
        end
      end

      # ------------------------------------------------------------ lockstep
      # Called by a scene thread at the start of every frame.
      def boundary
        t = Thread.current
        return unless scene_thread?(t)
        @lock.synchronize do
          @waiting[t] = true
          @cond.broadcast
          @cond.wait_until { @permit.equal?(t) }
          @permit = nil
        end
        input = @pending_input
        @pending_input = nil
        @frame_hooks.dup.each { |hook| hook.call }
        input
      end

      def add_frame_hook(&block)
        @frame_hooks << block
        block
      end

      def remove_frame_hook(block)
        @frame_hooks.delete(block)
      end

      def waiting?(thread)
        @lock.synchronize { @waiting[thread] == true }
      end

      # Makes the calling thread a ticker. spawns: role of the threads it
      # starts (:scene for the scene controller, :fg for a service whose
      # requests the test should wait for).
      def ticker!(spawns: :fg)
        t = Thread.current
        register(t, :ticker)
        t.thread_variable_set(:klangten_test_spawns, spawns)
        @lock.synchronize do
          @tickers[t] = { state: :busy, wake: 0.0 }
          @cond.broadcast
        end
      end

      def ticker_wait(seconds)
        t = Thread.current
        @lock.synchronize do
          entry = @tickers[t]
          entry[:wake] = @clock.elapsed + seconds.to_f
          entry[:state] = :idle
          @cond.broadcast
          @cond.wait_until { entry[:state] == :go }
          entry[:state] = :busy
        end
      end

      # Lets every ticker whose sleep is over run until its next sleep.
      def run_tickers
        @lock.synchronize { @tickers.keys }.each do |t|
          entry = @tickers[t]
          10.times do
            break unless t.alive?
            wait_real(5.0, "a service loop (#{t.name || t.object_id}) to reach its sleep") { entry[:state] == :idle || !t.alive? }
            break unless t.alive? && entry[:wake] <= @clock.elapsed
            @lock.synchronize do
              entry[:state] = :go
              @cond.broadcast
            end
            wait_real(5.0, "a service loop (#{t.name || t.object_id}) to finish its round") { entry[:state] == :idle || !t.alive? }
          end
        end
      end

      # Runs one frame: tickers, then the owner of the interaction.
      # Returns false when Klangten has finished.
      def step(input = nil)
        run_tickers
        owner = wait_owner_ready
        return false if owner == nil
        @lock.synchronize do
          @pending_input = input
          @waiting.delete(owner)
          @permit = owner
          @cond.broadcast
        end
        @frames += 1
        wait_owner_ready
        true
      end

      # Waits until the thread that owns the interaction stops at a frame
      # boundary. nil when no scene thread is alive any more.
      def wait_owner_ready
        deadline = real_now + STEP_TIMEOUT
        loop do
          o = owner
          return nil if o == nil
          return o if waiting?(o)
          if !o.alive?
            return nil if @boot_thread == nil || !@boot_thread.alive?
            # The owner ended (an inserted scene closed): the scene
            # controller hands the interaction back on its next round, and
            # that round only comes when time goes on - nobody else sleeps
            # now, so let one frame pass.
            @clock.advance(KlangtenTest::App::FRAME) if @clock != nil
            run_tickers
          end
          if real_now > deadline
            raise HarnessError, "Klangten is stuck in one frame for #{STEP_TIMEOUT}s.\n#{KlangtenTest.thread_report}"
          end
          @lock.synchronize { @cond.wait(0.005) }
        end
      end

      def wait_real(seconds, what, thread = nil)
        deadline = real_now + seconds
        @lock.synchronize do
          until yield
            if real_now > deadline
              raise HarnessError, "Timed out waiting for #{what}.\n#{KlangtenTest.thread_report}"
            end
            @cond.wait(0.01)
          end
        end
      end

      def real_now
        Process.__kt_real_clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  # Readable state of every thread, for error messages.
  def self.thread_report
    Thread.list.map do |t|
      kind = Runtime.kind(t) || :unknown
      bt = Array(t.backtrace).reject { |l| l.include?("/test/support/") }.first(8)
      "-- #{kind} thread #{t.object_id} (#{t.status.inspect})\n   " + bt.join("\n   ")
    end.join("\n")
  end

  # ---------------------------------------------------------------- patches

  module ThreadTracking
    def initialize(*args, &block)
      kind = Runtime.child_kind(Thread.current)
      raise ThreadError, "must be called with a block" if block == nil
      super(*args) do |*a|
        Runtime.register(Thread.current, kind)
        block.call(*a)
      end
    end
  end
end

class << Time
  alias_method :__kt_real_now, :now

  def now(**kw)
    if KlangtenTest::Runtime.virtual_time?
      Time.at(KlangtenTest::Runtime.clock.wall, **kw)
    else
      __kt_real_now(**kw)
    end
  end
end

module Process
  class << self
    alias_method :__kt_real_clock_gettime, :clock_gettime

    VIRTUAL_CLOCKS = [Process::CLOCK_MONOTONIC, (Process::CLOCK_MONOTONIC_RAW if defined?(Process::CLOCK_MONOTONIC_RAW))].compact.freeze

    def clock_gettime(id, unit = :float_second)
      return __kt_real_clock_gettime(id, unit) unless KlangtenTest::Runtime.virtual_time?
      if VIRTUAL_CLOCKS.include?(id)
        seconds = KlangtenTest::Runtime.clock.monotonic
      elsif id == Process::CLOCK_REALTIME
        seconds = KlangtenTest::Runtime.clock.wall
      else
        return __kt_real_clock_gettime(id, unit)
      end
      case unit
      when :float_second then seconds
      when :float_millisecond then seconds * 1000.0
      when :float_microsecond then seconds * 1_000_000.0
      when :second then seconds.floor
      when :millisecond then (seconds * 1000).floor
      when :microsecond then (seconds * 1_000_000).floor
      when :nanosecond then (seconds * 1_000_000_000).floor
      else __kt_real_clock_gettime(id, unit)
      end
    end
  end
end

module Kernel
  alias_method :__kt_real_sleep, :sleep
  module_function :__kt_real_sleep

  def sleep(*args)
    if args.size == 1 && args[0].is_a?(Numeric)
      result = KlangtenTest::Runtime.virtual_sleep(args[0])
      return result if result != nil
    end
    __kt_real_sleep(*args)
  end
  private :sleep

  class << self
    def sleep(*args)
      if args.size == 1 && args[0].is_a?(Numeric)
        result = KlangtenTest::Runtime.virtual_sleep(args[0])
        return result if result != nil
      end
      __kt_real_sleep(*args)
    end
  end
end

Thread.prepend(KlangtenTest::ThreadTracking)
