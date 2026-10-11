# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# What Klango shows about people besides Elten's lists: the status history of
# a user (own history on Control+F9), the contacts of a user, a comment on a
# contact, the special users with their roles and the recently changed audio
# avatars. Reached from the user menu and the Users menu.

module UsersKlango
  # Klango's role keys with Klangten's own names; unknown keys fall back to the
  # description sent by the server.
  def self.role_name(role)
    names = {
      "administrators" => p_("UsersKlango", "Administrator of the media catalog"),
      "editors" => p_("UsersKlango", "Editor of the media catalog"),
      "moderators" => p_("UsersKlango", "Forum moderator"),
      "developers" => p_("UsersKlango", "Developer"),
      "translators" => p_("UsersKlango", "Translator"),
      "testers21" => p_("UsersKlango", "Beta tester"),
      "klangovip" => p_("UsersKlango", "Very important person of the network"),
      "admin" => p_("UsersKlango", "Administrator"),
      "founder" => p_("UsersKlango", "Founder"),
      "moderator" => p_("UsersKlango", "Moderator"),
      "translator" => p_("UsersKlango", "Translator"),
      "tester" => p_("UsersKlango", "Tester")
    }
    names[role.key.to_s] || (role.name.to_s != "" ? role.name.to_s : role.key.to_s)
  end

  # Form for the comment on a contact (at most 75 characters, private or
  # public). Returns true when something was saved.
  def self.edit_comment(user)
    current = nil
    begin
      current = EltenLink::Community.contact_comments(elten_link)[user.to_s.downcase]
    rescue EltenLink::Error => e
      Log.warning("Contact comments failed: #{e.message}")
      alert(_("Error"))
      return false
    end
    saved = false
    form = Form.new([
      edt = EditBox.new(p_("UsersKlango", "Comment on %{user}") % { user: user }, text: current ? current.comment.to_s : "", max_length: 75),
      chk = CheckBox.new(p_("UsersKlango", "Others may see this comment"), checked: current ? current.public : false),
      btn_save = Button.new(_("Save")),
      btn_delete = Button.new(p_("UsersKlango", "Delete comment")),
      btn_cancel = Button.new(_("Cancel"))
    ])
    form.hide(btn_delete) if current == nil
    form.accept_button = btn_save
    form.cancel_button = btn_cancel
    btn_cancel.on(:press) { form.resume }
    btn_save.on(:press) do
      begin
        if edt.text.to_s.strip == ""
          EltenLink::Community.delete_contact_comment(elten_link, user)
        else
          EltenLink::Community.set_contact_comment(elten_link, user, edt.text.to_s.strip, public: chk.checked == true)
        end
      rescue EltenLink::Error => e
        alert(e.message.to_s != "" ? e.message.to_s : _("Error"))
      else
        alert(p_("UsersKlango", "The comment has been saved."))
        saved = true
        form.resume
      end
    end
    btn_delete.on(:press) do
      begin
        EltenLink::Community.delete_contact_comment(elten_link, user)
      rescue EltenLink::Error
        alert(_("Error"))
      else
        alert(p_("UsersKlango", "The comment has been deleted."))
        saved = true
        form.resume
      end
    end
    form.wait
    saved
  end
end

# Status history of a user; the own one can be cleaned up (Delete).
class Scene_StatusHistory
  def initialize(user = nil, toscene = nil)
    @user = user
    @toscene = toscene
  end

  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene = @toscene || Scene_Main.new
      return
    end
    @user ||= Session.name
    @own = @user.to_s.downcase == Session.name.to_s.downcase
    begin
      @entries = EltenLink::Community.status_history(elten_link, @user)
    rescue EltenLink::Error => e
      Log.warning("Status history failed: #{e.message}")
      alert(_("Error"))
      $scene = @toscene || Scene_Main.new
      return
    end
    header = @own ? p_("UsersKlango", "My status history") : p_("UsersKlango", "Status history of %{user}") % { user: @user }
    @sel = ListBox.new(labels, header: header, index: 0, flags: 0, quiet: false, empty_label: p_("UsersKlango", "There is no status in the history."))
    @sel.bind_context { |menu| context(menu) }
    @sel.focus
    loop do
      loop_update
      @sel.update
      $scene = @toscene || Scene_Main.new if key_pressed?(:key_escape)
      break if $scene != self
    end
  end

  def labels
    @entries.map { |entry| "#{format_date(Time.at(entry.time), false, false)}: #{entry.status}" }
  end

  def context(menu)
    return if @entries.empty?
    entry = @entries[@sel.index]
    menu.option(p_("UsersKlango", "Copy to the clipboard")) do
      Clipboard.text = entry.status.to_s
      alert(p_("UsersKlango", "Copied to the clipboard."))
    end
    return if !@own
    menu.option(_("Delete"), nil, :del) do
      if confirm(p_("UsersKlango", "Do you want to delete this status from your history?"))
        begin
          EltenLink::Community.delete_status(elten_link, entry.id)
        rescue EltenLink::Error
          alert(_("Error"))
        else
          @entries.delete(entry)
          @sel.options = labels
          @sel.index = [[@sel.index, @entries.size - 1].min, 0].max
          play_sound("editbox_delete")
          @sel.focus
        end
      end
    end
  end
