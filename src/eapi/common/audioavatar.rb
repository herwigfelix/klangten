# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

module EltenAPI
  module Common
    private

    # Plays the audio avatar of a user (user menu). Returns true when played.
    def play_audio_avatar(user)
      info = EltenLink::Avatars.info(elten_link, user)
      if !info.exists? || info.url.to_s == ""
        alert(p_("Klangten", "This user has no audio avatar."))
        return false
      end
      player(info.url, label: p_("Klangten", "Audio avatar of %{user}") % { user: user })
      true
    rescue EltenLink::Error => e
      Log.warning("Audio avatar playback failed: #{e.message}")
      alert(e.message.to_s == "" ? _("Error") : e.message)
      false
    end

    # "Set as audio avatar" (file manager, YouTube). source is a local file or
    # a stream URL. It is encoded to Opus and cut to the first two minutes like
    # a recording made in the account settings, so neither a long song nor a
    # video container reaches the server's size limit. Returns true when saved.
    def set_audio_avatar_from(source, title = nil)
      unless Session.logged?
        alert(_("This section is unavailable for guests"))
        return false
      end
      return false if source.to_s == ""
      question = if title.to_s == ""
        p_("Klangten", "Do you want to use this as your audio avatar? Only the first two minutes are kept.")
      else
        p_("Klangten", "Do you want to use %{title} as your audio avatar? Only the first two minutes are kept.") % { title: title.to_s }
      end
      return false if !confirm(question, default_yes: true)
      output = EltenPath.join(Dirs.temp, "audioavatar_set.opus")
      File.delete(output) if File.file?(output)
      waiting
      begin
        Recorder.encode_opus_file(source, output, 64, 60, 2049, 1, Scene_Account_AudioAvatar::TIME_LIMIT)
        if !File.file?(output) || File.size(output) <= 0
          waiting_end
          alert(p_("Klangten", "This file could not be converted to audio."))
          return false
        end
        if File.size(output) > EltenLink::Avatars::MAX_BYTES
          waiting_end
          alert(p_("Klangten", "The recording is too large."))
          return false
        end
        EltenLink::Avatars.upload(elten_link, File.binread(output))
        waiting_end
        alert(p_("Klangten", "Your audio avatar has been saved."))
        true
      rescue EltenLink::Error => e
        waiting_end
        Log.warning("Audio avatar upload failed: #{e.message}")
        alert(e.message.to_s == "" ? _("Error") : e.message)
        false
      rescue StandardError => e
        waiting_end
        Log.warning("Audio avatar conversion failed: #{e.class}: #{e.message}")
        alert(p_("Klangten", "This file could not be converted to audio."))
        false
      ensure
        File.delete(output) if File.file?(output) rescue nil
      end
    end
  end
end
