# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Global player keys: they work while another program has the focus, so the
# background player and the playlist can be controlled from anywhere - the
# keys Klango users know:
#
#   Windows+F5 / Windows+F6    player volume down / up
#   Windows+Z / Windows+X      previous / next (playlist)
#   Windows+Space              play or pause
#   Windows+F7                 what is playing
#   Windows+F8                 stop
#   Windows+F11                record from the microphone (again: save)
#
# Windows itself keeps some of these (Windows+X opens the quick link menu,
# Windows+Space switches the keyboard layout); Control+Windows with the same
# key works as well, and a combination another program holds is skipped. On
# macOS Option takes the place of Windows (Option+Command for
# Control+Windows); Option+Command+F5 belongs to VoiceOver and is left out.
#
# The platform part (src/platforms/<os>/eapi/globalkeys.rb) defines
# KlangtenGlobalKeys::Backend with start(bindings, queue) and stop; it
# reports a pressed key by pushing the action to the queue. The actions run in
# KlangtenGlobalKeys.tick (called by KlangtenMedia.tick from loop_update) on
# the interface thread. Settings, Media, "Global player keys" switches them.

module KlangtenGlobalKeys
  MOD_ALT = 1
  MOD_CONTROL = 2
  MOD_SHIFT = 4
  MOD_WIN = 8
  VK_SPACE = 0x20
  VK_X = 0x58
  VK_Z = 0x5A
  VK_F5 = 0x74
  VK_F6 = 0x75
  VK_F7 = 0x76
  VK_F8 = 0x77
  VK_F11 = 0x7A
  CONFIG_GROUP = "Media".freeze
  CONFIG_KEY = "GlobalPlayerKeys".freeze
  REFRESH_SECONDS = 5.0

  # [id, modifiers, virtual key, action]
  BINDINGS = [
    [1, MOD_WIN, VK_F5, :volume_down],
    [2, MOD_WIN, VK_F6, :volume_up],
    [3, MOD_WIN, VK_X, :next],
    [4, MOD_WIN, VK_Z, :previous],
    [5, MOD_WIN, VK_SPACE, :toggle],
    [6, MOD_WIN, VK_F7, :status],
    [7, MOD_WIN, VK_F8, :stop],
    [8, MOD_WIN, VK_F11, :microphone],
    [11, MOD_CONTROL | MOD_WIN, VK_F5, :volume_down],
    [12, MOD_CONTROL | MOD_WIN, VK_F6, :volume_up],
    [13, MOD_CONTROL | MOD_WIN, VK_X, :next],
    [14, MOD_CONTROL | MOD_WIN, VK_Z, :previous],
    [15, MOD_CONTROL | MOD_WIN, VK_SPACE, :toggle]
  ].freeze

  # Klangten 0.4: the media keys of a keyboard, where the backend can take
  # them (Windows) and the headset and media buttons are on
  # (src/eapi/mediabuttons.rb). They report a media button code.
  MEDIA_BINDINGS = [
    [21, 0, 0xB3, 1],
    [22, 0, 0xB0, 4],
    [23, 0, 0xB1, 5],
    [24, 0, 0xB2, 6]
  ].freeze

  @queue = Queue.new
  @running = false
  @wanted = nil
  @checked_at = nil

  class << self
    def supported?
      defined?(KlangtenGlobalKeys::Backend) != nil
    end

    def enabled?
      readconfig(CONFIG_GROUP, CONFIG_KEY, "true").to_s != "false"
    rescue StandardError
      true
    end

    def running?
      @running
    end

    # Starts or stops the keys as the setting says (checked every few
    # seconds) and runs what was pressed.
    def tick
      return if !supported?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @checked_at == nil || now - @checked_at > REFRESH_SECONDS
        @checked_at = now
        refresh
      end
      return if @queue.empty?
      loop do
        action = @queue.pop(true)
        if action.is_a?(Integer)
          KlangtenMediaButtons::KeysBackend.queue << action
        elsif action.is_a?(Symbol)
          KlangtenMedia.quick_action(action)
        end
      end
    rescue ThreadError
      nil
    rescue StandardError => e
      Log.error("Global player keys: #{e.class}: #{e.message}") if defined?(Log)
    end

    # A start that fails (the system refused every key) is not repeated until
    # the setting changes.
    def refresh(force: false)
      want = [enabled?, media_keys?]
      return if want == @wanted && !force
      @wanted = want
      bindings = (want[0] ? BINDINGS : []) + (want[1] ? MEDIA_BINDINGS : [])
      if !bindings.empty?
        @running = Backend.start(bindings, @queue) == true
        Log.warning("Global player keys could not be started") if !@running && defined?(Log)
      else
        Backend.stop
        @running = false
      end
    end

    def media_keys?
      Backend.respond_to?(:media_keys?) && Backend.media_keys? &&
        defined?(KlangtenMediaButtons) && KlangtenMediaButtons.enabled?
    rescue StandardError
      false
    end

    def stop
      Backend.stop if supported?
      @running = false
      @wanted = nil
    end
  end
end
