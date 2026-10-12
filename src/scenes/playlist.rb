# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The playlist: the screen (Scene_Playlist) and the playlist tab of the main
# window, both made of one KlangtenPlaylistView.
#
# Like in Klango there is one playlist: the list that plays or played last
# (also a Spotify list), otherwise the internal one (KlangtenPlaylist.shown_list).
# Scene_Playlist.new shows it, Scene_Playlist.new(path) a playlist file
# (M3U/M3U8/PLS), Scene_Playlist.new(list) a list made elsewhere.
#
# Items speak their title (or file name, or URL without query) and the
# duration when known; the playing item is marked. Playback goes through
# KlangtenPlaylist and keeps running when the screen is closed.
#
# Keys: Enter plays from the focused item, Space pauses and resumes,
# Left/Right seek by five seconds, Alt+Up/Down (Option on the Mac) change the
# volume without a word, Alt+Shift+Up/Down move the item, the main modifier
# with Up/Down the tempo, Shift with Up/Down the pitch, Shift with Left/Right
# the balance, Backspace resets them, Delete removes the item, Ctrl+Delete
# clears the list, Insert adds files. Everything else is in the context menu.
# Changes to the internal playlist are saved at once; a playlist file asks on
# closing the screen.
# When the scene was run inline (from the file manager) it returns to its
# caller, otherwise to the main menu.

class KlangtenPlaylistView
  VOLUME_STEPS = (0..100).step(5).to_a.freeze
  URL_PATTERN = /\A(https?|ftp|rtmp|rtsp|mms):\/\/\S+\z/i.freeze

  # The player keys come before the list: with a modifier the arrows would
  # otherwise move the focus or speak the item number.
  class SoundList < EltenAPI::Controls::ListBox
    def initialize(view, *args, **kw)
      super(*args, **kw)
      @view = view
    end

    def update
      return if @view.player_keys
      super
    end
  end

  attr_reader :list, :sel

  # list: the list to show; nil shows the playlist and follows it when another
  # list starts to play. tab: the header of the main window tab.
  # The block, if given, adds its options to the end of the context menu.
  def initialize(list = nil, tab: false, &menu_extra)
    @follow = list == nil
    @tab = tab
    @menu_extra = menu_extra
    @followed = KlangtenPlaylist.current_list
    @list = list || KlangtenPlaylist.shown_list
    index = 0
    index = KlangtenPlaylist.saved_index if @list.internal?
    index = KlangtenPlaylist.current_index if KlangtenPlaylist.current_list.equal?(@list) && KlangtenPlaylist.current_index != nil
    @sel = SoundList.new(self, labels, header: header, index: index, empty_label: p_("Klangten", "The playlist is empty."), quiet: true)
    @revision = @list.revision
    @marked = nil
    @marked_entry = nil
    update_marker(true)
    bind_context
  end

  def header
    if @list.internal?
      p_("Klangten", "My playlist")
    elsif @tab
      p_("Klangten", "Playlist: %{title}") % { title: title }
    else
      title
    end
  end

  def title
    @list.title.to_s != "" ? @list.title.to_s : File.basename(@list.path.to_s)
  end

  def focus
    @sel.focus
  end

  def say_option
    @sel.say_option
  end

  def focused_entry
    @list.empty? ? nil : @list[@sel.index]
  end

  # Shows another list (without playing it).
  def show(list, index = nil)
    @list = list
    @sel.header = header
    index ||= KlangtenPlaylist.current_list.equal?(list) ? KlangtenPlaylist.current_index : (list.internal? ? KlangtenPlaylist.saved_index : 0)
    refresh(index)
  end

  # One frame: follows the playlist, runs the list and the playback keys.
  def update
    follow_playlist
    refresh if @list.revision != @revision
    @sel.update
    update_marker
    say_notice
    if key_pressed?(:key_enter)
      play_focused
    elsif key_first_pressed?(:key_space)
      toggle_pause
    elsif key_pressed?(:key_delete) && modifier_held?(:main_modifier)
      clear
    elsif key_pressed?(:key_left, repeat: true) && !navigation_modifier_held? && !raw_key_held?(:key_shift)
      seek(-KlangtenPlaylist::SEEK_STEP)
    elsif key_pressed?(:key_right, repeat: true) && !navigation_modifier_held? && !raw_key_held?(:key_shift)
      seek(KlangtenPlaylist::SEEK_STEP)
    end
  end

  # The keys of Klangten's player (src/ui/controls/player.rb): Alt (Option)
  # with Up/Down the volume, the main modifier with Up/Down the tempo, Shift
  # with Up/Down the pitch, Shift with Left/Right the balance, Backspace back
  # to normal; Alt with Shift and Up/Down moves the item. True when one was used.
  def player_keys
    main = modifier_held?(:main_modifier)
    shift = raw_key_held?(:key_shift)
    alt = modifier_held?(:option)
    up = key_pressed?(:key_up, repeat: true)
    down = key_pressed?(:key_down, repeat: true)
    if alt && !main && (up || down)
      # releasing Alt afterwards must not open the menu
      cancel_pending_alt_menu
      if shift
        move(up ? -1 : 1)
      else
        KlangtenPlaylist.step_volume(up ? KlangtenPlaylist::KEY_VOLUME_STEP : -KlangtenPlaylist::KEY_VOLUME_STEP)
      end
      return true
    end
    return false if alt
    if main && !shift && (up || down)
      value = KlangtenPlaylist.change_tempo(up ? KlangtenPlaylist::TEMPO_STEP : -KlangtenPlaylist::TEMPO_STEP)
      play_sound("listbox_focus") if value == 0
      return true
    end
    if shift && !main
      if up || down
        value, base = KlangtenPlaylist.change_frequency(up ? 1 : -1)
        play_sound("listbox_focus") if value != nil && value == base
        return true
      end
      if key_pressed?(:key_left, repeat: true) || key_pressed?(:key_right, repeat: true)
        value = KlangtenPlaylist.change_pan(key_pressed?(:key_right, repeat: true) ? KlangtenPlaylist::PAN_STEP : -KlangtenPlaylist::PAN_STEP)
        play_sound("listbox_focus") if value == 0
        return true
      end
    end
    if !main && !shift && key_pressed?(0x08)
      KlangtenPlaylist.reset_sound
      return true
    end
    false
  end

  private

  # A new list started to play elsewhere (Spotify, a playlist file, a quick
  # action): the playlist shows it.
  def follow_playlist
    return if !@follow
    current = KlangtenPlaylist.current_list
    return if current == nil || current.equal?(@followed)
    @followed = current
    show(current) if !current.equal?(@list)
  end

  # A Spotify track the playlist skipped (Premium, not available).
  def say_notice
    return unless defined?(KlangtenSpotify) && KlangtenSpotify.respond_to?(:take_notice_text)
    text = KlangtenSpotify.take_notice_text
    alert(text, false) if text != nil
  end

  # ------------------------------------------------------------------ data

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
    @revision = @list.revision
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
      if @list.unsaveable
        nil
      elsif @list.internal?
        menu.option(p_("Klangten", "Export")) { save_as(export: true) }
      else
        menu.option(_("Save")) { save }
        menu.option(p_("Klangten", "Save as")) { save_as }
      end
      if !@list.internal?
        menu.option(p_("Klangten", "Show my playlist")) do
          show(KlangtenPlaylist.internal)
          focus
        end
      end
      @menu_extra.call(menu) if @menu_extra != nil
    end
  end

  # -------------------------------------------------------------- playback

  def play_focused
    return play_sound("border") if focused_entry == nil
    KlangtenPlaylist.play(@list, @sel.index)
    @followed = @list
    update_marker(true)
  end

  # Space pauses what plays; with nothing playing the internal playlist
  # continues where it was left and any other list starts at the focus.
  def toggle_pause
    if KlangtenPlaylist.active?
      result = KlangtenPlaylist.toggle_pause
      alert(p_("Klangten", "Paused"), false) if result == :paused
    elsif @list.internal?
      result = KlangtenPlaylist.toggle_pause
      alert(p_("Klangten", "The playlist is empty."), false) if result == nil
    else
      return play_focused
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
    elsif @list.path.to_s != ""
      File.dirname(File.expand_path(@list.path))
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

  public

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
      @sel.header = header
    end
    alert(p_("Klangten", "Saved"))
    @sel.focus
    true
  rescue StandardError => e
    Log.warning("Playlist could not be saved: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be saved."))
    false
  end
