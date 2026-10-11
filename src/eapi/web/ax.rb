# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The reading buffer of the Klangten browser.
#
# Chrome describes a page through its accessibility tree
# (Accessibility.getFullAXTree), the same tree screen readers use. AX.linearize
# turns it into lines, like the virtual buffer of a screen reader:
#
# - elements whose computed CSS display is a block (from DOMSnapshot) start a
#   new line, inline content flows into the current one;
# - links, buttons, menu items and similar elements "own" their text: it stays
#   ordinary text but remembers the element it belongs to;
# - text fields, check boxes, combo boxes and images are "leaves": one piece of
#   text holding their value or name;
# - lists, tables and landmarks are announced when a line enters them.
#
# Roles keep Chrome's names; the browser screen turns them into words in the
# user's language. Node and line references are 1-based (0 = none).

module KlangtenWeb
  module AX
    OWNER_ROLES = %w[link button menuitem menuitemcheckbox menuitemradio tab option treeitem
                     DisclosureTriangle PopUpButton ToggleButton].freeze
    LEAF_ROLES = %w[checkbox radio switch textbox searchbox combobox listbox slider spinbutton progressbar
                    meter ColorWell Date DateTime InputTime image img Video Audio video audio].freeze
    ANNOUNCED = %w[list table grid treegrid navigation main banner contentinfo complementary search dialog
                   alertdialog article blockquote figure menu menubar tablist toolbar tree radiogroup
                   DescriptionList alert].freeze
    NAMED_ANNOUNCED = %w[region form group].freeze
    BLOCKISH = %w[heading listitem cell gridcell columnheader rowheader paragraph blockquote
                  DescriptionListTerm DescriptionListDetail term definition caption code separator].freeze
    VALUE_ROLES = %w[textbox searchbox combobox listbox slider spinbutton progressbar meter Date DateTime InputTime].freeze
    COUNTED = %w[listitem treeitem menuitem menuitemcheckbox menuitemradio tab radio].freeze
    PASSTHROUGH = %w[StaticText InlineTextBox LineBreak RootWebArea WebArea ListMarker Iframe IframePresentational].freeze

    UNSET = -1

    Node = Struct.new(:backend, :role, :name, :value, :desc, :props, :line, :seg, :count, :rows, :cols, :headers, keyword_init: true) do
      def self.blank(**values)
        new(backend: 0, role: "", name: "", value: "", desc: "", props: {}, line: UNSET, seg: 0,
            count: 0, rows: 0, cols: 0, headers: {}, **values)
      end
    end

    Segment = Struct.new(:text, :owner, :leaf, :src)

    class Line
      attr_accessor :segs, :blk, :enter, :tbl, :row, :col

      def initialize
        @segs = []
        @blk = 0
        @enter = []
        @tbl = 0
        @row = 0
        @col = 0
      end

      def text
        @segs.map(&:text).join
      end
    end

    class Document
      attr_accessor :title, :lines, :nodes

      def initialize
        @title = ""
        @lines = []
        @nodes = []
      end
    end

    module_function

    def announced?(role, name)
      ANNOUNCED.include?(role) || (NAMED_ANNOUNCED.include?(role) && name.to_s != "")
    end

    def inline_display?(display)
      display.to_s == "" || display.start_with?("inline") || %w[contents ruby].include?(display)
    end

    def value_string(value)
      case value
      when String then value
      when true then "true"
      when false then "false"
      when nil then ""
      when Float then value == value.floor && value.finite? ? value.to_i.to_s : value.to_s
      else value.to_s
      end
    end

    def value_of(node, key)
      entry = node[key]
      entry.is_a?(Hash) ? value_string(entry["value"]) : ""
    end

    def properties(node)
      out = {}
      Array(node["properties"]).each do |property|
        next unless property.is_a?(Hash)
        name = property["name"].to_s
        next if name == ""
        out[name] = value_string((property["value"] || {})["value"])
      end
      out
    end

    def collapse(text)
      text.to_s.gsub(/[­​﻿]/, "").gsub(/\s+/, " ")
    end

    # nodes: the main tree; frames: backendNodeId of an <iframe> => its nodes;
    # display: backendNodeId => CSS display.
    def linearize(nodes, frames = {}, display = {})
      Walker.new(nodes || [], frames || {}, display || {}).run
    end

    # DOMSnapshot.captureSnapshot(computedStyles: ["display"]) =>
    # {backendNodeId => display} over all documents.
    def display_map(snapshot)
      out = {}
      strings = Array(snapshot["strings"])
      Array(snapshot["documents"]).each do |document|
        backend = Array((document["nodes"] || {})["backendNodeId"])
        layout = document["layout"] || {}
        indexes = Array(layout["nodeIndex"])
        styles = Array(layout["styles"])
        indexes.each_with_index do |node_index, i|
          next unless node_index.is_a?(Integer) && node_index >= 0 && node_index < backend.size
          style = styles[i]
          string_index = style.is_a?(Array) && !style.empty? ? style[0] : -1
          out[backend[node_index]] = strings[string_index] if string_index.is_a?(Integer) && string_index >= 0 && string_index < strings.size
        end
      end
      out
    end

    class Table
      attr_accessor :node, :row, :col, :maxcol, :row_open

      def initialize(node)
        @node = node
        @row = 0
        @col = 0
        @maxcol = 0
        @row_open = false
      end
    end

    class Walker
      def initialize(nodes, frames, display)
        @all = nodes
        @ax = index(nodes)
        @frames = frames
        @display = display
        @doc = Document.new
        @cur = Line.new
        @pending_enter = []
        @blk_stack = []
        @tbl_stack = []
        @depth = 0
      end

      def run
        root = @all.find { |node| node.is_a?(Hash) && !node.key?("parentId") } || @all.first
        walk(root, 0) if root != nil
        newline
        count = @doc.lines.size
        @doc.nodes.each do |node|
          next unless node.line == UNSET
          node.line = [count - 1, 0].max
          node.seg = 0
        end
        @doc
      end

      private

      def index(nodes)
        out = {}
        nodes.each { |node| out[node["nodeId"]] = node if node.is_a?(Hash) && node["nodeId"] != nil }
        out
      end

      def block?(backend)
        display = @display[backend]
        display != nil && !AX.inline_display?(display)
      end

      def node_at(index)
        @doc.nodes[index - 1]
      end

      def newline
        segs = @cur.segs
        until segs.empty?
          last = segs.last
          if last.leaf || last.owner != 0
            last.text = last.text.rstrip
            break
          end
          trimmed = last.text.rstrip
          if trimmed == ""
            segs.pop
          else
            last.text = trimmed
            break
          end
        end
        @doc.lines << @cur if segs.any? { |seg| seg.leaf || seg.owner != 0 || seg.text != "" }
        @cur = Line.new
      end

      def begin_line_if_needed
        return unless @cur.segs.empty?
        @cur.blk = @blk_stack.last || 0
        @cur.enter = @pending_enter
        @pending_enter = []
        line_index = @doc.lines.size
        (@cur.enter + @blk_stack).each do |entry|
          node_at(entry).line = line_index if entry > 0 && node_at(entry).line == UNSET
        end
        table = @tbl_stack.last
        return if table == nil
        if table.row_open && table.col > 0
          table.row += 1
          table.row_open = false
        end
        if table.row > 0 && table.col > 0
          @cur.tbl = table.node
          @cur.row = table.row
          @cur.col = table.col
        end
      end

      def push_text(text, owner, src)
        piece = AX.collapse(text)
        piece = piece.lstrip if @cur.segs.empty?
        return if piece == ""
        begin_line_if_needed
        last = @cur.segs.last
        if last != nil
          glue = last.owner != owner || last.leaf
          last_space = last.text.end_with?(" ")
          piece = " " + piece if glue && !last_space && !piece.start_with?(" ")
          piece = piece[1..-1] if last_space && piece.start_with?(" ")
        end
        if owner != 0 && node_at(owner).line == UNSET
          node = node_at(owner)
          node.line = @doc.lines.size
          node.seg = @cur.segs.sum { |seg| seg.text.length } + (piece.start_with?(" ") ? 1 : 0)
        end
        @cur.segs << Segment.new(piece, owner, false, src)
      end

      def push_leaf(node_index, text, src)
        begin_line_if_needed
        piece = AX.collapse(text).strip
        last = @cur.segs.last
        piece = " " + piece if last != nil && last.text != "" && !last.text.end_with?(" ")
        node = node_at(node_index)
        node.line = @doc.lines.size
        node.seg = @cur.segs.sum { |seg| seg.text.length } + (piece.start_with?(" ") ? 1 : 0)
        @cur.segs << Segment.new(piece, node_index, true, src)
      end

      def add_node(raw, role)
        @doc.nodes << Node.blank(
          backend: raw["backendDOMNodeId"].to_i,
          role: role,
          name: AX.collapse(AX.value_of(raw, "name")).strip,
          value: AX.collapse(AX.value_of(raw, "value")).strip,
          desc: AX.collapse(AX.value_of(raw, "description")).strip,
          props: AX.properties(raw)
        )
        @doc.nodes.size
      end

      def children(raw)
        Array(raw["childIds"]).map { |id| @ax[id] }.compact
      end

      def walk(raw, owner)
        @depth += 1
        walk_inner(raw, owner) if @depth <= 400
      ensure
        @depth -= 1
      end

      def role_of(raw)
        (raw["role"] || {})["value"].to_s
      end

      # A contenteditable region (and designMode) reaches Chrome's tree as a
      # "generic" element that is only marked editable: it becomes a text box,
      # otherwise focus mode could never be entered there.
      def editable_role(raw, role)
        return role if LEAF_ROLES.include?(role) || OWNER_ROLES.include?(role) || PASSTHROUGH.include?(role)
        props = AX.properties(raw)
        if %w[plaintext richtext].include?(props["editable"]) && props["focusable"] == "true"
          (raw["properties"] ||= []) << { "name" => "multiline", "value" => { "value" => props["editable"] == "richtext" } }
          return "textbox"
        end
        role
      end

      def walk_inner(raw, owner)
        role = role_of(raw)
        backend = raw["backendDOMNodeId"].to_i
        ignored = raw["ignored"] == true
        if %w[Iframe IframePresentational].include?(role) || (ignored && @frames.key?(backend))
          frame_nodes = @frames[backend]
          if frame_nodes != nil && !frame_nodes.empty?
            newline
            saved = @ax
            @ax = index(frame_nodes)
            walk(frame_nodes.first, owner)
            @ax = saved
            newline
          end
          return
        end
        if ignored
          children(raw).each { |child| walk(child, owner) }
          return
        end
        name = AX.value_of(raw, "name")
        block = block?(backend)

        case role
        when "InlineTextBox"
          return
        when "StaticText"
          push_text(name, owner, backend)
          return
        when "LineBreak"
          in_cell = !@tbl_stack.empty? && @tbl_stack.last.col > 0
          if owner != 0 || in_cell
            last = @cur.segs.last
            last.text += " " if last != nil && !last.text.end_with?(" ") && !last.leaf
          else
            newline
          end
          return
        when "RootWebArea", "WebArea"
          @doc.title = AX.collapse(name).strip if @doc.title == "" && @depth <= 1
          children(raw).each { |child| walk(child, owner) }
          return
        when "ListMarker"
          push_text(name.strip + " ", owner, backend) if name.strip != ""
          return
        end

        role = editable_role(raw, role)
        if LEAF_ROLES.include?(role)
          image = %w[image img].include?(role)
          if image && name.strip == ""
            children(raw).each { |child| walk(child, owner) }
            return
          end
          newline if block
          if image && owner != 0
            push_text(name, owner, backend)
          else
            node_index = add_node(raw, role)
            node = node_at(node_index)
            text = VALUE_ROLES.include?(role) && node.value != "" ? node.value : node.name
            push_leaf(node_index, text, backend)
          end
          newline if block
          return
        end

        if OWNER_ROLES.include?(role)
          newline if block
          node_index = add_node(raw, role)
          lines_before = @doc.lines.size
          segs_before = @cur.segs.size
          children(raw).each { |child| walk(child, node_index) }
          produced = @doc.lines.size != lines_before || @cur.segs.size != segs_before
          unless produced
            label = node_at(node_index).name
            if label == "" && role == "link"
              path = node_at(node_index).props["url"].to_s.split(/[?#]/).first.to_s.sub(/\/+\z/, "")
              label = path.split("/").last.to_s
              label = "" if label.include?(":")
            end
            label != "" ? push_text(label, node_index, backend) : push_leaf(node_index, "", backend)
          end
          newline if block
          return
        end

        announced = AX.announced?(role, name.strip)
        blockish = BLOCKISH.include?(role)
        starts_block = block || blockish || announced
        newline if starts_block
        node_index = 0
        node_index = add_node(raw, role) if announced || blockish || %w[row table grid treegrid].include?(role)
        if role == "separator"
          push_leaf(node_index, "", backend)
          newline
          return
        end
        if announced
          if %w[list tree menu menubar tablist radiogroup].include?(role)
            node_at(node_index).count = children(raw).count { |child| child["ignored"] != true && COUNTED.include?(role_of(child)) }
          end
          @pending_enter << node_index
        end
        table = %w[table grid treegrid].include?(role)
        @tbl_stack << Table.new(node_index) if table
        if role == "row" && !@tbl_stack.empty?
          @tbl_stack.last.row_open = true
          @tbl_stack.last.col = 0
        end
        if %w[cell gridcell columnheader rowheader].include?(role) && !@tbl_stack.empty?
          current = @tbl_stack.last
          current.col += 1
          current.maxcol = [current.maxcol, current.col].max
          if role == "columnheader"
            label = AX.collapse(name).strip
            node_at(current.node).headers[current.col] ||= label if current.node > 0 && label != ""
          end
        end
        @blk_stack << node_index if blockish
        children(raw).each { |child| walk(child, owner) }
        @blk_stack.pop if blockish
        newline if starts_block
        if table && !@tbl_stack.empty?
          finished = @tbl_stack.pop
          if finished.node > 0
            node_at(finished.node).rows = finished.row
            node_at(finished.node).cols = finished.maxcol
          end
        end
        @pending_enter.delete(node_index) if announced
      end
    end
  end
end
