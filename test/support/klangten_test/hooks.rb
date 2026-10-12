# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Hooks around the loaded core. Each one wraps a single entry point and
# calls the original - Klangten's own logic is never copied here. When one of
# the wrapped methods is renamed, KlangtenTest::Hooks.install fails loudly
# instead of silently testing something else.

module KlangtenTest
  module Hooks
    module_function

    def install
      wrap_play_sound
      wrap_timed_waits
      wrap_scene_controller
      wrap_background_services
      record_uploads
      route_audio_to_no_sound_device
      forbid_real_audio_devices
      require_relative "microphone"
      Microphone.install
    end

    def wrap(owner, name, &replacement)
      raise HarnessError, "#{owner}##{name} is gone - update test/support/klangten_test/hooks.rb" unless owner.method_defined?(name) || owner.private_method_defined?(name)
      original = owner.instance_method(name)
      visibility = owner.private_method_defined?(name) ? :private : :public
      owner.send(:define_method, name) do |*args, **kw, &block|
        replacement.call(original.bind(self), *args, **kw, &block)
      end
      owner.send(visibility, name)
    end

    # Theme sounds go into the transcript under their theme name, together
    # with their length, so settle can wait until they have finished.
    def wrap_play_sound
      wrap(EltenAPI::UI, :play_sound) do |original, voice, **kw|
        audible = Configuration.soundthemeactivation == true || kw[:ignore_soundtheme] == true || (voice.is_a?(String) && FileTest.exists?(voice))
        KlangtenTest.record(:sound, voice.to_s) if audible
        original.call(voice, **kw)
      end
    end

    # delay() waits for time, not for the user: busy while it runs.
    def wrap_timed_waits
      [:delay, :delay_precise].each do |name|
        wrap(EltenAPI, name) do |original, *args, **kw, &block|
          Runtime.timed_wait { original.call(*args, **kw, &block) }
        end
      end
    end

    # $thr2 inserts scenes; it runs in step with the test (Runtime :ticker).
    # $thr1 only polls NVDA and stays in real time.
    def wrap_scene_controller
      wrap(EltenAPI::Common, :thr2) do |original|
        Runtime.ticker!(spawns: :scene)
        original.call
      end
      # The notification service polls the server in virtual time; the
      # requests it sends count as work the test waits for.
      wrap(EltenAPI::NotificationService.singleton_class, :worker_loop) do |original|
        Runtime.ticker!(spawns: :fg)
        original.call
      end
      wrap(EltenAPI::Common, :thr1) do |original|
        Runtime.register(Thread.current, :bg)
        original.call
      end
    end

    # Long-running services (the notification service, workers of loaded
    # programs such as MCP, the conference worker) are background threads, not work the test has to
    # wait for.
    def wrap_background_services
      [[EltenAPI::NotificationService.singleton_class, :start], [Programs.singleton_class, :load_all],
       [TeamConference::Client, :ensure_thread]].each do |owner, name|
        wrap(owner, name) do |original, *args, **kw, &block|
          Runtime.background { original.call(*args, **kw, &block) }
        end
      end
      # The conference library connects by itself, past Ruby's sockets.
      wrap(TeamConference::Library, :connect) do |original, host, *args|
        NetGuard.allowed?(host) ? original.call(host, *args) : (NetGuard.blocked << "conference #{host}"; false)
      end
    end

    # Binary uploads (audio posts, voice messages, attachments) are kept
    # byte for byte: app.uploads => [{method:, path:, body:, params:}, ...]
    def record_uploads
      wrap(EltenLink::Client, :api_binary_payload) do |original, method, path, body, headers = {}, params = nil, **kw|
        data = body.respond_to?(:read) ? nil : body.to_s.b
        KlangtenTest.uploads << { method: method.to_s.upcase, path: path.to_s, body: data, params: (params || {}).dup }
        original.call(method, path, body, headers, params, **kw)
      end
    end

    # No test may ever reach a real sound card or microphone. On 2026-10-11/12
    # test runs on a developer's Mac drove coreaudiod into an overload loop
    # (audio hung, the machine had to be switched off): the conference
    # library (TeamConference, cpal) opens CoreAudio by itself after login.
    # So: no conference library at all, BASS output only on device 0 and no
    # BASS recording, no Chrome. Conference tests use a fake library.
    def forbid_real_audio_devices
      # klangten_audio itself: every device is the null device
      ENV["KLANGTEN_AUDIO_NULL"] = "1"
      wrap(TeamConference::Library.singleton_class, :open) do |_original, *_args|
        [nil, "the conference library is disabled in tests"]
      end
      wrap(Bass.singleton_class, :setdevice) do |original, _device, *args, **kw|
        original.call(0, *args, **kw)
      end
      wrap(Bass.singleton_class, :record_prepare) do |_original, *_args|
        false
      end
      wrap(KlangtenWeb::Chrome.singleton_class, :browser) do |_original, *_args|
        raise HarnessError, "Chrome must not start in tests (tools/web-probe.rb is the manual check)"
      end
    end

    # BASS runs on its "no sound" device: streams are created and decoded as
    # usual, nothing reaches a sound card, and machines without one (CI) work.
    def route_audio_to_no_sound_device
      Bass.instance_variable_set(:@setdeviceoninit, 0)
      # BASS fetches URLs itself, past Ruby's sockets: same rule as NetGuard.
      wrap(Bass.singleton_class, :raw_create_url_stream) do |original, url, *args, **kw|
        NetGuard.check_url!(url)
        original.call(url, *args, **kw)
      end
      wrap(Bass.singleton_class, :prewarm_url_loader) do |original, *args|
        Runtime.background { original.call(*args) }
      end
    end
  end
end
