# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: the call history is kept locally, because the Klango server stores none.

class Scene_CallHistory
  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene = Scene_Main.new
      return
    end
    @refresh = false
    @calls = Conference.history
    rows = @calls.map { |c|
      name = c["nickname"].to_s == "" ? c["user"].to_s : c["nickname"].to_s
      type = c["direction"] == "incoming" ? p_("CallHistory", "Incoming") : p_("CallHistory", "Outgoing")
      status = c["answered"] ? p_("CallHistory", "Answered") : p_("CallHistory", "Unanswered")
      if c["answered"] && c["duration"].to_i > 0
        status += ", " + p_("CallHistory", "%{minutes} min %{seconds} s") % { minutes: c["duration"].to_i / 60, seconds: c["duration"].to_i % 60 }
      end
      [name, type, status, format_date(Time.at(c["time"].to_i))]
    }
    headers = [nil, p_("CallHistory", "Type"), p_("CallHistory", "Status"), p_("CallHistory", "Time")]
    @sel = TableBox.new(headers, rows, index: 0, header: p_("CallHistory", "Call History"), quiet: false)
    @sel.bind_context { |menu| context(menu) }
    loop do
      loop_update
      @sel.update
      break if key_pressed?(:key_escape)
      return main if @refresh
    end
    $scene = Scene_Main.new
  end

  def context(menu)
    call = @calls[@sel.index]
    if call != nil && call["user"].to_s != ""
      menu.useroption(call["user"].to_s)
      menu.option(p_("CallHistory", "Call back"), nil, "c") { voicecall(call["user"].to_s) }
    end
    if @calls.size > 0
      menu.option(p_("CallHistory", "Clear call history"), nil, :del) {
        if confirm(p_("CallHistory", "Are you sure you want to clear the call history?"))
          Conference.clear_history
          @refresh = true
        end
      }
    end
    menu.option(_("Refresh"), nil, "r") { @refresh = true }
  end
end
