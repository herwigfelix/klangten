# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klango media catalog: radio stations, podcasts and other media entries with
# categories, search, lists, favourites and ratings (Media menu). Since 0.4
# also the play history kept on this device, favourites of friends, public
# and group favourites, sharing the own favourites, entering an address and
# notes to the catalog's editors (editors and administrators maintain entries).

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
    entries << [p_("MediaCatalog", "Favourites of friends"), proc { show_owners(:shared) }] if Session.logged?
    entries << [p_("MediaCatalog", "Public favourites"), proc { show_owners(:public) }]
    entries << [p_("MediaCatalog", "Group favourites"), proc { show_groups }] if Session.logged?
    entries << [p_("MediaCatalog", "My history"), proc { show_history }]
    entries << [p_("MediaCatalog", "Popular"), proc { show_list("popular", p_("MediaCatalog", "Popular")) }]
    entries << [p_("MediaCatalog", "Top rated"), proc { show_list("top_rated", p_("MediaCatalog", "Top rated")) }]
    entries << [p_("MediaCatalog", "Recently rated"), proc { show_list("recently_rated", p_("MediaCatalog", "Recently rated")) }]
    entries << [p_("MediaCatalog", "Recently added"), proc { show_list("newest", p_("MediaCatalog", "Recently added")) }]
    entries << [p_("MediaCatalog", "Recently played"), proc { show_list("recently_played", p_("MediaCatalog", "Recently played")) }]
    entries << [p_("MediaCatalog", "Random selection"), proc { show_list("random", p_("MediaCatalog", "Random selection")) }]
    entries << [p_("MediaCatalog", "Enter an address"), proc { enter_address }]
    entries << [p_("MediaCatalog", "Media type: %{type}") % { type: type_name(@type) }, proc { choose_type }]
    entries << [p_("MediaCatalog", "Add my own stream or podcast"), proc { create_bookmark }] if Session.logged?
    entries << [p_("MediaCatalog", "Share my favourites"), proc { manage_sharing }] if Session.logged?
    entries
  end

  # ------------------------------------------------------------------ helpers

  def catalog_call
    yield
  rescue EltenLink::Error => e
    Log.warning("Media catalog request failed: #{e.class}: #{e.message}")
    # A guest reads the catalogue; anything that changes it needs an account and
    # is announced as such instead of the server's error text.
    message = e.message.to_s
    if Session.login_required_error?(e)
      alert(Session.login_required_message)
    else
      alert(message == "" ? _("Error") : message)
    end
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
  # offset and returns an EltenLink::MediaPage (or nil on error). extra, if
  # given, adds options to the context menu of an item: it is called with the
  # menu, the item and a proc that takes the item out of the list.
  def show_page(header, extra: nil, empty_message: nil, &loader)
    page = catalog_call { loader.call(0) }
    return if page == nil
    categories = page.categories.to_a
    items = page.items.to_a
    more = page.more
    if categories.empty? && items.empty?
      alert(empty_message || p_("MediaCatalog", "No entries found."))
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
    remove = proc do |item|
      items.delete(item)
      refresh.call
      list.focus if !list.options.empty?
    end
    list.bind_context do |menu|
      index = list.index
      if index < categories.size
        category_context(menu, categories[index], refresh)
      elsif index < categories.size + items.size
        item = items[index - categories.size]
        item_context(menu, item, refresh)
        extra.call(menu, item, remove) if extra != nil
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
    actions[:youtube] = p_("MediaCatalog", "Open in YouTube") if item.type == "youtube" && item.url.to_s != "" && youtube_available?
    actions[:open] = p_("MediaCatalog", "Open in the web browser") if item.type == "webpage" && item.url.to_s != ""
    # Entries without a catalog number (history of typed addresses) have no
    # favourites, ratings or details on the server.
    catalogued = item.id.to_i > 0
    if Session.logged? && catalogued
      actions[:favorite] = item.favorite ? p_("MediaCatalog", "Remove from favourites") : p_("MediaCatalog", "Add to favourites")
      actions[:group_favorite] = p_("MediaCatalog", "Add to group favourites") if editable_groups.size > 0
      actions[:rate] = p_("MediaCatalog", "Rate")
    end
    actions[:ratings] = p_("MediaCatalog", "Show ratings") if catalogued
    actions[:details] = p_("MediaCatalog", "Details") if catalogued
    actions[:homepage] = p_("MediaCatalog", "Open homepage") if item.homepage.to_s != ""
    actions[:copy] = p_("MediaCatalog", "Copy address to the clipboard") if item.url.to_s != ""
    if Session.logged? && catalogued
      actions[:report] = p_("MediaCatalog", "Send a correction or note to the editors")
      actions[:edit] = p_("MediaCatalog", "Edit entry") if permissions["editor"]
      if permissions["admin"]
        actions[:hide] = item.hidden ? p_("MediaCatalog", "Show this entry in the catalog again") : p_("MediaCatalog", "Hide this entry in the catalog")
      end
    end
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
    Klangten::MediaHistory.add(item) if [:play, :episodes, :youtube, :open].include?(action)
    case action
    when :play then play_item(item)
    when :episodes then show_episodes(item)
    when :youtube then open_youtube(item)
    when :open then platform_open_url(item.url)
    when :favorite then toggle_favorite(item)
    when :group_favorite then add_group_favorite(item)
    when :report then report_item(item)
    when :edit then edit_item(item)
    when :hide then toggle_hidden(item)
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

  # Klangten: YouTube does not run everywhere (Scene_YouTube.available? is false
  # on iOS, where neither yt-dlp nor a JavaScript runtime can be executed). There
  # the action is left out of the item menu entirely instead of offering an entry
  # that only announces its own absence.
  def youtube_available?
    defined?(Scene_YouTube) != nil && Scene_YouTube.respond_to?(:available?) && Scene_YouTube.available? == true
  rescue Exception
    false
  end

  def open_youtube(item)
    if !youtube_available? || !Scene_YouTube.respond_to?(:open_url)
      alert(p_("Klangten", "This feature is not available on this system."))
      return
    end
    Scene_YouTube.open_url(item.url)
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

  # ------------------------------------------------- Klangten 0.4 additions

  # What the catalog's editorial team may do ({"editor", "admin"}), asked once.
  def permissions
    return @permissions if @permissions != nil
    @permissions = { "editor" => false, "admin" => false }
    return @permissions if !Session.logged?
    begin
      @permissions = EltenLink::Media.permissions(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Media catalog permissions failed: #{e.message}")
    end
    @permissions
  end

  # Klango groups of the account with their favourites, asked once.
  def media_groups
    return @media_groups if @media_groups != nil
    @media_groups = []
    return @media_groups if !Session.logged?
    begin
      @media_groups = EltenLink::Media.groups(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Media catalog groups failed: #{e.message}")
    end
    @media_groups
  end

  def editable_groups
    media_groups.select(&:can_edit)
  end

  # A list of names with a context menu; returns when Escape is pressed.
  # rows: proc returning [label, object] pairs; open: proc called on Enter;
  # context: proc(menu, object, reload) for the context menu.
  def show_simple_list(header, rows, open:, context: nil)
    entries = rows.call
    list = ListBox.new(entries.map(&:first), header: header, index: 0, flags: 0, quiet: false)
    reload = proc do
      entries = rows.call
      index = list.index
      list.options = entries.map(&:first)
      list.index = [[index, entries.size - 1].min, 0].max
    end
    list.bind_context { |menu| context.call(menu, entries[list.index][1], reload) if context != nil && entries[list.index] != nil }
    list.focus
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || $scene != self || entries.empty?
      next if !key_pressed?(:key_enter) || entries[list.index] == nil
      open.call(entries[list.index][1])
      break if $scene != self
      list.focus
    end
  end

  # ------------------------------------------- favourites of other people

  def show_owners(kind)
    owners = catalog_call do
      kind == :shared ? EltenLink::Media.shared_owners(elten_link) : EltenLink::Media.public_owners(elten_link)
    end
    return if owners == nil
    if owners.empty?
      alert(kind == :shared ? p_("MediaCatalog", "Nobody has shared their favourites with you yet.") : p_("MediaCatalog", "Nobody has published their favourites yet."))
      return
    end
    header = kind == :shared ? p_("MediaCatalog", "Favourites of friends") : p_("MediaCatalog", "Public favourites")
    rows = proc do
      owners.map { |owner| [np_("MediaCatalog", "%{user}, %{count} favourite", "%{user}, %{count} favourites", owner.favorites) % { user: owner.user, count: owner.favorites }, owner] }
    end
    context = proc do |menu, owner, reload|
      menu.option(p_("MediaCatalog", "Open")) { show_owner_favorites(owner) }
      menu.useroption(owner.user) if Session.logged?
      if kind == :shared
        menu.option(p_("MediaCatalog", "Remove from my list"), nil, :del) do
          if confirm(p_("MediaCatalog", "Do you want to remove the favourites of %{user} from your list?") % { user: owner.user })
            if catalog_call { EltenLink::Media.leave_shared(elten_link, owner.user) }
              owners.delete(owner)
              alert(p_("MediaCatalog", "Removed from your list."))
              reload.call
            end
          end
        end
      end
    end
    show_simple_list(header, rows, open: proc { |owner| show_owner_favorites(owner) }, context: context)
  end

  def show_owner_favorites(owner)
    result = catalog_call { EltenLink::Media.user_favorites(elten_link, owner.user) }
    return if result == nil
    page = EltenLink::MediaPage.new
    page.categories, page.items = result
    page.more = false
    show_page(p_("MediaCatalog", "Favourites of %{user}") % { user: owner.user }, empty_message: p_("MediaCatalog", "This list of favourites is empty.")) { |_offset| page }
  end

  # ------------------------------------------------------ group favourites

  def show_groups
    groups = catalog_call { EltenLink::Media.groups(elten_link) }
    return if groups == nil
    @media_groups = groups
    if groups.empty?
      alert(p_("MediaCatalog", "You are not a member of any Klango group."))
      return
    end
    rows = proc do
      groups.map { |group| [np_("MediaCatalog", "%{group}, %{count} entry", "%{group}, %{count} entries", group.items) % { group: group.name, count: group.items }, group] }
    end
    show_simple_list(p_("MediaCatalog", "Group favourites"), rows, open: proc { |group| show_group_favorites(group) })
  end

  def show_group_favorites(group)
    result = catalog_call { EltenLink::Media.group_favorites(elten_link, group.id) }
    return if result == nil
    info, items = result
    page = EltenLink::MediaPage.new
    page.categories = []
    page.items = items
    page.more = false
    extra = nil
    if info.can_edit
      extra = proc do |menu, item, remove|
        menu.option(p_("MediaCatalog", "Remove from group favourites"), nil, :del) do
          if confirm(p_("MediaCatalog", "Do you want to remove %{title} from the favourites of the group?") % { title: item.title })
            if catalog_call { EltenLink::Media.remove_group_favorite(elten_link, group.id, item.id) }
              alert(p_("MediaCatalog", "Removed from the group favourites."))
              group.items = [group.items - 1, 0].max
              remove.call(item)
            end
          end
        end
      end
    end
    show_page(group.name, extra: extra, empty_message: p_("MediaCatalog", "This group has no favourites yet.")) { |_offset| page }
  end

  def add_group_favorite(item)
    groups = editable_groups
    return alert(p_("MediaCatalog", "You do not moderate any Klango group.")) if groups.empty?
    index = 0
    if groups.size > 1
      index = selector(groups.map(&:name), header: p_("MediaCatalog", "Add to the favourites of which group?"), start_index: 0, cancel_index: -1)
      return if index == nil || index < 0
    end
    group = groups[index]
    added = catalog_call { EltenLink::Media.add_group_favorite(elten_link, group.id, item.id) }
    return if added == nil
    if added
      group.items += 1
      alert(p_("MediaCatalog", "Added to the favourites of %{group}.") % { group: group.name })
    else
      alert(p_("MediaCatalog", "This entry is already among the favourites of %{group}.") % { group: group.name })
    end
  end

  # ------------------------------------------------------------- history

  def show_history
    entries = Klangten::MediaHistory.entries
    if entries.empty?
      alert(p_("MediaCatalog", "Your history is empty."))
      return
    end
    by_item = {}
    items = entries.map do |entry|
      item = EltenLink::Media.stub_item(id: entry.id, title: entry.title, type: entry.type, url: entry.url)
      by_item[item.object_id] = entry
      item
    end
    page = EltenLink::MediaPage.new
    page.categories = []
    page.items = items
    page.more = false
    extra = proc do |menu, item, remove|
      menu.option(p_("MediaCatalog", "Remove from history"), nil, :del) do
        entry = by_item[item.object_id]
        Klangten::MediaHistory.remove(entry) if entry != nil
        remove.call(item)
      end
      menu.option(p_("MediaCatalog", "Clear history")) do
        if confirm(p_("MediaCatalog", "Do you want to clear your history?"))
          Klangten::MediaHistory.clear
          items.dup.each { |old| remove.call(old) }
          alert(p_("MediaCatalog", "The history has been cleared."))
        end
      end
    end
    show_page(p_("MediaCatalog", "My history"), extra: extra) { |_offset| page }
  end

  # ------------------------------------------------------ entering an address

  def enter_address
    address = input_text(p_("MediaCatalog", "Address of a stream, feed or web page, or the number of a catalog entry"), escapable: true)
    return if address == nil || address.strip == ""
    address = address.strip
    item = nil
    begin
      item = EltenLink::Media.lookup(elten_link, address)
    rescue EltenLink::Error => e
      Log.warning("Media catalog lookup failed: #{e.message}")
    end
    return item_action(item) if item != nil
    if address =~ /\A\d+\z/
      alert(p_("MediaCatalog", "There is no entry with this number in the catalog."))
      return
    end
    address = "http://" + address if address !~ %r{\A[a-z][a-z0-9+.-]*://}i
    item = EltenLink::Media.stub_item(title: address, url: address)
    Klangten::MediaHistory.add(item)
    player(address, label: address)
  end

  # ---------------------------------------------- sharing my favourites

  def manage_sharing
    result = catalog_call { EltenLink::Media.favorite_shares(elten_link) }
    return if result == nil
    users, published = result
    users_list = ListBox.new(users.dup, header: p_("MediaCatalog", "People who can see your favourites"), empty_label: p_("MediaCatalog", "Nobody yet"))
    public_box = CheckBox.new(p_("MediaCatalog", "Publish my favourites for everyone"), checked: published)
    add_button = Button.new(p_("MediaCatalog", "Share with a user"))
    close = Button.new(_("Close"))
    form = Form.new([users_list, public_box, add_button, close])
    add_share = proc do
      user = input_user(p_("MediaCatalog", "Who should see your favourites?"))
      if user != nil && user.to_s != ""
        added = catalog_call { EltenLink::Media.share_favorites(elten_link, user) }
        if added != nil
          users << user if !users.include?(user)
          users_list.options = users.dup
          alert(added ? p_("MediaCatalog", "%{user} can now see your favourites.") % { user: user } : p_("MediaCatalog", "%{user} can already see your favourites.") % { user: user })
        end
      end
      users_list.focus
    end
    remove_share = proc do
      user = users[users_list.index]
      if user != nil && confirm(p_("MediaCatalog", "Do you want to stop sharing your favourites with %{user}?") % { user: user })
        if catalog_call { EltenLink::Media.unshare_favorites(elten_link, user) }
          users.delete(user)
          users_list.options = users.dup
          users_list.index = [[users_list.index, users.size - 1].min, 0].max
          alert(p_("MediaCatalog", "%{user} can no longer see your favourites.") % { user: user })
        end
      end
      users_list.focus
    end
    users_list.bind_context do |menu|
      menu.option(p_("MediaCatalog", "Share with a user"), nil, "n") { add_share.call }
      menu.option(p_("MediaCatalog", "Stop sharing"), nil, :del) { remove_share.call } if !users.empty?
    end
    public_box.on(:change) do
      wanted = public_box.checked == true
      if catalog_call { EltenLink::Media.publish_favorites(elten_link, wanted) }
        alert(wanted ? p_("MediaCatalog", "Everyone can now see your favourites.") : p_("MediaCatalog", "Your favourites are no longer public."))
      else
        public_box.checked = !wanted
      end
    end
    add_button.on(:press) { add_share.call }
    close.on(:press) { form.resume }
    form.cancel_button = close
    form.wait
  end

  # ------------------------------------------------- editors and corrections

  def report_item(item)
    text = input_text(p_("MediaCatalog", "Your correction or note for the editors of the catalog about %{title}") % { title: item.title }, flags: EditBox::Flags::MultiLine, escapable: true)
    return if text == nil || text.strip == ""
    if catalog_call { EltenLink::Media.report(elten_link, item.id, text.strip) } != nil
      alert(p_("MediaCatalog", "Your note has been sent to the editors."))
    end
  end

  def toggle_hidden(item)
    hide = !item.hidden
    question = hide ? p_("MediaCatalog", "Do you want to hide %{title} in the catalog?") : p_("MediaCatalog", "Do you want to show %{title} in the catalog again?")
    return if !confirm(question % { title: item.title })
    hidden = catalog_call { EltenLink::Media.report(elten_link, item.id, "", hide: hide ? :hide : :unhide) }
    return if hidden == nil
    item.hidden = hidden
    alert(hidden ? p_("MediaCatalog", "The entry is hidden.") : p_("MediaCatalog", "The entry is visible again."))
  end

  # Flat list of all categories as [id, "Parent / Child"] pairs.
  def category_choices
    return @category_choices if @category_choices != nil
    data = catalog_call { elten_link.api_data("GET", "/api/v1/media/categories/tree", { "depth" => 8 }) }
    return [] if data == nil
    out = []
    walk = proc do |nodes, prefix|
      Array(nodes).each do |node|
        name = prefix == "" ? node["name"].to_s : "#{prefix} / #{node["name"]}"
        out << [node["id"].to_i, name]
        walk.call(node["children"], name)
      end
    end
    walk.call(data["categories"], "")
    @category_choices = out
  end

  def edit_item(item)
    full = catalog_call { EltenLink::Media.item(elten_link, item.id) }
    return if full == nil
    choices = category_choices
    names = choices.to_h
    tags = full.tag_ids.to_a.dup
    tag_label = proc { |id| names[id] || full.tags.to_a[full.tag_ids.to_a.index(id).to_i].to_s }
    form = Form.new([
      title = EditBox.new(p_("MediaCatalog", "Title"), text: full.title.to_s),
      description = EditBox.new(p_("MediaCatalog", "Description"), type: EditBox::Flags::MultiLine, text: full.description.to_s),
      keywords = EditBox.new(p_("MediaCatalog", "Keywords"), text: full.keywords.to_s),
      homepage = EditBox.new(p_("MediaCatalog", "Homepage (optional)"), text: full.homepage.to_s),
      language = EditBox.new(p_("MediaCatalog", "Language"), text: full.language.to_s),
      categories = ListBox.new(tags.map { |id| tag_label.call(id) }, header: p_("MediaCatalog", "Categories"), empty_label: p_("MediaCatalog", "No categories")),
      save = Button.new(_("Save")),
      cancel = Button.new(_("Cancel"))
    ])
    categories.bind_context do |menu|
      menu.option(p_("MediaCatalog", "Add a category"), nil, "n") do
        available = choices.reject { |choice| tags.include?(choice[0]) }
        index = available.empty? ? -1 : selector(available.map { |choice| choice[1] }, header: p_("MediaCatalog", "Category"), start_index: 0, cancel_index: -1)
        if index != nil && index >= 0
          tags << available[index][0]
          categories.options = tags.map { |id| tag_label.call(id) }
          categories.index = tags.size - 1
        end
        categories.focus
      end
      if !tags.empty?
        menu.option(p_("MediaCatalog", "Remove this category"), nil, :del) do
          tags.delete_at(categories.index)
          categories.options = tags.map { |id| tag_label.call(id) }
          categories.index = [[categories.index, tags.size - 1].min, 0].max
          categories.focus
        end
      end
    end
    form.cancel_button = cancel
    cancel.on(:press) { form.resume }
    save.on(:press) do
      if title.text.to_s.strip == ""
        alert(p_("MediaCatalog", "Enter a title."))
        next
      end
      fields = {
        title: title.text.to_s.strip, description: description.text.to_s.strip, keywords: keywords.text.to_s.strip,
        homepage: homepage.text.to_s.strip, language: language.text.to_s.strip, categories: tags
      }
      updated = catalog_call { EltenLink::Media.update_item(elten_link, item.id, fields) }
      if updated != nil
        item.title = updated.title
        item.description = updated.description
        item.homepage = updated.homepage
        item.language = updated.language
        alert(p_("MediaCatalog", "The entry has been saved."))
        form.resume
      end
    end
    form.wait
  end
end
