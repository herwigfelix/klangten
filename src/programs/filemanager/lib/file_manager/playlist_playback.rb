require_relative "playlist_store"

module FileManagerPlaylist
  class Playback
    attr_reader :playlist, :current_index, :last_error, :volume

    def initialize(store:, sound_factory: nil, random: Random.new, &on_change)
      @store = store
      @sound_factory = sound_factory || proc { |location| Sound.new(location) }
      @random = random
      @on_change = on_change
      @playlist = @store.current_playlist
      settings = @store.playback_settings
      @shuffle = settings["shuffle"] == true
      @volume = [[settings["volume"].to_i, 0].max, 100].min
      @current_index = settings["index"].to_i
      @current_index = 0 if @current_index >= @playlist.entries.size
      @sound = nil
      @active = false
      @paused = false
      @order = []
      @order_position = 0
      @last_error = nil
    end

    def active?
      @active == true
    end

    def paused?
      active? && @paused == true
    end

    def playing?
      active? && !paused?
    end

    def shuffle?
      @shuffle == true
    end

    def current_entry
      return nil if @playlist == nil || @playlist.entries.empty?
      @playlist.entries[@current_index]
    end

    def start(playlist = @playlist, index: 0)
      close_sound
      @playlist = @store.set_current(playlist, index: index, shuffle: @shuffle, volume: @volume)
      @last_error = nil
      if @playlist.empty?
        @active = false
        @paused = false
        changed(:start)
        return false
      end
      @current_index = [[index.to_i, 0].max, @playlist.entries.size - 1].min
      rebuild_order
      @active = true
      @paused = false
      opened = open_current
      changed(:start)
      opened
    end

    def play
      return false if !active?
      if @sound == nil
        return false if !open_current
      else
        @sound.play
      end
      @paused = false
      changed(:state)
      true
    rescue Exception => e
      playback_error(e, current_entry)
      false
    end

    def pause
      return false if !active? || @sound == nil
      @sound.pause
      @paused = true
      changed(:state)
      true
    rescue Exception => e
      playback_error(e, current_entry)
      false
    end

    def toggle_pause
      paused? ? play : pause
    end

    def toggle_shuffle
      @shuffle = !@shuffle
      rebuild_order if active?
      persist_state
      changed(:shuffle)
      @shuffle
    end

    def set_volume(value)
      @volume = [[value.to_i, 0].max, 100].min
      @sound.volume = @volume / 100.0 if @sound != nil
      persist_state
      changed(:volume)
      @volume
    rescue Exception => e
      playback_error(e, current_entry)
      false
    end

    def seek(offset)
      return false if !active? || @sound == nil || !@sound.respond_to?(:position=)
      position = @sound.respond_to?(:position) ? @sound.position.to_f : 0.0
      length = @sound.respond_to?(:length) ? @sound.length.to_f : 0.0
      target = [position + offset.to_f, 0.0].max
      target = [target, length].min if length > 0
      @sound.position = target
      changed(:seek)
      target
    rescue Exception => e
      playback_error(e, current_entry)
      false
    end

    def next
      return false if !active?
      close_sound
      advance_order(:manual_advance)
    end

    def previous
      return false if !active? || @order_position <= 0
      close_sound
      @order_position -= 1
      @current_index = @order[@order_position]
      persist_state
      opened = open_current
      changed(:manual_advance)
      opened
    end

    def tick
      return if !playing? || @sound == nil
      advance_after_completion if sound_finished?
    rescue Exception => e
      playback_error(e, current_entry)
      close_sound
      advance_order(:automatic_advance)
    end

    def replace_current(playlist)
      location = current_entry&.location
      @playlist = @store.set_current(
        playlist, index: @current_index, shuffle: @shuffle, volume: @volume
      )
      if active?
        matched = @playlist.entries.index { |entry| entry.location == location }
        @current_index = matched || [[@current_index, 0].max, [@playlist.entries.size - 1, 0].max].min
        if @playlist.empty?
          close
        else
          rebuild_order
          if matched == nil
            close_sound
            open_current
          end
        end
      else
        @current_index = 0 if @current_index >= @playlist.entries.size
      end
      changed(:playlist)
      @playlist
    end

    def close
      was_active = active?
      close_sound
      @active = false
      @paused = false
      @order = []
      @order_position = 0
      changed(:close) if was_active
      true
    end

    alias shutdown close

    private

    def rebuild_order
      size = @playlist.entries.size
      if size == 0
        @order = []
      elsif shuffle?
        remaining = (0...size).to_a.reject { |index| index == @current_index }
        @order = [@current_index] + remaining.shuffle(random: @random)
      else
        @order = (@current_index...size).to_a
      end
      @order_position = 0
      persist_state
    end

    def open_current
      attempts = 0
      while active? && attempts < @playlist.entries.size
        entry = current_entry
        begin
          sound = @sound_factory.call(entry.location)
          if sound == nil || (sound.respond_to?(:opened?) && !sound.opened?)
            sound.close if sound != nil && sound.respond_to?(:close)
            raise RuntimeError, "Audio source could not be opened"
          end
          @sound = sound
          @sound.volume = @volume / 100.0
          @sound.play
          @paused = false
          persist_state
          return true
        rescue Exception => e
          playback_error(e, entry)
          close_sound
          attempts += 1
          if !move_to_next_order_item
            finish_queue
            return false
          end
        end
      end
      finish_queue
      false
    end

    def advance_after_completion
      close_sound
      advance_order(:automatic_advance)
    end

    def advance_order(reason)
      if move_to_next_order_item
        opened = open_current
        changed(reason)
        opened
      else
        finish_queue(reason)
        false
      end
    end

    def move_to_next_order_item
      @order_position += 1
      return false if @order_position >= @order.size
      @current_index = @order[@order_position]
      persist_state
      true
    end

    def finish_queue(reason = :close)
      close_sound
      @active = false
      @paused = false
      changed(reason)
    end

    def sound_finished?
      return true if @sound.respond_to?(:closed?) && @sound.closed?
      return @sound.finished? if @sound.respond_to?(:finished?)
      status = @sound.status if @sound.respond_to?(:status)
      status != nil && status.respond_to?(:stopped?) && status.stopped?
    end

    def close_sound
      sound = @sound
      @sound = nil
      sound.close if sound != nil && (!sound.respond_to?(:closed?) || !sound.closed?)
    rescue Exception => e
      playback_error(e, current_entry)
    end

    def persist_state
      @store.update_current(
        @playlist, index: @current_index, shuffle: @shuffle, volume: @volume
      )
    rescue Exception => e
      log_error("Cannot save playlist state", e)
    end

    def playback_error(error, entry)
      location = entry == nil ? "" : entry.location.to_s
      @last_error = [location, error.message.to_s].reject(&:empty?).join(": ")
      log_error("Playlist item failed#{location == "" ? "" : " (#{location})"}", error)
    end

    def changed(reason = :state)
      @on_change.call(self, reason) if @on_change != nil
    rescue Exception => e
      log_error("Playlist state callback failed", e)
    end

    def log_error(message, error)
      Log.warning("#{message}: #{error.class}: #{error.message}") if defined?(Log)
    rescue Exception
    end
  end
end
