# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The playlist editor: the internal playlist (Scene_Playlist.new) or a
# playlist file (Scene_Playlist.new(path), M3U/M3U8/PLS).
#
# Items speak their title (or file name, or URL without query) and the
# duration when known; the playing item is marked. Playback goes through
# KlangtenPlaylist and keeps running when the screen is closed.
#
# Keys: Enter plays from the focused item, Space pauses and resumes,
# Left/Right seek by five seconds, Shift+Up/Down (and Alt+Up/Down where the main
# modifier is Ctrl) move the item, Delete removes it, Ctrl+Delete clears the
# list, Insert adds files, Ctrl+S switches shuffle, Ctrl+R repeat and Ctrl+I
# speaks what is playing. Everything else is in the context menu. Changes to
# the internal playlist are saved at once; a playlist file asks on closing.
# When the scene was run inline (from the file manager) it returns to its
# caller, otherwise to the main menu.

class Scene_Playlist
  VOLUME_STEPS = (0..100).step(5).to_a.freeze
  URL_PATTERN = /\A(https?|ftp|rtmp|rtsp|mms):\/\/\S+\z/i.freeze

  def initialize(file = nil)
    @file = file
  end

  def main
    @list = load_list
    if @list == nil
      $scene = Scene_Main.new if $scene == self
      return
    end
    header = @list.internal? ? p_("Klangten", "My playlist") : File.basename(@file.to_s)
    index = 0
    index = KlangtenPlaylist.saved_index if @list.internal?
    index = KlangtenPlaylist.current_index if KlangtenPlaylist.current_list.equal?(@list) && KlangtenPlaylist.current_index != nil
    @sel = ListBox.new(labels, header: header, index: index, empty_label: p_("Klangten", "The playlist is empty."), quiet: true)
    @marked = nil
    @marked_entry = nil
    update_marker(true)
    bind_context
    @sel.focus
    @closing = false
    loop do
      loop_update
      @sel.update
      update_marker
      break if $scene != self || @closing
      if key_pressed?(:key_escape)
        close
      elsif key_pressed?(:key_enter)
        play_focused
      elsif key_first_pressed?(:key_space)
        toggle_pause
      elsif key_pressed?(:key_delete) && modifier_held?(:main_modifier)
        clear
      elsif (key_pressed?(:key_up) || key_pressed?(:key_down)) && move_modifier_held?
        move(key_pressed?(:key_up) ? -1 : 1)
      elsif key_pressed?(:key_left, repeat: true) && !navigation_modifier_held? && !raw_key_held?(:key_shift)
        seek(-KlangtenPlaylist::SEEK_STEP)
      elsif key_pressed?(:key_right, repeat: true) && !navigation_modifier_held? && !raw_key_held?(:key_shift)
        seek(KlangtenPlaylist::SEEK_STEP)
      end
      break if $scene != self || @closing
    end
    $scene = Scene_Main.new if $scene == self
  end

  private

  # ------------------------------------------------------------------ data

  def load_list
    return KlangtenPlaylist.internal if @file == nil
    if File.file?(@file)
      KlangtenPlaylist.read_file(@file)
    else
      KlangtenPlaylist::List.new([], path: @file)
    end
  rescue StandardError => e
    Log.warning("Playlist file could not be read: #{e.class}: #{e.message}")
    alert(p_("Klangten", "This playlist cannot be read."))
    nil
  end

  def label(entry)
    text = entry.name
    text += " (#{KlangtenPlaylist.format_duration(entry.length)})" if entry.length != nil
    text
  end

  def labels
    @list.entries.map { |entry| label(entry) }
  end

  def playing_status
    @playing_status ||= ListBox.item_status("listbox_itempinned", p_("Klangten", "Playing"), p_("Klangten", "Playing"))
  end

  # Rebuilds the item texts and the marker of the playing item.
  def refresh(index = @sel.index)
    @sel.options = labels
    @sel.index = [[index.to_i, @list.size - 1].min, 0].max
    @marked = nil
    update_marker(true)
  end

  # Follows the engine: the marker moves with the playing entry, and the
  # length it learns is shown in the item.
  def update_marker(force = false)
    entry = KlangtenPlaylist.current_list.equal?(@list) ? KlangtenPlaylist.current_entry : nil
    index = entry == nil ? nil : @list.index_of(entry)
    return if !force && index == @marked && entry.equal?(@marked_entry) && (entry == nil || @marked_length == entry.length)
    @sel.clear_item_state(@marked, playing_status) if @marked != nil && @marked < @list.size
    if entry != nil && @marked_length != entry.length && index != nil
      @sel.options[index] = label(entry)
    end
    @marked = index
    @marked_entry = entry
    @marked_length = entry == nil ? nil : entry.length
    @sel.set_item_state(index, playing_status) if index != nil
  end

  def move_modifier_held?
    return false if modifier_held?(:main_modifier)
    raw_key_held?(:key_shift) || (EltenAPI::KeyboardScheme.main_modifier == :control && modifier_held?(:option))
  end

  def focused_entry
    @list.empty? ? nil : @list[@sel.index]
  end

  # --------------------------------------------------------------- context

  def bind_context
    @sel.bind_context do |menu|
      active = KlangtenPlaylist.active?
      if !@list.empty?
        menu.option(p_("Klangten", "Play from here")) { play_focused }
      end
      if active
        menu.option(KlangtenPlaylist.paused? ? p_("Klangten", "Resume") : p_("Klangten", "Pause")) { toggle_pause }
        menu.option(p_("Klangten", "Previous")) { skip(:previous) }
        menu.option(p_("Klangten", "Next")) { skip(:next) }
        menu.option(p_("Klangten", "Stop")) do
          KlangtenPlaylist.stop
          update_marker(true)
          alert(p_("Klangten", "Stopped"), false)
        end
      end
      menu.option(p_("Klangten", "What is playing"), nil, "i") { speak(KlangtenPlaylist.status_text) }
      menu.option(KlangtenPlaylist.shuffle? ? p_("Klangten", "Shuffle: on") : p_("Klangten", "Shuffle: off"), nil, "s") { toggle_shuffle }
      menu.option(KlangtenPlaylist.repeat? ? p_("Klangten", "Repeat: on") : p_("Klangten", "Repeat: off"), nil, "r") { toggle_repeat }
      menu.option(p_("Klangten", "Volume: %{volume}") % { volume: KlangtenPlaylist.volume }) { choose_volume }
      if focused_entry != nil
        menu.option(p_("Klangten", "Edit title")) { edit_title }
      end
      menu.option(p_("Klangten", "Add file"), nil, :ins) { add_file }
      menu.option(p_("Klangten", "Add folder")) { add_folder }
      menu.option(p_("Klangten", "Add address")) { add_url }
      if focused_entry != nil
        menu.option(p_("Klangten", "Remove"), nil, :del) { remove }
        menu.option(p_("Klangten", "Clear the playlist")) { clear }
        menu.option(p_("Klangten", "Move up")) { move(-1) }
        menu.option(p_("Klangten", "Move down")) { move(1) }
      end
      if @list.internal?
        menu.option(p_("Klangten", "Export")) { save_as(export: true) }
      else
        menu.option(_("Save")) { save }
        menu.option(p_("Klangten", "Save as")) { save_as }
      end
      menu.option(_("Close")) { close }
    end
  end

  # -------------------------------------------------------------- playback

  def play_focused
    return play_sound("border") if focused_entry == nil
    KlangtenPlaylist.play(@list, @sel.index)
    update_marker(true)
  end

  def toggle_pause
    if !KlangtenPlaylist.active?
      return play_focused if !@list.internal?
      result = KlangtenPlaylist.toggle_pause
      alert(p_("Klangten", "The playlist is empty."), false) if result == nil
    else
      result = KlangtenPlaylist.toggle_pause
      alert(p_("Klangten", "Paused"), false) if result == :paused
    end
    update_marker(true)
  end

  def skip(direction)
    entry = direction == :next ? KlangtenPlaylist.next : KlangtenPlaylist.previous
    if entry == nil
      alert(p_("Klangten", "End of the playlist"), false)
    else
      update_marker(true)
      index = @list.index_of(entry)
      @sel.index = index if index != nil
      @sel.say_option
    end
  end

  def seek(delta)
    play_sound("border") if !KlangtenPlaylist.seek(delta)
  end

  def toggle_shuffle
    KlangtenPlaylist.shuffle = !KlangtenPlaylist.shuffle?
    alert(KlangtenPlaylist.shuffle? ? p_("Klangten", "Shuffle: on") : p_("Klangten", "Shuffle: off"), false)
  end

  def toggle_repeat
    KlangtenPlaylist.repeat = !KlangtenPlaylist.repeat?
    alert(KlangtenPlaylist.repeat? ? p_("Klangten", "Repeat: on") : p_("Klangten", "Repeat: off"), false)
  end

  def choose_volume
    labels = VOLUME_STEPS.map(&:to_s)
    start = VOLUME_STEPS.index(VOLUME_STEPS.min_by { |step| (step - KlangtenPlaylist.volume).abs }) || 0
    index = selector(labels, header: p_("Klangten", "Volume"), start_index: start, cancel_index: -1)
    KlangtenPlaylist.volume = VOLUME_STEPS[index] if index != nil && index >= 0
    @sel.focus
  end

  # --------------------------------------------------------------- editing

  def edit_title
    entry = focused_entry
    return if entry == nil
    title = input_text(p_("Klangten", "Title"), text: entry.title || entry.name, escapable: true)
    if title != nil
      @list.rename(@sel.index, title.strip)
      refresh
    end
    @sel.focus
  end

  def add_entries(entries)
    entries = Array(entries)
    return alert(p_("Klangten", "No audio files found.")) if entries.empty?
    at = @list.empty? ? 0 : @sel.index + 1
    first = @list.add(entries, at: at)
    refresh(first)
    alert(np_("Klangten", "%{count} entry added to the playlist.", "%{count} entries added to the playlist.", entries.size) % { count: entries.size })
    @sel.focus
  end

  def start_folder
    entry = focused_entry
    if entry != nil && !entry.url? && File.directory?(File.dirname(entry.location))
      File.dirname(entry.location)
    elsif @file != nil
      File.dirname(File.expand_path(@file))
    else
      ""
    end
  end

  def add_file
    file = get_file(p_("Klangten", "Add file"), path: start_folder, extensions: FilesTree::AUDIO_EXTENSIONS + KlangtenPlaylist::PLAYLIST_EXTENSIONS)
    if file == nil
      @sel.focus
      return
    end
    if KlangtenPlaylist.playlist_file?(file)
      begin
        add_entries(KlangtenPlaylist.read_file(file).entries)
      rescue StandardError
        alert(p_("Klangten", "This playlist cannot be read."))
      end
    else
      add_entries([KlangtenPlaylist::Entry.new(file)])
    end
  end

  def add_folder
    folder = get_folder(p_("Klangten", "Add folder"), path: start_folder)
    if folder == nil
      @sel.focus
      return
    end
    files = EltenAPI::Tasks.run(title: p_("Klangten", "Searching for audio files...")) do |progress, token|
      KlangtenPlaylist.collect_audio_files(folder, FilesTree::AUDIO_EXTENSIONS) do |count|
        token.raise_if_cancelled!
        progress.update(count, message: np_("Klangten", "%{count} file found", "%{count} files found", count) % { count: count })
      end
    end
    if files.size >= KlangtenPlaylist::MAX_FOLDER_FILES
      alert(p_("Klangten", "Only the first %{count} files are added.") % { count: KlangtenPlaylist::MAX_FOLDER_FILES })
    end
    add_entries(files.map { |path| KlangtenPlaylist::Entry.new(path) })
  rescue EltenAPI::Tasks::Cancelled
    @sel.focus
  end

  def add_url
    url = input_text(p_("Klangten", "Address of the stream or file"), text: "", escapable: true)
    if url == nil || url.strip == ""
      @sel.focus
      return
    end
    url = url.strip
    return alert(p_("Klangten", "This is not a valid address.")) if !url.match?(URL_PATTERN)
    add_entries([KlangtenPlaylist::Entry.new(url)])
  end

  def remove
    return play_sound("border") if focused_entry == nil
    @list.remove(@sel.index)
    refresh
    @sel.say_option if !@list.empty?
    alert(p_("Klangten", "The playlist is empty."), false) if @list.empty?
  end

  def clear
    return play_sound("border") if @list.empty?
    if confirm(p_("Klangten", "Do you really want to remove all entries from the playlist?"))
      @list.clear
      refresh(0)
      alert(p_("Klangten", "The playlist is empty."), false)
    end
    @sel.focus
  end

  def move(delta)
    return play_sound("border") if focused_entry == nil
    target = @list.move(@sel.index, delta)
    return play_sound("border") if target == nil
    refresh(target)
    @sel.say_option
  end

  # ---------------------------------------------------------------- saving

  def save
    return save_as if @list.path.to_s == ""
    @list.save
    alert(p_("Klangten", "Saved"))
    true
  rescue StandardError => e
    Log.warning("Playlist could not be saved: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be saved."))
    false
  end

  # Asks for folder, name and format; export writes a copy and keeps the
  # list bound to where it was (the internal playlist).
  def save_as(export: false)
    folder = @list.path.to_s != "" ? File.dirname(File.expand_path(@list.path)) : KlangtenPlaylist.playlists_dir(create: true)
    folder = get_folder(p_("Klangten", "Folder for the playlist"), path: folder)
    return (@sel.focus; false) if folder == nil
    default_name = @list.path.to_s != "" ? File.basename(@list.path, File.extname(@list.path)) : p_("Klangten", "My playlist")
    name = input_text(p_("Klangten", "Playlist name"), text: default_name, escapable: true)
    return (@sel.focus; false) if name == nil || name.strip == ""
    name = name.strip
    if !KlangtenPlaylist.playlist_file?(name)
      format = select_action([[".m3u", "M3U"], [".pls", "PLS"], [:cancel, _("Cancel")]], header: p_("Klangten", "Format"), cancel: :cancel)
      return (@sel.focus; false) if format == :cancel
      name += format
    end
    path = File.join(folder, name)
    if File.exist?(path) && !confirm(p_("Klangten", "%{file} already exists. Do you want to replace it?") % { file: name })
      @sel.focus
      return false
    end
    if export
      KlangtenPlaylist.write_file(path, @list.entries)
    else
      @list.save(path)
      @file = path
      @sel.header = File.basename(path)
    end
    alert(p_("Klangten", "Saved"))
    @sel.focus
    true
  rescue StandardError => e
    Log.warning("Playlist could not be saved: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be saved."))
    false
  end

  def close
    if !@list.internal? && @list.dirty
      choice = select_action(
        [[:save, _("Save")], [:discard, p_("Klangten", "Discard changes")], [:cancel, _("Cancel")]],
        header: p_("Klangten", "The playlist has been changed."), cancel: :cancel
      )
      return @sel.focus if choice == :cancel
      return if choice == :save && !save
    end
    @closing = true
  end
end
