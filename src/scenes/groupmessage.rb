# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# A private message to all members of a Klango group (Klango's "message to
# the group"): every member gets it as an ordinary message whose subject is
# the group name. Reached from the context menu of the messages and of a
# group in the forum.

module GroupMessage
  # group: EltenLink::CommunityGroup, or nil to choose one of my groups.
  # Returns true when the message was sent.
  def self.compose(group = nil)
    group ||= choose_group
    return false if group == nil
    targets = [["members", p_("GroupMessage", "All members")], ["moderators", p_("GroupMessage", "Moderators only")]]
    targets << ["suspended", p_("GroupMessage", "Suspended members")] if group.moderator
    sent = false
    form = Form.new([
      edt = EditBox.new(p_("GroupMessage", "Message to the members of %{group}") % { group: group.name }, type: EditBox::Flags::MultiLine, text: "", quiet: true),
      lst = ListBox.new(targets.map { |target| target[1] }, header: p_("GroupMessage", "Recipients")),
      btn_send = Button.new(p_("GroupMessage", "Send")),
      btn_cancel = Button.new(_("Cancel"))
    ])
    form.cancel_button = btn_cancel
    btn_cancel.on(:press) do
      form.resume if edt.text.to_s.strip == "" || confirm(p_("GroupMessage", "Are you sure you want to discard this message?"))
    end
    btn_send.on(:press) do
      if edt.text.to_s.strip == ""
        alert(p_("GroupMessage", "The message is empty."))
        next
      end
      begin
        count = EltenLink::Community.message_group(elten_link, group.id, edt.text.to_s, to: targets[lst.index][0])
      rescue EltenLink::Error => e
        Log.warning("Group message failed: #{e.message}")
        alert(e.message.to_s != "" ? e.message.to_s : _("Error"))
      else
        if count > 0
          alert(np_("GroupMessage", "The message has been sent to %{count} person.", "The message has been sent to %{count} people.", count) % { count: count })
        else
          alert(p_("GroupMessage", "Nobody in this group could receive the message."))
        end
        sent = true
        form.resume
      end
    end
    form.wait
    sent
  end

  def self.choose_group
    groups = EltenLink::Community.groups(elten_link)
    if groups.empty?
      alert(p_("GroupMessage", "You are not a member of any Klango group."))
      return nil
    end
    index = selector(groups.map(&:name), header: p_("GroupMessage", "Send a message to the members of which group?"), start_index: 0, cancel_index: -1)
    index == nil || index < 0 ? nil : groups[index]
  rescue EltenLink::Error => e
    Log.warning("Groups for a group message failed: #{e.message}")
    alert(_("Error"))
    nil
  end

  # The group with this id, if I am a member (for the forum's group list).
  def self.group_by_id(id)
    EltenLink::Community.groups(elten_link).find { |group| group.id == id.to_i }
  rescue EltenLink::Error
    nil
  end
end
