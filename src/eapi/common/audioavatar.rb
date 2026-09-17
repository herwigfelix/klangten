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
  end
end
