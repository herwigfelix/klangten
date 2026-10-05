# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The file manager (Files -> File manager).
#
# Built on the core FilesTree control, which already navigates (Right opens,
# Left goes up, letters search), lists drives and the user's shortcuts, plays
# type sounds, previews with Space and offers Rename, Delete, Copy, Paste and
# New folder. This scene adds what happens on Enter (play, read, edit, extract,
# open a playlist or hand the file to the system), information keys, format
# conversion, ZIP archives, recordings, text files and the internal playlist.
#
# Keys on top of FilesTree: Enter opens, Shift+Left goes to the drives and
# shortcuts; the others are context menu entries with their shortcut
# (Ctrl+O open with the system, Ctrl+I size, Ctrl+D duration or contents,
# Ctrl+S spell the name, Ctrl+R reload; Cmd instead of Ctrl on macOS).

require "fileutils"

class Scene_FileManager
  TEXT_EXTENSIONS = %w[
    .txt .text .log .md .markdown .csv .tsv .ini .cfg .conf .json .xml .srt .lrc .nfo .yml .yaml
    .bat .cmd .sh .rb .py .lua .js .css .tex .po
  ].freeze
  ARCHIVE_EXTENSIONS = %w[.zip].freeze
  RECORDING_EXTENSIONS = %w[.ogg .opus .wav].freeze
  BITRATES = [32, 48, 64, 96, 128, 160, 192, 224, 256, 320].freeze
  TEXT_EDIT_LIMIT = 4 * 1024 * 1024
  ZIP_CHUNK = 64 * 1024

  # path: folder or file to start at; nil returns to where the file manager
  # was left in this session (FilesTree remembers it).
  def initialize(path = nil)
    @start_path = path.to_s
  end

  def main
    @tree = FilesTree.new(p_("Klangten", "File manager"), path: @start_path, quiet: true, use_sounds: true)
    bind_menus
    @tree.focus
    offer_storage_access
    loop do
      loop_update
      @tree.update
      break if $scene != self
      if key_pressed?(:key_escape)
        $scene = Scene_Main.new
        break
      end
      if key_pressed?(:key_left) && raw_key_held?(:key_shift) && !navigation_modifier_held? && @tree.path.to_s != ""
        go_to_root
      elsif key_pressed?(:key_enter) && !raw_key_held?(:key_shift)
        open_selected
        break if $scene != self
      end
    end
  ensure
    @tree.close_preview if @tree != nil
  end

  # ------------------------------------------------------------ archives
  # (class methods so they can be used and tested without the interface)

  # The absolute target of a ZIP entry below root, or nil when the entry would
  # end up outside root (absolute names, drive letters, "..").
  def self.zip_entry_target(root, name)
    name = name.to_s.tr("\\", "/")
    return nil if name == "" || name.start_with?("/") || name.match?(/\A[A-Za-z]:/) || name.include?("\0")
    parts = name.split("/")
    return nil if parts.include?("..")
    base = File.expand_path(root)
    target = File.expand_path(parts.reject { |part| part == "" || part == "." }.join("/"), base)
    return nil if target != base && !target.start_with?(base.end_with?("/") ? base : base + "/")
    target
  end

  # The name of a ZIP entry as UTF-8: rubyzip returns the raw bytes; names
  # without the UTF-8 flag that are not valid UTF-8 are CP437 (old DOS/Windows
  # archivers). Paths must be UTF-8, or Windows would read them in its ANSI page.
  def self.zip_entry_name(entry)
    name = entry.name.to_s.dup.force_encoding(Encoding::UTF_8)
    return name if name.valid_encoding?
    entry.name.to_s.dup.force_encoding(Encoding::IBM437).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  # Names of the files in archive that already exist below destination.
  def self.zip_conflicts(archive, destination)
    require "zip"
    conflicts = []
    Zip::File.open(archive) do |zip|
      zip.entries.each do |entry|
        next if entry.directory?
        name = zip_entry_name(entry)
        target = zip_entry_target(destination, name)
        conflicts << name if target != nil && File.exist?(target)
      end
    end
    conflicts
  end

  # Extracts archive into destination. overwrite: true replaces existing files,
  # false skips them. Entries leaving the destination and symbolic links are
  # skipped. Returns [extracted files, skipped entries, first extracted name].
  def self.extract_zip(archive, destination, overwrite: false, token: nil, progress: nil)
    require "zip"
    extracted = 0
    skipped = 0
    first = nil
    FileUtils.mkdir_p(destination)
    Zip::File.open(archive) do |zip|
      entries = zip.entries
      entries.each_with_index do |entry, index|
        token.raise_if_cancelled! if token != nil
        name = zip_entry_name(entry)
        target = zip_entry_target(destination, name)
        if target == nil || entry.symlink?
          skipped += 1
          next
        end
        first ||= name.tr("\\", "/").split("/").reject(&:empty?).first
        if entry.directory?
          FileUtils.mkdir_p(target)
          next
        end
        if File.exist?(target) && !overwrite
          skipped += 1
          next
        end
        FileUtils.mkdir_p(File.dirname(target))
        temporary = target + ".part"
        begin
          stream = entry.get_input_stream
          File.open(temporary, "wb") do |file|
            while (chunk = stream.read(ZIP_CHUNK))
              token.raise_if_cancelled! if token != nil
              file.write(chunk)
            end
          end
          File.delete(target) if File.exist?(target)
          File.rename(temporary, target)
          extracted += 1
        ensure
          stream.close if stream.respond_to?(:close) rescue nil
          File.delete(temporary) if File.exist?(temporary) rescue nil
        end
        progress.call(index + 1, entries.size, name) if progress != nil
      end
    end
    [extracted, skipped, first]
  end

  # Packs a file or a folder (recursively, without following symbolic links)
  # into output. Returns the number of files packed.
  def self.compress_zip(source, output, token: nil, progress: nil)
    require "zip"
    source = File.expand_path(source)
    items = []
    if File.directory?(source)
      base = File.basename(source)
      walk = lambda do |dir, prefix|
        children = Dir.children(dir).sort_by(&:downcase)
        items << [prefix + "/", nil] if children.empty?
        children.each do |name|
          full = File.join(dir, name)
          next if File.symlink?(full)
          if File.directory?(full)
            walk.call(full, prefix + "/" + name)
          elsif File.file?(full)
            items << [prefix + "/" + name, full]
          end
        end
      end
      walk.call(source, base)
    else
      items << [File.basename(source), source]
    end
    temporary = output + ".part"
    count = 0
    begin
      Zip::OutputStream.open(temporary) do |zip|
        items.each_with_index do |(name, path), index|
          token.raise_if_cancelled! if token != nil
          entry = Zip::Entry.new(output, name.encode(Encoding::UTF_8))
          # Mark UTF-8 names (general purpose bit 11), or other tools read CP437.
          entry.gp_flags |= 0x800 if !name.ascii_only?
          zip.put_next_entry(entry)
          next if path == nil
          File.open(path, "rb") do |file|
            while (chunk = file.read(ZIP_CHUNK))
              token.raise_if_cancelled! if token != nil
              zip.write(chunk)
            end
          end
          count += 1
          progress.call(index + 1, items.size, name) if progress != nil
        end
      end
      File.delete(output) if File.exist?(output)
      File.rename(temporary, output)
    ensure
      File.delete(temporary) if File.exist?(temporary) rescue nil
    end
    count
  end

  # "name (2).ext" when path exists.
  def self.unique_path(path)
    return path if !File.exist?(path)
    dir = File.dirname(path)
    ext = File.extname(path)
    base = File.basename(path, ext)
    (2..9999).each do |number|
      candidate = File.join(dir, "#{base} (#{number})#{ext}")
      return candidate if !File.exist?(candidate)
    end
    path
  end

  # "12.3 MB"
  def self.format_size(bytes)
    bytes = bytes.to_i
    return "#{bytes} B" if bytes < 1024
    units = %w[KB MB GB TB]
    value = bytes.to_f
    unit = nil
    units.each do |name|
      value /= 1024.0
      unit = name
      break if value < 1024
    end
    format("%.1f %s", value, unit)
  end

  private

  # ----------------------------------------------------------------- menus

  def bind_menus
    @tree.bind_filesmenu do |menu|
      file = @tree.selected
      next if file.to_s == ""
      directory = File.directory?(file)
      menu.option(p_("Klangten", "Open")) { open_selected }
      menu.option(p_("Klangten", "Open with the system program"), nil, "o") { system_open(@tree.selected) }
      if !directory && audio?(file)
        menu.option(p_("Klangten", "Play")) { play_file(file) }
        menu.option(p_("Klangten", "Convert")) { convert(file) }
        if Session.logged?
          menu.option(p_("Klangten", "Set as audio avatar")) { set_audio_avatar_from(file, File.basename(file)) }
        end
      end
      if !directory && document?(file)
        menu.option(p_("Klangten", "Read the text")) { read_document(file) }
      end
      if !directory && text_file?(file)
        menu.option(p_("Klangten", "Edit")) { edit_text_file(file) }
      end
      if directory || audio?(file) || KlangtenPlaylist.playlist_file?(file)
        menu.option(p_("Klangten", "Add to the playlist")) { add_to_playlist(file) }
      end
      if !directory && KlangtenPlaylist.playlist_file?(file)
        menu.option(p_("Klangten", "Open the playlist file")) { open_playlist_file(file) }
      end
      if !directory && archive?(file)
        menu.option(p_("Klangten", "Extract here")) { extract(file, :here) }
        menu.option(p_("Klangten", "Extract to a folder named after the archive")) { extract(file, :folder) }
        menu.option(p_("Klangten", "Extract to...")) { extract(file, :choose) }
      end
      menu.option(p_("Klangten", "Compress to ZIP")) { compress(file) } if !@tree.path.to_s.empty?
      menu.option(p_("Klangten", "Size"), nil, "i") { speak_size(@tree.selected) }
      menu.option(p_("Klangten", "Duration or contents"), nil, "d") { speak_details(@tree.selected) }
      menu.option(p_("Klangten", "Spell the name"), nil, "s") { spell(@tree.file) }
    end
    @tree.bind_createmenu do |menu|
      next if @tree.path.to_s == ""
      menu.option(p_("Klangten", "New text file")) { create_text_file }
      menu.option(p_("Klangten", "New recording")) { create_recording }
      menu.option(p_("Klangten", "New M3U playlist")) { create_playlist(".m3u") }
      menu.option(p_("Klangten", "New PLS playlist")) { create_playlist(".pls") }
    end
    @tree.bind_menu do |menu|
      menu.option(p_("Klangten", "Reload"), nil, "r") do
        @tree.refresh
        alert(p_("Klangten", "Reloaded"), false)
      end
      if KlangtenPlaylist.active? || !KlangtenPlaylist.internal.empty?
        menu.submenu(p_("Klangten", "My playlist")) do |sub|
          sub.option(p_("Klangten", "Open the playlist")) { open_internal_playlist }
          if KlangtenPlaylist.active?
            sub.option(KlangtenPlaylist.paused? ? p_("Klangten", "Resume") : p_("Klangten", "Pause")) { KlangtenPlaylist.quick_action(:toggle) }
            sub.option(p_("Klangten", "Previous")) { KlangtenPlaylist.quick_action(:previous) }
            sub.option(p_("Klangten", "Next")) { KlangtenPlaylist.quick_action(:next) }
            sub.option(p_("Klangten", "Stop")) do
              KlangtenPlaylist.stop
              alert(p_("Klangten", "Stopped"), false)
            end
          else
            sub.option(p_("Klangten", "Play")) { KlangtenPlaylist.quick_action(:toggle) }
          end
        end
      end
      if storage_access_missing?
        menu.option(p_("Klangten", "Allow access to all files")) { request_storage_access }
      end
    end
  end

  # ----------------------------------------------------------- navigation

  def go_to_root
    @tree.file = ""
    @tree.path = ""
    @tree.update
  end

  # Moves the cursor to name in folder (after creating or converting a file).
  def select_file(folder, name)
    if EltenPath.normalize(folder).chomp("/") != EltenPath.normalize(@tree.path).chomp("/")
      @tree.path = folder
    end
    @tree.file = name
    @tree.refresh
    @tree.update
  end

  def refocus
    loop_update
    @tree.focus
  end

  # ---------------------------------------------------------- file types

  def extension(file)
    File.extname(file.to_s).downcase
  end

  def audio?(file)
    FilesTree::AUDIO_EXTENSIONS.include?(extension(file))
  end

  def text_file?(file)
    TEXT_EXTENSIONS.include?(extension(file))
  end

  def document?(file)
    KlangtenDocuments.supported?(file) && extension(file) != ".txt"
  end

  def archive?(file)
    ARCHIVE_EXTENSIONS.include?(extension(file))
  end

  # ----------------------------------------------------------------- Enter

  # Enter on a folder (as in Klango): open it or add all its audio files,
  # subfolders included, to the playlist. Right arrow still opens directly.
  def folder_action(folder)
    options = [p_("Klangten", "Open folder"), p_("Klangten", "Add to playlist with all subfolders")]
    index = selector(options + [_("Cancel")], header: p_("Klangten", "What do you want to do?"), cancel_index: options.size)
    case index
    when 0 then @tree.go
    when 1 then add_to_playlist(folder)
    end
  end

  def open_selected
    file = @tree.selected
    return if file.to_s == ""
    if @tree.path.to_s == "" || File.directory?(file)
      folder_action(file)
      return
    end
    return alert(p_("Klangten", "This file no longer exists.")) if !File.file?(file)
    if KlangtenPlaylist.playlist_file?(file)
      playlist_file_action(file)
    elsif audio?(file)
      play_file(file)
    elsif text_file?(file)
      edit_text_file(file)
    elsif document?(file)
      read_document(file)
    elsif archive?(file)
      extract(file, :ask)
    else
      system_open(file)
    end
    refocus if $scene == self
  end

  def play_file(file)
    KlangtenPlaylist.suspend { player(file, label: File.basename(file)) }
  end

  def system_open(file)
    return if file.to_s == ""
    target = file.to_s
    target = target.tr("/", "\\") if EltenSystemHelpers.platform_os.to_s == "windows"
    alert(p_("Klangten", "No program could be opened for this file."), false) if !platform_open_url(target)
  end

  def playlist_file_action(file)
    action = select_action(
      [[:open, p_("Klangten", "Open the playlist file")], [:play, p_("Klangten", "Play")], [:import, p_("Klangten", "Add to the playlist")], [:cancel, _("Cancel")]],
      header: File.basename(file), cancel: :cancel
    )
    case action
    when :open then open_playlist_file(file)
    when :import then add_to_playlist(file)
    when :play
      list = read_playlist(file)
      if list != nil && !list.empty?
        KlangtenPlaylist.play(list, 0)
        alert(p_("Klangten", "Playing"), false)
      end
    end
  end

  def read_playlist(file)
    KlangtenPlaylist.read_file(file)
  rescue StandardError => e
    Log.warning("Playlist file could not be read: #{e.class}: #{e.message}")
    alert(p_("Klangten", "This playlist cannot be read."))
    nil
  end

  def open_playlist_file(file)
    Scene_Playlist.new(file).main
    @tree.refresh
    refocus
  end

  def open_internal_playlist
    Scene_Playlist.new.main
    refocus
  end

  # ---------------------------------------------------------------- text

  def edit_text_file(file)
    data = File.binread(file)
    if data.bytesize > TEXT_EDIT_LIMIT
      return read_document(file)
    end
    format = text_format(data)
    text = KlangtenDocuments.decode_text(data).gsub(/\r\n?/, "\n")
    edit = EditBox.new(File.basename(file), type: EditBox::Flags::MultiLine, text: text)
    save = Button.new(_("Save"))
    cancel = Button.new(_("Cancel"))
    form = Form.new([edit, save, cancel], quiet: true)
    form.cancel_button = cancel
    save.on(:press) do
      begin
        write_text_file(file, edit.text.to_s.gsub(/\r\n?/, "\n"), format)
        alert(p_("Klangten", "Saved"))
        form.resume
      rescue StandardError => e
        Log.warning("Text file could not be saved: #{e.class}: #{e.message}")
        alert(p_("Klangten", "The file could not be saved."))
      end
    end
    cancel.on(:press) do
      changed = edit.text.to_s.gsub(/\r\n?/, "\n") != text
      form.resume if !changed || confirm(p_("Klangten", "Do you want to discard your changes?"))
    end
    form.wait
  rescue StandardError => e
    Log.warning("Text file could not be opened: #{e.class}: #{e.message}")
    alert(p_("Klangten", "This file cannot be opened."))
  end

  # Encoding, byte order mark and line ending of an existing text file, so
  # saving keeps them.
  def text_format(data)
    decoded = KlangtenDocuments.decode_text(data)
    newline = decoded.include?("\r\n") ? "\r\n" : (decoded.include?("\n") ? "\n" : default_newline)
    encoding = if data.start_with?("\xFF\xFE".b)
      :utf16le
    elsif data.start_with?("\xFE\xFF".b)
      :utf16be
    elsif data.start_with?("\xEF\xBB\xBF".b)
      :utf8_bom
    elsif data.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      :utf8
    else
      :windows1252
    end
    { newline: newline, encoding: encoding }
  end

  def default_newline
    EltenSystemHelpers.platform_os.to_s == "windows" ? "\r\n" : "\n"
  end

  def write_text_file(file, text, format)
    text = text.gsub("\n", format[:newline])
    data = case format[:encoding]
    when :utf16le then "\xFF\xFE".b + text.encode(Encoding::UTF_16LE).b
    when :utf16be then "\xFE\xFF".b + text.encode(Encoding::UTF_16BE).b
    when :utf8_bom then "\xEF\xBB\xBF".b + text.b
    when :windows1252
      begin
        text.encode(Encoding::Windows_1252).b
      rescue EncodingError
        text.b
      end
    else text.b
    end
    temporary = File.join(File.dirname(file), ".#{File.basename(file)}.#{$$}.tmp")
    File.binwrite(temporary, data)
    File.rename(temporary, file)
  ensure
    File.delete(temporary) if temporary != nil && File.exist?(temporary) rescue nil
  end

  def create_text_file
    name = input_text(p_("Klangten", "File name"), text: "", escapable: true)
    return if name == nil || name.strip == ""
    name = name.strip
    name += ".txt" if File.extname(name) == ""
    file = File.join(@tree.path, name)
    return alert(p_("Klangten", "A file with this name already exists.")) if File.exist?(file)
    File.binwrite(file, "")
    select_file(@tree.path, name)
    edit_text_file(file)
    refocus
  rescue StandardError => e
    Log.warning("Text file could not be created: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be created."))
  end

  # ------------------------------------------------------------ documents

  def read_document(file)
    text = EltenAPI::Tasks.run(title: p_("Klangten", "Reading the document...")) do |_progress, token|
      KlangtenDocuments.extract(file, token: token)
    end
    if text.to_s.strip == ""
      alert(p_("Klangten", "This document contains no readable text."))
    else
      display_text(text, header: File.basename(file))
    end
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue KlangtenDocuments::EncryptedDocument
    alert(p_("Klangten", "This document is protected with a password."))
  rescue KlangtenDocuments::UnsupportedFormat
    system_open(file) if confirm(p_("Klangten", "Klangten cannot read this document. Do you want to open it with the system program?"))
  rescue StandardError => e
    Log.warning("Document could not be read: #{file}: #{e.class}: #{e.message}")
    alert(p_("Klangten", "This document cannot be read."))
  end

  # ------------------------------------------------------------- archives

  def extract(file, mode)
    folder = File.dirname(file)
    named = File.join(folder, File.basename(file, File.extname(file)))
    if mode == :ask
      mode = select_action(
        [[:here, p_("Klangten", "Extract here")], [:folder, p_("Klangten", "Extract to a folder named after the archive")], [:choose, p_("Klangten", "Extract to...")], [:cancel, _("Cancel")]],
        header: File.basename(file), cancel: :cancel
      )
    end
    destination = case mode
    when :here then folder
    when :folder then named
    when :choose then get_folder(p_("Klangten", "Extract to"), path: folder)
    end
    return if destination == nil
    conflicts = EltenAPI::Tasks.run(title: p_("Klangten", "Checking the archive...")) { self.class.zip_conflicts(file, destination) }
    overwrite = false
    if !conflicts.empty?
      choice = select_action(
        [[:skip, p_("Klangten", "Keep the existing files")], [:overwrite, p_("Klangten", "Replace the existing files")], [:cancel, _("Cancel")]],
        header: np_("Klangten", "%{count} file already exists.", "%{count} files already exist.", conflicts.size) % { count: conflicts.size }, cancel: :cancel
      )
      return if choice == :cancel
      overwrite = choice == :overwrite
    end
    extracted, skipped, first = EltenAPI::Tasks.run(title: p_("Klangten", "Extracting...")) do |progress, token|
      self.class.extract_zip(file, destination, overwrite: overwrite, token: token,
        progress: proc { |done, total, name| progress.update(done, total: total, message: name) })
    end
    message = np_("Klangten", "%{count} file extracted.", "%{count} files extracted.", extracted) % { count: extracted }
    message += " " + np_("Klangten", "%{count} entry skipped.", "%{count} entries skipped.", skipped) % { count: skipped } if skipped > 0
    alert(message)
    if mode == :folder
      select_file(folder, File.basename(named))
    elsif first != nil && EltenPath.normalize(destination).chomp("/") == EltenPath.normalize(@tree.path).chomp("/")
      select_file(destination, first)
    else
      @tree.refresh
    end
  rescue EltenAPI::Tasks::Cancelled
    alert(p_("Klangten", "Cancelled"))
    @tree.refresh
  rescue StandardError => e
    Log.warning("Archive could not be extracted: #{e.class}: #{e.message}")
    alert(p_("Klangten", "This archive cannot be extracted."))
    @tree.refresh
  end

  def compress(file)
    base = File.directory?(file) ? File.basename(file.chomp("/")) : File.basename(file, File.extname(file))
    output = self.class.unique_path(File.join(File.dirname(file.chomp("/")), base + ".zip"))
    count = EltenAPI::Tasks.run(title: p_("Klangten", "Compressing...")) do |progress, token|
      self.class.compress_zip(file, output, token: token,
        progress: proc { |done, total, name| progress.update(done, total: total, message: name) })
    end
    alert(np_("Klangten", "%{count} file compressed.", "%{count} files compressed.", count) % { count: count })
    select_file(File.dirname(output), File.basename(output))
  rescue EltenAPI::Tasks::Cancelled
    alert(p_("Klangten", "Cancelled"))
  rescue StandardError => e
    Log.warning("Archive could not be created: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The archive could not be created."))
  end

  # ------------------------------------------------------------ convert

  def audio_encoders
    MediaEncoders.list.select do |encoder|
      begin
        encoder.const_get(:Type) == :audio && encoder.available? && encoder.respond_to?(:encode_file)
      rescue StandardError
        false
      end
    end
  end

  def convert(file)
    encoders = audio_encoders
    return alert(p_("Klangten", "No audio formats are available.")) if encoders.empty?
    labels = encoders.map { |encoder| "#{encoder.const_get(:Name)} (#{encoder.const_get(:Extension)})" }
    index = selector(labels + [_("Cancel")], header: p_("Klangten", "Format"), cancel_index: labels.size)
    return if index == nil || index >= encoders.size
    encoder = encoders[index]
    return if !MediaEncoders.prepare(encoder)
    bitrate = nil
    if encoder.const_get(:IsBitrateSupported)
      default = encoder.respond_to?(:default_bitrate) ? encoder.default_bitrate.to_i : 128
      default = 128 if !BITRATES.include?(default)
      choice = selector(BITRATES.map { |rate| "#{rate} kbps" } + [_("Cancel")], header: p_("Klangten", "Bitrate"), start_index: BITRATES.index(default), cancel_index: BITRATES.size)
      return if choice == nil || choice >= BITRATES.size
      bitrate = BITRATES[choice]
    end
    output = self.class.unique_path(File.join(File.dirname(file), File.basename(file, File.extname(file)) + encoder.const_get(:Extension)))
    keywords = encoder.method(:encode_file).parameters.map { |_type, name| name }
    result = KlangtenPlaylist.suspend do
      EltenAPI::Tasks.run(title: p_("Klangten", "Converting...")) do |progress, token|
        options = {}
        options[:cancellation_token] = token if keywords.include?(:cancellation_token)
        options[:progress] = proc { |percent| progress.update(percent.to_f, total: 100) } if keywords.include?(:progress)
        options.empty? ? encoder.encode_file(file, output, bitrate) : encoder.encode_file(file, output, bitrate, **options)
      end
    end
    if result == false || !File.file?(output) || File.size(output) == 0
      File.delete(output) if File.exist?(output) rescue nil
      return alert(p_("Klangten", "The file could not be converted."))
    end
    alert(p_("Klangten", "Converted to %{file}") % { file: File.basename(output) })
    select_file(File.dirname(output), File.basename(output))
  rescue EltenAPI::Tasks::Cancelled
    File.delete(output) if output != nil && File.exist?(output) rescue nil
    alert(p_("Klangten", "Cancelled"))
  rescue StandardError => e
    File.delete(output) if output != nil && File.exist?(output) rescue nil
    Log.warning("Conversion failed: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be converted."))
  end

  # ------------------------------------------------------------ playlist

  def add_to_playlist(file)
    entries = playlist_entries_for(file)
    return if entries == nil
    return alert(p_("Klangten", "No audio files found.")) if entries.empty?
    KlangtenPlaylist.internal.add(entries)
    alert(np_("Klangten", "%{count} entry added to the playlist.", "%{count} entries added to the playlist.", entries.size) % { count: entries.size })
  end

  # Entries for a file, a playlist file or a folder (recursive, with progress).
  def playlist_entries_for(file)
    if File.directory?(file)
      files = EltenAPI::Tasks.run(title: p_("Klangten", "Searching for audio files...")) do |progress, token|
        KlangtenPlaylist.collect_audio_files(file, FilesTree::AUDIO_EXTENSIONS) do |count|
          token.raise_if_cancelled!
          progress.update(count, message: np_("Klangten", "%{count} file found", "%{count} files found", count) % { count: count })
        end
      end
      if files.size >= KlangtenPlaylist::MAX_FOLDER_FILES
        alert(p_("Klangten", "Only the first %{count} files are added.") % { count: KlangtenPlaylist::MAX_FOLDER_FILES })
      end
      files.map { |path| KlangtenPlaylist::Entry.new(path) }
    elsif KlangtenPlaylist.playlist_file?(file)
      list = read_playlist(file)
      list == nil ? nil : list.entries
    else
      [KlangtenPlaylist::Entry.new(file)]
    end
  rescue EltenAPI::Tasks::Cancelled
    nil
  end

  def create_playlist(extension)
    name = input_text(p_("Klangten", "Playlist name"), text: "", escapable: true)
    return if name == nil || name.strip == ""
    name = name.strip
    name += extension if !KlangtenPlaylist.playlist_file?(name)
    file = File.join(@tree.path, name)
    return alert(p_("Klangten", "A file with this name already exists.")) if File.exist?(file)
    KlangtenPlaylist.write_file(file, [])
    select_file(@tree.path, name)
    open_playlist_file(file)
  rescue StandardError => e
    Log.warning("Playlist could not be created: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The file could not be created."))
  end

  # ----------------------------------------------------------- recording

  def create_recording
    name = input_text(p_("Klangten", "Name of the recording"), text: p_("Klangten", "Recording") + " " + Time.now.strftime("%Y-%m-%d %H-%M"), escapable: true)
    return if name == nil || name.strip == ""
    name = name.strip
    name += ".ogg" if !RECORDING_EXTENSIONS.include?(File.extname(name).downcase)
    file = File.join(@tree.path, name)
    return alert(p_("Klangten", "A file with this name already exists.")) if File.exist?(file)
    saved = record_to(file)
    select_file(@tree.path, name) if saved
    refocus
  end

  # The recording form: Record/Stop, Play, Save, Cancel. Returns true when saved.
  def record_to(file)
    EltenSystemHelpers.request_microphone_access if EltenSystemHelpers.respond_to?(:request_microphone_access)
    ext = File.extname(file).downcase
    temporary = File.join(Dirs.temp, "filemanager_recording#{ext}")
    File.delete(temporary) if File.exist?(temporary)
    recorder = nil
    recorded = false
    saved = false
    record = Button.new(p_("Klangten", "Record"))
    play = Button.new(p_("Klangten", "Play"))
    save = Button.new(_("Save"))
    cancel = Button.new(_("Cancel"))
    form = Form.new([record, play, save, cancel], quiet: true)
    form.cancel_button = cancel
    form.hide(play)
    form.hide(save)
    stop_recording = proc do
      if recorder != nil
        recorder.stop
        recorder = nil
        play_sound("recording_stop")
        recorded = File.file?(temporary) && File.size(temporary) > 0
        record.label = p_("Klangten", "Record again")
        if recorded
          form.show(play)
          form.show(save)
        end
      end
    end
    record.on(:press) do
      if recorder != nil
        stop_recording.call
        form.focus
      elsif !recorded || confirm(p_("Klangten", "Do you want to replace the recording?"))
        begin
          play_sound("recording_start")
          recorder = case ext
          when ".opus" then Recorder.opus_recording(temporary, 64, 60, 2049)
          when ".wav" then Recorder.wave_recording(temporary)
          else Recorder.vorbis_recording(temporary, 128)
          end
          record.label = p_("Klangten", "Stop")
          form.hide(play)
          form.hide(save)
        rescue StandardError => e
          recorder = nil
          Log.warning("Recording could not be started: #{e.class}: #{e.message}")
          alert(p_("Klangten", "The recording could not be started."))
        end
      end
    end
    play.on(:press) { player(temporary, label: File.basename(file)) if recorded }
    save.on(:press) do
      stop_recording.call
      if recorded
        begin
          FileUtils.mv(temporary, file)
          saved = true
          alert(p_("Klangten", "The recording has been saved."))
          form.resume
        rescue StandardError => e
          Log.warning("Recording could not be saved: #{e.class}: #{e.message}")
          alert(p_("Klangten", "The file could not be saved."))
        end
      end
    end
    cancel.on(:press) do
      stop_recording.call
      form.resume if !recorded || confirm(p_("Klangten", "Do you want to discard the recording?"))
    end
    KlangtenPlaylist.suspend { form.wait }
    saved
  ensure
    recorder.stop if recorder != nil rescue nil
    File.delete(temporary) if temporary != nil && File.exist?(temporary) rescue nil
  end

  # --------------------------------------------------------- information

  def speak_size(file)
    return if file.to_s == ""
    if File.directory?(file)
      bytes, files, folders = EltenAPI::Tasks.run(title: p_("Klangten", "Counting...")) do |_progress, token|
        folder_totals(file, token)
      end
      speak(p_("Klangten", "%{size}, %{files}, %{folders}") % {
        size: self.class.format_size(bytes),
        files: np_("Klangten", "%{count} file", "%{count} files", files) % { count: files },
        folders: np_("Klangten", "%{count} folder", "%{count} folders", folders) % { count: folders }
      })
    else
      speak(self.class.format_size(File.size(file)))
    end
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue StandardError
    alert(_("Error"), false)
  end

  # Total size, file and folder count below folder (no symbolic links).
  def folder_totals(folder, token = nil)
    bytes = 0
    files = 0
    folders = 0
    stack = [folder]
    until stack.empty?
      token.raise_if_cancelled! if token != nil
      dir = stack.pop
      (Dir.children(dir) rescue []).each do |name|
        full = File.join(dir, name)
        next if File.symlink?(full)
        if File.directory?(full)
          folders += 1
          stack << full
        elsif File.file?(full)
          files += 1
          bytes += (File.size(full) rescue 0)
        end
      end
    end
    [bytes, files, folders]
  end

  def speak_details(file)
    return if file.to_s == ""
    if File.directory?(file)
      children = Dir.children(file) rescue []
      dirs = children.count { |name| File.directory?(File.join(file, name)) }
      count = children.size - dirs
      speak(np_("Klangten", "%{count} file", "%{count} files", count) % { count: count } + ", " +
        np_("Klangten", "%{count} folder", "%{count} folders", dirs) % { count: dirs })
    elsif audio?(file)
      sound = Sound.new(file)
      length = sound.opened? ? sound.length.to_f : 0
      sound.close
      speak(length > 0 ? KlangtenPlaylist.format_duration(length) : p_("Klangten", "The duration is unknown."))
    else
      speak(p_("Klangten", "Modified %{date}") % { date: File.mtime(file).strftime("%Y-%m-%d %H:%M") })
    end
  rescue StandardError
    speak(p_("Klangten", "The duration is unknown."))
  end

  def spell(name)
    return if name.to_s == ""
    speak(name.to_s.chars.map { |char| char == " " ? p_("Klangten", "space") : char }.join(" "))
  end

  # -------------------------------------------------------------- Android

  def storage_access_missing?
    EltenSystemHelpers.respond_to?(:storage_access_missing?) && EltenSystemHelpers.storage_access_missing?
  rescue StandardError
    false
  end

  # Android: offered once per session when Klangten sees only its own files.
  def offer_storage_access
    return if $klangten_storage_access_offered || !storage_access_missing?
    $klangten_storage_access_offered = true
    request_storage_access if confirm(p_("Klangten", "Klangten can only see its own files. Do you want to allow access to all files? Android opens a settings page: switch on the permission for Klangten there and come back. With TalkBack, use its gestures on that page."), default_yes: true)
    @tree.focus
  end

  def request_storage_access
    case EltenSystemHelpers.request_storage_access
    when :granted
      alert(p_("Klangten", "Access to all files has been granted."))
      @tree.path = ""
    when :opened
      nil
    else
      alert(p_("Klangten", "The permission page could not be opened."))
    end
  end
end
