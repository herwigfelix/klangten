# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: calls are TeamConference calls (call_invite).

module EltenAPI
  module Common
    private

    # Calls a user. voicecall(user) or, as before, voicecall(nil, nil, [user]).
    def voicecall(user=nil, _channel_password=nil, invite=[])
      target = Array(invite).first || user
      return unless Session.logged?
      return if !target.is_a?(String) || target.strip == ""
      target = target.strip
      if target.casecmp(Session.name.to_s) == 0
        alert(p_("Conference", "You cannot call yourself."))
        return
      end
      unless Conference.available?
        alert(p_("Conference", "Conferences are not available on this platform."))
        return
      end
      unless Conference.wait_connected(10)
        alert(p_("Conference", "Cannot connect to the conference server."))
        return
      end
      if Conference.call_info != nil
        alert(p_("Conference", "You are already in a call"))
        return
      end
      if Conference.opened?
        return unless confirm(p_("Conference", "You will leave the current room. Do you want to call %{user}?") % { user: target })
      end
      Conference.call(target)
      insert_scene(Scene_Conference.new(nil, 0, { "type" => "call" }))
    end
  end
end
