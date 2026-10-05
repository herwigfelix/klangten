# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# YouTube (Media menu): search, channels, playlists, favourites, history, a
# player screen and downloads. The data comes from KlangtenYouTube
# (src/eapi/youtube.rb); every slow call runs in EltenAPI::Tasks.run, so a
# busy indicator appears after half a second and Escape cancels.
#
# Keys in result lists: Enter plays a video or opens a channel or playlist,
# Shift+Enter shows the actions of a video, Control+I shows the details,
# Control+D speaks them briefly. The last entry loads the next 50 results.

class Scene_YouTube
  # Search field that steps through earlier searches with Up and Down.
  class SearchField < EltenAPI::Controls::EditBox
    def initialize(header, history)
      super(header, text: "")
      @history = history
      @history_index = -1
    end

    def history=(entries)
      @history = entries
      @history_index = -1
    end

    def update
      if !@history.empty? && !raw_key_held?(:key_shift) && !modifier_held?(:main_modifier) && (key_pressed?(:key_up) || key_pressed?(:key_down))
        step = key_pressed?(:key_up) ? 1 : -1
        index = @history_index + step
        if index >= @history.size || index < -1
          play_sound("border")
        else
          @history_index = index
          text = index < 0 ? "" : @history[index].to_s
          set_text(text)
          self.index = self.check = text.length
          text == "" ? play_sound("border") : speak(text)
        end
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        return
      end
      super
    end
  end

  # The core player without its "Save file" entry: that would save the
  # expiring stream address, the YouTube download does it properly. The
  # YouTube actions are added to the player's own menu.
  class StreamPlayer < EltenAPI::Controls::Player
    attr_accessor :extra_context

    def hascontext
      true
    end

    def context(menu, submenu = false)
      @extra_context.call(menu) if @extra_context != nil
      file = @file
      @file = nil
      begin
        super(menu, submenu)
      ensure
        @file = file
      end
    end
  end

  DownloadFormat = Struct.new(:kind, :label, :extension, :encoder, keyword_init: true)

  def self.available?
    defined?(KlangtenYouTube) && KlangtenYouTube.available?
  rescue Exception
    false
  end

  # Opens a YouTube address from elsewhere (media catalog, links in texts) and
  # returns when the user is done: a video shows its actions, a channel or
  # playlist its videos.
  def self.open_url(url)
    new.open_url(url)
  end

  def initialize
    @owner = nil
  end

  def main
    @owner = self
    if KlangtenYouTube.prepare
      start_screen
    end
    $scene = Scene_Main.new if $scene == self
  end

  def open_url(url)
    @owner = $scene
    return unless KlangtenYouTube.prepare
    target = KlangtenYouTube.parse_url(url)
    if target == nil
      alert(p_("Klangten", "This is not a YouTube address."))
      return
    end
    open_target(target, actions: true)
  end

  private

  def left?
    $scene != @owner
  end

  # ------------------------------------------------------------- start screen

  def start_screen
    kinds = [:video, :channel, :playlist]
    query = SearchField.new(p_("Klangten", "Search YouTube"), KlangtenYouTube.recent_searches)
    kind = ListBox.new([p_("Klangten", "Videos"), p_("Klangten", "Channels"), p_("Klangten", "Playlists")], header: p_("Klangten", "Search for"))
    search = Button.new(p_("Klangten", "Search"))
    favourites = Button.new(p_("Klangten", "Favourites"))
    history = Button.new(p_("Klangten", "History"))
    update = KlangtenYouTube.desktop? ? Button.new(p_("Klangten", "Update YouTube component")) : nil
    close = Button.new(_("Close"))
    fields = [query, kind, search, favourites, history]
    fields << update if update != nil
    fields << close
    form = Form.new(fields)
    form.accept_button = search
    form.cancel_button = close
    done = false
    query.bind_context do |menu|
      menu.option(p_("Klangten", "Recent searches")) do
        entries = KlangtenYouTube.recent_searches
        if entries.empty?
          alert(p_("Klangten", "You have not searched yet."))
        else
          index = selector(entries, header: p_("Klangten", "Recent searches"), cancel_index: -1)
          if index != nil && index >= 0
            query.set_text(entries[index])
            query.index = query.check = entries[index].length
          end
        end
      end
      menu.option(p_("Klangten", "Clear search history")) do
        if confirm(p_("Klangten", "Do you want to clear your search history?"))
          KlangtenYouTube.clear_searches
          query.history = []
          alert(p_("Klangten", "The search history has been cleared."))
        end
      end
    end
    search.on(:press) do
      text = query.text.to_s.strip
      if text == ""
        alert(p_("Klangten", "Enter what you are looking for."))
        next
      end
      target = KlangtenYouTube.parse_url(text)
      # A bare id that YouTube does not know was a search term after all.
      target = nil if target != nil && target[1] == text && !known_video?(text)
      if target != nil
        open_target(target)
      else
        KlangtenYouTube.remember_search(text)
        query.history = KlangtenYouTube.recent_searches
        run_search(text, kinds[kind.index] || :video)
      end
      form.focus unless left?
    end
    favourites.on(:press) do
      show_saved(:favourites)
      form.focus unless left?
    end
    history.on(:press) do
      show_saved(:history)
      form.focus unless left?
    end
    update.on(:press) { KlangtenYouTube.update_component(force: true) } if update != nil
    close.on(:press) { done = true }
    loop do
      loop_update
      form.update
      break if done || left?
    end
  end

  def known_video?(id)
    EltenAPI::Tasks.run(title: p_("Klangten", "Opening the video...")) do |_progress, token|
      KlangtenYouTube.video(id, token: token)
    end
    true
  rescue EltenAPI::Tasks::Cancelled, StandardError
    false
  end

  def run_search(text, kind)
    header = case kind
             when :channel then p_("Klangten", "Channels: %{query}") % { query: text }
             when :playlist then p_("Klangten", "Playlists: %{query}") % { query: text }
             else p_("Klangten", "Videos: %{query}") % { query: text }
             end
    show_results(header) { |page, token| KlangtenYouTube.search(text, kind, page: page, token: token) }
  end

  # target from KlangtenYouTube.parse_url. actions: true shows the action menu
  # of a video instead of playing it at once.
  def open_target(target, actions: false)
    kind, value = target
    case kind
    when :video
      item = KlangtenYouTube::Item.new(kind: :video, id: value, url: KlangtenYouTube.video_url(value), title: "")
      actions ? video_actions(item) : play_video(item)
    when :channel
      open_channel(KlangtenYouTube::Item.new(kind: :channel, id: value, url: value, title: p_("Klangten", "Channel")))
    when :playlist
      open_playlist(KlangtenYouTube::Item.new(kind: :playlist, id: value, url: value, title: p_("Klangten", "Playlist")))
    end
  end

  # ---------------------------------------------------------------- helpers

  # Runs a blocking YouTube call with a busy indicator. nil when cancelled or
  # failed (the failure is announced).
  def fetch(title)
    EltenAPI::Tasks.run(title: title) { |_progress, token| yield token }
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue KlangtenYouTube::Missing
    alert(p_("Klangten", "This feature is not available on this system."))
    nil
  rescue StandardError => e
    Log.warning("YouTube request failed: #{e.class}: #{e.message}")
    alert(p_("Klangten", "YouTube did not answer as expected. Try again later."))
    nil
  end

  def item_label(item)
    case item.kind
    when :channel
      item.title.to_s
    when :playlist
      [item.title, item.author].map(&:to_s).reject(&:empty?).join(", ")
    else
      parts = [item.title.to_s, item.author.to_s]
      parts << (item.live ? p_("Klangten", "live") : KlangtenYouTube.format_duration(item.duration).to_s)
      parts.reject(&:empty?).join(", ")
    end
  end

  def kind_name(item)
    case item.kind
    when :channel then p_("Klangten", "Channel")
    when :playlist then p_("Klangten", "Playlist")
    else p_("Klangten", "Video")
    end
  end

  def summary_parts(item)
    parts = []
    parts << p_("Klangten", "Author: %{name}") % { name: item.author } if item.author.to_s != ""
    duration = KlangtenYouTube.format_duration(item.duration)
    parts << p_("Klangten", "Duration: %{time}") % { time: duration } if duration != nil
    parts << p_("Klangten", "Live stream") if item.live
    parts << p_("Klangten", "Published: %{date}") % { date: format_date(item.date, false, false) } if item.date != nil
    parts << p_("Klangten", "Views: %{count}") % { count: item.views } if item.views.to_i > 0
    parts << p_("Klangten", "Subscribers: %{count}") % { count: item.subscribers } if item.subscribers.to_i > 0
    parts
  end

  # Control+D: what is known without asking YouTube again.
  def speak_summary(item)
    parts = [item.title.to_s] + summary_parts(item)
    parts << item.description.to_s if item.description.to_s != ""
    speak(parts.reject(&:empty?).join(", "))
  end

  # Control+I: everything, for videos with the full description.
  def show_details(item)
    if item.video?
      video = fetch(p_("Klangten", "Loading details...")) { |token| KlangtenYouTube.video(item.id, token: token) }
      return if video == nil
      item = KlangtenYouTube.item_from_video(video)
      likes = video.likes
    end
    lines = [item.title.to_s, kind_name(item)] + summary_parts(item)
    lines << p_("Klangten", "Likes: %{count}") % { count: likes } if likes.to_i > 0
    lines << p_("Klangten", "Address: %{url}") % { url: KlangtenYouTube.item_url(item) }
    lines << "" << item.description.to_s if item.description.to_s != ""
    display_text(lines.join("\n"), header: p_("Klangten", "Details"))
  end

  def copy_link(item)
    Clipboard.set_data(KlangtenYouTube.item_url(item))
    alert(p_("Klangten", "The link has been copied to the clipboard."))
  end

  def toggle_favourite(item)
    if KlangtenYouTube.toggle_favourite(item)
      alert(p_("Klangten", "Added to favourites."))
    else
      alert(p_("Klangten", "Removed from favourites."))
    end
  end

  def favourite_label(item)
    KlangtenYouTube.favourite?(item) ? p_("Klangten", "Remove from favourites") : p_("Klangten", "Add to favourites")
  end

  def mark_favourites(list, items)
    status = p_("Klangten", "favourite")
    items.each_with_index do |item, index|
      if KlangtenYouTube.favourite?(item)
        list.set_item_status(index, "listbox_itemliked", status, status)
      else
        list.clear_item_status(index, "listbox_itemliked", status, status)
      end
    end
  end

  # ------------------------------------------------------------ result lists

  # A paged list. The loader receives the page number (from 0) and the
  # cancellation token and returns a KlangtenYouTube::Page.
  def show_results(header, &loader)
    page = fetch(p_("Klangten", "Searching...")) { |token| loader.call(0, token) }
    return if page == nil
    items = page.items.to_a
    more = page.more
    next_page = 1
    if items.empty?
      alert(p_("Klangten", "Nothing was found."))
      return
    end
    rows = proc do
      labels = items.map { |item| item_label(item) }
      labels << p_("Klangten", "Load the next 50 results") if more
      labels
    end
    list = ListBox.new(rows.call, header: header + ", " + p_("Klangten", "found: %{count}") % { count: items.size }, index: 0, quiet: true)
    refresh = proc do
      index = list.index
      list.options = rows.call
      mark_favourites(list, items)
      list.index = [[index, list.options.size - 1].min, 0].max
    end
    mark_favourites(list, items)
    list.bind_context do |menu|
      item = items[list.index]
      item_context(menu, item, refresh) if item != nil
    end
    list.focus
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || left?
      item = items[list.index]
      if item != nil && main_shortcut_pressed?("d", first: true)
        speak_summary(item)
        next
      end
      next unless key_pressed?(:key_enter)
      if item == nil && more
        loaded = fetch(p_("Klangten", "Loading more results...")) { |token| loader.call(next_page, token) }
        if loaded != nil
          next_page += 1
          known = items.map(&:key)
          added = loaded.items.to_a.reject { |entry| known.include?(entry.key) }
          items.concat(added)
          more = loaded.more
          refresh.call
          alert(p_("Klangten", "No further results.")) if added.empty?
        end
      elsif item != nil
        open_item(item, actions: raw_key_held?(:key_shift))
        break if left?
        refresh.call
      end
      list.focus
    end
  end

  def open_item(item, actions: false)
    case item.kind
    when :channel then open_channel(item)
    when :playlist then open_playlist(item)
    else actions ? video_actions(item) : play_video(item)
    end
  end

  def open_channel(item)
    url = KlangtenYouTube.item_url(item)
    show_results(item.title.to_s == "" ? p_("Klangten", "Channel") : item.title.to_s) do |page, token|
      KlangtenYouTube.channel_videos(url, page: page, token: token)
    end
  end

  def open_playlist(item)
    url = KlangtenYouTube.item_url(item)
    show_results(item.title.to_s == "" ? p_("Klangten", "Playlist") : item.title.to_s) do |page, token|
      KlangtenYouTube.playlist_videos(url, page: page, token: token)
    end
  end

  def item_context(menu, item, refresh)
    if item.video?
      video_menu_entries(item).each do |key, label|
        next if key == :details
        menu.option(label) do
          run_video_action(item, key)
          refresh.call
        end
      end
    else
      menu.option(p_("Klangten", "Open")) { open_item(item) }
      if item.kind == :playlist && item.channel_url.to_s != ""
        menu.option(p_("Klangten", "Show channel")) { show_channel(item) }
      end
      menu.option(favourite_label(item)) do
        toggle_favourite(item)
        refresh.call
      end
      menu.option(p_("Klangten", "Copy link")) { copy_link(item) }
    end
    menu.option(p_("Klangten", "Details"), nil, "i") { show_details(item) }
  end

  # ----------------------------------------------------------- video actions

  def video_menu_entries(item)
    entries = {}
    entries[:play] = p_("Klangten", "Play")
    entries[:quality] = p_("Klangten", "Play in quality")
    entries[:channel] = p_("Klangten", "Show channel")
    entries[:download] = p_("Klangten", "Download")
    entries[:favourite] = favourite_label(item)
    entries[:copy] = p_("Klangten", "Copy link")
    entries[:avatar] = p_("Klangten", "Set as audio avatar") if Session.logged?
    entries[:details] = p_("Klangten", "Details")
    entries
  end

  def video_actions(item)
    item = complete_item(item) if item.title.to_s == ""
    return if item == nil
    entries = video_menu_entries(item)
    entries[:cancel] = _("Cancel")
    action = select_action(entries, header: item.title.to_s, cancel: :cancel, flags: 1)
    run_video_action(item, action)
  end

  def run_video_action(item, action)
    case action
    when :play then play_video(item)
    when :quality then play_in_quality(item)
    when :channel then show_channel(item)
    when :download then download(item)
    when :favourite then toggle_favourite(complete_item(item) || item)
    when :copy then copy_link(item)
    when :avatar then set_avatar(item)
    when :details then show_details(item)
    end
  end

  # A video known only by its id (address, history) gets title and author.
  def complete_item(item)
    return item if item.title.to_s != "" && item.author.to_s != ""
    video = resolve(item)
    video == nil ? nil : KlangtenYouTube.item_from_video(video)
  end

  def resolve(item, fresh: false)
    fetch(p_("Klangten", "Opening the video...")) { |token| KlangtenYouTube.video(item.id, token: token, cached: !fresh) }
  end

  def show_channel(item)
    url = item.channel_url.to_s
    author = item.author.to_s
    if url == "" && item.video?
      video = resolve(item)
      return if video == nil
      url = video.channel_url.to_s
      author = video.author.to_s
    end
    if url == ""
      alert(p_("Klangten", "The channel of this video is unknown."))
      return
    end
    open_channel(KlangtenYouTube::Item.new(kind: :channel, id: url, url: url, title: author))
  end

  def play_in_quality(item)
    video = resolve(item, fresh: true)
    return if video == nil
    streams = KlangtenYouTube.audio_streams(video)
    if streams.empty?
      alert(p_("Klangten", "This video has no audio stream that can be played."))
      return
    end
    labels = streams.map do |stream|
      [stream.codec, p_("Klangten", "%{bitrate} kbps") % { bitrate: stream.bitrate }, stream.container].map(&:to_s).reject(&:empty?).join(", ")
    end
    index = selector(labels, header: p_("Klangten", "Quality"), cancel_index: -1)
    return if index == nil || index < 0
    player_screen(video, streams[index])
  end

  def set_avatar(item)
    video = resolve(item, fresh: true)
    return if video == nil
    stream = KlangtenYouTube.original_audio(video)
    if stream == nil
      alert(p_("Klangten", "This video has no audio stream that can be played."))
      return
    end
    set_audio_avatar_from(stream.url, video.title)
  end

  # ------------------------------------------------------------------ player

  def play_video(item)
    video = resolve(item, fresh: true)
    return if video == nil
    stream = KlangtenYouTube.best_audio(video)
    if stream == nil
      alert(p_("Klangten", "This video has no audio stream that can be played."))
      return
    end
    player_screen(video, stream)
  end

  # Space pauses, Left/Right seek, Control+Up/Down change the tempo (all from
  # the core player), Escape closes. The end of the video starts it again
  # while repeat is on.
  def player_screen(video, stream)
    item = KlangtenYouTube.item_from_video(video)
    KlangtenYouTube.add_to_history(item)
    repeat = true
    close = false
    dialog_open
    # No dialog background sound under the video, as in the core player().
    dialog_mute
    player = StreamPlayer.new(stream.url, label: video.title.to_s, autoplay: true, quiet: false)
    player.extra_context = proc do |menu|
      if player.paused?
        menu.option(p_("Klangten", "Start")) { player.play }
      else
        menu.option(p_("Klangten", "Stop")) do
          player.stop
          player.sound.position = 0 if player.sound != nil && !player.sound.closed?
        end
      end
      menu.option(p_("Klangten", "Details"), nil, "i") { show_details(item) }
      menu.option(p_("Klangten", "Download"), nil, "s") { download(item) }
      menu.option(repeat ? p_("Klangten", "Turn repeat off") : p_("Klangten", "Turn repeat on"), nil, "r") do
        repeat = !repeat
        alert(repeat ? p_("Klangten", "Repeat on") : p_("Klangten", "Repeat off"))
      end
      menu.option(favourite_label(item)) { toggle_favourite(item) }
      menu.option(p_("Klangten", "Show channel")) do
        show_channel(item)
        close = true if left?
      end
      menu.option(p_("Klangten", "Copy link")) { copy_link(item) }
      menu.option(p_("Klangten", "Close player")) { close = true }
    end
    loop do
      loop_update
      player.update
      sound = player.sound
      if repeat && sound != nil && !sound.closed? && !player.paused? && sound.length > 0 && sound.position >= sound.length - 0.05
        sound.position = 0
        player.play
      end
      break if close || key_pressed?(:key_escape) || left? || sound == nil
    end
  ensure
    player.close if player != nil
    dialog_close
  end

  # --------------------------------------------------------------- downloads

  def download_folder
    base = nil
    if KlangtenYouTube.desktop?
      downloads = File.join(Dirs.user, "Downloads")
      base = downloads if File.directory?(downloads)
    elsif EltenSystemHelpers.respond_to?(:file_shortcuts)
      shortcut = EltenSystemHelpers.file_shortcuts.to_a.find { |entry| File.basename(entry[1].to_s) == "Download" }
      base = shortcut[1] if shortcut != nil
    end
    base ||= Dirs.music
    folder = File.join(base, "YouTube")
    FileUtils.mkdir_p(folder)
    folder
  rescue StandardError
    Dirs.music
  end

  def download_formats
    formats = [DownloadFormat.new(kind: :original, label: p_("Klangten", "Original audio (no conversion)"), extension: ".m4a")]
    MediaEncoders.list.each do |encoder|
      next unless encoder::Type == :audio && encoder_available?(encoder)
      formats << DownloadFormat.new(kind: :audio, label: "#{encoder::Name} (#{encoder::Extension})", extension: encoder::Extension, encoder: encoder)
    end
    if KlangtenYouTube.desktop?
      MediaEncoders.list.each do |encoder|
        next unless encoder::Type == :video && encoder_available?(encoder)
        label = p_("Klangten", "Video: %{format}") % { format: "#{encoder::Name} (#{encoder::Extension})" }
        formats << DownloadFormat.new(kind: :video, label: label, extension: encoder::Extension, encoder: encoder)
      end
    end
    formats
  end

  def encoder_available?(encoder)
    !encoder.respond_to?(:available?) || encoder.available?
  rescue StandardError
    false
  end

  def file_title(item)
    title = item.title.to_s.delete("\r\n\t\\/:*?\"<>|").strip.sub(/[. ]+\z/, "")
    title = "YouTube #{item.id}" if title == ""
    title[0, 120]
  end

  def download(item)
    item = complete_item(item)
    return if item == nil
    formats = download_formats
    title = file_title(item)
    choice = nil
    dialog_open
    begin
      destination = FilesTree.new(p_("Klangten", "Destination folder"), path: download_folder, hide_files: true, quiet: true)
      format = ListBox.new(formats.map(&:label), header: p_("Klangten", "Format"))
      name = EditBox.new(p_("Klangten", "File name"), text: title + formats[0].extension, quiet: true)
      save = Button.new(_("Save"))
      cancel = Button.new(_("Cancel"))
      form = Form.new([destination, format, name, save, cancel])
      form.cancel_button = cancel
      format.on(:move) do
        extension = formats[format.index].extension
        current = name.text.to_s
        old = File.extname(current)
        base = old == "" ? current : current[0...-old.length]
        name.set_text(base + extension)
      end
      cancel.on(:press) { form.resume }
      save.on(:press) do
        file = name.text.to_s.strip
        folder = destination.selected.to_s
        folder = destination.path.to_s if folder == ""
        folder = File.dirname(folder) if folder != "" && !File.directory?(folder)
        if file == "" || folder == "" || file.match?(%r{[\\/:*?"<>|]})
          alert(p_("Klangten", "Choose a folder and enter a valid file name."))
          next
        end
        target = EltenPath.join(folder, file)
        if File.exist?(target) && !confirm(p_("Klangten", "The file %{file} already exists. Do you want to replace it?") % { file: file })
          next
        end
        choice = [formats[format.index], target]
        form.resume
      end
      form.wait
    ensure
      dialog_close
    end
    return if choice == nil
    # FFmpeg formats on Windows: FFmpeg is downloaded now if it is missing.
    return if choice[0].encoder != nil && !MediaEncoders.prepare(choice[0].encoder)
    KlangtenYouTube.add_to_history(item)
    saved = perform_download(item, choice[0], choice[1])
    alert(p_("Klangten", "Saved as %{file}.") % { file: File.basename(saved) }) if saved != nil
  end

  # Returns the saved file or nil.
  def perform_download(item, format, target)
    temp = KlangtenYouTube.desktop? ? KlangtenYouTube.new_temp_dir : nil
    url = KlangtenYouTube.item_url(item)
    title = p_("Klangten", "Downloading %{title}...") % { title: item.title }
    case format.kind
    when :original
      if KlangtenYouTube.desktop?
        file = download_task(title) { |token, report| KlangtenYouTube.download(url, :audio, temp, token: token, &report) }
        return nil if file == nil
        target = with_extension(target, File.extname(file))
        move_file(file, target)
      else
        video = resolve(item, fresh: true)
        return nil if video == nil
        stream = KlangtenYouTube.original_audio(video)
        return no_stream if stream == nil
        target = with_extension(target, "." + stream.container) if stream.container.to_s != ""
        return nil unless download_file(stream.url, target, override: true)
        target
      end
    when :audio
      source = if KlangtenYouTube.desktop?
        download_task(title) { |token, report| KlangtenYouTube.download(url, :audio, temp, token: token, &report) }
      else
        video = resolve(item, fresh: true)
        stream = video == nil ? nil : KlangtenYouTube.original_audio(video)
        no_stream if video != nil && stream == nil
        stream == nil ? nil : stream.url
      end
      return nil if source == nil
      encode(format.encoder, source, target, item)
    when :video
      ffmpeg = KlangtenYouTube.ffmpeg_location
      source = download_task(title) { |token, report| KlangtenYouTube.download(url, :video, temp, token: token, ffmpeg: ffmpeg, &report) }
      return nil if source == nil
      encode(format.encoder, source, target, item)
    end
  rescue StandardError => e
    Log.error("YouTube download failed: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The download failed."))
    nil
  ensure
    FileUtils.rm_rf(temp) if temp != nil
  end

  def download_task(title)
    EltenAPI::Tasks.run(title: title) do |progress, token|
      yield token, proc { |percent| progress.update(percent, total: 100) }
    end
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue KlangtenYouTube::Error => e
    Log.warning("YouTube download failed: #{e.message}")
    alert(p_("Klangten", "The download failed."))
    nil
  end

  # FFmpeg encoders take a cancellation token and run in a task; the core
  # encoders drive the interface themselves (Escape interrupts them).
  def encode(encoder, source, target, item)
    keywords = encoder.method(:encode_file).parameters.select { |type, _name| type == :key || type == :keyreq }.map(&:last)
    if keywords.include?(:cancellation_token)
      title = p_("Klangten", "Converting %{title}...") % { title: item.title }
      EltenAPI::Tasks.run(title: title) do |progress, token|
        options = { cancellation_token: token }
        options[:progress] = proc { |percent| progress.update(percent, total: 100) } if keywords.include?(:progress)
        encoder.encode_file(source, target, nil, **options)
      end
    else
      waiting
      begin
        encoder.encode_file(source, target)
      ensure
        waiting_end
      end
    end
    return target if File.file?(target) && File.size(target) > 0
    alert(p_("Klangten", "The conversion failed."))
    nil
  rescue EltenAPI::Tasks::Cancelled, Interrupt
    File.delete(target) if File.file?(target) rescue nil
    nil
  rescue StandardError => e
    Log.error("YouTube conversion failed: #{e.class}: #{e.message}")
    File.delete(target) if File.file?(target) rescue nil
    alert(p_("Klangten", "The conversion failed."))
    nil
  end

  def with_extension(path, extension)
    return path if extension.to_s == "" || File.extname(path).casecmp?(extension)
    old = File.extname(path)
    (old == "" ? path : path[0...-old.length]) + extension
  end

  def move_file(source, target)
    File.delete(target) if File.file?(target)
    FileUtils.mv(source, target)
    target
  end

  def no_stream
    alert(p_("Klangten", "This video has no audio stream that can be played."))
    nil
  end

  # ------------------------------------------------- favourites and history

  def show_saved(which)
    load = proc { which == :history ? KlangtenYouTube.history : KlangtenYouTube.favourites }
    items = load.call
    header = which == :history ? p_("Klangten", "History") : p_("Klangten", "Favourites")
    if items.empty?
      alert(which == :history ? p_("Klangten", "Your history is empty.") : p_("Klangten", "You have no favourites yet."))
      return
    end
    labels = proc { items.map { |item| item.video? ? item_label(item) : "#{item_label(item)}, #{kind_name(item)}" } }
    list = ListBox.new(labels.call, header: header, index: 0, quiet: false)
    refresh = proc do
      items = load.call
      index = list.index
      list.options = labels.call
      list.index = [[index, items.size - 1].min, 0].max
    end
    remove = proc do
      item = items[list.index]
      if item != nil
        if which == :history
          KlangtenYouTube.remove_from_history(item)
        else
          KlangtenYouTube.toggle_favourite(item) if KlangtenYouTube.favourite?(item)
        end
        play_sound("listbox_delete")
        refresh.call
        list.focus
      end
    end
    list.bind_context do |menu|
      item = items[list.index]
      if item != nil
        item_context(menu, item, refresh)
        menu.option(which == :history ? p_("Klangten", "Remove from history") : p_("Klangten", "Remove from favourites"), nil, :del) { remove.call }
      end
      if which == :history
        menu.option(p_("Klangten", "Clear history")) do
          if confirm(p_("Klangten", "Do you want to clear your YouTube history?"))
            KlangtenYouTube.clear_history
            refresh.call
          end
        end
      end
    end
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || left?
      item = items[list.index]
      next if item == nil
      if main_shortcut_pressed?("d", first: true)
        speak_summary(item)
      elsif key_pressed?(:key_enter)
        open_item(item, actions: raw_key_held?(:key_shift))
        break if left?
        refresh.call
        list.focus
      end
      break if items.empty?
    end
  end
end
