# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# KlangtenTest - runs the real Klangten without a window, without sound and
# without waiting, and checks what a user would have heard. See
# docs/testing.md for the guide; the pieces:
#
#   isolation.rb   every test runs in a fresh Ruby process of its own
#   boot.rb        loads the core through elten.rb, platform doubles swapped in
#   runtime.rb     virtual time, thread roles, frame lockstep
#   platform/      window/keyboard, speech, clipboard, system doubles
#   hooks.rb       transcript of theme sounds, scene controller, BASS
#   app.rb         KlangtenTest::App - press, type, expect, settle ...
#   server.rb      the real Klango server as a subprocess (optional)
#   fake_web.rb    a tiny local web server for media and HTTP tests
#   microphone.rb  generated signal instead of a microphone
#   media.rb       helpers to inspect audio files (Ogg Opus)

require "minitest"
require "rbconfig"
require "tmpdir"
require "fileutils"

module KlangtenTest
  PASSWORD = "geheim123"

  # A failed expectation or a stuck/crashed Klangten; the message carries
  # the last things heard.
  class HarnessError < Minitest::Assertion
  end
  SUPPORT = File.join(__dir__, "klangten_test")

  class << self
    def child?
      ENV["KLANGTEN_TEST_CHILD"] == "1"
    end

    # ------------------------------------------------------------ transcript
    def events
      @events ||= []
    end

    def uploads
      @uploads ||= []
    end

    def record(kind, value, **info)
      @record_lock ||= Mutex.new
      @record_lock.synchronize do
        time = defined?(Runtime) && Runtime.clock ? Runtime.clock.elapsed : 0.0
        frame = defined?(Runtime) ? Runtime.frames.to_i : 0
        events << { kind: kind, value: value, time: time, frame: frame, info: info }
      end
      nil
    end

    # ------------------------------------------------------------ core
    def core_loaded?
      @core_loaded == true
    end

    # Loads Klangten into this (child) process. Only once per process: one
    # test, one Klangten.
    def load_core(dir:, data_dir:, api_url:)
      raise HarnessError, "Only one Klangten per test" if core_loaded?
      KlangtenTestBoot.environment(dir, api_url).each { |k, v| ENV[k] = v }
      NetGuard.install
      Runtime.setup
      KlangtenTestBoot.load_core(data_dir)
      # src/main.rb does the same first thing; done here already so the
      # harness can reach Dirs, Configuration ... before Klangten starts.
      Object.send(:include, EltenAPI)
      Hooks.install
      @core_loaded = true
    end

    # What the loading screen sets up before any scene can run; used by
    # App#start (a block instead of src/main.rb).
    def minimal_init
      $mainthread = Thread.current
      $currentthread = $mainthread
      $scenes = []
      Dirs.eltendata = EltenBoot.early_datadir
      Dirs.appsdata = EltenPath.join(Dirs.eltendata, "apps")
      Dirs.apps = EltenPath.join(Dirs.appsdata, "src")
      Dirs.extras = EltenPath.join(Dirs.eltendata, "extras")
      Dirs.soundthemes = EltenPath.join(Dirs.eltendata, "soundthemes")
      Dirs.temp = EltenPath.join(Dirs.tmp, Klangten::Config::TEMP_DIR_NAME)
      [Dirs.appsdata, Dirs.apps, Dirs.extras, Dirs.soundthemes, Dirs.temp].each { |d| FileUtils.mkdir_p(d) }
      $wnd = EltenWindow.ensure_window
      use_soundtheme("data/audio.elsnd", true)
      loadlocaledata
      load_configuration
      Bass.init($wnd)
      setlocale(Configuration.language)
      SpeechOutput.apply_current_settings
      $thr2 = Thread.new { thr2 } if $thr2 == nil
      true
    end

    def cleanup
      @servers&.each(&:stop)
      @webs&.each(&:stop)
    end

    def track_server(server)
      (@servers ||= []) << server
      server
    end

    def track_web(web)
      (@webs ||= []) << web
      web
    end
  end

  # Base class of all flow tests: each test method runs in a process of its
  # own (isolation.rb), with an empty data directory.
  class FlowTest < Minitest::Test
    parallelize_me!

    # A Klangten for this test. With server: it talks to that server,
    # otherwise the network is closed.
    def klangten(server: nil, **options)
      @klangten ||= App.new(dir: File.join(work_dir, "client"), server: server, test: self, **options)
    end

    # The real Klango server for this test (fresh database); the test is
    # skipped where it is not available (public CI).
    def server
      @server ||= begin
        reason = Server.unavailable_reason
        skip(reason) if reason
        KlangtenTest.track_server(Server.start(File.join(work_dir, "server")))
      end
    end

    def work_dir
      ENV.fetch("KLANGTEN_TEST_DIR")
    end

    def run
      return super if KlangtenTest.child?
      Isolation.run_in_child(self)
    end
  end
end

require_relative "klangten_test/boot"
require_relative "klangten_test/isolation"
require_relative "klangten_test/server"
if KlangtenTest.child?
  require_relative "klangten_test/runtime"
  require_relative "klangten_test/keys"
  require_relative "klangten_test/net_guard"
  require_relative "klangten_test/hooks"
  require_relative "klangten_test/app"
  require_relative "klangten_test/fake_web"
  require_relative "klangten_test/media"
end
