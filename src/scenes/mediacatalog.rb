# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klango media catalog: radio stations, podcasts and other media entries with
# categories, search, lists, favourites and ratings (Media menu).

class Scene_MediaCatalog
  def initialize
    @type = nil
    @types = nil
  end

  def main
    entries = home_entries
    @home = ListBox.new(entries.map { |entry| entry[0] }, header: p_("MediaCatalog", "Media catalog"), index: 0, flags: 0, quiet: false)
    @home.focus
    loop do
      loop_update
      @home.update
      if key_pressed?(:key_escape)
        $scene = Scene_Main.new
      elsif key_pressed?(:key_enter)
        action = entries[@home.index]
        action[1].call if action != nil
        break if $scene != self
        entries = home_entries
        index = @home.index
        @home.options = entries.map { |entry| entry[0] }
        @home.index = [index, entries.size - 1].min
        @home.focus
      end
      break if $scene != self
    end
  end

  private

  def home_entries
    entries = []
    entries << [p_("MediaCatalog", "Browse categories"), proc { browse_categories }]
    entries << [p_("MediaCatalog", "Search"), proc { search }]
    entries << [p_("MediaCatalog", "My favourites"), proc { show_favorites }] if Session.logged?
    entries << [p_("MediaCatalog", "Popular"), proc { show_list("popular", p_("MediaCatalog", "Popular")) }]
    entries << [p_("MediaCatalog", "Top rated"), proc { show_list("top_rated", p_("MediaCatalog", "Top rated")) }]
    entries << [p_("MediaCatalog", "Recently added"), proc { show_list("newest", p_("MediaCatalog", "Recently added")) }]
    entries << [p_("MediaCatalog", "Recently played"), proc { show_list("recently_played", p_("MediaCatalog", "Recently played")) }]
    entries << [p_("MediaCatalog", "Random selection"), proc { show_list("random", p_("MediaCatalog", "Random selection")) }]
    entries << [p_("MediaCatalog", "Media type: %{type}") % { type: type_name(@type) }, proc { choose_type }]
    entries << [p_("MediaCatalog", "Add my own stream or podcast"), proc { create_bookmark }] if Session.logged?
    entries
  end

  # ------------------------------------------------------------------ helpers

  def catalog_call
    yield
  rescue EltenLink::Error => e
    Log.warning("Media catalog request failed: #{e.class}: #{e.message}")
    message = e.message.to_s
    alert(message == "" ? _("Error") : message)
    nil
  end

  def static_type_names
    {
      "radio" => p_("MediaCatalog", "Radio station"),
      "podcast" => p_("MediaCatalog", "Podcast"),
      "audiobook" => p_("MediaCatalog", "Audiobook"),
      "youtube" => p_("MediaCatalog", "YouTube"),
      "rssfeed" => p_("MediaCatalog", "RSS feed"),
      "webpage" => p_("MediaCatalog", "Web page"),
      "mediafile" => p_("MediaCatalog", "Media file")
    }
  end

  def type_name(key)
    return p_("MediaCatalog", "All") if key == nil
    static_type_names[key.to_s] || key.to_s
  end

  def choose_type
    @types ||= catalog_call { EltenLink::Media.types(elten_link) } || []
    keys = [nil] + (@types.empty? ? static_type_names.keys : @types.map(&:key))
    labels = keys.map do |key|
      type = @types.find { |item| item.key == key }
      type == nil ? type_name(key) : "#{type_name(key)} (#{type.items})"
    end
    index = selector(labels, header: p_("MediaCatalog", "Media type"), start_index: keys.index(@type) || 0, cancel_index: -1)
    @type = keys[index] if index != nil && index >= 0
  end

  def item_label(item)
    parts = [item.title.to_s, type_name(item.type)]
    parts << item.language.to_s if item.language.to_s != ""
    if item.rating_count > 0
      parts << p_("MediaCatalog", "rating %{average} of 5 from %{count} votes") % { average: item.rating_average.round(1), count: item.rating_count }
    end
    parts << p_("MediaCatalog", "favourite") if item.favorite
    parts.join(", ")
  end

  def category_label(category)
    text = p_("MediaCatalog", "Category: %{name}") % { name: category.name }
    text += " (#{category.items})" if category.items > 0
    text += ", " + p_("MediaCatalog", "favourite") if category.favorite
    text
  end

  # -------------------------------------------------------------- list screen

  # Shows categories and items of a paged source. The loader receives an
  # offset and returns an EltenLink::MediaPage (or nil on error).
  def show_page(header, &loader)
    page = catalog_call { loader.call(0) }
    return if page == nil
    categories = page.categories.to_a
    items = page.items.to_a
    more = page.more
    if categories.empty? && items.empty?
      alert(p_("MediaCatalog", "No entries found."))
      return
    end
    rows = proc do
      labels = categories.map { |category| category_label(category) } + items.map { |item| item_label(item) }
      labels << p_("MediaCatalog", "Load more") if more
      labels
    end
    list = ListBox.new(rows.call, header: header, index: 0, flags: 0, quiet: false)
    refresh = proc do
      index = list.index
      list.options = rows.call
      list.index = [index, list.options.size - 1].min
    end
    list.bind_context do |menu|
      index = list.index
      if index < categories.size
        category_context(menu, categories[index], refresh)
      elsif index < categories.size + items.size
        item_context(menu, items[index - categories.size], refresh)
      end
    end
    list.focus
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || $scene != self
      next if !key_pressed?(:key_enter)
      index = list.index
      if index < categories.size
        show_category(categories[index])
      elsif index < categories.size + items.size
        item_action(items[index - categories.size])
        refresh.call
      elsif more
        next_page = catalog_call { loader.call(categories.size + items.size) }
        if next_page != nil
          items.concat(next_page.items.to_a)
          more = next_page.more
          refresh.call
        end
      end
      break if $scene != self
      list.focus
    end
  end

  def browse_categories
    page = catalog_call { EltenLink::Media.categories(elten_link, parent: 0, type: @type) }
    return if page == nil
    if page.categories.empty?
      alert(p_("MediaCatalog", "No entries found."))
      return
    end
    show_page(p_("MediaCatalog", "Categories")) { |_offset| page }
  end

  def show_category(category)
    show_page(category.name) do |offset|
      EltenLink::Media.category(elten_link, category.id, type: @type, offset: offset)
    end
  end

  def show_list(name, header)
    show_page(header) do |offset|
      EltenLink::Media.list(elten_link, name, type: @type, offset: offset)
    end
  end

  def search
    query = input_text(p_("MediaCatalog", "Search the media catalog"), escapable: true)
    return if query == nil || query.strip == ""
    show_page(p_("MediaCatalog", "Search results")) do |offset|
      EltenLink::Media.search(elten_link, query.strip, type: @type, offset: offset)
    end
  end

  def show_favorites
    result = catalog_call { EltenLink::Media.favorites(elten_link) }
    return if result == nil
    page = EltenLink::MediaPage.new
    page.categories, page.items = result
    page.more = false
    if page.categories.empty? && page.items.empty?
      alert(p_("MediaCatalog", "You have no favourites yet."))
      return
    end
    show_page(p_("MediaCatalog", "My favourites")) { |_offset| page }
  end

  # ------------------------------------------------------------ item actions

  def item_actions(item)
    actions = {}
    actions[:play] = p_("MediaCatalog", "Play") if item.stream?
    actions[:episodes] = p_("MediaCatalog", "Episodes") if item.feed?
    actions[:youtube] = p_("MediaCatalog", "Open in YouTube") if item.type == "youtube" && item.url.to_s != ""
    actions[:open] = p_("MediaCatalog", "Open in the web browser") if item.type == "webpage" && item.url.to_s != ""
    if Session.logged?
      actions[:favorite] = item.favorite ? p_("MediaCatalog", "Remove from favourites") : p_("MediaCatalog", "Add to favourites")
      actions[:rate] = p_("MediaCatalog", "Rate")
    end
    actions[:ratings] = p_("MediaCatalog", "Show ratings")
    actions[:details] = p_("MediaCatalog", "Details")
    actions[:homepage] = p_("MediaCatalog", "Open homepage") if item.homepage.to_s != ""
    actions[:copy] = p_("MediaCatalog", "Copy address to the clipboard") if item.url.to_s != ""
    actions
  end

  def item_action(item)
    actions = item_actions(item)
    actions[:cancel] = _("Cancel")
    action = select_action(actions, header: item.title, cancel: :cancel, flags: 1)
    run_item_action(item, action)
  end

  def item_context(menu, item, refresh)
    item_actions(item).each do |key, label|
      menu.option(label) do
        run_item_action(item, key)
        refresh.call
      end
    end
  end

  def run_item_action(item, action)
    case action
    when :play then play_item(item)
    when :episodes then show_episodes(item)
    when :youtube then open_youtube(item)
    when :open then platform_open_url(item.url)
    when :favorite then toggle_favorite(item)
    when :rate then rate_item(item)
    when :ratings then show_ratings(item)
    when :details then show_details(item)
    when :homepage then platform_open_url(item.homepage)
    when :copy
      Clipboard.set_data(item.url)
      alert(p_("MediaCatalog", "Copied to clipboard."))
    end
  end

  def category_context(menu, category, refresh)
    menu.option(p_("MediaCatalog", "Open")) { show_category(category) }
    return if !Session.logged?
    label = category.favorite ? p_("MediaCatalog", "Remove from favourites") : p_("MediaCatalog", "Add to favourites")
    menu.option(label) do
      done = catalog_call do
        if category.favorite
          EltenLink::Media.remove_favorite_category(elten_link, category.id)
        else
          EltenLink::Media.add_favorite_category(elten_link, category.id)
        end
      end
      if done
        category.favorite = !category.favorite
        alert(category.favorite ? p_("MediaCatalog", "Added to favourites.") : p_("MediaCatalog", "Removed from favourites."))
        refresh.call
      end
    end
  end

  def play_item(item)
    url = item.stream_url.to_s
    return alert(_("Error")) if url == ""
    if Session.logged?
      begin
        EltenLink::Media.register_play(elten_link, item.id)
      rescue EltenLink::Error => e
        Log.warning("Media catalog play counter failed: #{e.message}")
      end
    end
    player(url, label: item.title)
  end

  def open_youtube(item)
    program = defined?(Programs::BuiltIns) ? Programs::BuiltIns.program_class(:youtube) : nil
    if program == nil || !program.respond_to?(:yplayer)
      alert(p_("Klangten", "This feature is not available on this system."))
      return
    end
    program.yplayer(item.url)
  end

  def toggle_favorite(item)
    done = catalog_call do
      item.favorite ? EltenLink::Media.remove_favorite(elten_link, item.id) : EltenLink::Media.add_favorite(elten_link, item.id)
    end
    return if !done
    item.favorite = !item.favorite
    alert(item.favorite ? p_("MediaCatalog", "Added to favourites.") : p_("MediaCatalog", "Removed from favourites."))
  end

  def rate_item(item)
    labels = (1..5).map { |vote| p_("MediaCatalog", "%{vote} of 5") % { vote: vote } }
    labels << p_("MediaCatalog", "Remove my rating") if item.rating_mine > 0
    start = item.rating_mine > 0 ? item.rating_mine - 1 : 2
    index = selector(labels, header: p_("MediaCatalog", "Your rating"), start_index: start, cancel_index: -1)
    return if index == nil || index < 0
    if index == 5
      summary = catalog_call { EltenLink::Media.unrate(elten_link, item.id) }
      return if summary == nil
      alert(p_("MediaCatalog", "Your rating has been removed."))
    else
      text = input_text(p_("MediaCatalog", "Comment (optional)"), flags: EditBox::Flags::MultiLine, escapable: true)
      return if text == nil
      summary = catalog_call { EltenLink::Media.rate(elten_link, item.id, index + 1, text) }
      return if summary == nil
      alert(p_("MediaCatalog", "Thank you for your rating."))
    end
    item.rating_mine = summary["mine"].to_i
    item.rating_average = summary["average"].to_f
    item.rating_count = summary["count"].to_i
  end

  def show_ratings(item)
    result = catalog_call { EltenLink::Media.ratings(elten_link, item.id) }
    return if result == nil
    summary, ratings = result
    lines = [p_("MediaCatalog", "Average rating: %{average} of 5 from %{count} votes") % { average: summary["average"].to_f.round(1), count: summary["count"].to_i }, ""]
    ratings.each do |rating|
      line = "#{rating.user}: #{p_("MediaCatalog", "%{vote} of 5") % { vote: rating.vote }}"
      line += " (#{format_date(Time.at(rating.time), false, false)})" if rating.time > 0
      lines << line
      lines << rating.text if rating.text.to_s != ""
      lines << ""
    end
    display_text(lines.join("\n"), header: p_("MediaCatalog", "Ratings"))
  end

  def show_details(item)
    full = catalog_call { EltenLink::Media.item(elten_link, item.id) } || item
    lines = [full.title.to_s]
    lines << "#{p_("MediaCatalog", "Media type")}: #{type_name(full.type)}"
    lines << "#{p_("MediaCatalog", "Language")}: #{full.language}" if full.language.to_s != ""
    lines << "#{p_("MediaCatalog", "Categories")}: #{full.tags.join(", ")}" if full.tags.to_a.size > 0
    lines << "#{p_("MediaCatalog", "Bitrate")}: #{full.bitrate} kbps" if full.bitrate.to_s != ""
    lines << "#{p_("MediaCatalog", "Played")}: #{full.plays}"
    lines << "#{p_("MediaCatalog", "Added by")}: #{full.added_by}" if full.added_by.to_s != ""
    lines << "#{p_("MediaCatalog", "Homepage")}: #{full.homepage}" if full.homepage.to_s != ""
    lines << "#{p_("MediaCatalog", "Address")}: #{full.url}" if full.url.to_s != ""
    lines << "#{p_("MediaCatalog", "Keywords")}: #{full.keywords}" if full.keywords.to_s != ""
    lines << "" << full.description.to_s if full.description.to_s != ""
    display_text(lines.join("\n"), header: p_("MediaCatalog", "Details"))
  end

  # ----------------------------------------------------------------- podcasts

  def show_episodes(item)
    episodes = begin
      Tasks.run(title: p_("MediaCatalog", "Loading episodes...")) do |progress|
        EltenLink::Media.episodes(item.feed_url, cancellation_token: progress.respond_to?(:token) ? progress.token : nil)
      end
    rescue EltenAPI::Tasks::Cancelled
      return
    rescue StandardError => e
      Log.warning("Podcast feed failed: #{e.class}: #{e.message}")
      alert(p_("MediaCatalog", "The episodes of this podcast cannot be loaded."))
      return
    end
    if episodes.to_a.empty?
      alert(p_("MediaCatalog", "No episodes found."))
      return
    end
    labels = episodes.map do |episode|
      parts = [episode.title.to_s]
      parts << format_date(episode.published, false, false) if episode.published != nil
      parts << episode.duration if episode.duration.to_s != ""
      parts.join(", ")
    end
    list = ListBox.new(labels, header: item.title, index: 0, flags: 0, quiet: false)
    list.bind_context do |menu|
      episode = episodes[list.index]
      menu.option(p_("MediaCatalog", "Play")) { play_episode(item, episode) }
      menu.option(p_("MediaCatalog", "Download")) { download_episode(episode) }
      menu.option(p_("MediaCatalog", "Details")) { show_episode_details(episode) }
      menu.option(p_("MediaCatalog", "Copy address to the clipboard")) do
        Clipboard.set_data(episode.url)
        alert(p_("MediaCatalog", "Copied to clipboard."))
      end
    end
    list.focus
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || $scene != self
      next if !key_pressed?(:key_enter)
      episode = episodes[list.index]
      action = select_action(
        { play: p_("MediaCatalog", "Play"), download: p_("MediaCatalog", "Download"), details: p_("MediaCatalog", "Details"), cancel: _("Cancel") },
        header: episode.title, cancel: :cancel, flags: 1
      )
      case action
      when :play then play_episode(item, episode)
      when :download then download_episode(episode)
      when :details then show_episode_details(episode)
      end
      list.focus
    end
  end

  def play_episode(item, episode)
    if Session.logged?
      begin
        EltenLink::Media.register_play(elten_link, item.id)
      rescue EltenLink::Error => e
        Log.warning("Media catalog play counter failed: #{e.message}")
      end
    end
    player(episode.url, label: episode.title)
  end

  def download_episode(episode)
    directory = get_file(p_("MediaCatalog", "Select destination directory"), path: EltenPath.with_separator(Dirs.documents), save: true)
    return if directory == nil
    name = File.basename(episode.url.to_s.sub(/[?#].*\z/, ""))
    extension = File.extname(name)
    extension = ".mp3" if extension == "" || extension.size > 6
    title = episode.title.to_s.delete("\r\n\\/:*?\"<>|").strip
    title = File.basename(name, File.extname(name)) if title == ""
    title = title[0, 120]
    destination = EltenPath.join(directory, title + extension)
    if File.exist?(destination) && !confirm(p_("MediaCatalog", "The file %{file} already exists. Do you want to replace it?") % { file: File.basename(destination) })
      return
    end
    if download_file(episode.url, destination, override: true)
      alert(p_("MediaCatalog", "The episode has been saved."))
    else
      alert(_("Error"))
    end
  end

  def show_episode_details(episode)
    lines = [episode.title.to_s]
    lines << format_date(episode.published, false, false) if episode.published != nil
    lines << "#{p_("MediaCatalog", "Duration")}: #{episode.duration}" if episode.duration.to_s != ""
    lines << "#{p_("MediaCatalog", "Address")}: #{episode.url}"
    lines << "" << episode.description.to_s if episode.description.to_s != ""
    display_text(lines.join("\n"), header: p_("MediaCatalog", "Details"))
  end

  # ---------------------------------------------------------------- bookmarks

  def create_bookmark
    kinds = ["radio", "podcast", "mediafile"]
    form = Form.new([
      title = EditBox.new(p_("MediaCatalog", "Title"), text: ""),
      url = EditBox.new(p_("MediaCatalog", "Stream or feed address"), text: ""),
      kind = ListBox.new(kinds.map { |key| type_name(key) }, header: p_("MediaCatalog", "Media type")),
      homepage = EditBox.new(p_("MediaCatalog", "Homepage (optional)"), text: ""),
      create = Button.new(p_("MediaCatalog", "Add to favourites")),
      cancel = Button.new(_("Cancel"))
    ])
    form.cancel_button = cancel
    cancel.on(:press) { form.resume }
    create.on(:press) do
      if title.text.to_s.strip == "" || url.text.to_s.strip == ""
        alert(p_("MediaCatalog", "Enter a title and an address."))
        next
      end
      item = catalog_call do
        EltenLink::Media.create_bookmark(elten_link, title: title.text.strip, url: url.text.strip, type: kinds[kind.index], homepage: homepage.text.to_s.strip)
      end
      if item != nil
        alert(p_("MediaCatalog", "Added to favourites."))
        form.resume
      end
    end
    form.wait
  end
end
