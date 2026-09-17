# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebuilt on TeamConference (rooms, group rooms, calls, chat, room moderation); positional audio, cards, dice, recording, VST and whisper are not available.

# Conference scene: room list (group rooms of the user's forum groups first,
# then open rooms) and the room screen (participants, chat, microphone,
# options). Calls use the same room screen.
class Scene_Conference
  # Kept for quick actions saved by older versions; Elten channel identifiers
  # have no meaning for TeamConference and are ignored.
  def self.channel_target(id)
    { "type" => "channel", "id" => id.to_i }
  end

  def initialize(timeout=nil, prefocus=0, target=nil)
    @target = target
  end

  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene = Scene_Main.new
      return
    end
    unless Conference.available?
      alert(p_("Conference", "Conferences are not available on this platform."))
      $scene = Scene_Main.new
      return
    end
    unless Conference.connected?
      speak(p_("Conference", "Connecting to the conference server..."))
      unless Conference.wait_connected(12)
        if Conference.state == :disabled
          alert(p_("Conference", "Conferences are not enabled on the server."))
        else
          alert(p_("Conference", "Cannot connect to the conference server."))
        end
        $scene = Scene_Main.new
        return
      end
    end
    @client = Conference.client
    call_target = @target.is_a?(Hash) && @target["type"].to_s == "call"
    wait_for_call_room if call_target
    loop do
      if show_room_screen?
        result = room_screen
        # A call screen closes with the call instead of opening the room list.
        result = :close if call_target
      elsif call_target
        result = :close
      else
        result = room_list
      end
      break if result == :close
    end
    $scene = Scene_Main.new
  end

  def self.setvolumes
    dialog_open
    form = Form.new([
      lst_output = ListBox.new((0..200).to_a.reverse.map { |v| v.to_s + "%" }, header: p_("Conference", "Master volume"), index: 200 - Conference.output_volume),
      lst_stream = ListBox.new((0..200).to_a.reverse.map { |v| v.to_s + "%" }, header: p_("Conference", "Stream volume"), index: 200 - Conference.stream_volume),
      btn_close = Button.new(p_("Conference", "Close"))
    ], index: 0, silent: false, quiet: true)
    lst_output.on(:move) { Conference.output_volume = 200 - lst_output.index }
    lst_stream.on(:move) { Conference.stream_volume = 200 - lst_stream.index }
    btn_close.on(:press) { form.resume }
    form.cancel_button = btn_close
    form.accept_button = btn_close
    form.wait
    dialog_close
  end

  private

  def show_room_screen?
    return true if @client.in_room?
    call = @client.call_info
    call != nil && call[:direction] == :outgoing && call[:state] == :inviting
  end

  # After answering an incoming call the room is joined asynchronously.
  def wait_for_call_room
    deadline = Time.now.to_f + 10
    while Time.now.to_f < deadline
      break if @client.in_room?
      call = @client.call_info
      break if call == nil || (call[:direction] == :outgoing && call[:state] == :inviting)
      loop_update
    end
  end

  # ------------------------------------------------------------- room list

  def room_list
    @groups ||= load_groups
    entries = []
    revision = nil
    lst_rooms = TableBox.new([nil, p_("Conference", "Participants")], [], index: 0, header: p_("Conference", "Rooms"))
    refresh = Proc.new {
      index = lst_rooms.index
      entries = room_entries
      lst_rooms.rows = entries.map { |e| room_row(e) }
      lst_rooms.reload
      lst_rooms.clear_row_states
      entries.each_with_index { |e, i| lst_rooms.set_row_status(i, "conference_someoneonchannel", "", "") if room_users(e).size > 0 }
      lst_rooms.index = [[index.to_i, entries.size - 1].min, 0].max if entries.size > 0
    }
    refresh.call
    revision = @client.revision
    lst_rooms.focus
    result = nil
    lst_rooms.bind_context { |menu|
      entry = entries[lst_rooms.index]
      if entry != nil
        if entry[:room] == nil || entry[:room]["id"].to_i != @client.room_id.to_i
          menu.option(p_("Conference", "Join"), nil, "j") {
            result = :joined if join_entry(entry)
          }
        end
        if entry[:room] != nil && @client.room_moderator?(entry[:room])
          menu.option(p_("Conference", "Edit room"), nil, "e") { edit_room(entry[:room]) }
        end
        if entry[:room] != nil && entry[:room]["group_id"].to_s == "" && (entry[:room]["owner_id"].to_i == @client.user_id.to_i || @client.server_moderator?)
          menu.option(p_("Conference", "Delete room"), nil, :del) {
            if confirm(p_("Conference", "Are you sure you want to delete the room %{name}?") % { name: entry[:name] })
              @client.delete_room(entry[:room]["id"])
            end
          }
        end
      end
      if @client.in_room?
        menu.option(p_("Conference", "Return to the current room"), nil, "c") { result = :joined }
        menu.option(p_("Conference", "Leave"), nil, "J") { @client.leave_room }
      end
      menu.option(p_("Conference", "Create room"), nil, "n") {
        result = :joined if create_room
      }
      menu.option(p_("Conference", "Refresh"), nil, "r") {
        @groups = load_groups
        refresh.call
      }
    }
    loop do
      loop_update
      lst_rooms.update
      break if result != nil
      if @client.revision != revision
        revision = @client.revision
        refresh.call
      end
      if lst_rooms.selected?
        entry = entries[lst_rooms.index]
        if entry != nil
          if entry[:room] != nil && entry[:room]["id"].to_i == @client.room_id.to_i
            result = :joined
          elsif join_entry(entry)
            result = :joined
          end
          lst_rooms.focus if result == nil
        end
      end
      if key_pressed?(:key_escape)
        result = :close
      end
      break if result != nil
      if !@client.connected?
        alert(p_("Conference", "The connection to the conference server was lost."))
        result = :close
      end
    end
    result
  end

  def load_groups
    structure = EltenLink::Forum.structure(elten_link)
    structure.groups.select { |g| g.role == 1 || g.role == 2 }.map { |g| { gid: g.id.to_s, name: g.name.to_s } }.sort_by { |g| g[:name].downcase }
  rescue Exception => e
    Log.warning("Conference groups: #{e.class}: #{e.message}")
    []
  end

  def room_entries
    rooms = @client.rooms
    by_group = {}
    rooms.each { |r| by_group[r["group_id"].to_s] = r if r["group_id"].to_s != "" }
    entries = @groups.map { |g| { kind: :group, gid: g[:gid], name: g[:name], room: by_group[g[:gid]] } }
    open_rooms = rooms.select { |r| r["group_id"].to_s == "" && !TeamConference.truthy?(r["private"]) }
    open_rooms.sort_by { |r| r["name"].to_s.downcase }.each { |r| entries << { kind: :room, name: r["name"].to_s, room: r } }
    current = rooms.find { |r| r["id"].to_i == @client.room_id.to_i }
    if current != nil && !entries.any? { |e| e[:room] != nil && e[:room]["id"].to_i == current["id"].to_i }
      entries.unshift({ kind: :room, name: current["name"].to_s, room: current })
    end
    entries
  end

  def room_users(entry)
    entry[:room] == nil ? [] : Array(entry[:room]["users"])
  end

  def room_row(entry)
    parts = [entry[:name]]
    parts << " (" + p_("Conference", "group") + ")" if entry[:kind] == :group
    if entry[:room] != nil && TeamConference.truthy?(entry[:room]["has_password"])
      parts << EltenAPI::SpeechCommands::SoundCommand.new("listbox_itemclosed", " " + p_("EAPI_Speech", "Closed") + " ", "⣏⣹⠉⢹", immediate: true)
    end
    name = parts.size == 1 ? parts[0] : (parts.all? { |p| p.is_a?(String) } ? parts.join : EltenAPI::SpeechSequence.new(parts))
    users = room_users(entry).map { |u| u["nickname"].to_s == "" ? u["username"].to_s : u["nickname"].to_s }
    [name, users.join(", ")]
  end

  def join_entry(entry)
    mark = @client.event_mark
    if entry[:kind] == :group
      @client.join_group_room(entry[:gid], entry[:name])
    else
      password = nil
      if TeamConference.truthy?(entry[:room]["has_password"])
        password = input_text(p_("Conference", "Room password"), flags: EditBox::Flags::Password, text: "", escapable: true)
        loop_update
        return false if password == nil
      end
      @client.join_room(entry[:room]["id"], password)
    end
    event = Conference.wait_event(mark, ["room_joined", "error"], 10)
    if event != nil && event[1] == "room_joined"
      wait_until(3) { @client.in_room? }
      return true
    end
    message = event == nil ? "" : event[2]["message"].to_s
    @client.leave_room
    if message == "banned"
      alert(p_("Conference", "You are banned from this room."))
    elsif message != ""
      alert(p_("Conference", "You cannot join this room.") + " " + message)
    else
      alert(p_("Conference", "You cannot join this room."))
    end
    false
  end

  def wait_until(seconds)
    deadline = Time.now.to_f + seconds
    while Time.now.to_f < deadline
      return true if yield
      loop_update
    end
    false
  end

  # Returns [name, password, max_users] or nil.
  def room_form(title, name="", max_users=0, confirm_label=p_("Conference", "Create"))
    dialog_open
    edt_name = EditBox.new(p_("Conference", "Room name"), type: 0, text: name.to_s, quiet: true)
    edt_password = EditBox.new(p_("Conference", "Password (leave empty for none)"), type: EditBox::Flags::Password, text: "", quiet: true)
    edt_max = EditBox.new(p_("Conference", "Maximum number of participants (0 for no limit)"), type: 0, text: max_users.to_i.to_s, quiet: true)
    btn_ok = Button.new(confirm_label)
    btn_cancel = Button.new(p_("Conference", "Cancel"))
    form = Form.new([edt_name, edt_password, edt_max, btn_ok, btn_cancel], index: 0, silent: false, quiet: true)
    speak(title)
    result = nil
    btn_ok.on(:press) {
      if edt_name.text.strip == ""
        alert(p_("Conference", "Enter a room name."))
        form.focus
      else
        result = [edt_name.text.strip, edt_password.text, edt_max.text.to_i]
        form.resume
      end
    }
    btn_cancel.on(:press) { form.resume }
    form.cancel_button = btn_cancel
    form.accept_button = btn_ok
    form.wait
    dialog_close
    result
  end

  def create_room
    values = room_form(p_("Conference", "Create room"))
    return false if values == nil
    name, password, max_users = values
    mark = @client.event_mark
    @client.create_room(name, password: password, max_users: max_users)
    event = Conference.wait_event(mark, ["room_created", "error"], 10)
    if event == nil || event[1] != "room_created"
      message = event == nil ? "" : event[2]["message"].to_s
      alert(p_("Conference", "The room could not be created.") + (message == "" ? "" : " " + message))
      return false
    end
    room_id = event[2]["room_id"].to_i
    wait_until(2) { @client.room(room_id) != nil }
    mark = @client.event_mark
    @client.join_room(room_id, password)
    joined = Conference.wait_event(mark, ["room_joined", "error"], 10)
    if joined == nil || joined[1] != "room_joined"
      @client.leave_room
      alert(p_("Conference", "You cannot join this room."))
      return false
    end
    wait_until(3) { @client.in_room? }
    true
  end

  def edit_room(room)
    values = room_form(p_("Conference", "Edit room"), room["name"].to_s, room["max_users"].to_i, p_("Conference", "Save"))
    return if values == nil
    name, password, max_users = values
    mark = @client.event_mark
    @client.update_room(room["id"], name: name, password: password, max_users: max_users)
    event = Conference.wait_event(mark, ["room_list", "error"], 5)
    if event != nil && event[1] == "error"
      alert(p_("Conference", "The room could not be changed.") + " " + event[2]["message"].to_s)
    else
      alert(p_("Conference", "Room saved"), false)
    end
  end

  # ----------------------------------------------------------- room screen

  def room_screen
    @left = false
    @closed = false
    @users = []
    @chat = []
    @lst_users = ListBox.new([], header: p_("Conference", "Room participants"))
    @lst_chat = ListBox.new([], header: p_("Conference", "Chat history"))
    @edt_chat = EditBox.new(p_("Conference", "Chat message"), type: 0, text: "", quiet: true)
    @btn_mute = Button.new(mute_label)
    @btn_options = Button.new(p_("Conference", "More options"))
    @btn_leave = Button.new(leave_label)
    @btn_close = Button.new(p_("Conference", "Close"))
    @form = Form.new([@lst_users, @lst_chat, @edt_chat, @btn_mute, @btn_options, @btn_leave, @btn_close], index: 0, silent: false, quiet: true)
    speak(screen_title)
    @lst_users.bind_context { |menu| users_context(menu) }
    @lst_chat.bind_context { |menu|
      entry = @chat[@lst_chat.index]
      if entry != nil
        menu.option(p_("Conference", "Copy to clipboard"), nil, "c") {
          Clipboard.text = entry[:message]
          speak(_("Copied"))
        }
      end
      menu.submenu(p_("Conference", "Conference")) { |m| context(m) }
    }
    @edt_chat.bind_context { |menu| context(menu) }
    @btn_mute.bind_context { |menu| context(menu) }
    @btn_options.bind_context { |menu| context(menu) }
    @btn_leave.bind_context { |menu| context(menu) }
    @btn_close.bind_context { |menu| context(menu) }
    @edt_chat.on(:select) {
      @client.send_chat(@edt_chat.text)
      @edt_chat.set_text("")
    }
    @btn_mute.on(:press) { toggle_mute }
    @btn_options.on(:press) { $opencontextmenu = true }
    @btn_leave.on(:press) { leave_or_hang_up }
    @btn_close.on(:press) { close_screen }
    @form.cancel_button = @btn_close
    revision = nil
    loop do
      loop_update
      @form.update
      if @client.revision != revision
        revision = @client.revision
        refresh_screen
      end
      return :list if @left
      return :close if @closed
      return :list unless show_room_screen?
    end
  end

  def screen_title
    call = @client.call_info
    if call != nil
      name = call[:nickname].to_s == "" ? call[:username].to_s : call[:nickname].to_s
      return p_("Conference", "Calling %{user}") % { user: name } if call[:direction] == :outgoing && call[:state] != :active
      return p_("Conference", "Call with %{user}") % { user: name }
    end
    room = @client.room
    p_("Conference", "Room %{name}") % { name: room == nil ? "" : room["name"].to_s }
  end

  def mute_label
    @client.muted? ? p_("Conference", "Unmute microphone") : p_("Conference", "Mute microphone")
  end

  def leave_label
    @client.call_info != nil ? p_("Conference", "Hang up") : p_("Conference", "Leave room")
  end

  def refresh_screen
    selected = @users[@lst_users.index.to_i]
    @users = @client.users
    @lst_users.options = @users.map { |u| user_label(u) }
    index = selected == nil ? nil : @users.index { |u| u[:id] == selected[:id] }
    @lst_users.index = index || [[@lst_users.index.to_i, @users.size - 1].min, 0].max
    at_end = @lst_chat.index.to_i >= @chat.size - 1
    @chat = @client.chat
    @lst_chat.options = @chat.map { |c| chat_label(c) }
    @lst_chat.index = at_end ? [@chat.size - 1, 0].max : [@lst_chat.index.to_i, [@chat.size - 1, 0].max].min
    @btn_mute.label = mute_label
    @btn_leave.label = leave_label
  end

  def user_label(user)
    flags = []
    flags << p_("Conference", "you") if user[:me]
    if user[:owner]
      flags << p_("Conference", "owner")
    elsif user[:admin]
      flags << p_("Conference", "administrator")
    end
    flags << p_("Conference", "microphone muted") if user[:muted]
    flags << p_("Conference", "sound muted") if user[:deafened]
    flags << p_("Conference", "streaming") if user[:streaming]
    flags.empty? ? user[:nickname] : "#{user[:nickname]} (#{flags.join(', ')})"
  end

  def chat_label(entry)
    case entry[:kind]
    when :private
      p_("Conference", "Private message from %{user}: %{message}") % { user: entry[:nickname], message: entry[:message] }
    when :private_out
      p_("Conference", "Private message to %{user}: %{message}") % { user: entry[:nickname], message: entry[:message] }
    when :server
      p_("Conference", "Server message: %{message}") % { message: entry[:message] }
    else
      "#{entry[:nickname]}: #{entry[:message]}"
    end
  end

  def toggle_mute
    muted = !@client.muted?
    @client.mute = muted
    speak(muted ? p_("Conference", "Microphone muted") : p_("Conference", "Microphone unmuted"))
  end

  def toggle_deafen
    deafened = !@client.deafened?
    @client.deafen = deafened
    speak(deafened ? p_("Conference", "Sound muted") : p_("Conference", "Sound unmuted"))
  end

  def leave_or_hang_up
    if @client.call_info != nil
      @client.hang_up
    else
      @client.leave_room
    end
    @left = true
  end

  def close_screen
    question = @client.call_info != nil ? p_("Conference", "Do you want to hang up?") : p_("Conference", "Do you want to leave the room?")
    if confirm(question)
      leave_or_hang_up
    else
      @closed = true
    end
  end

  def users_context(menu)
    user = @users[@lst_users.index.to_i]
    if user != nil
      menu.useroption(user[:username]) if user[:username] != "" && !user[:me]
      unless user[:me]
        menu.option(p_("Conference", "Send private message"), nil, "p") {
          text = input_text(p_("Conference", "Private message to %{user}") % { user: user[:nickname] }, flags: 0, text: "", escapable: true, max_length: 500)
          @client.send_private(user[:id], text) if text != nil && text.strip != ""
          @form.focus
        }
        menu.option(p_("Conference", "Change user volume"), nil, "v") { user_volume(user) }
      end
      room = @client.room
      if !user[:me] && @client.room_moderator?(room)
        unless @client.room_moderator?(room, user[:id], user[:role])
          menu.option(p_("Conference", "Kick"), nil, "k") {
            @client.kick(user[:id]) if confirm(p_("Conference", "Are you sure you want to remove %{user} from the room?") % { user: user[:nickname] })
          }
          menu.option(p_("Conference", "Ban user"), nil, "b") { ban_user(user) }
        end
        if user[:muted]
          menu.option(p_("Conference", "Unmute user in the room"), nil, "u") { @client.room_mute(user[:id], false) }
        else
          menu.option(p_("Conference", "Mute user in the room"), nil, "u") { @client.room_mute(user[:id], true) }
        end
      end
      if !user[:me] && !user[:owner] && @client.can_manage_admins?(room)
        if user[:admin]
          menu.option(p_("Conference", "Remove room administrator"), nil, "a") { @client.set_room_admin(user[:id], false) }
        else
          menu.option(p_("Conference", "Make room administrator"), nil, "a") { @client.set_room_admin(user[:id], true) }
        end
      end
    end
    menu.submenu(p_("Conference", "Conference")) { |m| context(m) }
  end

  def user_volume(user)
    start = (@client.user_volume(user[:id]) * 100).round
    lst_volume = ListBox.new((0..200).to_a.reverse.map { |v| v.to_s + "%" }, header: p_("Conference", "User volume"), index: 200 - start, flags: 0, quiet: false)
    lst_volume.on(:move) { @client.set_user_volume(user[:id], (200 - lst_volume.index) / 100.0) }
    loop {
      loop_update
      lst_volume.update
      break if key_pressed?(:key_enter)
      if key_pressed?(:key_escape)
        @client.set_user_volume(user[:id], start / 100.0)
        break
      end
    }
    @form.focus
  end

  def ban_user(user)
    minutes = input_text(p_("Conference", "Ban duration in minutes (0 until the room is closed)"), flags: 0, text: "0", escapable: true)
    return @form.focus if minutes == nil
    @client.ban(user[:id], minutes.to_i)
    @form.focus
  end

  def context(menu)
    menu.option(@client.muted? ? p_("Conference", "Unmute microphone") : p_("Conference", "Mute microphone"), nil, "m") { toggle_mute }
    menu.option(@client.deafened? ? p_("Conference", "Unmute sound") : p_("Conference", "Mute sound"), nil, "d") { toggle_deafen }
    if @client.streaming?
      menu.option(p_("Conference", "Toggle pause"), nil, "P") {
        @client.stream_pause = !@client.stream_paused?
      }
      menu.option(p_("Conference", "Remove audio stream"), nil, "S") { Conference.remove_stream }
    else
      menu.option(p_("Conference", "Stream audio file"), nil, "s") {
        file = get_file(p_("Conference", "Select audio file"), path: EltenPath.with_separator(Dirs.documents), save: false, extensions: [".mp3", ".wav", ".ogg", ".m4a", ".flac", ".opus", ".aac", ".aiff"])
        if file != nil && !Conference.set_stream(file)
          alert(p_("Conference", "The file could not be streamed."))
        end
        @form.focus
      }
    end
    menu.option(p_("Conference", "Adjust volumes"), nil, "v") {
      Scene_Conference.setvolumes
      @form.focus
    }
    room = @client.room
    if room != nil && @client.room_moderator?(room)
      menu.option(p_("Conference", "Show banned users"), nil, "B") { show_bans }
      menu.option(p_("Conference", "Edit room"), nil, "e") {
        edit_room(room)
        @form.focus
      }
    end
    menu.option(leave_label, nil, "J") { leave_or_hang_up }
  end

  def show_bans
    mark = @client.event_mark
    @client.request_bans
    event = Conference.wait_event(mark, ["room_bans_result", "error"], 8)
    bans = event != nil && event[1] == "room_bans_result" ? Array(event[2]["bans"]) : []
    if bans.empty?
      alert(p_("Conference", "Nobody is banned from this room."))
      return @form.focus
    end
    names = bans.map { |b| b["nickname"].to_s == "" ? b["username"].to_s : b["nickname"].to_s }
    index = selector(names, header: p_("Conference", "Banned users"), start_index: 0, cancel_index: -1)
    if index >= 0 && confirm(p_("Conference", "Do you want to lift the ban of %{user}?") % { user: names[index] })
      @client.unban(bans[index]["user_id"])
    end
    @form.focus
  end
end
