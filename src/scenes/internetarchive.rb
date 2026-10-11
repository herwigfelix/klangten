# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Internet Archive (Media menu): search archive.org or open an address, then
# an entry shows its description and its files.
#
# Enter on a file offers to continue where you left it (when there is a
# bookmark), to play it, to play it in the background and to download it. The
# player keeps a bookmark of where you stopped; a file heard to its end loses
# it. The context menu has the same actions.

class Scene_InternetArchive
  def self.open_identifier(identifier)
    new.open_identifier(identifier)
  end

  # An archive.org address from elsewhere (the media catalog); false when it
  # is not one.
  def self.open_url(url)
    identifier = KlangtenArchive.identifier(url)
    return false if identifier == nil
    open_identifier(identifier)
    true
  end

  def initialize
    @owner = nil
  end

  def main
    @owner = self
    start_screen
    $scene = Scene_Main.new if $scene == self
  end

  def open_identifier(identifier)
    @owner = $scene
    show_entry(identifier)
  end

  private

  def left?
    $scene != @owner
  end

  # ------------------------------------------------------------ start

  def start_screen
    entries = [
      [p_("Klangten", "Search the Internet Archive"), proc { search }],
      [p_("Klangten", "Open an address or identifier"), proc { open_address }]
    ]
    list = ListBox.new(entries.map(&:first), header: p_("Klangten", "Internet Archive"), index: 0, quiet: false)
    while list.wait_for_item(actions: [:select, :escape]) != nil
      entries[list.index][1].call
      break if left?
    end
  end

  def search
    query = input_text(p_("Klangten", "Search the Internet Archive"), escapable: true)
    return if query == nil || query.strip == ""
    page = request { KlangtenArchive.search(query.strip) }
    return if page == nil
    if page.results.empty?
      alert(p_("Klangten", "Nothing was found."))
      return
    end
    results = page.results.dup
    labels = proc do
      rows = results.map { |result| [result.title, result.creator].reject { |part| part.to_s == "" }.join(", ") }
      rows << p_("MediaCatalog", "Load more") if page.more?
      rows
    end
    list = ListBox.new(labels.call, header: p_("Klangten", "Search results"), index: 0, quiet: false)
    list.bind_context do |menu|
      result = results[list.index]
      next if result == nil
      menu.option(p_("Klangten", "Open")) { show_entry(result.identifier) }
      menu.option(p_("Klangten", "Copy link")) { copy(KlangtenArchive.details_url(result.identifier)) }
    end
    while list.wait_for_item(actions: [:select, :escape]) != nil
      if list.index < results.size
        show_entry(results[list.index].identifier)
        return if left?
      elsif page.more?
        following = request { KlangtenArchive.search(query.strip, page: page.page + 1) }
        if following != nil
          index = results.size
          results.concat(following.results)
          page = following
          list.options = labels.call
          list.index = [index, list.options.size - 1].min
        end
      end
    end
  end

  def open_address
    text = input_text(p_("Klangten", "Address or identifier of the entry"), escapable: true)
    return if text == nil || text.strip == ""
    identifier = KlangtenArchive.identifier(text, bare: true)
    return alert(p_("Klangten", "This is not an Internet Archive address.")) if identifier == nil
    show_entry(identifier)
  end

  # ------------------------------------------------------------ entry

  def show_entry(identifier)
    entry = request { KlangtenArchive.entry(identifier) }
    return if entry == nil
    rows = proc do
      labels = []
      labels << p_("Klangten", "Description") if entry.description.to_s != ""
      labels + entry.files.map { |file| file_label(file) }
    end
    offset = entry.description.to_s != "" ? 1 : 0
    if entry.files.empty? && offset == 0
      alert(p_("Klangten", "This entry has no files."))
      return
    end
    list = ListBox.new(rows.call, header: entry.title, index: 0, quiet: false)
    list.bind_context do |menu|
      file = list.index >= offset ? entry.files[list.index - offset] : nil
      file_actions(file).each { |key, label| menu.option(label) { run(entry, file, key); refresh(list, rows) } } if file != nil
      menu.option(p_("Klangten", "Description")) { show_description(entry) }
      menu.option(p_("Klangten", "Copy link")) { copy(KlangtenArchive.details_url(entry.identifier)) }
      menu.option(p_("MediaCatalog", "Open in the web browser")) { platform_open_url(KlangtenArchive.details_url(entry.identifier)) }
    end
    while list.wait_for_item(actions: [:select, :escape]) != nil
      if list.index < offset
        show_description(entry)
      else
        file = entry.files[list.index - offset]
        actions = file_actions(file)
        actions[:cancel] = _("Cancel")
        action = select_action(actions, header: file.label, cancel: :cancel, flags: 1)
        run(entry, file, action)
      end
      return if left?
      refresh(list, rows)
    end
  end

  def refresh(list, rows)
    index = list.index
    list.options = rows.call
    list.index = [index, list.options.size - 1].min
  end

  def file_label(file)
    parts = [file.label]
    parts << file.format if file.format.to_s != ""
    parts << KlangtenPlaylist.format_duration(file.length) if file.length.to_f > 0
    parts << size_text(file.size) if file.size.to_i > 0 && !file.playable?
    position = file.playable? ? KlangtenBookmarks.position(file.url) : nil
    parts << p_("Klangten", "bookmark at %{position}") % { position: KlangtenPlaylist.format_duration(position) } if position != nil
    parts.join(", ")
  end

  def file_actions(file)
    actions = {}
    if file.playable?
      position = KlangtenBookmarks.position(file.url)
      actions[:resume] = p_("Klangten", "Continue from %{position}") % { position: KlangtenPlaylist.format_duration(position) } if position != nil
      actions[:play] = p_("MediaCatalog", "Play")
      actions[:background] = p_("Klangten", "Play in the background")
    end
    actions[:download] = p_("MediaCatalog", "Download")
    actions[:copy] = p_("MediaCatalog", "Copy address to the clipboard")
    actions
  end

  def run(entry, file, action)
    case action
    when :resume then play(entry, file, KlangtenBookmarks.position(file.url))
    when :play
      KlangtenBookmarks.forget(file.url)
      play(entry, file, nil)
    when :background then play_in_background(entry, file)
    when :download then download(entry, file)
    when :copy then copy(file.url)
    end
  end

  def title_of(entry, file)
    file.label == entry.title ? entry.title : "#{entry.title}: #{file.label}"
  end

  def play(entry, file, position)
    player(file.url, label: file.label, bookmark: file.url, position: position,
      background: { title: title_of(entry, file), kind: :archive, details: entry_details(entry) })
  end

  def play_in_background(entry, file)
    item = KlangtenBackgroundPlayer::Item.new(title: title_of(entry, file), location: file.url, kind: :archive, bookmark: true, details: entry_details(entry))
    KlangtenBackgroundPlayer.play(item, position: KlangtenBookmarks.position(file.url))
    alert(p_("Klangten", "Playing in the background"))
  end

  def entry_details(entry)
    lines = []
    lines << "#{p_("Klangten", "Author")}: #{entry.creator}" if entry.creator.to_s != ""
    lines << "#{p_("Klangten", "Date")}: #{entry.date}" if entry.date.to_s != ""
    lines << KlangtenArchive.details_url(entry.identifier)
    lines << "" << entry.description.to_s if entry.description.to_s != ""
    lines.join("\n")
  end

  def show_description(entry)
    display_text([entry.title, entry_details(entry)].join("\n"), header: p_("Klangten", "Description"))
  end

  def download(entry, file)
    folder = get_folder(p_("Klangten", "Download to"), path: download_folder)
    return if folder == nil
    name = KlangtenRecordings.safe_name(File.basename(file.name), "file")
    target = File.join(folder, KlangtenRecordings.safe_name(entry.title, entry.identifier), name)
    FileUtils.mkdir_p(File.dirname(target))
    if File.exist?(target) && !confirm(p_("MediaCatalog", "The file %{file} already exists. Do you want to replace it?") % { file: name })
      return
    end
    if download_file(file.url, target, override: true)
      alert(p_("Klangten", "Downloaded to %{folder}") % { folder: File.dirname(target) })
    else
      alert(p_("Klangten", "The download failed."))
    end
  end

  def download_folder
    downloads = File.join(Dirs.user, "Downloads")
    base = File.directory?(downloads) ? downloads : Dirs.music
    File.join(base, "Internet Archive")
  rescue StandardError
    Dirs.documents
  end

  # ------------------------------------------------------------ helpers

  def request
    yield
  rescue KlangtenArchive::Error => e
    Log.warning("Internet Archive: #{e.message}")
    alert(p_("Klangten", "The Internet Archive did not answer or does not know this entry."))
    nil
  rescue StandardError => e
    Log.warning("Internet Archive request failed: #{e.class}: #{e.message}")
    alert(p_("Klangten", "The Internet Archive did not answer or does not know this entry."))
    nil
  end

  def copy(text)
    Clipboard.set_data(text)
    alert(p_("MediaCatalog", "Copied to clipboard."))
  end

  def size_text(bytes)
    return Scene_FileManager.format_size(bytes) if defined?(Scene_FileManager) && Scene_FileManager.respond_to?(:format_size)
    "#{(bytes / 1_048_576.0).round(1)} MB"
  end
end
