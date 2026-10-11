# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: background playback, bookmarks and the start position.

module EltenAPI
  module Common
    private
# Opens an audio player
#
# @param file [String] a location or URL of a media to play
# @param label [String] player window caption
# @param wait [Boolean] close a player after audio is played
# @param control [Boolean] allow user to control the played audio, by for example scrolling it
# @param try_download [Boolean] download a file if the codec doesn't support streaming
# @param is_stream [Boolean] whether file is already a stream URL/source
# @param background [Hash] Klangten: offers "Continue in the background" (B);
#   keys :title, :location, :kind (see KlangtenBackgroundPlayer::Item), :details
# @param bookmark [String] Klangten: keep the position under this address
#   (podcast episodes, Internet Archive files) - see KlangtenBookmarks
# @param position [Numeric] Klangten: start at this second
def player(file, label: "", wait: false, control: true, try_download: false, is_stream: false, background: nil, bookmark: nil, position: nil)
  # Klangten: the playlist and the background player pause meanwhile.
  return player_session(file, label, wait, control, background, bookmark, position) if !defined?(KlangtenMedia)
  KlangtenMedia.suspend { player_session(file, label, wait, control, background, bookmark, position) }
end

def player_session(file, label, wait, control, background, bookmark, position)
  snd=nil
  dialog_opened=false
  handoff=false
  begin
  soundfont=EltenPath.join(Dirs.extras, "soundfont.sf2")
  if File.extname(file).downcase==".mid" and FileTest.exists?(soundfont) == false
    if confirm(p_("EAPI_Common", "You are trying to play a MIDI file. Elten needs an external instrument sound bank to play MIDI files. Do you want to download it from the server now? This may take several minutes."))
      alert(p_("EAPI_Common", "Please wait, the soundfont is being downloaded. It may take a while."))
    download_file(soundfont_url,soundfont)
    alert(p_("EAPI_Common", "SoundFont downloaded successfully."))
    Bass::BASS_SetConfigPtr.call(0x10403,soundfont)
  else
    return
    end
      end
    if label != ""
  if wait==false
    dialog_open
    dialog_opened=true
  end
dialog_mute
end
start_at=position.to_f
snd=Player.new(file,label: label,autoplay: start_at<=0,quiet: false)
if start_at>0 && snd.sound!=nil
  player_seek_to(snd.sound, start_at)
  snd.play
end
if background.is_a?(Hash) && wait==false && defined?(KlangtenBackgroundPlayer)
  snd.background_handoff=proc { handoff=true }
end
delay(0.1)
    loop do
                    loop_update
                    snd.update if control
  break if handoff
  if wait == true
    if snd.sound!=nil
  if !snd.paused?
    if snd.sound.length>0 && snd.sound.position>=snd.sound.length-0.05
      return
            end
          end
          end
  end
  if (key_pressed?(:key_enter) and !key_held?(0x10)) or key_pressed?(:key_escape) or snd.sound==nil
    snd.fade
    break
    end
  end
ensure
  if handoff && snd!=nil && snd.sound!=nil && !snd.sound.closed?
    player_to_background(snd, file, label, background, bookmark)
  else
    KlangtenBookmarks.update_from_sound(bookmark, snd.sound, title: label) if bookmark.to_s!="" && snd!=nil && snd.sound!=nil && !snd.sound.closed? && defined?(KlangtenBookmarks)
    snd.close if snd!=nil
  end
  dialog_close if dialog_opened
  alert(p_("Klangten", "Playing in the background"), false) if handoff
end
end

# Klangten: hands the sound of a player over to the background player.
def player_to_background(snd, file, label, background, bookmark)
  paused=snd.paused?
  title=background[:title].to_s
  title=label.to_s if title==""
  title=File.basename(file.to_s.split("?")[0].to_s) if title==""
  item=KlangtenBackgroundPlayer::Item.new(
    title: title,
    location: (background[:location] || file).to_s,
    kind: background[:kind] || :stream,
    bookmark: bookmark.to_s!="",
    details: background[:details]
  )
  item.location=bookmark.to_s if bookmark.to_s!=""
  KlangtenBackgroundPlayer.adopt(snd.detach, item, paused: paused)
rescue StandardError => e
  Log.error("Continuing in the background failed: #{e.class}: #{e.message}")
  snd.close
end

# Klangten: moves sound to a saved position. A bookmark of a long episode may
# lie beyond what has been downloaded; then Klangten waits for it (Escape
# starts from the beginning instead). Returns true when the position was reached.
def player_seek_to(sound, target)
  target=target.to_f
  sound.position=target
  return true if (sound.position.to_f-target).abs<2
  EltenAPI::Tasks.run(title: p_("Klangten", "Loading up to the saved position...")) do |progress, token|
    reached=false
    loop do
      token.raise_if_cancelled!
      sound.position=target
      if (sound.position.to_f-target).abs<2
        reached=true
        break
      end
      status=sound.download_status
      break if status==nil || status.download_complete?
      length=sound.length.to_f
      if status.file_size.to_i>0 && length>0
        needed=(status.file_size.to_f*target/length).to_i
        progress.update([status.downloaded_bytes.to_i, needed].min, total: [needed, 1].max)
      end
      sleep(0.3)
    end
    reached
  end
rescue EltenAPI::Tasks::Cancelled
  false
rescue StandardError => e
  Log.warning("Seeking to the saved position failed: #{e.class}: #{e.message}")
  false
end
  end
end
