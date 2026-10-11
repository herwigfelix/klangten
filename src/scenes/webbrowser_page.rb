# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The page of the full Klangten browser: one Chrome tab read like a screen
# reader reads it.
#
# Browse mode   the arrows read the buffer (lines, characters, words), single
#               letters jump to the next element of a kind (h heading, k link,
#               b button, f form field, e edit field, c combo box, x check box,
#               r radio button, l list, i list item, t table, g graphic,
#               d landmark, q quote, s separator, p player, 1 to 6 heading
#               level; with Shift backwards), Enter or Space activates, Tab
#               moves to the next focusable element, a reads from here,
#               Backspace goes back, the main modifier with Alt and the arrows
#               moves through tables.
# Focus mode    keys go to the page and Klangten speaks what changed.
#               Alt+Space switches, Escape returns to browse mode.
#
# The commands with the main modifier are the shortcuts of the context menu
# (Klangten triggers those itself). The page view never blocks: events of the
# tab are fetched in every update, slow things (snapshots) take a moment.

class Scene_WebBrowser
  class PageView < EltenAPI::Controls::FormField
    NodeView = Struct.new(:role, :name, :value, :props, :password, :desc, :count, :rows, :cols, :headers, :id, keyword_init: true)
    Span = Struct.new(:from, :to, :owner, :leaf, :src)

    EDITABLE = %w[textbox searchbox combobox spinbutton Date DateTime InputTime].freeze
    FIELDS = %w[textbox searchbox combobox listbox checkbox radio switch slider spinbutton button Date DateTime InputTime
                ColorWell PopUpButton ToggleButton menuitemcheckbox menuitemradio].freeze
    LANDMARKS = %w[navigation main banner contentinfo complementary search region form].freeze
    CONTAINER_LISTS = %w[list tree menu menubar tablist radiogroup].freeze
    TABLES = %w[table grid treegrid].freeze
    LOAD_TIMEOUT = 20
    REBUILD_INTERVAL = 1.0

    # Quick navigation: virtual key => [matcher, kind name for "not found"].
    QUICK_KEYS = {
      0x48 => :heading, 0x4B => :link, 0x42 => :button, 0x46 => :field, 0x45 => :edit, 0x43 => :combo,
      0x58 => :checkbox, 0x52 => :radio, 0x4C => :list, 0x49 => :listitem, 0x54 => :table, 0x47 => :graphic,
      0x44 => :landmark, 0x51 => :quote, 0x53 => :separator, 0x50 => :player,
      0x31 => :heading1, 0x32 => :heading2, 0x33 => :heading3, 0x34 => :heading4, 0x35 => :heading5, 0x36 => :heading6
    }.freeze

    attr_reader :title, :url, :mode

    # on_close receives :closed, :left, [:text, url] (open in the text
    # browser) or [:engine_failed, message].
    def initialize(tab, url, &on_close)
      @tab = tab
      @on_close = on_close
      @owner_scene = $scene
      @lines = []
      @texts = []
      @spans = []
      @nodes = []
      @node_positions = {}
      @cur = 1
      @col = 1
      @mode = :browse
      @title = ""
      @url = ""
      @live = []
      @loading = false
      @got_document = false
      @dirty = false
      @last_rebuild = nil
      @load_started = nil
      @last_find = nil
      @last_focus = nil
      @focus_id = nil
      @closed = false
      @header = p_("WebBrowser", "Web page")
      navigate(url) if url.to_s != ""
    end

    def hascontext
      true
    end

    def release
      waiting_end if @waiting
      @waiting = false
      @tab.close if @tab != nil
      @tab = nil
    end

    def focus(index = nil, count = nil)
      if @loading && @lines.empty?
        speak(p_("WebBrowser", "Loading..."))
      elsif @lines.empty?
        speak(@title.to_s == "" ? p_("WebBrowser", "Web page") : @title)
      else
        speak("#{@title}. #{line_speech(@cur, false)}")
      end
    end

    def blur
      stop_waiting
    end

    def update
      super
      return if @closed
      if $scene != @owner_scene
        close(:left)
        return
      end
      frame = $input_frame_serial
      poll_events
      return if @closed
      # A dialog opened by an event (download, page message) ran its own
      # frames; the key that closed it must not act on the page as well.
      return if frame != $input_frame_serial
      if raw_key_held?(:key_alt) && key_pressed?(:key_space) && !modifier_held?(:main_modifier)
        cancel_pending_alt_menu
        set_mode(@mode == :focus ? :browse : :focus)
        return
      end
      @mode == :focus ? focus_update : browse_update
    rescue KlangtenWeb::Chrome::Error => e
      Log.warning("Browser: #{e.message}")
      play_sound("border")
    end

    # ---------------------------------------------------------------- roles

    def role_name(role)
      case role
      when "link" then p_("WebBrowser", "link")
      when "button", "ToggleButton", "PopUpButton" then p_("WebBrowser", "button")
      when "checkbox", "menuitemcheckbox" then p_("WebBrowser", "check box")
      when "radio", "menuitemradio" then p_("WebBrowser", "radio button")
      when "switch" then p_("WebBrowser", "switch")
      when "textbox" then p_("WebBrowser", "edit")
      when "searchbox" then p_("WebBrowser", "search field")
      when "combobox" then p_("WebBrowser", "combo box")
      when "listbox" then p_("WebBrowser", "list box")
      when "slider" then p_("WebBrowser", "slider")
      when "spinbutton" then p_("WebBrowser", "spin button")
      when "progressbar", "meter" then p_("WebBrowser", "progress bar")
      when "image", "img" then p_("WebBrowser", "graphic")
      when "heading" then p_("WebBrowser", "heading")
      when "list" then p_("WebBrowser", "list")
      when "listitem" then p_("WebBrowser", "list item")
      when "table", "grid", "treegrid" then p_("WebBrowser", "table")
      when "navigation" then p_("WebBrowser", "navigation")
      when "main" then p_("WebBrowser", "main content")
      when "banner" then p_("WebBrowser", "banner")
      when "contentinfo" then p_("WebBrowser", "content information")
      when "complementary" then p_("WebBrowser", "complementary")
      when "search" then p_("WebBrowser", "search")
      when "region" then p_("WebBrowser", "region")
      when "form" then p_("WebBrowser", "form")
      when "dialog", "alertdialog" then p_("WebBrowser", "dialog")
      when "article" then p_("WebBrowser", "article")
      when "blockquote" then p_("WebBrowser", "quote")
      when "figure" then p_("WebBrowser", "figure")
      when "menu" then p_("WebBrowser", "menu")
      when "menubar" then p_("WebBrowser", "menu bar")
      when "menuitem" then p_("WebBrowser", "menu item")
      when "tab" then p_("WebBrowser", "tab")
      when "tablist" then p_("WebBrowser", "tab list")
      when "toolbar" then p_("WebBrowser", "toolbar")
      when "tree" then p_("WebBrowser", "tree view")
      when "treeitem" then p_("WebBrowser", "tree item")
      when "option" then p_("WebBrowser", "option")
      when "group" then p_("WebBrowser", "grouping")
      when "separator" then p_("WebBrowser", "separator")
      when "Video", "video" then p_("WebBrowser", "video")
      when "Audio", "audio" then p_("WebBrowser", "audio")
      when "alert" then p_("WebBrowser", "alert")
      when "radiogroup" then p_("WebBrowser", "radio group")
      when "Date", "DateTime", "InputTime" then p_("WebBrowser", "date field")
      when "ColorWell" then p_("WebBrowser", "color picker")
      when "DisclosureTriangle" then p_("WebBrowser", "disclosure")
      else ""
      end
    end

    def known_role?(role)
      role_name(role) != ""
    end

    def states(view)
      props = view.props || {}
      role = view.role
      out = []
      if props["checked"].to_s != ""
        out << case props["checked"]
               when "true" then p_("WebBrowser", "checked")
               when "mixed" then p_("WebBrowser", "half checked")
               else p_("WebBrowser", "not checked")
               end
      elsif %w[checkbox switch radio].include?(role)
        out << p_("WebBrowser", "not checked")
      end
      out << (props["pressed"] == "true" ? p_("WebBrowser", "pressed") : p_("WebBrowser", "not pressed")) if props["pressed"].to_s != ""
      out << (props["expanded"] == "true" ? p_("WebBrowser", "expanded") : p_("WebBrowser", "collapsed")) if props["expanded"].to_s != ""
      out << p_("WebBrowser", "selected") if props["selected"] == "true" && !%w[tab option].include?(role)
      out << p_("WebBrowser", "has submenu") if props["haspopup"].to_s != "" && props["haspopup"] != "false" && role != "combobox" && props["expanded"].to_s == ""
      out << p_("WebBrowser", "required") if props["required"] == "true"
      out << p_("WebBrowser", "invalid entry") if props["invalid"].to_s != "" && props["invalid"] != "false"
      out << p_("WebBrowser", "read only") if props["readonly"] == "true" && EDITABLE.include?(role)
      out << p_("WebBrowser", "unavailable") if props["disabled"] == "true"
      out.join(" ")
    end

    def describe(view, text = nil)
      return text.to_s if view == nil
      role = view.role
      name = view.name.to_s.strip
      value = view.value.to_s.strip
      role_label = role_name(role)
      role_label = p_("WebBrowser", "visited link") if role == "link" && view.props["visited"] == "true"
      role_label += " " + p_("WebBrowser", "multi line") if role == "textbox" && view.props["multiline"] == "true"
      state = states(view)
      shown = text.to_s.strip != "" ? text.to_s.strip : name
      parts = []
      if role == "link"
        parts += [role_label, shown, state]
      elsif role == "heading"
        level = view.props["level"].to_i
        parts << (level > 0 ? "#{role_label} #{p_("WebBrowser", "level %{level}") % { level: level }}" : role_label)
        parts << shown
      elsif EDITABLE.include?(role) || %w[listbox slider progressbar].include?(role)
        parts += [name, role_label, state]
        parts << p_("WebBrowser", "password") if view.password
        parts << value
      else
        parts += [shown, role_label, state]
      end
      out = parts.join(" ").gsub(/\s+/, " ").strip
      out += ". #{view.desc}" if view.desc.to_s != "" && view.desc != name
      out
    end

    def container_text(view)
      role = view.role
      label = role_name(role)
      if CONTAINER_LISTS.include?(role)
        return view.count > 0 ? "#{label} #{np_("WebBrowser", "with %{count} item", "with %{count} items", view.count) % { count: view.count }}" : label
      end
      return "#{label} #{p_("WebBrowser", "with %{rows} rows and %{columns} columns") % { rows: view.rows.to_i, columns: view.cols.to_i }}" if TABLES.include?(role)
      return "#{view.name} #{label}".strip if %w[group region form].include?(role)
      view.name.to_s != "" && role != "main" ? "#{label} #{view.name}" : label
    end

    def node_view(node)
      return nil if node == nil
      NodeView.new(role: node.role, name: node.name, value: node.value, props: node.props || {}, password: false, desc: node.desc,
                   count: node.count, rows: node.rows, cols: node.cols, headers: node.headers || {}, id: node.backend)
    end

    def focus_view(info)
      NodeView.new(role: info["role"].to_s, name: info["name"].to_s, value: (info["value"] || info["axvalue"]).to_s,
                   props: info["p"] || {}, password: info["pw"].to_i == 1, desc: info["desc"].to_s,
                   count: 0, rows: 0, cols: 0, headers: {}, id: info["id"])
    end

    # --------------------------------------------------------------- buffer

    def node(index)
      index.between?(1, @nodes.size) ? @nodes[index - 1] : nil
    end

    def build_line(line)
      text = +""
      spans = []
      line.segs.each do |seg|
        piece = seg.text.to_s
        if seg.leaf && piece.strip == "" && seg.owner != 0
          lead = piece.start_with?(" ") ? " " : ""
          label = role_name(node(seg.owner)&.role.to_s)
          piece = lead + (label == "" ? "_" : label)
        end
        spans << Span.new(text.length + 1, text.length + piece.length, seg.owner, seg.leaf, seg.src)
        text << piece
      end
      [text, spans]
    end

    def set_document(document)
      @lines = document.lines
      @nodes = document.nodes
      @title = document.title if document.title.to_s != ""
      @texts = []
      @spans = []
      @node_positions = {}
      @lines.each_with_index do |line, index|
        text, spans = build_line(line)
        @texts << text
        @spans << spans
        spans.each do |span|
          next if span.owner == 0 || @node_positions.key?(span.owner)
          start = span.from
          start += 1 if text[start - 1] == " " && span.to > start
          @node_positions[span.owner] = [index + 1, start]
        end
      end
      @nodes.each_with_index do |entry, index|
        @node_positions[index + 1] ||= [entry.line.to_i + 1, 1]
      end
    end

    def rebuild(keep)
      return false if @tab == nil
      document = @tab.snapshot
      anchor = nil
      offset = 0
      if keep && @cur.between?(1, @lines.size)
        spans = @spans[@cur - 1]
        hit = spans.find { |span| span.from <= @col && @col <= span.to } || spans.first
        if hit != nil
          anchor = hit.src
          offset = @col - hit.from if hit.from <= @col && @col <= hit.to
        end
      end
      set_document(document)
      if keep
        found = false
        if anchor != nil
          @spans.each_with_index do |spans, index|
            span = spans.find { |entry| entry.src == anchor }
            next if span == nil
            @cur = index + 1
            @col = [[span.from + offset, @texts[index].length].min, 1].max
            found = true
            break
          end
        end
        unless found
          @cur = @cur.clamp(1, [@lines.size, 1].max)
          @col = 1
        end
      else
        @cur = 1
        @col = 1
      end
      @dirty = false
      @last_rebuild = monotonic
      true
    rescue KlangtenWeb::Chrome::Error => e
      Log.warning("Browser: snapshot failed: #{e.message}")
      false
    end

    def line_speech(index, with_enter)
      return "" unless index.between?(1, @lines.size)
      line = @lines[index - 1]
      text = @texts[index - 1]
      spans = @spans[index - 1]
      out = []
      if with_enter
        line.enter.each do |entry|
          view = node_view(node(entry))
          out << container_text(view) if view != nil
        end
      end
      block = line.blk > 0 ? node(line.blk) : nil
      if block != nil && block.role == "heading"
        level = block.props["level"].to_i
        out << (level > 0 ? "#{role_name("heading")} #{p_("WebBrowser", "level %{level}") % { level: level }}" : role_name("heading"))
      end
      i = 0
      while i < spans.size
        span = spans[i]
        if span.owner != 0
          j = i
          parts = []
          while j < spans.size && spans[j].owner == span.owner
            parts << text[(spans[j].from - 1)...spans[j].to].to_s
            j += 1
          end
          out << describe(node_view(node(span.owner)), span.leaf ? nil : parts.join.strip)
          i = j
        else
          out << text[(span.from - 1)...span.to].to_s
          i += 1
        end
      end
      out.join(" ").gsub(/\s+/, " ").strip
    end

    def speak_line(with_enter)
      text = line_speech(@cur, with_enter)
      speak(text == "" ? " " : text)
    end

    def node_text(index)
      position = @node_positions[index]
      return "" if position == nil
      out = []
      last = [@lines.size, position[0] + 40].min
      (position[0]..last).each do |line_index|
        text = @texts[line_index - 1]
        found = false
        @spans[line_index - 1].each do |span|
          next unless span.owner == index
          out << text[(span.from - 1)...span.to].to_s unless span.leaf
          found = true
        end
        break if !found && !out.empty?
      end
      out.join(" ").gsub(/\s+/, " ").strip
    end

    # ------------------------------------------------------------- loading

    def navigate(address)
      url = KlangtenWeb.normalize_url(address)
      return false if url == nil || @tab == nil
      speech_stop
      @loading = true
      @got_document = false
      @load_started = monotonic
      start_waiting
      ok, error = @tab.navigate(url)
      unless ok
        @loading = false
        stop_waiting
        speak("#{p_("WebBrowser", "The page could not be loaded.")} #{error}")
        return false
      end
      true
    end

    def page_arrived
      return unless rebuild(false)
      @got_document = true
      info = @tab.info
      @url = info[:url].to_s if info[:url].to_s != ""
      @title = info[:title].to_s if info[:title].to_s != ""
      KlangtenWeb.add_history(@url, @title)
      if @lines.empty?
        speak("#{@title}. #{p_("WebBrowser", "The page is empty.")}")
      else
        say_all(@title)
      end
    end

    def start_waiting
      return if @waiting
      @waiting = true
      waiting
    end

    def stop_waiting
      return unless @waiting
      @waiting = false
      waiting_end
    end

    def loading?
      @loading
    end

    # ------------------------------------------------------------- events

    def poll_events
      return if @tab == nil
      @tab.poll.each do |event|
        case event[:type]
        when "loading"
          unless @loading
            @loading = true
            @got_document = false
            @load_started = monotonic
            start_waiting
          end
        when "nav"
          @url = event[:url] if event[:url].to_s != ""
        when "dom"
          if @loading && !@got_document && rebuild(false) && !@lines.empty?
            @loading = false
            stop_waiting
            page_arrived
          end
        when "load", "stopped"
          if @loading
            @loading = false
            stop_waiting
            page_arrived unless @got_document
          elsif @got_document
            @dirty = true
          end
        when "spa"
          @url = event[:url] if event[:url].to_s != ""
          @dirty = true
        when "mut"
          @dirty = true
        when "live"
          next if event[:text].to_s == ""
          event[:assertive] ? speak(event[:text]) : @live << event[:text]
        when "file"
          @loading = false
          stop_waiting
          handle_file(event)
        when "dialog"
          handle_dialog(event)
        when "download_started"
          speak(p_("WebBrowser", "Downloading %{name}") % { name: event[:name] })
        when "downloaded"
          speak(p_("WebBrowser", "Saved as %{name}") % { name: File.basename(event[:path].to_s) })
        when "download_failed"
          speak("#{p_("WebBrowser", "The download failed.")} #{event[:name]}")
        when "crash"
          handle_crash
          return
        end
      end
      speak(@live.shift) if !@live.empty? && !speech_actived
      if @dirty && @got_document && @mode == :browse && !@loading && (@last_rebuild == nil || monotonic - @last_rebuild > REBUILD_INTERVAL)
        rebuild(true)
      end
      if @loading && @load_started != nil && monotonic - @load_started > LOAD_TIMEOUT
        @loading = false
        stop_waiting
        page_arrived unless @got_document
      end
    end

    def handle_crash
      stop_waiting
      @loading = false
      speak(p_("WebBrowser", "The browser has stopped working. It is being restarted."))
      @tab.close rescue nil
      @tab = nil
      begin
        @tab = KlangtenWeb::Chrome.open_tab
        navigate(@url) if @url.to_s != ""
      rescue StandardError => e
        close([:engine_failed, e.message])
      end
    end

    def handle_file(event)
      name = event[:name].to_s
      name = "download" if name == ""
      if KlangtenWeb.media?(event[:url], event[:mime])
        choice = selector([p_("WebBrowser", "Play"), p_("WebBrowser", "Download"), _("Cancel")], header: p_("WebBrowser", "%{name} is a media file.") % { name: name }, cancel_index: 2)
        if choice != 1
          @tab.file_action(event[:request], "abort")
          player(event[:url], label: name) if choice == 0
          return
        end
      end
      path = KlangtenWeb.unique_path(KlangtenWeb.downloads_dir, name)
      job = @tab.file_action(event[:request], "save", path)
      begin
        EltenAPI::Tasks.run(title: p_("WebBrowser", "Saving %{name}...") % { name: name }, show_after: 0) do |progress, token|
          while job.running?
            if token.cancelled?
              job.cancel = true
              token.raise_if_cancelled!
            end
            progress.update(nil, message: format("%.1f MB", job.got / 1_048_576.0)) rescue nil
            sleep(0.1)
          end
        end
      rescue EltenAPI::Tasks::Cancelled
        job.cancel = true
        return
      end
      if job.state == :done
        alert(p_("WebBrowser", "Saved as %{name} in your downloads folder.") % { name: File.basename(job.path) })
      else
        alert("#{p_("WebBrowser", "The download failed.")} #{job.error}")
      end
    end

    def handle_dialog(event)
      message = event[:message].to_s.strip
      case event[:kind]
      when "alert"
        alert("#{p_("WebBrowser", "Message from the page")}: #{message}")
        @tab.dialog_answer(true)
      when "confirm"
        @tab.dialog_answer(confirm("#{p_("WebBrowser", "Question from the page")}: #{message}"))
      when "prompt"
        text = input_text("#{p_("WebBrowser", "Input requested by the page")}: #{message}", text: event[:default].to_s, escapable: true)
        @tab.dialog_answer(text != nil, text)
      else
        @tab.dialog_answer(true)
      end
    end

    # -------------------------------------------------------- reading aloud

    # Reads from the current line to the end; the position follows the voice.
    def say_all(head = nil)
      return if @lines.empty?
      commands = []
      commands << head.to_s + "\n" if head.to_s != ""
      generation = (@say_all_generation = @say_all_generation.to_i + 1)
      last = [@lines.size, @cur + 400].min
      (@cur..last).each do |index|
        commands << SpeechCommands::CustomCommand.new(index) { |line| (@cur = line; @col = 1) if @say_all_generation == generation }
        text = line_speech(index, true)
        commands << text + "\n" if text != ""
      end
      speak_sequence(SpeechSequence.new(commands))
    end

    # --------------------------------------------------------------- moving

    def move_line(step)
      if @lines.empty?
        play_sound("border")
        return
      end
      target = @cur + step
      if target < 1 || target > @lines.size
        play_sound("border")
        speak_line(false)
        return
      end
      @cur = target
      @col = 1
      speak_line(step > 0)
    end

    def move_char(step)
      unless @cur.between?(1, @lines.size)
        play_sound("border")
        return
      end
      length = @texts[@cur - 1].length
      target = @col + step
      if target < 1
        if @cur > 1
          @cur -= 1
          @col = [@texts[@cur - 1].length, 1].max
        else
          play_sound("border")
          @col = 1
        end
      elsif target > length
        if @cur < @lines.size
          @cur += 1
          @col = 1
        else
          play_sound("border")
          @col = [length, 1].max
        end
      else
        @col = target
      end
      speak_char(@texts[@cur - 1][@col - 1].to_s)
    end

    def speak_char(character)
      return speak(p_("WebBrowser", "blank")) if character == ""
      speak(character)
    end

    def word_starts(text)
      text.to_enum(:scan, /\S+/).map { Regexp.last_match.begin(0) + 1 }
    end

    def move_word(step)
      unless @cur.between?(1, @lines.size)
        play_sound("border")
        return
      end
      starts = word_starts(@texts[@cur - 1])
      target = nil
      if step > 0
        target = starts.find { |start| start > @col }
        if target == nil
          if @cur < @lines.size
            @cur += 1
            target = word_starts(@texts[@cur - 1]).first || 1
          else
            return play_sound("border")
          end
        end
      else
        target = starts.reverse.find { |start| start < @col }
        if target == nil
          if @cur > 1
            @cur -= 1
            target = word_starts(@texts[@cur - 1]).last || 1
          else
            return play_sound("border")
          end
        end
      end
      @col = target
      rest = @texts[@cur - 1][(target - 1)..-1].to_s
      speak(rest[/\S+/] || rest)
    end

    def matcher(kind)
      case kind
      when :heading then ->(n) { n.role == "heading" }
      when :link then ->(n) { n.role == "link" }
      when :button then ->(n) { %w[button ToggleButton PopUpButton].include?(n.role) }
      when :field then ->(n) { FIELDS.include?(n.role) }
      when :edit then ->(n) { EDITABLE.include?(n.role) && (n.role != "combobox" || n.props.key?("editable")) }
      when :combo then ->(n) { %w[combobox listbox].include?(n.role) }
      when :checkbox then ->(n) { %w[checkbox switch].include?(n.role) }
      when :radio then ->(n) { n.role == "radio" }
      when :list then ->(n) { n.role == "list" }
      when :listitem then ->(n) { n.role == "listitem" }
      when :table then ->(n) { TABLES.include?(n.role) }
      when :graphic then ->(n) { %w[image img].include?(n.role) }
      when :landmark then ->(n) { LANDMARKS.include?(n.role) }
      when :quote then ->(n) { n.role == "blockquote" }
      when :separator then ->(n) { n.role == "separator" }
      when :player then ->(n) { %w[Video Audio video audio].include?(n.role) }
      when :focusable then ->(n) { n.props["focusable"] == "true" && known_role?(n.role) }
      else
        level = kind.to_s[/\Aheading(\d)\z/, 1].to_i
        ->(n) { n.role == "heading" && n.props["level"].to_i == level }
      end
    end

    def find_node(match, backward)
      best = nil
      @nodes.each_with_index do |entry, i|
        position = @node_positions[i + 1]
        next if position == nil || !match.call(entry)
        if backward
          next unless (position <=> [@cur, @col]) < 0
          best = [i + 1, position] if best == nil || (position <=> best[1]) > 0
        else
          next unless (position <=> [@cur, @col]) > 0
          best = [i + 1, position] if best == nil || (position <=> best[1]) < 0
        end
      end
      best
    end

    def speak_node(index)
      entry = node(index)
      return if entry == nil
      if %w[heading list table grid treegrid blockquote listitem separator].include?(entry.role) || LANDMARKS.include?(entry.role)
        prefix = %w[heading listitem].include?(entry.role) ? "" : container_text(node_view(entry)) + " "
        speak(prefix + line_speech(@cur, false))
      else
        text = %w[checkbox radio switch textbox searchbox combobox listbox slider spinbutton].include?(entry.role) ? nil : node_text(index)
        speak(describe(node_view(entry), text))
      end
    end

    def quick_navigate(kind, backward)
      found = find_node(matcher(kind), backward)
      if found == nil
        play_sound("border")
        speak(backward ? p_("WebBrowser", "No previous element of this kind") : p_("WebBrowser", "No next element of this kind"))
        return
      end
      @cur, @col = found[1]
      speak_node(found[0])
    end

    def tab_navigate(backward)
      found = find_node(matcher(:focusable), backward)
      return play_sound("border") if found == nil
      @cur, @col = found[1]
      @tab.focus(@nodes[found[0] - 1].backend)
      speak_node(found[0])
    end

    def table_navigate(rows, cols)
      line = @cur.between?(1, @lines.size) ? @lines[@cur - 1] : nil
      if line == nil || line.tbl == 0
        play_sound("border")
        return speak(p_("WebBrowser", "Not in a table"))
      end
      cells = {}
      max_row = 0
      max_col = 0
      @lines.each_with_index do |entry, index|
        next unless entry.tbl == line.tbl
        cells[[entry.row, entry.col]] ||= index + 1
        max_row = [max_row, entry.row].max
        max_col = [max_col, entry.col].max
      end
      row = line.row + rows
      col = line.col + cols
      while row.between?(1, max_row) && col.between?(1, max_col) && !cells.key?([row, col])
        row += rows
        col += cols
      end
      target = cells[[row, col]]
      return play_sound("border") if target == nil
      @cur = target
      @col = 1
      prefix = ""
      if cols != 0
        table = node(line.tbl)
        header = table&.headers&.[](col)
        prefix = "#{header}. " if header.to_s != "" && row > 1
      end
      speak(prefix + (p_("WebBrowser", "row %{row}, column %{column}") % { row: row, column: col }) + " " + line_speech(target, false))
    end

    # ----------------------------------------------------------- activating

    def span_at(line_index, col)
      return nil unless line_index.between?(1, @lines.size)
      spans = @spans[line_index - 1]
      spans.find { |span| span.owner != 0 && span.from <= col && col <= span.to } || spans.find { |span| span.owner != 0 }
    end

    def activate
      span = span_at(@cur, @col)
      if span == nil
        spans = @cur.between?(1, @lines.size) ? @spans[@cur - 1] : []
        source = (spans.find { |entry| entry.from <= @col && @col <= entry.to } || spans.first)&.src
        source.to_i > 0 ? @tab.click(source) : play_sound("border")
        return
      end
      entry = node(span.owner)
      role = entry.role
      if (EDITABLE.include?(role) && role != "combobox") || role == "slider"
        @tab.focus(entry.backend)
        return set_mode(:focus)
      end
      if %w[combobox listbox].include?(role)
        options = @tab.options(entry.backend)
        if options.is_a?(Hash) && !Array(options["items"]).empty? && (options["native"] || role == "listbox")
          items = options["items"].map { |item| item["text"].to_s }
          current = options["items"].index { |item| item["selected"] } || 0
          choice = selector(items + [_("Cancel")], header: describe(node_view(entry)), start_index: current, cancel_index: items.size)
          if choice != nil && choice >= 0 && choice < items.size
            @tab.choose_option(entry.backend, choice)
            speak(items[choice])
            @dirty = true
          end
          return
        end
        @tab.focus(entry.backend)
        return set_mode(:focus)
      end
      ok, = @tab.click(entry.backend)
      return play_sound("border") unless ok
      if %w[checkbox radio switch menuitemcheckbox tab option].include?(role) || entry.props["expanded"].to_s != "" || entry.props["pressed"].to_s != ""
        sleep(0.05)
        fresh = @tab.node_info_for(entry.backend)
        state = fresh == nil ? "" : states(node_view(fresh))
        speak(state) if state != ""
      end
      @dirty = true
    end

    # ----------------------------------------------------------------- mode

    def set_mode(mode)
      return if mode == @mode
      @mode = mode
      speech_stop
      if mode == :focus
        info = @tab.focus_info
        @last_focus = info
        @focus_id = info && info["id"]
        text = p_("WebBrowser", "Focus mode")
        text += ". " + describe(focus_view(info)) if info != nil && info["role"].to_s != ""
        play_sound("editbox_marker")
        speak(text)
      else
        info = @tab.focus_info
        rebuild(true)
        if info != nil && info["id"] != nil
          index = @nodes.index { |entry| entry.backend == info["id"] }
          @cur, @col = @node_positions[index + 1] if index != nil && @node_positions.key?(index + 1)
        end
        play_sound("list_marker")
        speak(p_("WebBrowser", "Browse mode"))
      end
    end

    # ---------------------------------------------------------- browse mode

    def browse_update
      # A key ends reading aloud: the cursor stays where the voice was.
      @say_all_generation = @say_all_generation.to_i + 1 if key_any_pressed?
      main = modifier_held?(:main_modifier)
      shift = raw_key_held?(:key_shift)
      alt = raw_key_held?(:key_alt)
      if key_pressed?(:key_escape)
        close(:closed)
        return
      end
      if main && alt
        if key_pressed?(:key_up) then table_navigate(-1, 0)
        elsif key_pressed?(:key_down) then table_navigate(1, 0)
        elsif key_pressed?(:key_left) then table_navigate(0, -1)
        elsif key_pressed?(:key_right) then table_navigate(0, 1)
        end
        return
      end
      if (action = keyboard_action_pressed?(:text_start, :text_end)) != nil
        return play_sound("border") if @lines.empty?
        @cur = action == :text_start ? 1 : @lines.size
        @col = 1
        return speak_line(action == :text_start)
      end
      if modifier_held?(:word_modifier) && !main && (key_pressed?(:key_left) || key_pressed?(:key_right))
        return move_word(key_pressed?(:key_left) ? -1 : 1)
      end
      return if main || alt
      if key_pressed?(:key_down) then move_line(1)
      elsif key_pressed?(:key_up) then move_line(-1)
      elsif key_pressed?(:key_left) then move_char(-1)
      elsif key_pressed?(:key_right) then move_char(1)
      elsif key_pressed?(:key_home)
        @col = 1
        speak_char(@texts[@cur - 1].to_s[0].to_s) if !@lines.empty?
      elsif key_pressed?(:key_end)
        if !@lines.empty?
          @col = [@texts[@cur - 1].length, 1].max
          speak_char(@texts[@cur - 1][@col - 1].to_s)
        end
      elsif key_pressed?(:key_page_down)
        if !@lines.empty?
          @cur = [@lines.size, @cur + 20].min
          @col = 1
          speak_line(true)
        end
      elsif key_pressed?(:key_page_up)
        if !@lines.empty?
          @cur = [1, @cur - 20].max
          @col = 1
          speak_line(false)
        end
      elsif key_pressed?(:key_enter) || key_pressed?(:key_space)
        activate
      elsif key_pressed?(:key_tab)
        tab_navigate(shift)
      elsif key_pressed?(0x08)
        history_step(shift ? 1 : -1)
      elsif key_pressed?(0x41) && !shift
        say_all
      else
        QUICK_KEYS.each do |key, kind|
          next unless key_pressed?(key)
          quick_navigate(kind, shift)
          break
        end
      end
    end

    # ----------------------------------------------------------- focus mode

    FORWARD_SKIP = [0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0x5D, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x1B].freeze

    def focus_update
      if key_pressed?(:key_escape)
        set_mode(:browse)
        return
      end
      main = modifier_held?(:main_modifier)
      shift = raw_key_held?(:key_shift)
      alt = raw_key_held?(:key_alt)
      modifiers = 0
      modifiers |= 1 if alt
      modifiers |= 2 if modifier_held?(:control)
      modifiers |= 4 if modifier_held?(:command)
      modifiers |= 8 if shift
      characters = getkeychar(nil, true).to_s.chars
      # Control+Alt is AltGr on Windows: those characters are typed text.
      characters = [] if main && !alt
      sent = []
      (8..0xFE).each do |vk|
        next if FORWARD_SKIP.include?(vk) || vk.between?(0x70, 0x87)
        next unless EltenAPI::KeyboardState.pressed?(vk)
        # The context menu shortcuts (copy, paste, address...) stay Klangten's.
        next if main && vk.between?(0x41, 0x5A) && main_shortcut_taken?(vk)
        character = nil
        if vk == 0x0D
          character = "\r"
        elsif !characters.empty? && (vk == 0x20 || vk.between?(0x30, 0x5A) || vk.between?(0x60, 0x6F) || vk.between?(0xBA, 0xE2))
          character = characters.shift
        end
        if @tab.send_key(vk, character, modifiers)
          sent << { vk: vk, char: character, shift: shift, main: main, word: modifier_held?(:word_modifier) }
        end
      end
      characters.each do |character|
        sent << { vk: 0, char: character, shift: shift, main: false, word: false } if @tab.insert_text(character)
      end
      cancel_pending_alt_menu if alt && !sent.empty?
      return if sent.empty?
      speech_stop
      echo(sent)
    end

    def main_shortcut_taken?(vk)
      %w[C X V L R I H B D].include?(vk.chr)
    end

    def echo(sent)
      info = @tab.focus_info
      previous = @last_focus
      @last_focus = info
      return if info == nil
      last = sent.last
      if info["id"] != @focus_id
        @focus_id = info["id"]
        return speak(describe(focus_view(info)))
      end
      if info["edit"].to_i == 1
        value = info["value"].to_s
        start = info["ss"].to_i
        vk = last[:vk]
        if last[:char].to_s != "" && last[:char] != "\r" && !last[:main]
          return speak_char(info["pw"].to_i == 1 ? "*" : last[:char]) if typing_echo?
          return
        end
        case vk
        when 0x08
          old = previous == nil ? "" : previous["value"].to_s
          if old.length > value.length
            speak_char(old[start, old.length - value.length].to_s)
          else
            play_sound("border")
          end
        when 0x2E
          speak_char(value[start].to_s)
        when 0x25, 0x27, 0x24, 0x23
          finish = info["se"]
          if last[:shift] && finish != nil && finish.to_i != start
            speak(value[start...finish.to_i].to_s)
          elsif last[:word] && [0x25, 0x27].include?(vk)
            rest = value[start..-1].to_s
            speak(rest[/\A\s*\S+/] || rest)
          elsif [0x24, 0x23].include?(vk) && info["ml"].to_i == 1
            speak(line_at(value, start))
          else
            speak_char(value[start].to_s)
          end
        when 0x26, 0x28, 0x21, 0x22
          if info["ml"].to_i == 1
            speak(line_at(value, start))
          elsif info["ad"].to_s != "" && (previous == nil || previous["ad"] != info["ad"])
            speak(info["ad"])
          elsif previous != nil && previous["value"] != info["value"]
            speak(value)
          end
        when 0x41
          speak(value) if last[:main]
        end
        return
      end
      if info["ad"].to_s != "" && (previous == nil || previous["ad"] != info["ad"])
        speak(info["ad"])
      elsif previous != nil && previous["axvalue"] != info["axvalue"] && info["axvalue"].to_s != ""
        speak(info["axvalue"])
      elsif previous != nil && previous["name"] != info["name"]
        speak(describe(focus_view(info)))
      else
        now = states(focus_view(info))
        before = previous == nil ? "" : states(focus_view(previous))
        speak(now) if now != before
      end
    end

    def typing_echo?
      [:characters, :characters_and_words].include?(Configuration.typingecho)
    rescue StandardError
      true
    end

    def line_at(value, position)
      offset = 0
      value.split("\n", -1).each do |line|
        return line if position <= offset + line.length
        offset += line.length + 1
      end
      ""
    end

    # --------------------------------------------------------------- history

    def history_step(step, list: false)
      entries, current = @tab.history
      return play_sound("border") if entries.empty?
      if list
        range = step > 0 ? ((current + 1)...entries.size).to_a : (0...current).to_a.reverse
        return play_sound("border") if range.empty?
        labels = range.map { |index| entries[index][:title].to_s == "" ? entries[index][:url] : entries[index][:title] }
        choice = selector(labels + [_("Cancel")], header: step > 0 ? p_("WebBrowser", "Forward") : p_("WebBrowser", "Back"), cancel_index: labels.size)
        return if choice == nil || choice < 0 || choice >= labels.size
        return start_history(entries[range[choice]][:id])
      end
      target = current + step
      return play_sound("border") unless target.between?(0, entries.size - 1)
      start_history(entries[target][:id])
    end

    def start_history(id)
      speech_stop
      @loading = true
      @got_document = false
      @load_started = monotonic
      start_waiting
      return if @tab.history_go(id)
      @loading = false
      stop_waiting
      play_sound("border")
    end

    # ----------------------------------------------------------------- find

    def find(again: false, backward: false)
      query = @last_find
      if !again || query.to_s == ""
        query = input_text(p_("WebBrowser", "Find text on the page"), text: @last_find.to_s, escapable: true, select_all: true)
        return if query.to_s.strip == ""
        @last_find = query
      end
      needle = query.downcase
      count = @lines.size
      return play_sound("border") if count == 0
      step = backward ? -1 : 1
      (0..count).each do |k|
        index = ((@cur - 1 + k * step) % count) + 1
        haystack = @texts[index - 1].downcase
        position = nil
        if backward
          start = 0
          while (hit = haystack.index(needle, start)) != nil
            position = hit + 1 if k != 0 || hit + 1 < @col
            start = hit + 1
          end
        else
          hit = haystack.index(needle, k == 0 ? @col : 0)
          position = hit + 1 if hit != nil
        end
        next if position == nil
        @cur = index
        @col = position
        return speak_line(false)
      end
      play_sound("border")
      speak(p_("WebBrowser", "Text not found"))
    end

    def element_list(kind, title)
      match = kind == :field ? matcher(:field) : matcher(kind)
      items = []
      targets = []
      @nodes.each_with_index do |entry, i|
        next unless match.call(entry) && @node_positions.key?(i + 1)
        label = if entry.role == "heading"
                  "#{entry.props["level"]} #{entry.name.to_s != "" ? entry.name : line_speech(@node_positions[i + 1][0], false)}"
                elsif LANDMARKS.include?(entry.role)
                  container_text(node_view(entry))
                else
                  describe(node_view(entry), node_text(i + 1).to_s != "" ? node_text(i + 1) : entry.name)
                end
        items << label
        targets << i + 1
      end
      if items.empty?
        play_sound("border")
        return speak(p_("WebBrowser", "None found"))
      end
      choice = selector(items + [_("Cancel")], header: title, cancel_index: items.size)
      return if choice == nil || choice < 0 || choice >= items.size
      @cur, @col = @node_positions[targets[choice]]
      speak_node(targets[choice])
    end

    # ----------------------------------------------------------------- menu

    def ask_address
      address = Scene_WebBrowser.ask_address(@url)
      navigate(address) if address != nil
    end

    def close(result)
      return if @closed
      @closed = true
      stop_waiting
      speech_stop
      @on_close.call(result) if @on_close != nil
    end

    def context(menu, submenu = false)
      if @mode == :focus
        menu.option(p_("WebBrowser", "Copy selected text"), nil, "c") do
          text = @tab.selected_text
          if text.to_s == ""
            play_sound("border")
          else
            Clipboard.text = text
            speak(p_("WebBrowser", "Copied"))
          end
        end
        menu.option(p_("WebBrowser", "Cut selected text"), nil, "x") do
          text = @tab.selected_text
          if text.to_s == ""
            play_sound("border")
          else
            Clipboard.text = text
            @tab.send_key(0x2E)
            speak(p_("WebBrowser", "Cut"))
          end
        end
        menu.option(p_("WebBrowser", "Paste"), nil, "v") do
          text = Clipboard.text.to_s.delete("\r")
          text == "" ? play_sound("border") : (@tab.insert_text(text) && speak(p_("WebBrowser", "Pasted")))
        end
        menu.option(p_("WebBrowser", "Browse mode")) { set_mode(:browse) }
      end
      menu.option(p_("WebBrowser", "Enter address..."), nil, "l") { ask_address }
      menu.option(p_("WebBrowser", "Back")) { history_step(-1) }
      menu.option(p_("WebBrowser", "Forward")) { history_step(1) }
      menu.option(p_("WebBrowser", "Back to an earlier page...")) { history_step(-1, list: true) }
      menu.option(p_("WebBrowser", "Reload"), nil, "r") do
        @tab.reload
      end
      menu.option(p_("WebBrowser", "Stop loading")) do
        @tab.stop_loading
        @loading = false
        stop_waiting
      end
      if @mode == :browse
        menu.option(p_("WebBrowser", "Find..."), nil, "f") { find }
        menu.option(p_("WebBrowser", "Find next"), nil, "g") { find(again: true) }
        menu.option(p_("WebBrowser", "Find previous"), nil, "G") { find(again: true, backward: true) }
        menu.option(p_("WebBrowser", "Headings..."), nil, "H") { element_list(:heading, p_("WebBrowser", "Headings")) }
        menu.option(p_("WebBrowser", "Links..."), nil, "K") { element_list(:link, p_("WebBrowser", "Links")) }
        menu.option(p_("WebBrowser", "Form fields..."), nil, "F") { element_list(:field, p_("WebBrowser", "Form fields")) }
        menu.option(p_("WebBrowser", "Landmarks..."), nil, "D") { element_list(:landmark, p_("WebBrowser", "Landmarks")) }
        menu.option(p_("WebBrowser", "Read from here")) { say_all }
        menu.option(p_("WebBrowser", "Focus mode")) { set_mode(:focus) }
        menu.option(p_("WebBrowser", "Copy line"), nil, "c") do
          if @cur.between?(1, @lines.size)
            Clipboard.text = @texts[@cur - 1]
            speak(p_("WebBrowser", "Copied"))
          end
        end
      end
      menu.option(p_("WebBrowser", "Page title and address"), nil, "i") { speak("#{@title}. #{@url}") }
      menu.option(p_("WebBrowser", "Copy page address"), nil, "C") do
        Clipboard.text = @url
        speak(p_("WebBrowser", "Copied"))
      end
      menu.option(p_("WebBrowser", "History..."), nil, "h") do
        url = Scene_WebBrowser.pick_history
        navigate(url) if url != nil
      end
      menu.option(p_("WebBrowser", "Bookmarks..."), nil, "b") do
        url = Scene_WebBrowser.pick_bookmark
        navigate(url) if url != nil
      end
      menu.option(p_("WebBrowser", "Bookmark this page"), nil, "d") do
        if KlangtenWeb.add_bookmark(@url, @title)
          alert(p_("WebBrowser", "The page has been added to your bookmarks."))
        else
          alert(p_("WebBrowser", "This page is already in your bookmarks."))
        end
      end
      menu.option(p_("WebBrowser", "Open in the system browser")) { platform_open_url(@url) if @url.to_s != "" }
      menu.option(p_("WebBrowser", "Open in the text browser")) { close([:text, @url]) }
      menu.option(p_("WebBrowser", "Delete cookies and cache")) do
        if confirm(p_("WebBrowser", "Do you want to delete all cookies and the cache of the browser? You will be signed out of all websites."))
          KlangtenWeb::Chrome.clear_data
          alert(p_("WebBrowser", "Cookies and cache have been deleted."))
        end
      end
      menu.option(p_("WebBrowser", "Keyboard shortcuts")) { Scene_WebBrowser.show_keys }
      menu.option(p_("WebBrowser", "Close the browser")) { close(:closed) }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