end

class Scene_Playlist
  # file: nil (the playlist), a playlist file, or a KlangtenPlaylist::List
  # made elsewhere (Spotify, the internal playlist from the file manager).
  def initialize(file = nil)
    if file.is_a?(KlangtenPlaylist::List)
      @given = file
      @file = nil
    else
      @file = file
    end
  end

  def main
    # Run inline (file manager, Spotify), $scene is the caller's scene; the
    # screen closes when another scene is chosen.
    @owner_scene = $scene
    list = load_list
    if @file != nil && list == nil
      $scene = Scene_Main.new if $scene == self
      return
    end
    @view = KlangtenPlaylistView.new(list) do |menu|
      menu.option(_("Close")) { close }
    end
    @view.focus
    @closing = false
    loop do
      loop_update
      @view.update
      break if !$scene.equal?(@owner_scene) || @closing
      close if key_pressed?(:key_escape)
      break if !$scene.equal?(@owner_scene) || @closing
    end
    $scene = Scene_Main.new if $scene == self
  end

  private

  # nil: the playlist (the view follows it). A playlist file that is the one
  # playing is that same list, so the marker and the changes stay in step.
  def load_list
    return @given if @given != nil
    return nil if @file == nil
    current = KlangtenPlaylist.current_list
    if current != nil && current.path.to_s != "" && File.expand_path(current.path.to_s) == File.expand_path(@file.to_s)
      return current
    end
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

  def close
    list = @view.list
    if !list.internal? && !list.unsaveable && list.dirty
      choice = select_action(
        [[:save, _("Save")], [:discard, p_("Klangten", "Discard changes")], [:cancel, _("Cancel")]],
        header: p_("Klangten", "The playlist has been changed."), cancel: :cancel
      )
      return @view.focus if choice == :cancel
      return if choice == :save && !@view.save
    end
    @closing = true
  end
end
