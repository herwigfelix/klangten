# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Background playback: one radio station, podcast episode, Internet Archive
# file or YouTube video that keeps playing while you work elsewhere in
# Klangten.
#
# Something gets here in two ways: a player screen hands its sound over
# ("Continue in the background", B) - same position, no new connection, a
# running recording goes on - or a list starts an entry directly in the
# background. Only one entry plays in the background at a time; a new one
# replaces it.
#
# KlangtenBackgroundPlayer works like the playlist engine (src/eapi/playlist.rb):
# a small engine thread opens addresses (that can take seconds), notices the
# end of an entry, saves podcast bookmarks every few seconds and, on phones,
# follows the audio focus. It needs no loop_update. What it has to say (the end
# of an entry, a saved recording) goes into a queue that KlangtenMedia.tick
# speaks on the interface thread.
#
# KlangtenMedia ties the two background players together: when one of them
# starts, the other one pauses (it stays where it was, Space or the quick
# action resumes it), and the "Player: ..." quick actions and the global
# player keys control the one that was started last. A player screen in the
# foreground (player(), the YouTube player) pauses both and lets them continue
# afterwards - unless it sent its own sound to the background.

require "monitor"

# Audio focus on the phones: Android asks for it before playing and is told
# when a call or another app takes it; on iOS an interruption (a call, an
# alarm) is reported the same way. Desktop systems have no such thing, there
# focus is always ours.
module KlangtenAudioFocus
  class << self
    def supported?
      return @supported if defined?(@supported)
      @supported = defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:audio_focus_supported?) && IOSHostBridge.audio_focus_supported?
    rescue StandardError
      @supported = false
    end

    def request
      return true if !supported?
      IOSHostBridge.audio_focus_request
    rescue StandardError
      true
    end

    def abandon
      IOSHostBridge.audio_focus_abandon if supported?
    rescue StandardError
      nil
    end

    # :focused, :transient (lost for a moment: a call, a notification) or
    # :lost (another player took over for good).
    def state
      return :focused if !supported?
      case IOSHostBridge.audio_focus_state
      when 0 then :transient
      when -1 then :lost
      else :focused
      end
    rescue StandardError
      :focused
    end
  end
end

