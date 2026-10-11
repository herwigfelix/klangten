# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# KlangtenTest::App - one real Klangten, driven by keys and listened to.
#
#   app = klangten                     # offline (FlowTest helper)
#   app.boot                           # src/main.rb: loading, login screen ...
#   app.expect("Log in")
#   app.press("down")
#   app.type("hans")
#   app.press("ctrl+t")
#
# Every press/type sets the mark: expect, expect_not, expect_sound, spoken
# and sounds look at what happened since the last key. Frames run in
# lockstep with the test (runtime.rb); time is virtual, so a test never
# waits for real seconds.

module KlangtenTest
  class App
    FRAME = 0.01 # one loop_update sleeps EltenAPI::TICK_SECONDS

    attr_reader :dir, :data_dir, :server, :events

    def initialize(dir:, server: nil, test: nil, language: "en-GB", keyboard_scheme: :windows, settings: {}, wall_start: nil)
      @dir = dir
      @test = test
      @server = server
      @events = KlangtenTest.events
      @mark = 0
      @data_dir = KlangtenTestBoot.prepare_data_dir(dir, language: language, keyboard_scheme: keyboard_scheme, settings: settings)
      KlangtenTest.load_core(dir: dir, data_dir: @data_dir, api_url: server ? server.url : "http://127.0.0.1:9")
      Runtime.clock.wall_start = wall_start.to_f if wall_start
      @thread = nil
    end

    # ------------------------------------------------------------ start

    # Starts Klangten like a user does (src/main.rb) and runs it until it
    # waits for input.
    def boot
      start_thread { load KlangtenTestBoot.main_file }
    end

    # Shortcut for feature tests: an auto-login key for `user` is stored
    # first, so Klangten logs in by itself and ends in the main window.
    # The login itself is covered by test/flows/test_login.rb.
    def boot_logged_in(user, password: KlangtenTest::PASSWORD)
      raise HarnessError, "boot_logged_in needs a server (klangten(server: server))" if @server == nil
      token = @server.autologin_token(user, password)
      write_login_data(user, token)
      boot
    end

    # Runs a block as Klangten's scene thread, after the same initialisation
    # the loading screen does - for testing one control or dialog:
    #   app.start { alert("Hello") }
    def start(&block)
      raise ArgumentError, "block required" if block == nil
      start_thread do
        Object.send(:include, EltenAPI)
        KlangtenTest.minimal_init
        @result = block.call
      end
    end

    attr_reader :result

    def finished?
      @thread != nil && !@thread.alive?
    end

    # ------------------------------------------------------------ input

    # Presses keys one after another like a person does: a frame with the
    # key going down, one frame held, a frame with it released, then settle
    # (unless settle: false). Some shortcuts need the held frame - the
    # menu bar opens only when Alt was seen held before its release.
    def press(*keys, settle: true)
      keys.each do |spec|
        key = Keys.parse(spec)
        @mark = @events.size
        downs = key.mods.map { |m| [m, true] } + [[key.code, true]]
        chars = key.text != "" ? [[key.code, key.text]] : []
        step_input(events: downs, chars: chars)
        step_input(events: [])
        step_input(events: [[key.code, false]] + key.mods.reverse.map { |m| [m, false] })
        self.settle if settle
      end
      self
    end

    # Types text character by character (key event plus the character).
    def type(text, settle: true)
      text.to_s.each_char do |char|
        @mark = @events.size
        vk, shifted = Keys.for_char(char)
        downs = []
        downs << [0x10, true] if shifted
        downs << [vk, true] if vk
        step_input(events: downs, chars: [[vk, char]])
        ups = []
        ups << [vk, false] if vk
        ups << [0x10, false] if shifted
        step_input(events: ups)
        settle_quietly(0.05)
      end
      self.settle if settle
      self
    end

    def hold(spec)
      key = Keys.parse(spec)
      downs = key.mods.map { |m| [m, true] } + [[key.code, true]]
      step_input(events: downs, chars: key.text != "" ? [[key.code, key.text]] : [])
      self
    end

    def release(spec, settle: true)
      key = Keys.parse(spec)
      step_input(events: [[key.code, false]] + key.mods.reverse.map { |m| [m, false] })
      self.settle if settle
      self
    end

    # Close button / Alt+F4 of the window.
    def close_window
      step_input(close: true)
      settle
      self
    end

    # Opens the menu bar with Alt and walks a path of menu items, the way a
    # user does: on each level move on until the name has been heard, then
    # open it; the last item is activated with Enter.
    #   app.menu("Community", "Forum")
    def menu(*path, max_steps: 30)
      press("alt")
      path.each_with_index do |name, depth|
        found = false
        max_steps.times do
          if spoken.first(2).any? { |s| s.downcase.start_with?(name.downcase) }
            found = true
            break
          end
          press(depth == 0 ? "right" : "down")
        end
        raise HarnessError, "Menu item #{name.inspect} not found.\n#{transcript(last: 25)}" unless found
        press(depth == path.size - 1 ? "enter" : (depth == 0 ? "down" : "right"))
      end
      self
    end

    # Presses `key` (Tab by default) until `name` is heard (substring,
    # case-insensitive; what the last key already said counts) - the way a
    # user moves to a button or a list entry.
    #   app.move_to("Send")            app.move_to("Hallo Welt", key: "down")
    def move_to(name, key: "tab", max_steps: 40)
      return self if heard?(name)
      max_steps.times do
        press(key)
        return self if heard?(name)
      end
      raise HarnessError, "#{name.inspect} not reached with #{key}.\n#{transcript(last: 25)}"
    end

    # ------------------------------------------------------------ time

    def step(frames = 1)
      frames.times do
        break unless Runtime.step(nil)
      end
      raise_if_crashed
      self
    end

    def run_for(seconds)
      target = Runtime.clock.elapsed + seconds
      deadline = Runtime.real_now + 60
      while Runtime.clock.elapsed < target
        break unless Runtime.step(nil)
        raise_if_crashed
        raise HarnessError, "run_for(#{seconds}) did not finish within 60 real seconds.\n#{busy_report}" if Runtime.real_now > deadline
      end
      self
    end

    # Runs until Klangten is quiet and waits for input: nothing is spoken or
    # playing, no work started by the interface is running, and nothing new
    # was heard for `quiet` virtual seconds. timeout is in virtual seconds.
    def settle(quiet: 0.3, timeout: 120)
      start = Runtime.clock.elapsed
      calm_since = start
      last = @events.size
      deadline = Runtime.real_now + 60
      loop do
        return self if finished? && (raise_if_crashed || true)
        break unless Runtime.step(nil)
        raise_if_crashed
        now = Runtime.clock.elapsed
        if @events.size != last || busy_in_virtual_time?
          last = @events.size
          calm_since = now
        elsif now - calm_since >= quiet && !working?
          # Work in progress (requests, tasks) stops the virtual clock, so it
          # neither counts as quiet time nor restarts it - how long it takes
          # in real time cannot change what the test hears.
          return self
        end
        if now - start > timeout || Runtime.real_now > deadline
          raise HarnessError, "Klangten does not settle (#{(now - start).round(1)}s virtual).\nLast heard:\n#{transcript(last: 20)}\n#{busy_report}"
        end
      end
      raise_if_crashed
      self
    end

    def wait_until(timeout: 30)
      start = Runtime.clock.elapsed
      deadline = Runtime.real_now + 60
      until yield
        raise HarnessError, "Condition not met after #{timeout}s.\n#{transcript(last: 15)}" if Runtime.clock.elapsed - start > timeout || Runtime.real_now > deadline
        break unless Runtime.step(nil)
        raise_if_crashed
      end
      raise HarnessError, "Condition not met (Klangten finished).\n#{transcript(last: 15)}" unless yield
      self
    end

    def wait_for(text, timeout: 30)
      wait_until(timeout: timeout) { heard?(text) }
    end

    # Runs a block on Klangten's scene thread at the start of the next frame
    # (for entry points without a key). It may open dialogs; drive them with
    # keys afterwards. Returns the block's value if it has finished.
    def call(settle: true, &block)
      box = {}
      hook = Runtime.add_frame_hook do
        if Runtime.owner?
          Runtime.remove_frame_hook(hook)
          box[:ran] = true
          box[:value] = block.call
        end
      end
      @mark = @events.size
      500.times do
        break if box[:ran]
        step
      end
      self.settle if settle
      box[:value]
    end

    # ------------------------------------------------------------ output

    def mark
      @mark = @events.size
    end

    def spoken(since: nil)
      select_events(:speak, since)
    end

    def sounds(since: nil)
      select_events(:sound, since)
    end

    def all_spoken
      spoken(since: 0)
    end

    def last_spoken
      ev = @events.reverse.find { |e| e[:kind] == :speak }
      ev ? ev[:value] : ""
    end

    def heard?(text, since: nil)
      low = text.downcase
      spoken(since: since).any? { |s| s.downcase.include?(low) }
    end

    def expect(text, since: nil)
      count_assertion
      return self if heard?(text, since: since)
      heard = spoken(since: since)
      raise HarnessError, "Expected to hear #{text.inspect}. Heard since the mark:\n" + (heard.empty? ? "  (nothing)" : heard.map { |s| "  #{s}" }.join("\n"))
    end

    def expect_not(text, since: nil)
      count_assertion
      return self unless heard?(text, since: since)
      raise HarnessError, "Did NOT expect to hear #{text.inspect}, but did:\n#{transcript(last: 15)}"
    end

    def expect_sound(name, since: nil)
      count_assertion
      return self if sounds(since: since).include?(name)
      raise HarnessError, "Expected sound #{name.inspect}, heard: #{sounds(since: since).inspect}"
    end

    # Readable transcript with virtual timestamps.
    def transcript(last: nil)
      rows = last ? @events.last(last) : @events
      rows.map do |e|
        prefix = { speak: "»", sound: "♪" }[e[:kind]] || "[#{e[:kind]}]"
        text = e[:value].to_s.split.join(" ")
        text = text[0, 157] + "..." if text.length > 160
        format("%7.2fs %s %s", e[:time], prefix, text)
      end.join("\n")
    end

    def clipboard
      Clipboard
    end

    def opened_urls
      select_events(:open_url, 0)
    end

    def message_boxes
      EltenWindow.message_boxes
    end

    def microphone
      Microphone
    end

    def opus_encoders
      Microphone.opus_encoders
    end

    # Binary uploads to the API, byte for byte (hooks.rb).
    def uploads
      KlangtenTest.uploads
    end

    def blocked_connections
      NetGuard.blocked
    end

    def scene
      $scene
    end

    def log
      path = File.join(@data_dir, "klangten.log")
      File.file?(path) ? File.binread(path).force_encoding("UTF-8").scrub : ""
    end

    def now
      Runtime.clock.elapsed
    end

    # ------------------------------------------------------------ internals

    def busy?
      working? || busy_in_virtual_time?
    end

    # Something is running in virtual time: speech, a delay().
    def busy_in_virtual_time?
      KlangtenTestSpeech.speaking? || Runtime.timed_wait?
    end

    # Work started by the interface is running (the clock stands still).
    def working?
      !Runtime.busy_threads.empty?
    end

    def busy_report
      lines = ["Busy because:"]
      lines << "  speech is still speaking" if KlangtenTestSpeech.speaking?
      lines << "  a delay() is running" if Runtime.timed_wait?
      Runtime.busy_threads.each do |t|
        bt = Array(t.backtrace).reject { |l| l.include?("/test/support/") }.first(6)
        lines << "  work thread #{t.object_id}:\n      " + bt.join("\n      ")
      end
      lines << "  (nothing - Klangten produced output until the deadline)" if lines.size == 1
      lines.join("\n")
    end

    private

    def start_thread(&block)
      raise HarnessError, "Klangten is already running" if @thread != nil
      @thread = Thread.new do
        Runtime.boot_thread = Thread.current
        begin
          block.call
        rescue SystemExit
        rescue Exception => e
          @crash = e
        end
      end
      Runtime.boot_thread = @thread
      Runtime.wait_owner_ready
      raise_if_crashed
      settle
    end

    def step_input(input)
      Runtime.step(input)
      raise_if_crashed
    end

    def settle_quietly(quiet)
      settle(quiet: quiet)
    end

    def count_assertion
      @test.assertions += 1 if @test
    end

    def raise_if_crashed
      return nil if @crash == nil
      e = @crash
      @crash = nil
      raise HarnessError, "Klangten crashed: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(15).join("\n  ")}\n--- last heard:\n#{transcript(last: 15)}"
    end

    def select_events(kind, since)
      start = since || @mark
      @events[start..].to_a.select { |e| e[:kind] == kind }.map { |e| e[:value].to_s }
    end

    def write_login_data(user, token)
      Dirs.eltendata = @data_dir
      Scene_Login.new.write_logindata(3, user, token, 0)
    end
  end
end
