# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Notes as Klango has them besides the server notes: notes that stay on this
# device (Klangten::LocalNotes) and notes shared with a Klango group. Both are
# reached from the context menu of the notes list (Scene_Notes).

module NotesKlango
  # Opens the note form: title and text. Returns [title, text] or nil.
  def self.edit_form(title: "", text: "")
    result = nil
    form = Form.new([
      edt_title = EditBox.new(p_("Notes", "note title"), text: title.to_s, quiet: true),
      edt_text = EditBox.new(p_("Notes", "Note content"), type: EditBox::Flags::MultiLine, text: text.to_s, quiet: true),
      btn_save = Button.new(_("Save")),
      btn_cancel = Button.new(_("Cancel"))
    ])
    form.accept_button = btn_save
    form.cancel_button = btn_cancel
    btn_save.on(:press) do
      if edt_title.text.to_s.strip == ""
        alert(p_("Notes", "Enter a title for the note."))
      else
        result = [edt_title.text.to_s.strip, edt_text.text.to_s]
        form.resume
      end
    end
    btn_cancel.on(:press) do
      changed = edt_title.text.to_s != title.to_s || edt_text.text.to_s != text.to_s
      form.resume if !changed || confirm(p_("Notes", "Are you sure you want to close this note without saving?"))
    end
    form.wait
    result
  end

  # Klango groups of the account, or nil after an error.
  def self.groups
    EltenLink::Community.groups(elten_link)
  rescue EltenLink::Error => e
    Log.warning("Note groups failed: #{e.message}")
    alert(_("Error"))
    nil
  end

  # Lets the user pick one of the groups; returns the group or nil.
  def self.choose_group(header, groups = self.groups)
    return nil if groups == nil
    if groups.empty?
      alert(p_("Notes", "You are not a member of any Klango group."))
      return nil
    end
    index = selector(groups.map(&:name), header: header, start_index: 0, cancel_index: -1)
    index == nil || index < 0 ? nil : groups[index]
  end

  def self.copy_to_device(note)
    title = note.name.to_s
    author = note.author.to_s
    title += " (#{author})" if author != "" && author != Session.name.to_s
    if Klangten::LocalNotes.create(title, note.text.to_s, author: author) != nil
      alert(p_("Notes", "The note has been saved on this device."))
    else
      alert(_("Error"))
    end
  end
end

# Notes kept on this device only.
class Scene_Notes_Local
  def initialize(index = 0)
    @index = index
  end

  def main
    @notes = Klangten::LocalNotes.all
    @sel = ListBox.new(labels, header: p_("Notes", "Notes on this device"), index: @index, flags: 0, quiet: false, empty_label: p_("Notes", "There are no notes on this device yet."))
    @sel.bind_context { |menu| context(menu) }
    @sel.focus
    loop do
      loop_update
      @sel.update
      $scene = Scene_Notes.new if key_pressed?(:key_escape)
      open(@notes[@sel.index]) if key_pressed?(:key_enter) && @notes.size > 0
      break if $scene != self
    end
  end

  def labels
    @notes.map { |note| "#{note.name}\r\n#{p_("Notes", "Modified")}: #{format_date(Time.at(note.modified), false, false)}" }
  end

  def reload(index = @sel.index)
    @notes = Klangten::LocalNotes.all
    @sel.options = labels
    @sel.index = [[index, @notes.size - 1].min, 0].max
    @sel.focus
  end

  def open(note)
    result = NotesKlango.edit_form(title: note.name, text: note.text)
    if result != nil && (result[0] != note.name || result[1] != note.text)
      Klangten::LocalNotes.update(note.id, name: result[0], text: result[1])
      alert(p_("Notes", "The note has been modified."))
    end
    reload
  end

  def context(menu)
    if @notes.size > 0
      note = @notes[@sel.index]
      menu.option(p_("Notes", "Open")) { open(note) }
      menu.option(p_("Notes", "Save on the server")) do
        begin
          EltenLink::Notes.create(elten_link, note.name, note.text)
        rescue EltenLink::Error => e
          Log.warning("Note upload failed: #{e.message}")
          alert(_("Error"))
        else
          alert(p_("Notes", "The note has been saved on the server."))
        end
      end if Session.logged?
      menu.option(_("Delete"), nil, :del) do
        if confirm(p_("Notes", "Do you really want to delete %{name}?") % { name: note.name })
          Klangten::LocalNotes.delete(note.id)
          alert(p_("Notes", "The note has been deleted."))
          reload
        end
      end
    end
    menu.option(p_("Notes", "New note"), nil, "n") do
      result = NotesKlango.edit_form
      if result != nil
        Klangten::LocalNotes.create(result[0], result[1], author: Session.name.to_s)
        alert(p_("Notes", "The note has been created"))
        reload(0)
      else
        @sel.focus
      end
    end
  end
end

# Notes shared with one Klango group (read and copy only).
class Scene_Notes_Group
  def initialize(group)
    @group = group
  end

  def main
    begin
      @notes = EltenLink::Notes.group_notes(elten_link, @group.id)
    rescue EltenLink::Error => e
      Log.warning("Group notes failed: #{e.message}")
      alert(_("Error"))
      $scene = Scene_Notes.new
      return
    end
    rows = @notes.map { |note| "#{note.name}\r\n#{p_("Notes", "Shared by")}: #{note.shared_by}" }
    @sel = ListBox.new(rows, header: p_("Notes", "Notes of %{group}") % { group: @group.name }, index: 0, flags: 0, quiet: false, empty_label: p_("Notes", "Nobody has shared a note with this group yet."))
    @sel.bind_context { |menu| context(menu) }
    @sel.focus
    loop do
      loop_update
      @sel.update
      $scene = Scene_Notes.new if key_pressed?(:key_escape)
      read(@notes[@sel.index]) if key_pressed?(:key_enter) && @notes.size > 0
      break if $scene != self
    end
  end

  def read(note)
    display_text(note.text.to_s, header: note.name.to_s)
    @sel.focus
  end

  def context(menu)
    return if @notes.empty?
    note = @notes[@sel.index]
    menu.option(p_("Notes", "Read")) { read(note) }
    menu.option(p_("Notes", "Copy to this device")) { NotesKlango.copy_to_device(note) }
    menu.useroption(note.shared_by) if note.shared_by.to_s != ""
  end
end