module KlangtenBackgroundPlayer
  # What plays: title, address or path, kind (:radio, :podcast, :archive,
  # :youtube, :file, :stream), whether a bookmark is kept, and an optional
  # text for Details.
  Item = Struct.new(:title, :location, :kind, :bookmark, :details, keyword_init: true) do
    def live?
      kind == :radio || kind == :stream
    end
  end

  ENGINE_INTERVAL = 0.25
  START_GRACE_SECONDS = 1.5
  BOOKMARK_INTERVAL = 15
  SEEK_TIMEOUT = 180
  RECONNECT_ATTEMPTS = 3
  VOLUME_STEP = 0.05
  MAX_VOLUME = 2.0
  MIN_VOLUME = 0.05
  DEFAULT_VOLUME = 0.8
  SEEK_STEP = 5

  @lock = Monitor.new
  @sound = nil
  @item = nil
  @paused = false
  @pending = nil
  @generation = 0
  @thread = nil
  @volume = DEFAULT_VOLUME
  @events = Queue.new
  @seek_target = nil
  @focus_paused = false

  class << self
    # ---------------------------------------------------------- starting

    # Takes over an open sound from a player screen, where it is.
    def adopt(sound, item, paused: false)
      raise ArgumentError, "No sound to continue" if sound == nil || sound.closed?
      previous = nil
      @lock.synchronize do
        previous = release_locked
        @generation += 1
        @sound = sound
        @item = item
        @volume = sound.volume.to_f rescue DEFAULT_VOLUME
        @paused = paused == true
        @started_at = monotonic
        @bookmark_saved_at = monotonic
        @reconnects = 0
        @seek_target = nil
        @focus_paused = false
        ensure_thread
      end
      KlangtenRecordings.announce_stopped(previous) if previous != nil
      KlangtenAudioFocus.request
      KlangtenMedia.background_started
      true
    end

    # Opens item in the background; position (seconds) continues from there.
    def play(item, position: nil)
      previous = nil
      @lock.synchronize do
        previous = release_locked
        @generation += 1
        @item = item
        @paused = false
        @reconnects = 0
        @focus_paused = false
        @seek_target = nil
        @pending = [item, @generation, position]
        ensure_thread
      end
      KlangtenRecordings.announce_stopped(previous) if previous != nil
      KlangtenAudioFocus.request
      KlangtenMedia.background_started
      true
    end

    # Stops playback (keeping a bookmark where one belongs) and says when a
    # recording was saved with it.
    def stop
      recording = @lock.synchronize { release_locked }
      KlangtenAudioFocus.abandon
      KlangtenRecordings.announce_stopped(recording) if recording != nil
      true
    end

    # ----------------------------------------------------------- control

    # Not under the lock: resume tells KlangtenMedia, which may pause the
    # playlist, and the lock of the playlist is never taken inside this one.
    def toggle_pause
      return nil if @item == nil
      if @paused
        resume
        :playing
      else
        pause
        :paused
      end
    end

    def pause
      @lock.synchronize do
        return false if @item == nil
        @paused = true
        @focus_paused = false
        @sound.pause if @sound != nil && !@sound.closed?
        save_bookmark_locked
        true
      end
    end

    def resume
      @lock.synchronize do
        return false if @item == nil
        @paused = false
        @focus_paused = false
        if @sound != nil && !@sound.closed?
          @sound.play if @seek_target == nil
          @started_at = monotonic
        elsif @pending == nil
          @generation += 1
          @pending = [@item, @generation, nil]
          ensure_thread
        end
      end
      KlangtenAudioFocus.request
      KlangtenMedia.background_started
      true
    end

    def seek(delta)
      @lock.synchronize do
        return false if @sound == nil || @sound.closed? || @item == nil || @item.live?
        return false if KlangtenRecordings.recording?(@sound)
        length = @sound.length.to_f
        target = [@sound.position.to_f + delta, 0].max
        target = [target, length - 0.5].min if length > 0
        @sound.position = target
        true
      end
    rescue StandardError
      false
    end

    def volume
      @volume
    end

    # Volume in percent of normal (100 = as loud as the file).
    def volume_percent
      (@volume * 100).round
    end

    def change_volume(delta)
      @lock.synchronize do
        @volume = (@volume + delta).round(2)
        @volume = MAX_VOLUME if @volume > MAX_VOLUME
        @volume = MIN_VOLUME if @volume < MIN_VOLUME
        @sound.volume = @volume if @sound != nil && !@sound.closed?
      end
      volume_percent
    end

    # The volume the player screen changed directly on the sound.
    def sync_volume
      @lock.synchronize { @volume = @sound.volume.to_f if @sound != nil && !@sound.closed? }
    rescue StandardError
      nil
    end

    def toggle_recording
      sound = @sound
      return nil if sound == nil || sound.closed? || @item == nil
      KlangtenRecordings.toggle_stream(sound, @item.title)
    end

    # ------------------------------------------------------------- state

    def active?
      @item != nil
    end

    def playing?
      @item != nil && !@paused
    end

    def paused?
      @item != nil && @paused
    end

    def item
      @item
    end

    def sound
      @sound
    end

    def generation
      @generation
    end

    def opening?
      @item != nil && (@sound == nil || @seek_target != nil)
    end

    def recording?
      KlangtenRecordings.recording?(@sound)
    end

    def position
      @sound == nil || @sound.closed? ? nil : @sound.position.to_f
    rescue StandardError
      nil
    end

    def length
      return nil if @sound == nil || @sound.closed? || (@item != nil && @item.live?)
      value = @sound.length.to_f
      value > 0 ? value : nil
    rescue StandardError
      nil
    end

    # Spoken status: "Playing in the background: Title, 12:03 of 45:00".
    def status_text
      item = @item
      return p_("Klangten", "Nothing is playing in the background.") if item == nil
      text = if opening?
        p_("Klangten", "Opening: %{title}") % { title: item.title }
      elsif @paused
        p_("Klangten", "Paused: %{title}") % { title: item.title }
      else
        p_("Klangten", "Playing in the background: %{title}") % { title: item.title }
      end
      pos = position
      len = length
      if pos != nil && len != nil
        text += ", " + p_("Klangten", "%{position} of %{length}") % { position: KlangtenPlaylist.format_duration(pos), length: KlangtenPlaylist.format_duration(len) }
      elsif pos != nil && pos > 0 && item.live?
        text += ", " + KlangtenPlaylist.format_duration(pos)
      end
      text += ", " + p_("Klangten", "recording") if recording?
      text
    end

    # Messages of the engine thread for the interface: [:finished, title],
    # [:failed, title], [:recording_saved, recording], [:seek_failed, title].
    def events_pending?
      !@events.empty?
    end

    def take_events
      events = []
      loop { events << @events.pop(true) }
    rescue ThreadError
      events
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(level, message)
      Log.__send__(level, message) if defined?(Log) && Log.respond_to?(level)
    rescue StandardError
      nil
    end

    # Ends what plays now (lock held): bookmark, recording, sound. Returns the
    # recording that was stopped, so the caller can announce it.
    def release_locked
      @generation += 1
      @pending = nil
      @seek_target = nil
      save_bookmark_locked
      recording = KlangtenRecordings.stop_stream(@sound)
      close_sound_locked
      @item = nil
      @paused = false
      @focus_paused = false
      recording
    end

    def close_sound_locked
      sound = @sound
      @sound = nil
      sound.close if sound != nil && !sound.closed?
    rescue StandardError => e
      log(:warning, "Closing the background sound failed: #{e.class}: #{e.message}")
    end

    def save_bookmark_locked
      return if @item == nil || !@item.bookmark || @sound == nil || @sound.closed? || @seek_target != nil
      KlangtenBookmarks.update_from_sound(@item.location, @sound, title: @item.title)
      @bookmark_saved_at = monotonic
    rescue StandardError => e
      log(:warning, "Saving a bookmark failed: #{e.class}: #{e.message}")
    end

    def ensure_thread
      return if @thread != nil && @thread.alive?
      @thread = Thread.new { engine_loop }
      @thread.name = "klangten-background-player"
      @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
    end

    def engine_loop
      loop do
        job = nil
        @lock.synchronize do
          job = @pending
          @pending = nil
          if job == nil
            if @item == nil && @sound == nil
              @thread = nil
              return
            end
            check_state
          end
        end
        open_job(job) if job != nil
        sleep(ENGINE_INTERVAL)
      end
    rescue Exception => e
      log(:error, "Background player failed: #{e.class}: #{e.message}")
      @lock.synchronize { @thread = nil if @thread.equal?(Thread.current) }
    end

    # Opens the sound outside the lock (a stream address may take seconds).
    def open_job(job)
      item, generation, position = job
      sound = nil
      begin
        location = item.location.to_s
        location = EltenLink::Client.absolute_api_url(location) if location.start_with?("/") && !File.exist?(location)
        sound = Sound.new(location)
        if !sound.opened?
          sound.close
          sound = nil
        end
      rescue Exception => e
        log(:warning, "Background entry could not be opened (#{e.class}: #{e.message}): #{item.location}")
        sound = nil
      end
      @lock.synchronize do
        if generation != @generation
          sound.close if sound != nil
          return
        end
        if sound == nil
          @events << [:failed, item.title]
          @item = nil
          @paused = false
          return
        end
        @sound = sound
        sound.volume = @volume
        @started_at = monotonic
        @bookmark_saved_at = monotonic
        @seek_target = position.to_f > 0 ? [position.to_f, monotonic] : nil
        try_seek_locked if @seek_target != nil
        sound.play if !@paused && @seek_target == nil
      end
    end

    # A bookmark may lie beyond what has been downloaded yet; until it is
    # reached the sound waits, then plays from there.
    def try_seek_locked
      target, since = @seek_target
      @sound.position = target
      if (@sound.position.to_f - target).abs < 2
        @seek_target = nil
        @started_at = monotonic
        @sound.play if !@paused
      elsif monotonic - since > SEEK_TIMEOUT || download_complete?
        @seek_target = nil
        @events << [:seek_failed, @item.title]
        @sound.play if !@paused
      end
    rescue StandardError
      @seek_target = nil
    end

    def download_complete?
      status = @sound.download_status
      status == nil || status.download_complete?
    rescue StandardError
      true
    end

    def check_state
      return if @item == nil || @sound == nil
      if @sound.closed?
        # Closed by someone else: nothing plays any more.
        @sound = nil
        @item = nil
        @paused = false
        return
      end
      return try_seek_locked if @seek_target != nil
      follow_focus
      if !@paused && @item.bookmark && monotonic - @bookmark_saved_at.to_f > BOOKMARK_INTERVAL
        save_bookmark_locked
      end
      return if @paused
      return if @started_at != nil && monotonic - @started_at < START_GRACE_SECONDS
      return if !@sound.finished?
      finished
    rescue StandardError => e
      log(:warning, "Background playback check failed: #{e.class}: #{e.message}")
    end

    # The end of an entry: a radio station whose connection broke is opened
    # again (a few times), anything else is over - and heard to the end.
    def finished
      recording = KlangtenRecordings.stop_stream(@sound)
      @events << [:recording_saved, recording] if recording != nil
      item = @item
      if item.live? && @reconnects.to_i < RECONNECT_ATTEMPTS
        @reconnects = @reconnects.to_i + 1
        close_sound_locked
        @generation += 1
        @pending = [item, @generation, nil]
        log(:info, "Background stream ended, reconnecting (#{@reconnects}): #{item.location}")
        return
      end
      KlangtenBookmarks.forget(item.location) if item.bookmark
      close_sound_locked
      @item = nil
      @paused = false
      @events << [:finished, item.title]
    end

    def follow_focus
      return if !KlangtenAudioFocus.supported?
      focus = KlangtenAudioFocus.state
      case focus
      when :transient, :lost
        if !@paused
          @sound.pause
          @paused = true
          # Only a short loss (a call) gives the sound back by itself.
          @focus_paused = focus == :transient
        elsif focus == :lost
          @focus_paused = false
        end
      when :focused
        if @focus_paused
          @focus_paused = false
          @paused = false
          @sound.play
        end
      end
    end
  end
