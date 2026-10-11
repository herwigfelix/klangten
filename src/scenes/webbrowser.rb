# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The Klangten browser (Media menu, and every link in Klangten texts).
#
# The start screen takes an address or search words and offers bookmarks,
# history and the settings. A page opens in the full browser (Chrome without a
# window, webbrowser_page.rb) when that is available and wanted, otherwise in
# the text browser below: the document in a read-only text field, Enter on a
# link follows it, Tab moves between links, Backspace goes back.
#
# Scene_WebBrowser.open_link(url) is where links from the rest of Klangten
# arrive (see process_url); Scene_WebBrowser.open_url(url) opens a page and
# returns when the user closes the browser.

class Scene_WebBrowser
  def self.available?
    defined?(KlangtenWeb) ? true : false
  end

  # A link from a Klangten text: the browser setting decides where it opens.
  def self.open_link(url)
    url = url.to_s
    target = KlangtenWeb.link_target
    if target == "ask"
      options = [p_("WebBrowser", "Open in the Klangten browser"), p_("WebBrowser", "Open in the system browser"), p_("WebBrowser", "Copy the link"), _("Cancel")]
      choice = selector(options, header: url, cancel_index: 3)
      case choice
      when 0 then target = "klangten"
      when 1 then target = "system"
      when 2
        Clipboard.text = url
        alert(p_("WebBrowser", "The link has been copied."))
        return true
      else
        return true
      end
    end
    if target == "system"
      platform_open_url(url)
    else
      open_url(url)
    end
    true
  end

  # Opens url in the browser and returns when it is closed.
  def self.open_url(url)
    new(url).run_inline
  end

  def initialize(url = nil)
    @start_url = url
    @owner = nil
  end

  def main
    @owner = self
    start_screen
    $scene = Scene_Main.new if $scene == self
  end

  def run_inline
    @owner = $scene
    browse(@start_url) if @start_url.to_s != ""
  end

  # ------------------------------------------------------------- helpers

  class << self
    # Asks for an address (Up and Down step through the history).
    def ask_address(current = "")
      field = AddressField.new(p_("WebBrowser", "Address or search words"), KlangtenWeb.history.map { |entry| entry["url"] })
      field.set_text(current.to_s)
      field.select_all if current.to_s != ""
      ok = Button.new(p_("WebBrowser", "Open"))
      cancel = Button.new(_("Cancel"))
      form = Form.new([field, ok, cancel], quiet: true)
      form.accept_button = ok
      form.cancel_button = cancel
      result = nil
      ok.on(:press) do
        result = field.text.to_s.strip
        form.resume
      end
      cancel.on(:press) { form.resume }
      dialog_open
      form.wait
      dialog_close
      result == "" ? nil : result
    end

    def pick_history
      entries = KlangtenWeb.history
      if entries.empty?
        alert(p_("WebBrowser", "The history is empty."))
        return nil
      end
      labels = entries.map { |entry| KlangtenWeb.entry_label(entry) }
      choice = selector(labels + [_("Cancel")], header: p_("WebBrowser", "History"), cancel_index: labels.size)
      choice != nil && choice >= 0 && choice < labels.size ? entries[choice]["url"] : nil
    end

    # Bookmarks with their own context actions (rename, delete).
    def pick_bookmark
      selected = nil
      loop do
        entries = KlangtenWeb.bookmarks
        if entries.empty?
          alert(p_("WebBrowser", "You have no bookmarks yet. Open a page and choose Bookmark this page in its context menu."))
          return nil
        end
        list = ListBox.new(entries.map { |entry| KlangtenWeb.entry_label(entry) }, header: p_("WebBrowser", "Bookmarks"), index: 0, quiet: false)
        changed = false
        list.bind_context do |menu|
          entry = entries[list.index]
          next if entry == nil
          menu.option(p_("WebBrowser", "Rename")) do
            title = input_text(p_("WebBrowser", "Name of the bookmark"), text: entry["title"].to_s, escapable: true)
            if title != nil
              KlangtenWeb.rename_bookmark(entry["url"], title)
              changed = true
            end
          end
          menu.option(p_("WebBrowser", "Delete")) do
            if confirm(p_("WebBrowser", "Do you want to delete this bookmark?"))
              KlangtenWeb.remove_bookmark(entry["url"])
              changed = true
            end
          end
        end
        dialog_open
        loop do
          loop_update
          list.update
          break if changed
          if key_pressed?(:key_escape)
            dialog_close
            return nil
          end
          if list.selected?
            selected = entries[list.index]["url"]
            break
          end
        end
        dialog_close
        return selected if selected != nil
      end
    end

    def show_keys
      main = main_modifier_name
      lines = [
        p_("WebBrowser", "Browse mode"),
        p_("WebBrowser", "Up and Down arrows: previous and next line. Left and Right: characters, with %{word} words.") % { word: EltenAPI::KeyboardScheme.modifier_name(:word_modifier) },
        p_("WebBrowser", "Enter or Space: activate the element (follow a link, press a button, fill a field)."),
        p_("WebBrowser", "Tab and Shift+Tab: next and previous element that can take the focus."),
        p_("WebBrowser", "Single letters jump to the next element, with Shift to the previous one: H heading, 1 to 6 heading level, K link, B button, F form field, E edit field, C combo box, X check box, R radio button, L list, I list item, T table, G graphic, D landmark, Q quote, S separator, P player."),
        p_("WebBrowser", "A: read from here. Backspace: back, Shift+Backspace: forward."),
        p_("WebBrowser", "%{main}+Alt+arrows: move through the cells of a table.") % { main: main },
        p_("WebBrowser", "%{main}+L address, %{main}+R reload, %{main}+F find, %{main}+G find next, %{main}+H history, %{main}+B bookmarks, %{main}+D bookmark this page, %{main}+I title and address.") % { main: main },
        p_("WebBrowser", "%{main}+Shift+H, K, F, D: lists of headings, links, form fields and landmarks.") % { main: main },
        p_("WebBrowser", "Escape closes the browser."),
        "",
        p_("WebBrowser", "Focus mode"),
        p_("WebBrowser", "Keys go to the page, for typing into fields and for web applications. Enter or Space on an edit field switches to focus mode."),
        p_("WebBrowser", "Alt+Space switches between browse and focus mode, Escape returns to browse mode.")
      ]
      input_text(p_("WebBrowser", "Keyboard shortcuts"), flags: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: lines.join("\n"))
    end

    # True when the full browser should be used now. The first time it asks
    # whether Chrome may be downloaded; "no" is remembered.
    def engine_ready?
      return false unless KlangtenWeb.engine_supported?
      return false if KlangtenWeb.prefer_text_browser?
      return true if KlangtenWeb::Chrome.installed?
      return false if KlangtenWeb.engine_declined?
      question = p_("WebBrowser", "The full Klangten browser reads pages like a screen reader, with forms, scripts and sign-ins. It needs Chrome for Testing from Google, which is downloaded once (about 200 MB) and runs invisibly. Download it now? If you answer No, pages open in the simple text browser; you can download it later in the browser settings.")
      unless confirm(question, default_yes: true)
        KlangtenWeb.engine_declined = true
        return false
      end
      install_engine
    end

    def install_engine
      version = EltenAPI::Tasks.run(title: p_("WebBrowser", "Downloading the full browser..."), show_after: 0) do |progress, token|
        KlangtenWeb::Chrome.install(token: token) do |percent, _got|
          progress.update(percent, total: 100) rescue nil
        end
      end
      KlangtenWeb.engine_declined = false
      alert(p_("WebBrowser", "The full browser (Chrome %{version}) is ready.") % { version: version })
      true
    rescue EltenAPI::Tasks::Cancelled
      false
    rescue StandardError => e
      Log.error("Browser: Chrome installation failed: #{e.class}: #{e.message}")
      alert(p_("WebBrowser", "The full browser could not be downloaded. Check your internet connection and try again.") + " " + e.message.to_s)
      false
    end
  end

  # Address field: Up and Down step through earlier addresses.
  class AddressField < EltenAPI::Controls::EditBox
    def initialize(header, history)
      super(header, text: "")
      @history = history
      @history_index = -1
    end

    def update
      if !@history.empty? && !raw_key_held?(:key_shift) && !modifier_held?(:main_modifier) && (key_pressed?(:key_up) || key_pressed?(:key_down))
        index = @history_index + (key_pressed?(:key_up) ? 1 : -1)
        if index >= @history.size || index < -1
          play_sound("border")
        else
          @history_index = index
          value = index < 0 ? "" : @history[index].to_s
          set_text(value)
          self.index = self.check = value.length
          value == "" ? play_sound("border") : speak(value)
        end
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        return
      end
      super
    end
  end

  # The text browser's view: a read-only text field whose links stay inside
  # the browser. Backspace and Shift+Backspace go back and forward.
  class TextView < EltenAPI::Controls::EditBox
    def initialize(header, html, on_link:, on_history:)
      super(header, type: Flags::ReadOnly | Flags::MultiLine | Flags::HTML, text: html, quiet: true, detect_text_links: true)
      @on_link = on_link
      @on_history = on_history
    end

    def update
      if key_pressed?(:key_enter) && !modifier_held?(:main_modifier) && (url = link_at_cursor) != nil
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        @on_link.call(url)
        return
      end
      if key_pressed?(0x08) && !modifier_held?(:main_modifier)
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        @on_history.call(raw_key_held?(:key_shift) ? 1 : -1)
        return
      end
      if key_pressed?(:key_tab)
        element = find_element([Element::Link, Element::Frame], nil, raw_key_held?(:key_shift), @index)
        if element == nil
          play_sound("border")
        else
          @index = @check = @vindex = element.from
          speak(text_range(element.from, element.to))
        end
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        return
      end
      super
    end
  end

  # ------------------------------------------------------------ start screen

  private

  def left?
    $scene != @owner
  end

  def start_screen
    address = AddressField.new(p_("WebBrowser", "Address or search words"), KlangtenWeb.history.map { |entry| entry["url"] })
    open = Button.new(p_("WebBrowser", "Open"))
    bookmarks = Button.new(p_("WebBrowser", "Bookmarks"))
    history = Button.new(p_("WebBrowser", "History"))
    settings = Button.new(p_("WebBrowser", "Settings"))
    close = Button.new(_("Close"))
    form = Form.new([address, open, bookmarks, history, settings, close])
    form.accept_button = open
    form.cancel_button = close
    done = false
    open.on(:press) do
      text = address.text.to_s.strip
      if text == ""
        alert(p_("WebBrowser", "Enter an address or what you are looking for."))
        next
      end
      browse(text)
      form.focus unless left?
    end
    bookmarks.on(:press) do
      url = Scene_WebBrowser.pick_bookmark
      browse(url) if url != nil
      form.focus unless left?
    end
    history.on(:press) do
      history_screen
      form.focus unless left?
    end
    settings.on(:press) do
      settings_screen
      form.focus unless left?
    end
    close.on(:press) { done = true }
    loop do
      loop_update
      form.update
      break if done || left?
    end
  end

  def history_screen
    entries = KlangtenWeb.history
    if entries.empty?
      alert(p_("WebBrowser", "The history is empty."))
      return
    end
    list = ListBox.new(entries.map { |entry| KlangtenWeb.entry_label(entry) }, header: p_("WebBrowser", "History"), index: 0, quiet: false)
    cleared = false
    list.bind_context do |menu|
      menu.option(p_("WebBrowser", "Clear the history")) do
        if confirm(p_("WebBrowser", "Do you want to clear the history of visited pages?"))
          KlangtenWeb.clear_history
          cleared = true
        end
      end
    end
    url = nil
    loop do
      loop_update
      list.update
      break if key_pressed?(:key_escape) || cleared || left?
      if list.selected?
        url = entries[list.index]["url"]
        break
      end
    end
    browse(url) if url != nil
  end

  def settings_screen
    targets = KlangtenWeb::LINK_TARGETS
    links = ListBox.new([p_("WebBrowser", "Ask every time"), p_("WebBrowser", "In the Klangten browser"), p_("WebBrowser", "In the system browser")],
                        header: p_("WebBrowser", "Open links from posts and messages"), index: targets.index(KlangtenWeb.link_target) || 0)
    fields = [links]
    engine = KlangtenWeb.engine_supported?
    if engine
      text_only = CheckBox.new(p_("WebBrowser", "Always use the simple text browser"), checked: KlangtenWeb.prefer_text_browser?)
      install = Button.new(KlangtenWeb::Chrome.installed? ? p_("WebBrowser", "Update the full browser") : p_("WebBrowser", "Download the full browser"))
      remove = Button.new(p_("WebBrowser", "Remove the full browser"))
      clear = Button.new(p_("WebBrowser", "Delete cookies and cache"))
      fields += [text_only, install]
      fields += [remove, clear] if KlangtenWeb::Chrome.installed?
    end
    save = Button.new(_("Save"))
    cancel = Button.new(_("Cancel"))
    fields += [save, cancel]
    form = Form.new(fields)
    form.accept_button = save
    form.cancel_button = cancel
    if engine
      install.on(:press) do
        Scene_WebBrowser.install_engine
        form.focus
      end
      remove.on(:press) do
        if confirm(p_("WebBrowser", "Do you want to remove the full browser? Its cookies and sign-ins are deleted as well."))
          KlangtenWeb::Chrome.uninstall
          alert(p_("WebBrowser", "The full browser has been removed."))
        end
        form.focus
      end
      clear.on(:press) do
        if confirm(p_("WebBrowser", "Do you want to delete all cookies and the cache of the browser? You will be signed out of all websites."))
          if KlangtenWeb::Chrome.running?
            KlangtenWeb::Chrome.clear_data
          else
            FileUtils.rm_rf(KlangtenWeb::Chrome.profile_dir)
          end
          alert(p_("WebBrowser", "Cookies and cache have been deleted."))
        end
        form.focus
      end
    end
    save.on(:press) do
      KlangtenWeb.link_target = targets[links.index] || "ask"
      KlangtenWeb.prefer_text_browser = text_only.checked? if engine
      alert(p_("WebBrowser", "Saved"))
      form.resume
    end
    cancel.on(:press) { form.resume }
    form.wait
  end

  # ----------------------------------------------------------------- browsing

  # Opens a page; the full browser and the text browser can hand it over to
  # each other.
  def browse(address)
    url = KlangtenWeb.normalize_url(address)
    return if url == nil
    use_full = Scene_WebBrowser.engine_ready?
    loop do
      result = use_full ? full_browser(url) : text_browser(url)
      break unless result.is_a?(Array)
      case result[0]
      when :text
        use_full = false
        url = result[1]
      when :full
        break unless Scene_WebBrowser.engine_ready?
        use_full = true
        url = result[1]
      when :engine_failed
        alert(p_("WebBrowser", "The full browser could not be started. The page opens in the text browser.") + " " + result[1].to_s)
        use_full = false
        url = result[2] || url
      else
        break
      end
      break if url.to_s == "" || left?
    end
  end

  def full_browser(url)
    tab = begin
      EltenAPI::Tasks.run(title: p_("WebBrowser", "Starting the browser..."), timeout: 60) do |_progress, _token|
        KlangtenWeb::Chrome.open_tab
      end
    rescue EltenAPI::Tasks::Cancelled
      return :closed
    rescue StandardError => e
      Log.error("Browser: Chrome did not start: #{e.class}: #{e.message}")
      return [:engine_failed, e.message, url]
    end
    result = nil
    view = PageView.new(tab, url) { |outcome| result = outcome }
    # The page owns Tab and Escape (a Form would take Tab for itself), so it
    # gets a frame loop of its own.
    view.focus
    loop do
      loop_update
      view.update
      break if result != nil
    end
    result = [:engine_failed, result[1], url] if result.is_a?(Array) && result[0] == :engine_failed
    result
  ensure
    view.release if view != nil
  end

  # ------------------------------------------------------------ text browser

  def text_browser(url)
    @pages = []
    @page_index = -1
    @text_result = nil
    return :closed unless text_open(url)
    # Like the full browser: Tab moves between links, so no Form here.
    @text_view = text_view
    @text_view.focus
    loop do
      loop_update
      @text_view.update
      @text_result ||= :closed if key_pressed?(:key_escape) || left?
      break if @text_result != nil
    end
    @text_result
  ensure
    @text_view = nil
  end

  def current_page
    @pages[@page_index][:page]
  end

  def text_view
    entry = @pages[@page_index]
    page = entry[:page]
    title = page.title.to_s == "" ? page.url : page.title
    html = page.html.to_s == "" ? CGI.escapeHTML(p_("WebBrowser", "The page is empty.")) : page.html
    view = TextView.new(title, html, on_link: proc { |link| text_follow(link) }, on_history: proc { |step| text_step(step) })
    view.index = entry[:position].to_i
    bind_text_context(view)
    view
  end

  # Shows the current page; read: false keeps the place and speaks only the
  # title and the line (going back), read: true reads the new page.
  def text_show(read: true)
    view = @text_view = text_view
    if read
      view.focus
    else
      speak("#{view.header}. #{view.text_range(view.line_beginning(view.index), view.line_ending(view.index))}")
    end
  end

  def text_open(url, replace: false)
    page = EltenAPI::Tasks.run(title: p_("WebBrowser", "Loading the page...")) do |_progress, token|
      KlangtenWeb::TextPage.load(url, token: token)
    end
    if page.error == :not_page
      text_file(page.url, page.mime)
      return false
    end
    if page.error != nil
      alert("#{p_("WebBrowser", "The page could not be loaded.")} #{page.error}")
      return false
    end
    @pages = @pages[0..@page_index] if @page_index >= 0
    @pages.pop if replace && !@pages.empty?
    @pages << { page: page, position: 0 }
    @page_index = @pages.size - 1
    KlangtenWeb.add_history(page.url, page.title)
    true
  rescue EltenAPI::Tasks::Cancelled
    false
  end

  # A link that is not a page: media are played or saved, other files saved.
  def text_file(url, mime)
    name = KlangtenWeb.file_name_for("", url)
    if KlangtenWeb.media?(url, mime)
      choice = selector([p_("WebBrowser", "Play"), p_("WebBrowser", "Download"), _("Cancel")], header: p_("WebBrowser", "%{name} is a media file.") % { name: name }, cancel_index: 2)
      return player(url, label: name) if choice == 0
      return if choice != 1
    else
      return unless confirm(p_("WebBrowser", "%{name} is not a web page. Do you want to download it?") % { name: name }, default_yes: true)
    end
    path = KlangtenWeb.unique_path(KlangtenWeb.downloads_dir, name)
    EltenAPI::Tasks.run(title: p_("WebBrowser", "Saving %{name}...") % { name: name }, show_after: 0) do |progress, token|
      KlangtenWeb.http_download(url, path, token: token) do |got, total|
        begin
          total > 0 ? progress.update(got * 100 / total, total: 100) : progress.update(nil, message: format("%.1f MB", got / 1_048_576.0))
        rescue StandardError
        end
      end
    end
    alert(p_("WebBrowser", "Saved as %{name} in your downloads folder.") % { name: File.basename(path) })
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue StandardError => e
    alert("#{p_("WebBrowser", "The download failed.")} #{e.message}")
  end

  def text_follow(link)
    absolute = (URI.join(current_page.url, link.to_s).to_s rescue link.to_s)
    @pages[@page_index][:position] = @text_view.index
    unless KlangtenWeb.web_url?(absolute)
      platform_open_url(absolute)
      return
    end
    if KlangtenWeb.media?(absolute)
      text_file(absolute, nil)
      return
    end
    text_show if text_open(absolute)
  end

  def text_step(step)
    target = @page_index + step
    return play_sound("border") unless target.between?(0, @pages.size - 1)
    @pages[@page_index][:position] = @text_view.index
    @page_index = target
    text_show(read: false)
  end

  def bind_text_context(view)
    view.bind_context(p_("WebBrowser", "Browser")) do |menu|
      menu.option(p_("WebBrowser", "Enter address..."), nil, "l") do
        url = KlangtenWeb.normalize_url(Scene_WebBrowser.ask_address(current_page.url))
        text_show if url != nil && text_open(url)
      end
      menu.option(p_("WebBrowser", "Back")) { text_step(-1) }
      menu.option(p_("WebBrowser", "Forward")) { text_step(1) }
      menu.option(p_("WebBrowser", "Reload"), nil, "r") do
        text_show if text_open(current_page.url, replace: true)
      end
      menu.option(p_("WebBrowser", "Page title and address"), nil, "i") do
        speak("#{current_page.title}. #{current_page.url}")
      end
      menu.option(p_("WebBrowser", "History..."), nil, "h") do
        url = Scene_WebBrowser.pick_history
        text_show if url != nil && text_open(url)
      end
      menu.option(p_("WebBrowser", "Bookmarks..."), nil, "b") do
        url = Scene_WebBrowser.pick_bookmark
        text_show if url != nil && text_open(url)
      end
      menu.option(p_("WebBrowser", "Bookmark this page"), nil, "d") do
        if KlangtenWeb.add_bookmark(current_page.url, current_page.title)
          alert(p_("WebBrowser", "The page has been added to your bookmarks."))
        else
          alert(p_("WebBrowser", "This page is already in your bookmarks."))
        end
      end
      menu.option(p_("WebBrowser", "Copy page address"), nil, "C") do
        Clipboard.text = current_page.url
        speak(p_("WebBrowser", "Copied"))
      end
      menu.option(p_("WebBrowser", "Open in the system browser")) { platform_open_url(current_page.url) }
      if KlangtenWeb.engine_supported?
        menu.option(p_("WebBrowser", "Open in the full browser")) do
          @text_result = [:full, current_page.url]
        end
      end
      menu.option(p_("WebBrowser", "Keyboard shortcuts")) { Scene_WebBrowser.show_keys }
      menu.option(p_("WebBrowser", "Close the browser")) { @text_result = :closed }
    end
  end
end
