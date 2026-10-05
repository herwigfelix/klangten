# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The internal playlist, playlist files and background playback.
#
# KlangtenPlaylist keeps one persistent internal playlist (playlist.json in the
# data directory: entries plus shuffle, repeat, position and volume) and reads
# and writes M3U/M3U8 and PLS files as KlangtenPlaylist::List objects.
#
# Playback runs in the background: it keeps going after the playlist screen or
# the file manager is closed, advances by itself, skips entries that cannot be
# opened, wraps around when repeat is on (the default) and stops at the end
# otherwise. A small engine thread does the slow part (opening a file or a
# stream URL) and watches for the end of the current entry; it exists only while
# something is playing or paused and needs no loop_update, so playback also
# advances while another scene thread owns the interface. The core Scheduler
# was not used: it ticks once a second, only on the main scene thread, and runs
# its tasks on short-lived workers meant for periodic jobs.
#
# Playback quick actions (play/pause, previous, next, volume) are registered
# with EltenAPI::QuickActions and can be put on a function key by the user.

require "json"
require "fileutils"
require "monitor"

module KlangtenPlaylist
  PLAYLIST_EXTENSIONS = %w[.m3u .m3u8 .pls].freeze
  STATE_FILE = "playlist.json".freeze
  STATE_VERSION = 1
  SEEK_STEP = 5
  VOLUME_STEP = 5
  DEFAULT_VOLUME = 80
  # Upper bound for "add folder" so a whole disk does not end up in the list.
  MAX_FOLDER_FILES = 10_000
  ENGINE_INTERVAL = 0.2
  # A sound that reports "stopped" this soon after starting is not finished yet.
  START_GRACE_SECONDS = 1.0

  # One playlist entry: a local path or a URL, an optional title and the
  # length in seconds (nil when unknown).
  class Entry
    attr_accessor :location, :title, :length

    def initialize(location, title = nil, length = nil)
      @location = location.to_s
      @title = title.to_s == "" ? nil : title.to_s
      @length = length.is_a?(Numeric) && length > 0 ? length : nil
    end

    def url?
      KlangtenPlaylist.url?(@location)
    end

    # What the lists speak: the title, otherwise the file name or the URL
    # without its query.
    def name
      return @title if @title != nil
      return @location.split(/[?#]/, 2)[0].to_s if url?
      File.basename(@location.tr("\\", "/"))
    end

    def to_h
      { "location" => @location, "title" => @title, "length" => @length }
    end

    def self.from_h(hash)
      return nil if !hash.is_a?(Hash) || hash["location"].to_s == ""
      new(hash["location"], hash["title"], hash["length"])
    end
  end

  # An editable list of entries: the internal playlist or a playlist file.
  class List
    attr_reader :entries
    attr_accessor :path, :dirty

    def initialize(entries = [], path: nil, internal: false)
      @entries = entries
      @path = path
      @internal = internal
      @dirty = false
    end

    def internal?
      @internal
    end

    def size
      @entries.size
    end

    def empty?
      @entries.empty?
    end

    def [](index)
      @entries[index]
    end

    def index_of(entry)
      @entries.index { |item| item.equal?(entry) }
    end

    # Inserts entries (at the end or before index); returns the first new index.
    def add(new_entries, at: nil)
      new_entries = Array(new_entries).compact
      return nil if new_entries.empty?
      at = @entries.size if at == nil || at > @entries.size || at < 0
      @entries.insert(at, *new_entries)
      changed
      at
    end

    def remove(index)
      return nil if index < 0 || index >= @entries.size
      entry = @entries.delete_at(index)
      changed
      entry
    end

    # Moves an entry by delta (-1 up, +1 down); returns the new index or nil.
    def move(index, delta)
      target = index + delta
      return nil if index < 0 || index >= @entries.size || target < 0 || target >= @entries.size
      @entries[index], @entries[target] = @entries[target], @entries[index]
      changed
      target
    end

    def clear
      @entries.clear
      changed
    end

    def rename(index, title)
      entry = @entries[index]
      return if entry == nil
      entry.title = title.to_s == "" ? nil : title.to_s
      changed
    end

    # The internal playlist is saved at once; a file only on save.
    def changed
      @dirty = true
      KlangtenPlaylist.save_internal if @internal
    end

    # Writes the list to its file (or to path, which then becomes its file).
    def save(path = @path)
      raise ArgumentError, "No playlist file" if path.to_s == ""
      KlangtenPlaylist.write_file(path, @entries)
      @path = path if !@internal
      @dirty = false if !@internal || path == @path
      true
    end
  end

  @lock = Monitor.new
  @internal = nil
  @settings = nil
  @sound = nil
  @current = nil
  @current_index = nil
  @list = nil
  @paused = false
  @pending = nil
  @generation = 0
  @thread = nil
  @started_at = nil
  @queue = []
  @history = []
  @failures = 0

  class << self
    # ------------------------------------------------------------ helpers

    def url?(value)
      value.to_s.match?(/\A[a-z][a-z0-9+.\-]*:\/\//i) && !value.to_s.downcase.start_with?("file://")
    end

    def playlist_file?(path)
      PLAYLIST_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    # Folder where playlists are saved and exported by default. Klangten's own
    # folder inside the documents (on iOS the documents already are Klangten's).
    def playlists_dir(create: false)
      base = Dirs.documents
      dir = ios? ? File.join(base, "Playlists") : File.join(base, "Klangten", "Playlists")
      FileUtils.mkdir_p(dir) if create && !File.directory?(dir)
      dir
    rescue StandardError
      dir
    end

    # "1:02:03" or "4:05".
    def format_duration(seconds)
      seconds = seconds.to_f.round
      hours, rest = seconds.divmod(3600)
      minutes, secs = rest.divmod(60)
      hours > 0 ? format("%d:%02d:%02d", hours, minutes, secs) : format("%d:%02d", minutes, secs)
    end

    # Audio files below folder (recursive, sorted, symlinked folders are not
    # followed), at most limit entries. The block, if given, is called with the
    # number found so far and may raise to cancel.
    def collect_audio_files(folder, extensions, limit: MAX_FOLDER_FILES, &block)
      found = []
      visited = {}
      walk = lambda do |dir|
        real = File.realpath(dir) rescue dir
        return if visited[real]
        visited[real] = true
        children = (Dir.children(dir) rescue [])
        children = children.sort_by { |name| name.downcase }
        files = []
        dirs = []
        children.each do |name|
          full = File.join(dir, name)
          next if File.symlink?(full) && File.directory?(full)
          if File.directory?(full)
            dirs << full
          elsif extensions.include?(File.extname(name).downcase)
            files << full
          end
        end
        files.each do |file|
          return if found.size >= limit
          found << file
        end
        block.call(found.size) if block != nil
        dirs.each do |sub|
          return if found.size >= limit
          walk.call(sub)
        end
      end
      walk.call(folder)
      found
    end

    # ------------------------------------------------------- reading files

    # Reads an M3U/M3U8/PLS file into a List bound to that file.
    def read_file(path)
      data = File.binread(path)
      base = File.dirname(File.expand_path(path))
      text = decode(data)
      entries = if File.extname(path).downcase == ".pls" || text.lstrip.downcase.start_with?("[playlist]")
        parse_pls(text, base)
      else
        parse_m3u(text, base)
      end
      List.new(entries, path: path)
    end

    def decode(data)
      data = data.to_s.b
      text = if data.start_with?("\xEF\xBB\xBF".b)
        data.byteslice(3..).to_s.force_encoding(Encoding::UTF_8)
      elsif data.start_with?("\xFF\xFE".b)
        data.byteslice(2..).to_s.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      elsif data.start_with?("\xFE\xFF".b)
        data.byteslice(2..).to_s.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      else
        utf8 = data.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : data.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
      text.valid_encoding? ? text : text.scrub("")
    end

    def parse_m3u(text, base)
      entries = []
      title = nil
      length = nil
      text.each_line do |line|
        line = line.strip
        next if line == ""
        if line.start_with?("#")
          if (match = /\A#EXTINF:\s*(-?\d+(?:\.\d+)?)[^,]*,(.*)\z/i.match(line))
            length = match[1].to_f
            title = match[2].strip
          end
          next
        end
        location = resolve_location(line, base)
        entries << Entry.new(location, title, length) if location != nil
        title = nil
        length = nil
      end
      entries
    end

    def parse_pls(text, base)
      files = {}
      titles = {}
      lengths = {}
      text.each_line do |line|
        match = /\A\s*(file|title|length)(\d+)\s*=(.*)\z/i.match(line.chomp)
        next if match == nil
        number = match[2].to_i
        value = match[3].strip
        case match[1].downcase
        when "file" then files[number] = value
        when "title" then titles[number] = value
        when "length" then lengths[number] = value.to_f
        end
      end
      files.keys.sort.filter_map do |number|
        location = resolve_location(files[number], base)
        location == nil ? nil : Entry.new(location, titles[number], lengths[number])
      end
    end

    # An absolute path or URL for one playlist line.
    def resolve_location(value, base)
      value = value.to_s.strip
      return nil if value == ""
      return value if url?(value)
      if value.downcase.start_with?("file://")
        value = value.sub(/\Afile:\/\/(localhost)?/i, "")
        value = value.gsub(/%([0-9A-Fa-f]{2})/) { [$1].pack("H2") }.force_encoding(Encoding::UTF_8)
        value = value[1..] if value.match?(/\A\/[A-Za-z]:\//)
      end
      value = value.tr("\\", "/")
      return value if absolute_path?(value)
      normalize_path(File.join(base.tr("\\", "/"), value))
    end

    # ------------------------------------------------------- writing files

    def write_file(path, entries)
      base = File.dirname(File.expand_path(path))
      text = File.extname(path).downcase == ".pls" ? to_pls(entries, base) : to_m3u(entries, base)
      atomic_write(path, text)
    end

    def to_m3u(entries, base)
      lines = ["#EXTM3U"]
      entries.each do |entry|
        length = entry.length == nil ? -1 : entry.length.round
        lines << "#EXTINF:#{length},#{single_line(entry.title || entry.name)}"
        lines << relative_location(entry.location, base)
      end
      lines.join("\r\n") + "\r\n"
    end

    def to_pls(entries, base)
      lines = ["[playlist]"]
      entries.each_with_index do |entry, index|
        number = index + 1
        lines << "File#{number}=#{relative_location(entry.location, base)}"
        lines << "Title#{number}=#{single_line(entry.title || entry.name)}"
        lines << "Length#{number}=#{entry.length == nil ? -1 : entry.length.round}"
      end
      lines << "NumberOfEntries=#{entries.size}"
      lines << "Version=2"
      lines.join("\r\n") + "\r\n"
    end

    # A path relative to base when both are on the same root, otherwise as is.
    def relative_location(location, base)
      return location if url?(location)
      target = normalize_path(location.to_s.tr("\\", "/"))
      from = normalize_path(base.to_s.tr("\\", "/"))
      target_parts = target.split("/")
      from_parts = from.split("/")
      compare = windows? ? ->(a, b) { a.casecmp?(b) } : ->(a, b) { a == b }
      return target if target_parts.empty? || from_parts.empty? || !compare.call(target_parts[0], from_parts[0])
      common = 0
      common += 1 while common < from_parts.size && common < target_parts.size - 1 && compare.call(from_parts[common], target_parts[common])
      return target if common == 0 || (common == 1 && target_parts[0] == "")
      (([".."] * (from_parts.size - common)) + target_parts[common..]).join("/")
    end

    # Writes through a temporary file and a rename, so a crash never leaves a
    # half-written playlist or state file.
    def atomic_write(path, text)
      dir = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(dir)
      temporary = File.join(dir, ".#{File.basename(path)}.#{$$}.#{Thread.current.object_id}.tmp")
      File.binwrite(temporary, text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace))
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary != nil && File.exist?(temporary) rescue nil
    end

    # ------------------------------------------------- internal playlist

    def state_path
      File.join(Dirs.eltendata, STATE_FILE)
    end

    def internal
      @lock.synchronize do
        load_internal if @internal == nil
        @internal
      end
    end

    def save_internal
      @lock.synchronize do
        return if @internal == nil
        index = @list.equal?(@internal) ? @internal.index_of(@current) : nil
        @settings["index"] = index if index != nil
        data = {
          "version" => STATE_VERSION,
          "entries" => @internal.entries.map(&:to_h),
          "index" => @settings["index"].to_i,
          "shuffle" => @settings["shuffle"] == true,
          "repeat" => @settings["repeat"] != false,
          "volume" => volume
        }
        atomic_write(state_path, JSON.generate(data))
      end
    rescue StandardError => e
      log(:warning, "Saving the playlist failed: #{e.class}: #{e.message}")
    end

    # Index the internal playlist was at when it was last played.
    def saved_index
      internal
      [[@settings["index"].to_i, 0].max, [@internal.size - 1, 0].max].min
    end

    # ------------------------------------------------------------ settings

    def shuffle?
      settings["shuffle"] == true
    end

    def repeat?
      settings["repeat"] != false
    end

    def volume
      [[settings["volume"].to_i, 0].max, 100].min
    end

    def volume=(value)
      @lock.synchronize do
        settings["volume"] = [[value.to_i, 0].max, 100].min
        apply_volume
      end
      save_internal
    end

    def change_volume(delta)
      self.volume = volume + delta
      volume
    end

    def repeat=(value)
      settings["repeat"] = value == true
      save_internal
    end

    # Switching shuffle keeps the current entry; with shuffle on the others
    # follow in a new random order.
    def shuffle=(value)
      @lock.synchronize do
        settings["shuffle"] = value == true
        rebuild_queue
      end
      save_internal
    end

    # ------------------------------------------------------------- playback

    # Starts list (default: the internal playlist) at index.
    def play(list = internal, index = 0)
      @lock.synchronize do
        entry = list[index]
        return false if entry == nil
        @list = list
        @current = entry
        @current_index = index
        @failures = 0
        rebuild_queue
        start(entry)
      end
      true
    end

    def stop
      @lock.synchronize do
        @generation += 1
        @pending = nil
        close_sound
        @current = nil
        @paused = false
      end
      save_internal
    end

    # Play/pause; with nothing loaded it starts the internal playlist where it
    # was left. Returns :playing, :paused or nil (nothing to play).
    def toggle_pause
      @lock.synchronize do
        if @current == nil
          return play(internal, saved_index) ? :playing : nil
        end
        if @paused
          resume
          :playing
        else
          pause
          :paused
        end
      end
    end

    def pause
      @lock.synchronize do
        return if @current == nil
        @paused = true
        @sound.pause if @sound != nil
      end
    end

    def resume
      @lock.synchronize do
        return if @current == nil
        @paused = false
        if @sound != nil
          @sound.play
          @started_at = monotonic
        elsif @pending == nil
          start(@current)
        end
      end
    end

    # Pauses background playback while the block runs (another player is
    # open) and continues afterwards if it was playing.
    def suspend
      was_playing = playing?
      pause if was_playing
      yield
    ensure
      resume if was_playing && @current != nil && @paused
    end

    def next(auto: false)
      @lock.synchronize do
        return nil if @list == nil || @current == nil && !auto
        entry = next_entry
        if entry == nil
          stop_at_end if auto
          return nil
        end
        @current = entry
        @current_index = @list.index_of(entry)
        start(entry)
        entry
      end
    end

    def previous
      @lock.synchronize do
        return nil if @list == nil || @current == nil
        entry = previous_entry
        return nil if entry == nil
        @current = entry
        @current_index = @list.index_of(entry)
        start(entry)
        entry
      end
    end

    def seek(delta)
      @lock.synchronize do
        return false if @sound == nil
        length = @sound.length.to_f
        position = [@sound.position.to_f + delta, 0].max
        position = [position, length - 0.5].min if length > 0
        @sound.position = position
        true
      end
    rescue StandardError
      false
    end

    def playing?
      @current != nil && !@paused
    end

    def paused?
      @current != nil && @paused
    end

    def active?
      @current != nil
    end

    def current_entry
      @current
    end

    def current_list
      @list
    end

    # Index of the playing entry in its list, nil when it is not playing.
    def current_index
      @list == nil || @current == nil ? nil : @list.index_of(@current)
    end

    def position
      @sound == nil ? nil : @sound.position.to_f
    rescue StandardError
      nil
    end

    def length
      @sound == nil ? nil : @sound.length.to_f
    rescue StandardError
      nil
    end

    # Spoken status, e.g. "Playing: Title, 1:02 of 4:05".
    def status_text
      entry = @current
      return p_("Klangten", "The playlist is stopped.") if entry == nil
      label = @paused ? p_("Klangten", "Paused: %{title}") : p_("Klangten", "Playing: %{title}")
      text = label % { title: entry.name }
      pos = position
      len = length
      if pos != nil && len != nil && len > 0
        text += ", " + p_("Klangten", "%{position} of %{length}") % { position: format_duration(pos), length: format_duration(len) }
      end
      text
    end

    # Registers the playback quick actions (idempotent).
    def register_quick_actions
      return if @quick_actions_registered || !defined?(EltenAPI::QuickActions)
      @quick_actions_registered = true
      quick = EltenAPI::QuickActions
      quick.register_proc(:klangten_playlist, :toggle, proc { p_("Klangten", "Playlist: play or pause") }, proc { quick_action(:toggle) })
      quick.register_proc(:klangten_playlist, :previous, proc { p_("Klangten", "Playlist: previous") }, proc { quick_action(:previous) })
      quick.register_proc(:klangten_playlist, :next, proc { p_("Klangten", "Playlist: next") }, proc { quick_action(:next) })
      quick.register_proc(:klangten_playlist, :volume_down, proc { p_("Klangten", "Playlist: volume down") }, proc { quick_action(:volume_down) })
      quick.register_proc(:klangten_playlist, :volume_up, proc { p_("Klangten", "Playlist: volume up") }, proc { quick_action(:volume_up) })
    end

    def quick_action(action)
      case action
      when :toggle
        case toggle_pause
        when :playing then alert(status_text, false)
        when :paused then alert(p_("Klangten", "Paused"), false)
        else alert(p_("Klangten", "The playlist is empty."), false)
        end
      when :previous, :next
        entry = action == :next ? self.next : previous
        if entry != nil
          alert(entry.name, false)
        elsif !active?
          alert(p_("Klangten", "The playlist is stopped."), false)
        else
          alert(p_("Klangten", "End of the playlist"), false)
        end
      when :volume_down, :volume_up
        alert(p_("Klangten", "Volume %{volume}") % { volume: change_volume(action == :volume_up ? VOLUME_STEP : -VOLUME_STEP) }, false)
      end
    rescue StandardError => e
      log(:error, "Playlist quick action failed: #{e.class}: #{e.message}")
    end

    private

    def settings
      @lock.synchronize do
        load_internal if @settings == nil
        @settings
      end
    end

    def load_internal
      data = {}
      begin
        data = JSON.parse(File.read(state_path, encoding: "UTF-8")) if File.file?(state_path)
      rescue StandardError => e
        log(:warning, "The playlist could not be read: #{e.class}: #{e.message}")
        data = {}
      end
      data = {} if !data.is_a?(Hash)
      entries = Array(data["entries"]).filter_map { |item| Entry.from_h(item) }
      @internal = List.new(entries, internal: true)
      @settings = {
        "index" => data["index"].to_i,
        "shuffle" => data["shuffle"] == true,
        "repeat" => data.key?("repeat") ? data["repeat"] != false : true,
        "volume" => data.key?("volume") ? data["volume"].to_i : DEFAULT_VOLUME
      }
    end

    def windows?
      defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:platform_os) ? EltenSystemHelpers.platform_os.to_s == "windows" : RUBY_PLATFORM.match?(/mswin|mingw/)
    rescue StandardError
      false
    end

    def ios?
      defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:platform_os) && EltenSystemHelpers.platform_os.to_s == "ios"
    rescue StandardError
      false
    end

    def absolute_path?(value)
      value.start_with?("/") || value.match?(/\A[A-Za-z]:\//)
    end

    # Resolves "." and ".." without touching the disk.
    def normalize_path(path)
      prefix = ""
      if (match = /\A([A-Za-z]:)\//.match(path))
        prefix = match[1]
        path = path[2..]
      elsif path.start_with?("//")
        prefix = "/"
        path = path[1..]
      end
      parts = []
      path.split("/").each do |part|
        next if part == "" || part == "."
        part == ".." ? parts.pop : parts << part
      end
      prefix + "/" + parts.join("/")
    end

    def single_line(value)
      value.to_s.gsub(/[\r\n]+/, " ")
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(level, message)
      Log.__send__(level, message) if defined?(Log) && Log.respond_to?(level)
    rescue StandardError
      nil
    end

    # Shuffle order: the entries not yet played, in random order.
    def rebuild_queue
      @history = @current == nil ? [] : [@current]
      @queue = []
      return if @list == nil || !shuffle?
      @queue = @list.entries.reject { |entry| entry.equal?(@current) }.shuffle
    end

    def next_entry
      entries = @list.entries
      return nil if entries.empty?
      if shuffle?
        @queue.select! { |entry| @list.index_of(entry) != nil }
        if @queue.empty?
          return nil if !repeat?
          @queue = entries.reject { |entry| entry.equal?(@current) }.shuffle
          @queue = [@current] if @queue.empty? && @current != nil && @list.index_of(@current) != nil
        end
        entry = @queue.shift
        @history << entry if entry != nil
        @history.shift while @history.size > 1000
        return entry
      end
      index = @list.index_of(@current)
      # A removed current entry leaves its successor at the old index.
      index = index == nil ? (@current_index || 0) : index + 1
      if index >= entries.size
        return nil if !repeat?
        index = 0
      end
      entries[index]
    end

    def previous_entry
      entries = @list.entries
      return nil if entries.empty?
      if shuffle?
        @history.select! { |entry| @list.index_of(entry) != nil || entry.equal?(@current) }
        return nil if @history.size < 2
        current = @history.pop
        @queue.unshift(current) if current != nil
        return @history.last
      end
      index = @list.index_of(@current) || @current_index || 0
      index -= 1
      if index < 0
        return nil if !repeat?
        index = entries.size - 1
      end
      entries[index]
    end

    def stop_at_end
      @generation += 1
      @pending = nil
      close_sound
      @current = nil
      @paused = false
    end

    # Hands an entry to the engine thread (called with the lock held).
    def start(entry)
      @generation += 1
      close_sound
      @paused = false
      @pending = [entry, @generation]
      ensure_thread
      save_internal if @list.equal?(@internal)
    end

    def close_sound
      sound = @sound
      @sound = nil
      sound.close if sound != nil
    rescue StandardError => e
      log(:warning, "Closing a playlist sound failed: #{e.class}: #{e.message}")
    end

    def apply_volume
      @sound.volume = volume / 100.0 if @sound != nil
    rescue StandardError
      nil
    end

    def ensure_thread
      return if @thread != nil && @thread.alive?
      @thread = Thread.new { engine_loop }
      @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
    end

    def engine_loop
      loop do
        job = nil
        @lock.synchronize do
          job = @pending
          @pending = nil
          if job == nil
            if @current == nil && @sound == nil
              @thread = nil
              return
            end
            check_finished
          end
        end
        open_job(job) if job != nil
        sleep(ENGINE_INTERVAL)
      end
    rescue Exception => e
      log(:error, "Playlist engine failed: #{e.class}: #{e.message}")
      @lock.synchronize { @thread = nil if @thread.equal?(Thread.current) }
    end

    # Opens the sound outside the lock (a stream URL may take seconds).
    def open_job(job)
      entry, generation = job
      sound = nil
      error = nil
      begin
        location = entry.location
        raise "missing file" if !url?(location) && !File.file?(location)
        sound = Sound.new(location)
        if !sound.opened?
          sound.close
          sound = nil
          raise "cannot open"
        end
      rescue Exception => e
        error = e
        sound = nil
      end
      @lock.synchronize do
        if generation != @generation
          sound.close if sound != nil
          return
        end
        if sound == nil
          log(:warning, "Playlist entry skipped (#{error&.message}): #{entry.location}")
          @failures += 1
          if @list == nil || @failures >= [@list.size, 1].max
            stop_at_end
          else
            self.next(auto: true)
          end
          return
        end
        @failures = 0
        @sound = sound
        apply_volume
        length = sound.length.to_f rescue 0
        if length > 0 && (entry.length == nil || (entry.length - length).abs > 1)
          entry.length = length
          save_internal if @list.equal?(@internal)
        end
        @started_at = monotonic
        if @paused
          nil
        else
          sound.play
        end
      end
    end

    def check_finished
      return if @sound == nil || @paused || @current == nil
      return if @started_at != nil && monotonic - @started_at < START_GRACE_SECONDS
      return if !@sound.finished?
      self.next(auto: true)
    rescue StandardError => e
      log(:warning, "Playlist playback check failed: #{e.class}: #{e.message}")
    end
  end

  register_quick_actions
end