end

module KlangtenMedia
  # One-time default keys for the player quick actions (only where the key is
  # still free): F7 opens the player, Shift+F7 plays and pauses, Shift+F5 and
  # Shift+F6 change its volume, Control+F11 records from the microphone.
  # Klango uses F11 for that, but in Klangten F11 speaks the last text.
  DEFAULT_HOTKEYS = [
    [7, :open],
    [-7, :toggle],
    [-5, :volume_down],
    [-6, :volume_up],
    [23, :microphone]
  ].freeze
  HOTKEYS_MARK = "KlangtenMediaHotkeys".freeze

  @last = nil
  @events = Queue.new

  class << self
    # ---------------------------------------------------- coordination

    def background_started
      @last = :background
      if KlangtenPlaylist.playing?
        KlangtenPlaylist.pause
      end
    end

    def playlist_started
      @last = :playlist
      KlangtenBackgroundPlayer.pause if KlangtenBackgroundPlayer.playing?
    end

    # Which background player the generic actions control: the one started
    # last while it is still there, otherwise the other one.
    def source
      background = KlangtenBackgroundPlayer.active?
      playlist = KlangtenPlaylist.active?
      return @last if @last == :background && background
      return @last if @last == :playlist && playlist
      return :background if background
      return :playlist if playlist
      nil
    end

    def active?
      source != nil
    end

    # Pauses what plays in the background while a player screen is open and
    # lets it continue afterwards. When the screen handed its own sound to the
    # background, that one keeps playing and nothing else resumes.
    def suspend
      playlist = KlangtenPlaylist.playing?
      background = KlangtenBackgroundPlayer.playing?
      generation = KlangtenBackgroundPlayer.generation
      KlangtenPlaylist.pause if playlist
      KlangtenBackgroundPlayer.pause if background
      yield
    ensure
      if generation != nil && KlangtenBackgroundPlayer.generation == generation
        KlangtenBackgroundPlayer.resume if background && KlangtenBackgroundPlayer.paused?
        KlangtenPlaylist.resume if playlist && KlangtenPlaylist.paused? && !KlangtenBackgroundPlayer.playing?
      end
    end

    # ------------------------------------------------- interface thread

    # Called by loop_update on every frame: speaks what the engine reported,
    # runs the global player keys and gives the quick actions their keys once.
    def tick
      KlangtenBackgroundPlayer.take_events.each { |event| announce(event) } if KlangtenBackgroundPlayer.events_pending?
      KlangtenGlobalKeys.tick if defined?(KlangtenGlobalKeys)
      # Only once the main menu is there: the quick actions are saved with
      # their labels, which must already be in the user's language.
      ensure_default_hotkeys if !@hotkeys_checked && defined?(Scene_Main) && $scene.is_a?(Scene_Main)
    rescue StandardError => e
      Log.error("Media tick failed: #{e.class}: #{e.message}") if defined?(Log)
    end

    def announce(event)
      case event[0]
      when :finished
        alert(p_("Klangten", "Finished: %{title}") % { title: event[1] }, false)
      when :failed
        alert(p_("Klangten", "%{title} cannot be played.") % { title: event[1] }, false)
      when :seek_failed
        alert(p_("Klangten", "The saved position of %{title} could not be reached, it plays from the beginning.") % { title: event[1] }, false)
      when :recording_saved
        KlangtenRecordings.announce_stopped(event[1])
      end
    end

    def ensure_default_hotkeys
      @hotkeys_checked = true
      return if LocalConfig[HOTKEYS_MARK, type: :numeric].to_i == 1
      LocalConfig[HOTKEYS_MARK] = 1
      used = EltenAPI::QuickActions.get.map { |action| action.key.to_i }
      DEFAULT_HOTKEYS.each do |key, action|
        next if used.include?(key)
        EltenAPI::QuickActions.assign_hotkey(key, quick_action_symbol(action), quick_action_label(action))
      end
    rescue StandardError => e
      Log.error("Media hotkeys could not be assigned: #{e.class}: #{e.message}") if defined?(Log)
    end

    # ---------------------------------------------------- quick actions

    QUICK_ACTIONS = [:open, :toggle, :stop, :volume_down, :volume_up, :status, :record, :microphone].freeze

    def quick_action_symbol(action)
      "klangten_player__#{action}".to_sym
    end

    def quick_action_label(action)
      case action
      when :open then p_("Klangten", "Player: open")
      when :toggle then p_("Klangten", "Player: play or pause")
      when :stop then p_("Klangten", "Player: stop")
      when :volume_down then p_("Klangten", "Player: volume down")
      when :volume_up then p_("Klangten", "Player: volume up")
      when :status then p_("Klangten", "Player: what is playing")
      when :record then p_("Klangten", "Player: start or stop recording")
      when :microphone then p_("Klangten", "Record from the microphone")
      else action.to_s
      end
    end

    def register_quick_actions
      return if @quick_actions_registered || !defined?(EltenAPI::QuickActions)
      @quick_actions_registered = true
      QUICK_ACTIONS.each do |action|
        EltenAPI::QuickActions.register_proc(:klangten_player, action, proc { quick_action_label(action) }, proc { quick_action(action) })
      end
    end

    # The player actions, for quick actions and the global keys.
    def quick_action(action)
      case action
      when :microphone
        KlangtenRecordings.toggle_microphone
        return
      when :open
        return open_player
      end
      case source
      when :background then background_action(action)
      when :playlist then playlist_action(action)
      else
        alert(p_("Klangten", "Nothing is playing in the background."), false)
      end
    rescue StandardError => e
      Log.error("Player action #{action} failed: #{e.class}: #{e.message}") if defined?(Log)
    end

    def open_player
      return if defined?(GlobalMenu) && GlobalMenu.opened?
      case source
      when :background
        insert_scene(Scene_NowPlaying.new)
      when :playlist
        list = KlangtenPlaylist.current_list
        insert_scene(list == nil || list.internal? ? Scene_Playlist.new : Scene_Playlist.new(list.path))
      else
        alert(p_("Klangten", "Nothing is playing in the background."), false)
      end
    end

    private

    def background_action(action)
      player = KlangtenBackgroundPlayer
      case action
      when :toggle
        result = player.toggle_pause
        result == :paused ? alert(p_("Klangten", "Paused"), false) : alert(player.status_text, false)
      when :stop
        title = player.item&.title
        player.stop
        alert(p_("Klangten", "Stopped: %{title}") % { title: title }, false)
      when :volume_down, :volume_up
        percent = player.change_volume(action == :volume_up ? KlangtenBackgroundPlayer::VOLUME_STEP : -KlangtenBackgroundPlayer::VOLUME_STEP)
        alert(p_("Klangten", "Volume %{volume}") % { volume: percent }, false)
      when :status
        alert(player.status_text, false)
      when :record
        player.toggle_recording
      when :next, :previous
        play_sound("border")
      end
    end

    def playlist_action(action)
      case action
      when :toggle then KlangtenPlaylist.quick_action(:toggle)
      when :next, :previous then KlangtenPlaylist.quick_action(action)
      when :volume_down, :volume_up then KlangtenPlaylist.quick_action(action)
      when :status then alert(KlangtenPlaylist.status_text, false)
      when :stop
        KlangtenPlaylist.stop
        alert(p_("Klangten", "Stopped"), false)
      when :record
        alert(p_("Klangten", "The playlist cannot be recorded. Open the entry in the player to record it."), false)
      end
    end
  end

  register_quick_actions
end