end

# The contacts of a user. Other users' lists only show the contacts they gave
# a public comment.
class Scene_UserContacts
  def initialize(user, toscene = nil)
    @user = user
    @toscene = toscene
  end

  def main
    begin
      complete, @contacts = EltenLink::Community.contacts_of(elten_link, @user)
    rescue EltenLink::Error => e
      Log.warning("Contacts of user failed: #{e.message}")
      alert(_("Error"))
      $scene = @toscene || Scene_Main.new
      return
    end
    if @contacts.empty?
      alert(complete ? p_("UsersKlango", "The contact list is empty.") : p_("UsersKlango", "%{user} has not made any contacts public.") % { user: @user })
      $scene = @toscene || Scene_Main.new
      return
    end
    rows = @contacts.map { |contact| contact.comment.to_s == "" ? contact.user : "#{contact.user}: #{contact.comment}" }
    header = complete ? p_("UsersKlango", "My contacts with comments") : p_("UsersKlango", "Public contacts of %{user}") % { user: @user }
    @sel = ListBox.new(rows, header: header, index: 0, flags: 0, quiet: false)
    @sel.bind_context { |menu| menu.useroption(@contacts[@sel.index].user) }
    @sel.focus
    loop do
      loop_update
      @sel.update
      usermenu(@contacts[@sel.index].user, false) if key_pressed?(:key_enter)
      $scene = @toscene || Scene_Main.new if key_pressed?(:key_escape)
      break if $scene != self
    end
  end
end

# Special users: everybody with a role in the Klango network.
class Scene_Users_Roles
  def main
    begin
      @holders = EltenLink::Community.roles(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Roles failed: #{e.message}")
      alert(_("Error"))
      $scene = Scene_Main.new
      return
    end
    rows = @holders.map { |holder| "#{holder.user}: #{holder.roles.map { |role| UsersKlango.role_name(role) }.join(", ")}" }
    @sel = ListBox.new(rows, header: p_("UsersKlango", "Special users"), index: 0, flags: 0, quiet: false, empty_label: p_("UsersKlango", "Nobody has a special role."))
    @sel.bind_context { |menu| menu.useroption(@holders[@sel.index].user) if !@holders.empty? }
    @sel.focus
    loop do
      loop_update
      @sel.update
      usermenu(@holders[@sel.index].user, false) if key_pressed?(:key_enter) && !@holders.empty?
      $scene = Scene_Main.new if key_pressed?(:key_escape)
      break if $scene != self
    end
  end
end

# The audio avatars changed last; Enter plays one.
class Scene_Users_RecentAvatars
  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene = Scene_Main.new
      return
    end
    begin
      @avatars = EltenLink::Community.recent_avatars(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Recent avatars failed: #{e.message}")
      alert(_("Error"))
      $scene = Scene_Main.new
      return
    end
    rows = @avatars.map { |avatar| "#{avatar.user}, #{format_date(Time.at(avatar.time), false, false)}" }
    @sel = ListBox.new(rows, header: p_("UsersKlango", "Recently changed audio avatars"), index: 0, flags: 0, quiet: false, empty_label: p_("UsersKlango", "Nobody has changed an audio avatar yet."))
    @sel.bind_context do |menu|
      next if @avatars.empty?
      user = @avatars[@sel.index].user
      menu.option(p_("Klangten", "Play audio avatar")) { play_audio_avatar(user) }
      menu.useroption(user)
    end
    @sel.focus
    loop do
      loop_update
      @sel.update
      play_audio_avatar(@avatars[@sel.index].user) if key_pressed?(:key_enter) && !@avatars.empty?
      $scene = Scene_Main.new if key_pressed?(:key_escape)
      break if $scene != self
    end
  end
end
