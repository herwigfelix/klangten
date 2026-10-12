# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Spotify in the playlist: like in Klango, a Spotify list is played by
# Klangten's ordinary playlist (KlangtenPlaylist), not by a player of its
# own. An entry whose location is a Spotify address ("spotify:track:...",
# "spotify:episode:...") is opened as a PlaylistSound: it answers what the
# playlist asks a Sound (play, pause, finished?, position, length, volume,
# tempo, frequency, pan) and plays the one track through the session's
# Spotify player (KlangtenSpotify.player), which runs in its own thread.

module KlangtenSpotify
  @notice_lock = Mutex.new
  @notice = nil

  # The last problem of a track the playlist played (:unavailable, :failed);
  # the Spotify screens and the playlist announce it.
  def self.notice=(value)
    @notice_lock.synchronize { @notice = value }
  end

  def self.take_notice
    @notice_lock.synchronize do
      value = @notice
      @notice = nil
      value
    end
  end

  # Spoken text of the last problem, nil when there was none.
  def self.take_notice_text
    case take_notice
    when :unavailable
      p_("Spotify", "Spotify does not play this track. Playback needs Spotify Premium, and some tracks are not available in your country.")
    when :failed
      p_("Spotify", "This track could not be opened. Check your internet connection.")
    end
  end

  class PlaylistSound
    def self.location?(location)
      value = location.to_s
      value.start_with?("spotify:track:") || value.start_with?("spotify:episode:")
    end

    def initialize(location, title = nil, length = nil)
      @length = length.to_f
      @track = Track.new(uri: location.to_s, title: title.to_s, duration: (@length * 1000).to_i)
      @player = nil
      @started = false
      @closed = false
      client = KlangtenSpotify.client
      @player = KlangtenSpotify.player if client != nil && client.logged_in?
    end

    def opened?
      @player != nil && !@closed
    end

    def closed?
      @closed
    end

    def mine?
      @started && @player.current_track != nil && @player.current_track.uri == @track.uri
    end

    def play
      return if !opened?
      if !@started || !mine?
        @started = true
        @player.play([@track], 0)
      else
        @player.resume
      end
    end

    def pause
      @player.pause if opened? && mine?
    end

    def stop
      @player.stop if opened? && mine?
    end

    def close
      stop
      @closed = true
    end

    # The player is :loading from the moment it is asked to play, so the
    # playlist needs no grace time after the start.
    def reports_end?
      true
    end

    # The end of the track (or a track Spotify does not play): the player
    # stops after its one-track list.
    def finished?
      return true if !opened?
      return false if !@started
      @player.events.each do |event|
        KlangtenSpotify.notice = event.type if [:unavailable, :failed].include?(event.type)
      end
      !mine? || @player.state == :stopped
    end

    def playing?
      opened? && mine? && @player.state == :playing
    end

    def position
      opened? && mine? ? @player.position.to_f : 0.0
    end

    def position=(seconds)
      return if !opened? || !mine?
      @player.seek(seconds.to_f - position)
    end

    def length
      return 0.0 if !opened?
      return @length if @length > 0
      now = NowPlaying.from(KlangtenSpotify.client.library.now_playing)
      now.uri == @track.uri ? now.duration / 1000.0 : 0.0
    rescue StandardError
      0.0
    end

    def volume
      opened? ? @player.volume : 0.0
    end

    def volume=(value)
      @player.volume = value if opened?
    end

    def tempo
      opened? ? @player.tempo.to_f : 0.0
    end

    def tempo=(value)
      @player.tempo = value if opened?
    end

    def basefrequency
      BassSink::DEFAULT_FREQUENCY.to_f
    end

    def frequency
      opened? ? @player.frequency.to_f : basefrequency
    end

    def frequency=(value)
      @player.frequency = value if opened?
    end

    def pan
      opened? ? @player.pan.to_f : 0.0
    end

    def pan=(value)
      @player.pan = value if opened?
    end
  end
end
