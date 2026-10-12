# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The player of what plays in the background (Media menu, "Player: open"
# quick action, F7 by default). It is the usual player - Space pauses, the
# arrows seek and change the volume, R records - working on the background
# sound. Escape leaves the screen and the sound plays on; Stop in the context
# menu ends it. When the playlist is what plays, the playlist screen opens
# instead.

class Scene_NowPlaying
  # The core player on the background sound: play and pause go through the
  # background player (which keeps its state and bookmarks), and closing the
  # screen leaves the sound alone.
  class BackgroundControl < EltenAPI::Controls::Player
    attr_accessor :extra_context

    def initialize(sound, label)
      super(sound, label: label, autoplay: false, quiet: true, owns_sound: false)
      @pause = !KlangtenBackgroundPlayer.playing?
    end

    def play
      return if @closed
      KlangtenBackgroundPlayer.resume
      @pause = false
    end

    def pause
      return if @closed
      KlangtenBackgroundPlayer.pause
      @pause = true
    end

    def stop
      pause
    end

    def close
      @closed = true
    end

    def hascontext
      true
    end

    def context(menu, submenu = false)
      @extra_context.call(menu) if @extra_context != nil
      super(menu, submenu)
    end
  end

  def self.available?
    defined?(KlangtenBackgroundPlayer) && KlangtenBackgroundPlayer.active?
  rescue StandardError
    false
  end

  def main
    if !KlangtenBackgroundPlayer.active?
      if KlangtenPlaylist.active?
        list = KlangtenPlaylist.current_list
        $scene = list == nil || list.internal? ? Scene_Playlist.new : Scene_Playlist.new(list.unsaveable ? list : list.path)
      else
        alert(p_("Klangten", "Nothing is playing in the background."))
        $scene = Scene_Main.new
      end
      return
    end
    show_player
    $scene = Scene_Main.new if $scene == self
  end

  private

  def show_player
    leave = false
    generation = nil
    control = nil
    item = nil
    speak(KlangtenBackgroundPlayer.status_text)
    loop do
      loop_update
      break if $scene != self
      # Ended (KlangtenMedia.tick says why) or stopped elsewhere.
      break if !KlangtenBackgroundPlayer.active?
      # A new entry (or the first sound of one that was still opening) gets a
      # fresh player.
      if control == nil || generation != KlangtenBackgroundPlayer.generation || !control.sound.equal?(KlangtenBackgroundPlayer.sound)
        sound = KlangtenBackgroundPlayer.sound
        if sound != nil && !sound.closed?
          item = KlangtenBackgroundPlayer.item
          generation = KlangtenBackgroundPlayer.generation
          control = BackgroundControl.new(sound, item.title)
          control.extra_context = proc { |menu| extra_options(menu, item, proc { leave = true }) }
          control.focus
        end
      end
      if control != nil
        control.update
        KlangtenBackgroundPlayer.sync_volume
      end
      break if leave || key_pressed?(:key_escape)
    end
  ensure
    control.close if control != nil
  end

  def extra_options(menu, item, close)
    menu.option(p_("Klangten", "What is playing"), nil, "i") { speak(KlangtenBackgroundPlayer.status_text) }
    menu.option(p_("Klangten", "Details")) { show_details(item) }
    if item.location.to_s.match?(/\Ahttps?:\/\//i)
      menu.option(p_("MediaCatalog", "Copy address to the clipboard")) do
        Clipboard.set_data(item.location)
        alert(p_("MediaCatalog", "Copied to clipboard."))
      end
    end
    menu.option(p_("Klangten", "Stop")) do
      KlangtenBackgroundPlayer.stop
      alert(p_("Klangten", "Stopped"), false)
      close.call
    end
    menu.option(p_("Klangten", "Close the player, keep playing")) { close.call }
  end

  def show_details(item)
    lines = [item.title.to_s]
    lines << KlangtenBackgroundPlayer.status_text
    lines << "#{p_("MediaCatalog", "Address")}: #{item.location}" if item.location.to_s != ""
    lines << "" << item.details.to_s if item.details.to_s != ""
    display_text(lines.join("\n"), header: p_("Klangten", "Details"))
  end
end
