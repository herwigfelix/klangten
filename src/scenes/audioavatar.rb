# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Account settings: record, upload, play and remove the own audio avatar.

class Scene_Account_AudioAvatar
  RECORDING_FILE = "audioavatar.opus".freeze
  TIME_LIMIT = 120

  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      return
    end
    loop do
      info = load_info
      return if info == nil
      outcome = show_form(info)
      break if outcome != :refresh
    end
  ensure
    File.delete(recording_path) if File.file?(recording_path) rescue nil
  end

  private

  def recording_path
    EltenPath.join(Dirs.temp, RECORDING_FILE)
  end

  def load_info
    EltenLink::Avatars.info(elten_link, Session.name)
  rescue EltenLink::Error => e
    Log.warning("Audio avatar info failed: #{e.message}")
    alert(e.message.to_s == "" ? _("Error") : e.message)
    nil
  end

  def status_text(info)
    if info.exists?
      text = p_("Klangten", "You have an audio avatar.")
      text += " " + p_("Klangten", "Last changed: %{date}") % { date: format_date(Time.at(info.updated), false, false) } if info.updated > 0
      text
    else
      p_("Klangten", "You have no audio avatar yet. Record a short greeting or select an audio file (at most two minutes). Other users can play it from the user menu, in Klangten and in Klango.")
    end
  end

  def show_form(info)
    outcome = nil
    status = EditBox.new(p_("Klangten", "Audio avatar"), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: status_text(info), quiet: true)
    play = Button.new(p_("Klangten", "Play my audio avatar"))
    record = OpusRecordButton.new(p_("Klangten", "Record a new audio avatar or select a file"), recording_path, max_bitrate: 128, bitrate: 64, time_limit: TIME_LIMIT)
    upload = Button.new(p_("Klangten", "Save as my audio avatar"))
    remove = Button.new(p_("Klangten", "Remove my audio avatar"))
    close = Button.new(_("Close"))
    fields = [status]
    fields << play if info.exists?
    fields << record << upload
    fields << remove if info.exists?
    fields << close
    form = Form.new(fields)
    form.cancel_button = close
    close.on(:press) { form.resume }
    play.on(:press) do
      player(info.url, label: p_("Klangten", "Audio avatar"))
      form.focus
    end
    upload.on(:press) do
      file = record.get_recording_file(true)
      if file == nil || !File.file?(file)
        alert(p_("Klangten", "Record or select an audio file first."))
        next
      end
      if File.size(file) > EltenLink::Avatars::MAX_BYTES
        alert(p_("Klangten", "The recording is too large."))
        next
      end
      begin
        waiting
        EltenLink::Avatars.upload(elten_link, File.binread(file))
        waiting_end
        alert(p_("Klangten", "Your audio avatar has been saved."))
        outcome = :refresh
        form.resume
      rescue EltenLink::Error => e
        waiting_end
        Log.warning("Audio avatar upload failed: #{e.message}")
        alert(e.message.to_s == "" ? _("Error") : e.message)
      end
    end
    remove.on(:press) do
      next if !confirm(p_("Klangten", "Do you really want to remove your audio avatar?"))
      begin
        EltenLink::Avatars.delete(elten_link)
        alert(p_("Klangten", "Your audio avatar has been removed."))
        outcome = :refresh
        form.resume
      rescue EltenLink::Error => e
        Log.warning("Audio avatar removal failed: #{e.message}")
        alert(e.message.to_s == "" ? _("Error") : e.message)
      end
    end
    form.wait
    outcome
  end
end
