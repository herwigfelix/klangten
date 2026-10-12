# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Headset and media buttons (Klangten 0.4): play/pause, next and previous of
# a headset, a Bluetooth device, the lock screen or the media keys of a
# keyboard control Klangten's playback - the background player or the
# playlist, whichever plays (KlangtenMedia.quick_action).
#
# Where the buttons come from:
#   iOS      remote commands (ios/Klangten/Sources/EltenHostBridge.swift)
#   Android  a media session (android/.../Host.java)
#   Windows  the media keys, through the global keys (src/platforms/windows/eapi/globalkeys.rb)
#   macOS    remote commands (src/platforms/osx/eapi/mediabuttons.rb)
# Linux has none. Settings, Media switches them; on by default on the phones,
# off on computers, where they would take the media keys from other players.
#
# Every backend reports a pressed button as a code: 1 play/pause, 2 play,
# 3 pause, 4 next, 5 previous, 6 stop. KlangtenMediaButtons.tick (called by
# KlangtenMedia.tick from loop_update) runs them on the interface thread and
# tells the system what plays, so the right app gets the buttons. On the
# phones that happens with the buttons off as well: Android keeps a playback
# service running while something plays, so it goes on with the screen locked.

module KlangtenMediaButtons
  CONFIG_GROUP = "Media".freeze
  CONFIG_KEY = "MediaButtons".freeze
  REFRESH_SECONDS = 2.0
  TOGGLE = 1
  PLAY = 2
  PAUSE = 3
  NEXT = 4
  PREVIOUS = 5
  STOP = 6

  # The phones: the host bridge of the app.
  module HostBackend
    class << self
      def supported?
        defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:media_buttons_supported?) && IOSHostBridge.media_buttons_supported?
      rescue StandardError
        false
      end

      def enable(on)
        IOSHostBridge.media_buttons_enable(on)
      end

      def poll
        IOSHostBridge.media_buttons_poll.to_i
      end

      def now_playing(title, state)
        IOSHostBridge.media_now_playing(title, state)
      end
    end
  end

  # Windows: the media keys are global keys without a modifier.
  module KeysBackend
    @queue = Queue.new

    class << self
      attr_reader :queue

      def supported?
        defined?(KlangtenGlobalKeys::Backend) && KlangtenGlobalKeys::Backend.respond_to?(:media_keys?) && KlangtenGlobalKeys::Backend.media_keys?
      end

      # KlangtenGlobalKeys registers the keys while the setting is on.
      def enable(_on)
        KlangtenGlobalKeys.refresh(force: true)
      end

      def poll
        @queue.pop(true)
      rescue ThreadError
        0
      end

      def now_playing(_title, _state)
        nil
      end
    end
  end

  @queue = []
  @wanted = nil
  @checked_at = nil
  @announced = nil

  class << self
    def backend
      return @backend if defined?(@backend)
      @backend = [HostBackend, KeysBackend, (defined?(MacBackend) ? MacBackend : nil)].compact.find { |candidate| candidate.supported? }
    end

    def supported?
      backend != nil
    end

    def phone?
      %w[ios android].include?(EltenSystemHelpers.platform_os.to_s)
    rescue StandardError
      false
    end

    def enabled?
      readconfig(CONFIG_GROUP, CONFIG_KEY, phone? ? "true" : "false").to_s == "true"
    rescue StandardError
      phone?
    end

    def enabled=(value)
      writeconfig(CONFIG_GROUP, CONFIG_KEY, value == true || value.to_s == "true" ? "true" : "false")
      @checked_at = nil
    end

    def tick
      return if !supported?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @checked_at == nil || now - @checked_at > REFRESH_SECONDS
        @checked_at = now
        refresh
      end
      if @wanted
        while (code = backend.poll.to_i) > 0
          press(code)
        end
      end
      # The phones always hear what plays: Android keeps its playback
      # service running with it, iOS shows it on the lock screen.
      update_now_playing if @wanted || backend == HostBackend
    rescue StandardError => e
      Log.error("Media buttons: #{e.class}: #{e.message}") if defined?(Log)
    end

    def refresh
      want = enabled?
      return if want == @wanted
      @wanted = want
      @announced = nil
      backend.enable(want)
      Log.info("Media buttons #{want ? "on" : "off"}") if defined?(Log)
    end

    # A pressed button. With nothing loaded, play continues the playlist.
    def press(code)
      source = KlangtenMedia.source
      playing = case source
                when :background then KlangtenBackgroundPlayer.playing?
                when :playlist then KlangtenPlaylist.playing?
                else false
                end
      case code.to_i
      when TOGGLE
        source == nil ? KlangtenPlaylist.quick_action(:toggle) : KlangtenMedia.quick_action(:toggle)
      when PLAY
        if source == nil
          KlangtenPlaylist.quick_action(:toggle)
        elsif !playing
          KlangtenMedia.quick_action(:toggle)
        end
      when PAUSE
        KlangtenMedia.quick_action(:toggle) if playing
      when NEXT then KlangtenMedia.quick_action(:next) if source != nil
      when PREVIOUS then KlangtenMedia.quick_action(:previous) if source != nil
      when STOP then KlangtenMedia.quick_action(:stop) if source != nil
      end
    end

    # The title and state of what plays, for the lock screen and so the
    # system hands the buttons to Klangten.
    def update_now_playing
      title, state = now_playing
      return if [title, state] == @announced
      @announced = [title, state]
      backend.now_playing(title, state)
    end

    def now_playing
      case KlangtenMedia.source
      when :background
        player = KlangtenBackgroundPlayer
        [player.item&.title.to_s, player.playing? ? 1 : 2]
      when :playlist
        [KlangtenPlaylist.current_entry&.name.to_s, KlangtenPlaylist.playing? ? 1 : 2]
      else
        ["", 0]
      end
    end
  end
end
