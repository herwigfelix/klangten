# FileManager - a former Elten component (author: pajper), Copyright (C) Dawid Pieper.
# Licensed under the GNU General Public License, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: built into Klangten and opened from the
# Files menu (hidden from the Programs menu); "Set as audio avatar" for audio files.
=begin Elten3AppInfo
{
  "id": "8c8d86ce-dc24-453f-a388-e9b5e8626c5c",
  "name": "FileManager",
  "menu": { "hidden": true },
  "version": "1.1",
  "build_id": 20260831001,
  "EltenAPIVersion": "3.0.1",
  "author": "pajper",
  "main_language": "en",
  "supported_languages": ["en", "de", "es", "pl", "tr"],
  "main_class": "ProgramFileManager",
  "platforms": ["all"],
  "gems": ["pdf-reader", "docx", "gepub", "ruby-rtf"],
  "description": "Simple file manager"
}
=end Elten3AppInfo

require "fileutils"
require_relative "lib/file_manager/playlist"
require_relative "lib/file_manager/playlist_store"
require_relative "lib/file_manager/playlist_playback"
require_relative "lib/file_manager/playlist_settings"
require_relative "lib/file_manager/menu_integration"
require_relative "lib/file_manager/main_tab"

class ProgramFileManager < Program
  ARCHIVE_EXTENSIONS = [".zip"].freeze
  RECORD_EXTENSIONS = [".ogg", ".opus", ".wav"].freeze
  AUDIO_EXTENSIONS = %w[
    .mp3 .ogg .wav .mid .wma .flac .aac .opus .m4a .mov .mp4 .avi
    .mts .aiff .m4v .mkv .vob .m2ts .w64 .mod
  ].freeze
  PLAYLIST_EXTENSIONS = FileManagerPlaylist::PLAYLIST_EXTENSIONS
  MAIN_PLAYLIST_ACTION = "filemanager_background_playlist".freeze
  DIRECTORY_SCAN_TIMEOUT = 10
  PLAYLIST_VOLUME_STEP = 5

  class << self
    def activate
      @playlist_store = FileManagerPlaylist::Store.new(
        reader: proc { |path, default| read_json(path, default: default) },
        writer: proc { |path, data| write_json(path, data) }
      )
      @playlist_settings = FileManagerPlaylist::Settings.new(
        reader: proc { |path, default| read_json(path, default: default) },
        writer: proc { |path, data| write_json(path, data) }
      )
      @playlist_controls = []
      @playlist_playback = FileManagerPlaylist::Playback.new(store: @playlist_store) do |playback, reason|
        @menu_integration.refresh if @menu_integration != nil
        refresh_playlist_controls(playback, reason)
      end
      @menu_integration = FileManagerPlaylist::MenuIntegration.new(
        scene_class: defined?(Scene_Main) ? Scene_Main : nil,
        menu_module: defined?(GlobalMenu) ? GlobalMenu : nil,
        action_id: MAIN_PLAYLIST_ACTION,
        label: proc { _("Open playlist") },
        main_visible: proc { playlist_visible?("show_on_main_window") },
        menu_visible: proc { playlist_visible?("show_in_main_menu") }
      ) { open_playlist_scene }
      @menu_integration.install
      if defined?(Scene_Main)
        @main_tab_integration = FileManagerPlaylist::MainTabIntegration.new(
          scene_class: Scene_Main,
          visible: proc { playlist_visible?("show_on_main_window") },
          control: proc do |scene, current|
            controller = scene.instance_variable_get(:@filemanager_playlist_tab_controller)
            if controller == nil
              controller = new(false, mode: :playlist)
              scene.instance_variable_set(:@filemanager_playlist_tab_controller, controller)
            end
            controller.build_main_playlist_control(current, scene)
          end
        )
        @main_tab_integration.install
      end
      register_playlist_quickactions
      extension(:filemanager_playlists) do |service|
        service.tick(interval: 0.1) { @playlist_playback.tick }
        service.settings { |settings| add_playlist_settings(settings) }
        service.stop { |_reason| shutdown_playlists }
      end
    end

    def playlist_store
      @playlist_store
    end

    def playlist_playback
      @playlist_playback
    end

    def playlist_settings
      @playlist_settings
    end

    def playlist_setting(key)
      @playlist_settings == nil ? FileManagerPlaylist::Settings::DEFAULTS.fetch(key.to_s) : @playlist_settings[key]
    end

    def set_playlist_setting(key, value)
      return false if @playlist_settings == nil
      result = @playlist_settings[key] = value == true
      @menu_integration.refresh if @menu_integration != nil
      result
    end

    def playlist_visible?(setting)
      @playlist_playback != nil && !@playlist_playback.playlist.empty? && playlist_setting(setting)
    end

    def add_playlist_settings(settings)
      settings.category(_("FileManager"))
      settings.boolean(:show_on_main_window,
        label: _("Show playlist in the main window"),
        get: proc { playlist_setting("show_on_main_window") },
        set: proc { |value| set_playlist_setting("show_on_main_window", value) })
      settings.boolean(:show_in_main_menu,
        label: _("Show playlist in the main menu"),
        get: proc { playlist_setting("show_in_main_menu") },
        set: proc { |value| set_playlist_setting("show_in_main_menu", value) })
      settings.boolean(:autoplay_first_item,
        label: _("Automatically play the playlist after adding its first item"),
        get: proc { playlist_setting("autoplay_first_item") },
        set: proc { |value| set_playlist_setting("autoplay_first_item", value) })
    end

    def register_playlist_quickactions
      register_quickaction(:playlist_play_pause, _("Playlist: play or pause")) do
        toggle_playlist_playback
      end
      register_quickaction(:playlist_previous, _("Playlist: previous track")) do
        previous_playlist_track
      end
      register_quickaction(:playlist_next, _("Playlist: next track")) do
        next_playlist_track
      end
      register_quickaction(:playlist_volume_down, _("Playlist: volume down")) do
        change_playlist_volume(-PLAYLIST_VOLUME_STEP)
      end
      register_quickaction(:playlist_volume_up, _("Playlist: volume up")) do
        change_playlist_volume(PLAYLIST_VOLUME_STEP)
      end
    end

    def toggle_playlist_playback
      playback = @playlist_playback
      return playlist_feedback(_("The playlist is empty."), false) if playback == nil || playback.playlist.empty?
      playback.active? ? playback.toggle_pause : playback.start(playback.playlist, index: playback.current_index)
    end

    def previous_playlist_track
      playback = @playlist_playback
      return playlist_feedback(_("The playlist is empty."), false) if playback == nil || playback.playlist.empty?
      return playback.previous if playback.active?
      index = [playback.current_index - 1, 0].max
      playback.start(playback.playlist, index: index)
    end

    def next_playlist_track
      playback = @playlist_playback
      return playlist_feedback(_("The playlist is empty."), false) if playback == nil || playback.playlist.empty?
      return playback.next if playback.active?
      index = [playback.current_index + 1, playback.playlist.entries.size - 1].min
      playback.start(playback.playlist, index: index)
    end

    def change_playlist_volume(offset)
      playback = @playlist_playback
      return false if playback == nil
      playback.set_volume(playback.volume + offset.to_i)
    end

    def playlist_feedback(message, result = true)
      speak(message.to_s) if message != nil && message.to_s != ""
      result
    rescue Exception
      result
    end

    def register_playlist_control(control)
      @playlist_controls ||= []
      @playlist_controls << control if !@playlist_controls.include?(control)
      control
    end

    def unregister_playlist_control(control)
      @playlist_controls.delete(control) if @playlist_controls != nil
      control
    end

    def refresh_playlist_controls(playback = @playlist_playback, reason = :state)
      return if playback == nil || @playlist_controls == nil
      @playlist_controls.delete_if do |control|
        begin
          refresh = control.instance_variable_get(:@filemanager_playlist_refresh)
          if refresh == nil
            true
          else
            index = reason == :automatic_advance ? playback.current_index : control.index
            refresh.call(index)
            false
          end
        rescue Exception
          true
        end
      end
    end

    def open_playlist_scene
      insert_scene(new(false, mode: :playlist), true)
      true
    end

    def shutdown_playlists
      @playlist_playback.shutdown if @playlist_playback != nil
      @main_tab_integration.uninstall if @main_tab_integration != nil
      @menu_integration.uninstall if @menu_integration != nil
      @playlist_controls.clear if @playlist_controls != nil
    end
  end

  def initialize(startpath = false, mode: :files)
    @startpath = startpath == false ? "" : startpath.to_s
    @mode = mode
  end

  def program_main
    return edit_playlist(playlist_store.current_playlist, storage: :current) if @mode == :playlist
    @tree = FilesTree.new(_("FileManager"), path: @startpath, hide_files: false, quiet: false, use_sounds: true)
    bind_tree_menus
    runner = Runner.new
    runner.on_key(:key_escape) { |current| current.stop }
    runner.on_key(0x44) { speak_directory_count if key_held?(0x11) }
    runner.on_key(0x49) { speak_selected_size if key_held?(0x11) }
    runner.on_key(0x4f) { open_associated(selected_path) if key_held?(0x11) }
    runner.on_key(:key_enter) { handle_enter }
    runner.on_tick { @tree.update }
    runner.run
  ensure
    @tree.blur if @tree != nil
  end

  def bind_tree_menus
    @tree.bind_filesmenu { |menu| build_files_menu(menu) }
    @tree.bind_createmenu { |menu| build_create_menu(menu) }
    @tree.bind_menu { |menu| build_context_menu(menu) }
  end

  def build_files_menu(menu)
    file = selected_path
    ext = File.extname(file).downcase
    menu.option(_("Open in an associated application")) { open_associated(file) }
    if File.directory?(file)
      menu.option(_("Add all audio files to playlist")) { add_directory_to_current_playlist(file) }
    elsif AUDIO_EXTENSIONS.include?(ext)
      menu.option(_("Add to playlist")) { add_to_current_playlist(file) }
    elsif PLAYLIST_EXTENSIONS.include?(ext)
      menu.option(_("Open or import playlist")) { playlist_file_action(file) }
    end
    if ARCHIVE_EXTENSIONS.include?(ext)
      menu.option(_("Extract")) { extract_archive(file) }
    else
      menu.option(_("Compress")) { compress_selected(file) }
    end
  end

  def build_create_menu(menu)
    menu.option(_("New text file")) { create_text_file }
    menu.option(_("New record")) { create_recording }
    menu.option(_("New M3U playlist")) { create_playlist_file(:m3u) }
    menu.option(_("New PLS playlist")) { create_playlist_file(:pls) }
  end

  def build_context_menu(menu)
    if !playlist_store.current_playlist.empty?
      menu.option(_("Open playlist")) do
        self.class.open_playlist_scene
      end
    end
    menu.customoption(_("Audio")) { audiomenu(true) } if @tree.filetype == 1
    menu.customoption(_("Playlist")) { playlistmenu(true) } if playlist_file?(selected_path)
    menu.customoption(_("Text")) { textmenu(true) } if @tree.filetype == 2
    menu.customoption(_("Document")) { documentmenu(true) } if @tree.filetype == 4
  end

  def handle_enter
    file = selected_path
    if File.directory?(file)
      @tree.go
    elsif playlist_file?(file)
      playlist_file_action(file)
    else
      case @tree.filetype
      when 1 then audiomenu
      when 2 then textmenu
      when 4 then documentmenu
      when 3 then archive_prompt
      end
    end
    speak(@tree.file)
  end

  def create_text_file
    name = prompt_filename(".txt")
    return if name == nil
    File.binwrite(path_in_current_dir(name), "")
    alert(_("The file has been created."))
    @tree.refresh
  end

  def create_recording
    name = prompt_filename(".ogg")
    return if name == nil
    ext = File.extname(name).downcase
    name += ".ogg" if !RECORD_EXTENSIONS.include?(ext)
    file = path_in_current_dir(name)
    recorder = nil
    record = Button.new(_("Record"))
    cancel = Button.new(_("Cancel"))
    form = Form.new([record, cancel])
    record.on(:press) do
      if recorder == nil
        recorder = start_recorder(file)
        play_sound("recording_start")
        record.label = _("Save")
      else
        recorder.stop
        recorder = nil
        play_sound("recording_stop")
        alert(_("Saved"))
        form.resume
      end
    end
    cancel.on(:press) do
      recorder.stop if recorder != nil
      recorder = nil
      form.resume
    end
    form.cancel_button = cancel
    form.wait
    alert(_("The file has been created."))
    @tree.refresh
  end

  def start_recorder(file)
    case File.extname(file).downcase
    when ".opus" then Recorder.opus_recording(file, 192, 20)
    when ".ogg" then Recorder.vorbis_recording(file, 192)
    when ".wav" then Recorder.wave_recording(file)
    else Recorder.vorbis_recording(file, 192)
    end
  end

  def prompt_filename(default_extension)
    name = ""
    name = input_text(_("Enter a file name"), flags: 0, text: default_extension, escapable: true) while name == ""
    name
  end

  def archive_prompt
    action = select_action({ extract: _("Extract"), cancel: _("Cancel") }, cancel: :cancel, flags: 1)
    if action == :extract
      extract_archive(@tree.selected)
      speech_wait
    end
  end

  def extract_archive(file)
    Tasks.run(title: _("Processing...")) { extract_zip(file, @tree.path) }
    @tree.refresh
    alert(_("Unpacked."))
  rescue Zip::Error, RuntimeError => e
    Log.warning("FileManager ZIP extract failed: #{e.class}: #{e.message}")
    alert(_("This archive cannot be unpacked."))
  end

  def compress_selected(file)
    destination = file + ".zip"
    Tasks.run(title: _("Processing...")) { create_zip(file, destination) }
    @tree.refresh
    alert(_("Compressed"))
  rescue Zip::Error, RuntimeError => e
    Log.warning("FileManager ZIP create failed: #{e.class}: #{e.message}")
    alert(_("This file cannot be compressed."))
  end

  def extract_zip(source, destination)
    require "zip"
    FileUtils.mkdir_p(destination)
    Zip::File.open(source) do |zip|
      zip.each do |entry|
        name = safe_zip_name(entry.name)
        target = safe_zip_target(destination, name)
        if entry.directory? || name.end_with?("/")
          FileUtils.mkdir_p(target)
        else
          FileUtils.mkdir_p(File.dirname(target))
          write_zip_entry(entry, target)
        end
      end
    end
  end

  def write_zip_entry(entry, target)
    entry.get_input_stream do |input|
      File.open(target, "wb") do |output|
        while (chunk = input.read(64 * 1024))
          output.write(chunk)
        end
      end
    end
  end

  def create_zip(source, destination)
    require "zip"
    FileUtils.rm_f(destination)
    root = File.dirname(source)
    paths = if File.directory?(source)
              [source] + Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH)
            else
              [source]
            end
    Zip::File.open(destination, create: true) do |zip|
      paths.sort.each do |path|
        next if [".", ".."].include?(File.basename(path))
        relative = path.delete_prefix(root + File::SEPARATOR).tr("\\", "/")
        next if relative == "" || relative == File.basename(destination)
        if File.directory?(path)
          zip.mkdir(relative) if zip.find_entry(relative) == nil
        else
          zip.get_output_stream(relative) { |io| io.write(File.binread(path)) }
        end
      end
    end
  end

  def safe_zip_name(name)
    name = name.to_s.tr("\\", "/").sub(/\A\/+/, "")
    raise "Unsafe ZIP entry path" if name == "" || name.split("/").include?("..") || name.include?(":")
    name
  end

  def safe_zip_target(destination, name)
    base = File.expand_path(destination).tr("\\", "/").sub(/\/+\z/, "")
    target = File.expand_path(File.join(destination, *name.split("/"))).tr("\\", "/")
    raise "Unsafe ZIP entry target" if target != base && !target.start_with?(base + "/")
    target
  end

  def playlist_file?(file)
    PLAYLIST_EXTENSIONS.include?(File.extname(file.to_s).downcase)
  end

  def playlistmenu(submenu = false)
    actions = {
      open: _("Open"),
      import: _("Import into internal playlist")
    }
    actions[:cancel] = _("Cancel") if !submenu
    action = select_action(actions, flags: submenu ? 0 : 1, cancel_key: submenu ? :left : nil)
    case action
    when :open
      open_playlist_file(selected_path)
    when :import
      import_playlist_file(selected_path)
    end
    action != nil
  end

  def playlist_file_action(file)
    action = select_action(
      { open: _("Open"), import: _("Import into internal playlist"), cancel: _("Cancel") },
      header: File.basename(file), cancel: :cancel, flags: 1
    )
    open_playlist_file(file) if action == :open
    import_playlist_file(file) if action == :import
  end

  def open_playlist_file(file)
    playlist = FileManagerPlaylist::Formats.load(file)
    edit_playlist(playlist, storage: :file)
  rescue FileManagerPlaylist::FormatError, SystemCallError, ArgumentError => e
    log_playlist_error("Cannot open playlist", e)
    alert(_("This playlist cannot be opened."))
  end

  def import_playlist_file(file)
    source = FileManagerPlaylist::Formats.load(file)
    current = playlist_store.current_playlist
    return if !current.empty? && !confirm(_("Replace the internal playlist with the contents of this file?"))
    imported = FileManagerPlaylist::Playlist.new(
      name: _("Playlist"),
      entries: source.entries.map { |entry| FileManagerPlaylist::Entry.from_h(entry.to_h) }
    )
    persist_current_playlist(imported)
    alert(_("Imported %{count} items into the internal playlist.") % { count: imported.entries.size })
  rescue FileManagerPlaylist::FormatError, SystemCallError, ArgumentError => e
    log_playlist_error("Cannot import playlist", e)
    alert(_("This playlist cannot be opened."))
  end

  def create_playlist_file(format)
    extension = format == :pls ? ".pls" : ".m3u"
    name = prompt_filename(extension)
    return if name == nil
    name += extension if File.extname(name) == ""
    path = path_in_current_dir(name)
    playlist = FileManagerPlaylist::Playlist.new(
      name: File.basename(path, File.extname(path)), source_path: path, format: format
    )
    FileManagerPlaylist::Formats.save(playlist, path, format: format)
    @tree.refresh
    edit_playlist(playlist, storage: :file)
  rescue SystemCallError, ArgumentError => e
    log_playlist_error("Cannot create playlist", e)
    alert(_("The playlist cannot be created."))
  end

  def add_to_current_playlist(file)
    return if !File.file?(file) || !AUDIO_EXTENSIONS.include?(File.extname(file).downcase)
    current = playlist_store.current_playlist
    current.entries << FileManagerPlaylist::Entry.new(File.expand_path(file))
    persist_current_playlist(current)
    alert(_("Added to the playlist."))
  end

  def add_directory_to_current_playlist(directory)
    files = scan_audio_files(directory)
    return false if files == nil
    current = playlist_store.current_playlist
    files.each { |file| current.entries << FileManagerPlaylist::Entry.new(file) }
    persist_current_playlist(current)
    alert(_("Added %{count} items to the playlist.") % { count: files.size })
  end

  def persist_current_playlist(playlist)
    playback = self.class.playlist_playback
    if playback != nil
      was_empty = playback.playlist.empty?
      playback.replace_current(playlist)
      if was_empty && !playback.playlist.empty? && self.class.playlist_setting("autoplay_first_item")
        playback.start(playback.playlist, index: 0)
      end
    else
      playlist_store.set_current(playlist)
    end
  end

  def playlist_store
    self.class.playlist_store
  end

  def play_playlist(playlist, index: 0)
    if playlist.empty?
      alert(_("The playlist is empty."))
      return false
    end
    playback = self.class.playlist_playback
    if playback == nil || !playback.start(playlist, index: index)
      alert(_("No playlist item could be played."))
      return false
    end
    true
  end

  def scan_audio_files(directory)
    Tasks.run(
      title: _("Searching for audio files..."),
      timeout: DIRECTORY_SCAN_TIMEOUT,
      cancellable: false
    ) { audio_files_in_directory(directory) }
  rescue EltenAPI::Tasks::TimedOut
    alert(_("Searching subfolders took longer than 10 seconds. No files were added to the playlist."))
    nil
  end

  def audio_files_in_directory(directory)
    directories = [File.expand_path(directory)]
    visited = {}
    files = []
    until directories.empty?
      current = directories.pop
      real = File.realpath(current) rescue File.expand_path(current)
      next if visited[real]
      visited[real] = true
      child_directories = []
      children = begin
        Dir.children(current).sort
      rescue SystemCallError
        next
      end
      children.each do |name|
        path = File.join(current, name)
        begin
          if File.directory?(path)
            child_directories << path
          elsif File.file?(path) && AUDIO_EXTENSIONS.include?(File.extname(path).downcase)
            files << File.expand_path(path)
          end
        rescue SystemCallError
          next
        end
      end
      directories.concat(child_directories.reverse)
    end
    files
  end

  def add_items_to_playlist(playlist)
    action = select_action(
      { file: _("Add audio file"), directory: _("Add directory"), url: _("Add URL"), cancel: _("Cancel") },
      cancel: :cancel,
      flags: 1
    )
    case action
    when :file
      file = get_file(_("Select audio file"), path: playlist_start_path(playlist), save: false, extensions: AUDIO_EXTENSIONS)
      return 0 if file == nil
      playlist.entries << FileManagerPlaylist::Entry.new(File.expand_path(file))
      1
    when :directory
      directory = get_file(_("Select directory"), path: playlist_start_path(playlist), save: true)
      return 0 if directory == nil
      files = scan_audio_files(directory)
      return 0 if files == nil
      files.each { |file| playlist.entries << FileManagerPlaylist::Entry.new(file) }
      files.size
    when :url
      url = input_text(_("Enter an audio URL"), flags: 0, text: "", escapable: true)
      return 0 if url == nil || url.strip == ""
      playlist.entries << FileManagerPlaylist::Entry.new(url.strip)
      1
    else
      0
    end
  end

  def playlist_start_path(playlist)
    return File.dirname(playlist.source_path) if playlist.source_path != nil
    @tree == nil ? "" : @tree.path
  end

  def save_playlist(playlist, storage, save_as: false)
    if storage == :current
      persist_current_playlist(playlist)
    else
      path = playlist.source_path
      path = choose_playlist_path(playlist) if save_as || path == nil
      return false if path == nil
      FileManagerPlaylist::Formats.save(playlist, path)
      @tree.refresh if @tree != nil
    end
    alert(_("Saved"))
    true
  rescue SystemCallError, ArgumentError, FileManagerPlaylist::FormatError => e
    log_playlist_error("Cannot save playlist", e)
    alert(_("The playlist cannot be saved."))
    false
  end

  def choose_playlist_path(playlist)
    format = playlist.format == :pls ? :pls : :m3u
    extension = format == :pls ? ".pls" : ".m3u"
    directory = get_file(_("Select destination directory"), path: playlist_start_path(playlist), save: true)
    return nil if directory == nil
    default_name = playlist.name.to_s.strip
    default_name = _("Playlist") if default_name == ""
    name = input_text(_("Enter a file name"), flags: 0, text: default_name + extension, escapable: true)
    return nil if name == nil || name.strip == ""
    name += extension if !PLAYLIST_EXTENSIONS.include?(File.extname(name).downcase)
    File.join(directory, name)
  end

  def export_playlist(playlist)
    format = select_action(
      { m3u: _("M3U playlist"), pls: _("PLS playlist"), cancel: _("Cancel") },
      header: _("Export playlist"), cancel: :cancel, flags: 1
    )
    return false if format == :cancel || format == nil
    exported = playlist.copy(new_id: true)
    exported.source_path = nil
    exported.format = format
    save_playlist(exported, :file, save_as: true)
  end

  def edit_playlist(playlist, storage:)
    close = Button.new(_("Close"))
    list, dirty = build_playlist_control(
      playlist, storage: storage, close_action: proc { close.press }
    )
    form = Form.new([list, close], quiet: true)
    form.hide(close)
    form.cancel_button = close
    close.on(:press) do
      next if dirty.call && !confirm(_("Discard unsaved playlist changes?"))
      form.resume
    end
    form.wait
    list.instance_variable_get(:@filemanager_playlist_model)
  ensure
    self.class.unregister_playlist_control(list) if defined?(list) && list != nil
  end

  def build_main_playlist_control(current, scene)
    source = self.class.playlist_playback.playlist
    if current == nil
      control, = build_playlist_control(
        source.copy, storage: :current, close_action: proc { scene.advance_main_focus }
      )
      control
    else
      sync_playlist_control(current, source)
    end
  end

  def sync_playlist_control(control, source)
    playlist = control.instance_variable_get(:@filemanager_playlist_model)
    refresh = control.instance_variable_get(:@filemanager_playlist_refresh)
    return control if playlist == nil || refresh == nil
    if playlist.to_h != source.to_h
      playlist.id = source.id
      playlist.name = source.name
      playlist.entries = source.entries.map { |entry| FileManagerPlaylist::Entry.from_h(entry.to_h) }
      control.header = _("Playlist")
      refresh.call(control.index)
    end
    control
  end

  def build_playlist_control(playlist, storage:, close_action:)
    dirty = false
    header = storage == :current ? _("Playlist") : playlist.name
    playback = self.class.playlist_playback
    initial_index = storage == :current && playback != nil ? playback.current_index : 0
    list = ListBox.new(
      playlist_entry_labels(playlist), header: header, index: initial_index, flags: 0, quiet: true,
      empty_label: _("The playlist is empty.")
    )
    original_key_processed = list.method(:key_processed)
    list.define_singleton_method(:key_processed) do |key|
      return false if raw_key_held?(:key_shift) && [:up, :down].include?(key)
      original_key_processed.call(key)
    end
    # respond_to?: programs do not necessarily carry the Klangten UI mixin.
    unless respond_to?(:touch_ui?) && touch_ui?
      list.add_tip(_("Use Shift+Up and Shift+Down to move tracks."))
      list.add_tip(_("Use the Left/Right Arrow keys to seek"))
    end
    refresh = proc do |index = list.index|
      list.options = playlist_entry_labels(playlist)
      list.index = [[index.to_i, 0].max, [playlist.entries.size - 1, 0].max].min
      current = self.class.playlist_playback
      if storage == :current && current != nil && current.active? && !playlist.entries.empty?
        list.set_item_status(current.current_index, "listbox_itemnew", "", "")
      end
    end
    list.instance_variable_set(:@filemanager_playlist_model, playlist)
    list.instance_variable_set(:@filemanager_playlist_refresh, refresh)
    list.instance_variable_set(:@filemanager_playlist_storage, storage)
    self.class.register_playlist_control(list) if storage == :current
    refresh.call(initial_index)
    changed = proc do
      if storage == :current
        persist_current_playlist(playlist)
        dirty = false
      else
        dirty = true
      end
    end
    remove_entry = proc do
      if playlist.entries.empty?
        alert(_("The playlist is empty."))
      else
        index = list.index
        playlist.entries.delete_at(index)
        changed.call
        refresh.call(index)
        list.focus
      end
    end
    move_entry = proc do |offset|
      index = list.index
      target = index + offset
      next if index < 0 || index >= playlist.entries.size || target < 0 || target >= playlist.entries.size
      playlist.entries[index], playlist.entries[target] = playlist.entries[target], playlist.entries[index]
      changed.call
      refresh.call(target)
      list.focus
    end

    list.on(:select) do
      play_playlist(playlist, index: list.index) if storage == :current && !playlist.entries.empty?
    end
    list.on(:key_space) { self.class.toggle_playlist_playback if storage == :current }
    list.on(:key_left) do |params|
      self.class.playlist_playback&.seek(-5) if storage == :current && params.none?
    end
    list.on(:key_right) do |params|
      self.class.playlist_playback&.seek(5) if storage == :current && params.none?
    end
    list.on(:key_up) { |params| move_entry.call(-1) if params[0] == true }
    list.on(:key_down) { |params| move_entry.call(1) if params[0] == true }
    list.bind_context do |menu|
      add_playlist_playback_menu(menu, playlist, list) if storage == :current
      menu.option(_("Edit title")) do
        entry = playlist.entries[list.index]
        next if entry == nil
        title = input_text(_("Title"), flags: 0, text: entry.title.to_s, escapable: true)
        next if title == nil
        entry.title = title.strip == "" ? nil : title
        changed.call
        refresh.call
        list.focus
      end
      menu.option(_("Add")) do
        changed.call if add_items_to_playlist(playlist) > 0
        refresh.call
        list.focus
      end
      menu.option(_("Remove"), nil, :del) { remove_entry.call }
      if !playlist.empty?
        menu.option(_("Clear playlist")) do
          next if !confirm(_("Clear the playlist?"))
          playlist.entries.clear
          changed.call
          refresh.call(0)
          list.focus
        end
      end
      menu.option(_("Move up")) { move_entry.call(-1) }
      menu.option(_("Move down")) { move_entry.call(1) }
      if storage == :file
        menu.option(_("Save")) { dirty = false if save_playlist(playlist, storage) }
        menu.option(_("Save as")) { dirty = false if save_playlist(playlist, storage, save_as: true) }
      else
        menu.option(_("Export playlist")) { export_playlist(playlist) }
      end
      menu.option(_("Close")) { close_action.call }
    end
    [list, proc { dirty }]
  end

  def add_playlist_playback_menu(menu, playlist, list)
    playback = self.class.playlist_playback
    if playback != nil && playback.active?
      if playback.paused?
        menu.option(_("Play")) { playback.play }
      else
        menu.option(_("Pause")) { playback.pause }
      end
      menu.option(_("Play selected in background")) do
        play_playlist(playlist, index: list.index) if !playlist.empty?
      end
      menu.option(_("Previous track")) { playback.previous }
      menu.option(_("Next track")) { playback.next }
      menu.option(playback.shuffle? ? _("Disable shuffle") : _("Enable shuffle")) { playback.toggle_shuffle }
      menu.option(_("Close playlist playback")) { playback.close }
    else
      menu.option(_("Play in background")) do
        play_playlist(playlist, index: list.index) if !playlist.empty?
      end
      menu.option(playback != nil && playback.shuffle? ? _("Disable shuffle") : _("Enable shuffle")) do
        playback.toggle_shuffle if playback != nil
      end
    end
    volume = playback == nil ? 100 : playback.volume
    menu.option(_("Volume: %{volume}") % { volume: "#{volume}%" }) do
      select_playlist_volume(playback)
    end
  end

  def select_playlist_volume(playback)
    return if playback == nil
    values = (0..100).to_a
    index = selector(
      values.map { |value| "#{value}%" },
      header: _("Playlist volume"), start_index: playback.volume, flags: 1
    )
    playback.set_volume(values[index]) if index != -1
  end

  def playlist_entry_labels(playlist)
    playlist.entries.map do |entry|
      duration = entry.length != nil && entry.length >= 0 ? " (#{format_playlist_duration(entry.length)})" : ""
      "#{entry.label}#{duration}"
    end
  end

  def format_playlist_duration(seconds)
    value = seconds.to_i
    hours = value / 3600
    minutes = value / 60 % 60
    rest = value % 60
    hours > 0 ? format("%d:%02d:%02d", hours, minutes, rest) : format("%d:%02d", minutes, rest)
  end

  def log_playlist_error(message, error)
    Log.warning("FileManager #{message}: #{error.class}: #{error.message}") if defined?(Log)
  rescue Exception
  end

  def audiomenu(submenu = false)
    actions = { play: _("Play"), convert: _("convert"), add_to_playlist: _("Add to playlist") }
    actions[:avatar] = p_("Klangten", "Set as audio avatar") if Session.logged?
    actions[:cancel] = _("Cancel") if !submenu
    action = select_action(actions, flags: submenu ? 0 : 1, cancel_key: submenu ? :left : nil)
    case action
    when :play
      player(selected_path, label: _("Playing: %{file}") % { file: File.basename(path_in_current_dir(@tree.file)) }, wait: true)
    when :convert
      convert_audio
    when :add_to_playlist
      add_to_current_playlist(selected_path)
    when :avatar
      set_audio_avatar_from(selected_path, File.basename(selected_path))
    end
    action != nil
  end

  def convert_audio
    encoders = MediaEncoders.list.select { |encoder| encoder::Type == :audio }
    encoder = select_action(encoders.map { |item| [item, "#{item::Name} (#{item::Extension})"] }, header: _("Convert to"))
    return if encoder == nil
    bitrate = select_bitrate if encoder::IsBitrateSupported
    output = selected_path.sub(/#{Regexp.escape(File.extname(selected_path))}\z/, encoder::Extension)
    waiting
    begin
      encoder.encode_file(@tree.selected, output, bitrate)
    ensure
      waiting_end
    end
    alert(_("Converted."))
    @tree.refresh
    speech_wait
  end

  def select_bitrate
    bitrates = [48, 64, 96, 128, 160, 192, 224, 256, 320]
    index = selector(bitrates.map { |bitrate| "#{bitrate}KBPS" }, header: _("Sound quality"), start_index: 5)
    bitrates[index] if index != -1
  end

  def textmenu(submenu = false)
    file = selected_path
    text = File.binread(file)
    actions = { edit: _("Edit") }
    actions[:cancel] = _("Cancel") if !submenu
    action = select_action(actions, flags: submenu ? 0 : 1, cancel_key: submenu ? :left : nil)
    edit_text_file(file, text) if action == :edit
    action != nil
  end

  def edit_text_file(file, text)
    form = Form.new([
      EditBox.new(@tree.file, type: EditBox::Flags::MultiLine, text: text),
      Button.new(_("Save")),
      Button.new(_("Cancel"))
    ])
    save = form.fields[1]
    cancel = form.fields[2]
    save.on(:press) do
      File.binwrite(file, form.fields[0].text.gsub("\004LINE\004", "\r\n"))
      alert(_("Saved"))
      form.resume
    end
    cancel.on(:press) { form.resume }
    form.accept_button = save
    form.cancel_button = cancel
    form.wait
  end

  def documentmenu(submenu = false)
    actions = { read: _("Read") }
    actions[:cancel] = _("Cancel") if !submenu
    action = select_action(actions, flags: submenu ? 0 : 1, cancel_key: submenu ? :left : nil)
    if action == :read
      text = Tasks.run(title: _("Processing...")) { read_document(selected_path) }
      if text == nil
        alert(_("This file cannot be read."))
        return false
      end
    end
    show_document(text) if action == :read
    action != nil
  end

  def show_document(text)
    display_text(text.to_s, header: @tree.file)
  end

  def read_document(source)
    case File.extname(source).downcase
    when ".txt"
      File.binread(source)
    when ".pdf"
      read_pdf(source)
    when ".docx"
      read_docx(source)
    when ".epub"
      read_epub(source)
    when ".rtf"
      read_rtf(source)
    else
      nil
    end
  end

  def read_pdf(source)
    require "pdf/reader"
    reader = PDF::Reader.new(source)
    reader.pages.map(&:text).join("\n\n")
  rescue LoadError => e
    Log.warning("FileManager PDF reader unavailable: #{e.message}")
    nil
  rescue Exception => e
    Log.warning("FileManager PDF conversion failed: #{e.class}: #{e.message}")
    nil
  end

  def read_docx(source)
    require "docx"
    require "docx/document"
    Docx::Document.open(source).to_s
  rescue LoadError => e
    Log.warning("FileManager DOCX reader unavailable: #{e.message}")
    nil
  rescue Exception => e
    Log.warning("FileManager DOCX conversion failed: #{e.class}: #{e.message}")
    nil
  end

  def read_epub(source)
    require "gepub"
    book = GEPUB::Book.parse(source)
    book.spine_items.compact.map { |item| epub_item_text(item) }.reject { |part| part == "" }.join("\n\n")
  rescue LoadError => e
    Log.warning("FileManager EPUB reader unavailable: #{e.message}")
    nil
  rescue Exception => e
    Log.warning("FileManager EPUB conversion failed: #{e.class}: #{e.message}")
    nil
  end

  def epub_item_text(item)
    return "" if item == nil || item.content == nil
    media_type = item.respond_to?(:media_type) ? item.media_type.to_s : ""
    href = item.respond_to?(:href) ? item.href.to_s : ""
    return "" if media_type != "application/xhtml+xml" && href !~ /\.x?html?\z/i
    html = item.content.to_s
    html = html.encode("UTF-8", invalid: :replace, undef: :replace)
    ::Nokogiri::HTML(html).text.gsub(/[ \t\r\f]+/, " ").gsub(/\n{3,}/, "\n\n").strip
  end

  def read_rtf(source)
    require "ruby-rtf"
    data = File.binread(source).encode("UTF-8", invalid: :replace, undef: :replace)
    document = RubyRTF::Parser.new(:unknown_control_warning_enabled => false).parse(data)
    rtf_sections_text(document.sections)
  rescue LoadError => e
    Log.warning("FileManager RTF reader unavailable: #{e.message}")
    nil
  rescue Exception => e
    Log.warning("FileManager RTF conversion failed: #{e.class}: #{e.message}")
    nil
  end

  def rtf_sections_text(sections)
    parts = []
    Array(sections).each do |section|
      if section.is_a?(Hash)
        text = section[:text].to_s
        parts << text if text != ""
        parts << "\n" if section[:modifiers].is_a?(Hash) && section[:modifiers][:paragraph]
      elsif defined?(RubyRTF::Table) && section.is_a?(RubyRTF::Table)
        parts << section.rows.map do |row|
          row.cells.map { |cell| rtf_sections_text(cell.sections) }.join("\t")
        end.join("\n")
      elsif section.respond_to?(:sections)
        parts << rtf_sections_text(section.sections)
      end
    end
    parts.join.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
  end

  def speak_directory_count
    path = @tree.selected(false)
    if File.directory?(path)
      dirs, files = countsub(path)
      speak("#{files} #{dirs}")
    elsif @tree.filetype == 1
      sound = Sound.new(path)
      duration = sound.length
      sound.close
      if duration < 360000
        h = duration / 3600
        m = duration / 60 % 60
        s = duration % 60
        speak(format("%02d:%02d:%02d", h, m, s))
      end
    end
  end

  def countsub(dir)
    Dir.children(dir).each_with_object([0, 0]) do |entry, totals|
      path = EltenPath.join(dir, entry)
      if File.file?(path)
        totals[1] += 1
      elsif File.directory?(path)
        totals[0] += 1
        child_dirs, child_files = countsub(path)
        totals[0] += child_dirs
        totals[1] += child_files
      end
    end
  rescue Exception
    [0, 0]
  end

  def speak_selected_size
    size = getsize(@tree.selected(false)).to_f
    unit = "B"
    ["KB", "MB", "GB", "TB"].each do |next_unit|
      break if size <= 1024
      size /= 1024.0
      unit = next_unit
    end
    size = (size * 100).round / 100.0
    size = size.to_i if size.to_i == size
    size = 0 if size < 0
    speak("#{size}#{unit}")
  end

  def selected_path
    @tree.selected(true)
  end

  def path_in_current_dir(name)
    EltenPath.join(@tree.path, name.to_s)
  end

  def open_associated(file)
    alert(_("This file cannot be opened.")) if !platform_open_url(file)
  end

end
