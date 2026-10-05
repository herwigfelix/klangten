# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Plain text from documents, for reading them in the file manager.
#
# KlangtenDocuments.extract(path) returns the text of a plain text, HTML,
# DOCX, ODT, EPUB, RTF or PDF file. Everything is done in Ruby with the gems
# the core already ships (rubyzip, Nokogiri) and the standard library (zlib,
# openssl, digest); there is no external program and no vendored gem, so it
# behaves the same in a source checkout, in the embedded launcher builds and on
# iOS/Android.
#
# The PDF reader is deliberately small: it reads the objects (also from object
# streams and with a broken cross-reference table), follows the page tree and
# interprets the text operators of the content streams with ToUnicode maps,
# the standard single-byte encodings and /Differences. Documents protected with
# an empty user password (the common "no printing/copying" kind) are decrypted
# (RC4, AES-128, AES-256); anything that needs a password, scanned pages
# without a text layer and fonts without any Unicode information give an
# EncryptedDocument error or less text, never a crash.
#
# The work may take a while for large files: call it through
# EltenAPI::Tasks.run and pass the task's token so Escape interrupts it.

require "zlib"
require "digest"
require "openssl"

module KlangtenDocuments
  class Error < StandardError; end
  class UnsupportedFormat < Error; end
  class EncryptedDocument < Error; end
  class MalformedDocument < Error; end

  EXTENSIONS = %w[.txt .htm .html .xhtml .docx .odt .epub .rtf .pdf].freeze
  # Upper bounds against corrupt or hostile files (zip bombs, huge PDFs).
  MAX_FILE_BYTES = 200 * 1024 * 1024
  MAX_ENTRY_BYTES = 64 * 1024 * 1024
  MAX_TEXT_CHARACTERS = 20_000_000

  class << self
    # True for the file types extract understands (by extension).
    def supported?(path)
      EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    # Text of a document as a UTF-8 String with "\n" line breaks.
    # token: an optional EltenAPI::Tasks::CancellationToken.
    def extract(path, token: nil)
      path = path.to_s
      raise Error, "File not found" if !File.file?(path)
      raise Error, "File too large" if File.size(path) > MAX_FILE_BYTES
      kind = detect(path)
      text = case kind
      when :txt then decode_text(File.binread(path))
      when :html then html_to_text(decode_html(File.binread(path)))
      when :docx then docx_to_text(path)
      when :odt then odt_to_text(path)
      when :epub then epub_to_text(path, token)
      when :rtf then rtf_to_text(File.binread(path))
      when :pdf then PdfReader.new(File.binread(path), token: token).text
      else raise UnsupportedFormat, "Unsupported document type"
      end
      tidy(text)
    end

    # Decodes the bytes of a text file: UTF-8 or UTF-16 with byte order mark,
    # BOM-less UTF-8, UTF-16 recognised by its zero bytes, otherwise Windows-1252.
    def decode_text(data)
      data = data.to_s.b
      if data.start_with?("\xEF\xBB\xBF".b)
        return utf8(data.byteslice(3..).to_s.force_encoding(Encoding::UTF_8))
      elsif data.start_with?("\xFF\xFE".b)
        return convert(data.byteslice(2..).to_s, Encoding::UTF_16LE)
      elsif data.start_with?("\xFE\xFF".b)
        return convert(data.byteslice(2..).to_s, Encoding::UTF_16BE)
      end
      utf16 = utf16_without_bom(data)
      return convert(data, utf16) if utf16 != nil
      text = data.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?
      convert(data, Encoding::Windows_1252)
    end

    # Text of an HTML or XHTML document: block elements become lines, table
    # cells are separated by tabs, scripts and styles are left out.
    def html_to_text(html)
      require "nokogiri"
      document = Nokogiri::HTML(html.to_s)
      body = document.at("body") || document.root
      return "" if body == nil
      writer = TextWriter.new
      html_node(body, writer, false)
      writer.text
    end

    # Text of a .docx file (word/document.xml, then footnotes and endnotes).
    def docx_to_text(path)
      parts = []
      with_zip(path) do |zip|
        ["word/document.xml", "word/footnotes.xml", "word/endnotes.xml"].each do |name|
          xml = zip_read(zip, name)
          next if xml == nil
          writer = TextWriter.new
          docx_node(xml_document(xml).root, writer)
          parts << writer.text
        end
      end
      raise MalformedDocument, "No document part" if parts.empty?
      parts.reject { |part| part.strip == "" }.join("\n\n")
    end

    # Text of an OpenDocument text file (content.xml).
    def odt_to_text(path)
      xml = with_zip(path) { |zip| zip_read(zip, "content.xml") }
      raise MalformedDocument, "No content.xml" if xml == nil
      writer = TextWriter.new
      odt_node(xml_document(xml).root, writer)
      writer.text
    end

    # Text of an EPUB book: the XHTML documents in the order of the spine.
    def epub_to_text(path, token = nil)
      parts = []
      with_zip(path) do |zip|
        container = zip_read(zip, "META-INF/container.xml")
        raise MalformedDocument, "No container.xml" if container == nil
        rootfile = xml_document(container).xpath("//*[local-name()='rootfile']").first
        opf_path = rootfile == nil ? nil : rootfile["full-path"].to_s
        raise MalformedDocument, "No package document" if opf_path.to_s == ""
        opf = zip_read(zip, opf_path)
        raise MalformedDocument, "No package document" if opf == nil
        package = xml_document(opf)
        base = File.dirname(opf_path)
        base = "" if base == "."
        items = {}
        package.xpath("//*[local-name()='manifest']/*[local-name()='item']").each do |item|
          items[item["id"].to_s] = [item["href"].to_s, item["media-type"].to_s]
        end
        hrefs = package.xpath("//*[local-name()='spine']/*[local-name()='itemref']").filter_map do |ref|
          next if ref["linear"].to_s == "no"
          items[ref["idref"].to_s]
        end
        # A spine-less package still has its documents in the manifest.
        hrefs = items.values.select { |_href, type| type.include?("html") } if hrefs.empty?
        hrefs.each do |href, _type|
          token.raise_if_cancelled! if token != nil
          name = zip_join(base, href)
          data = zip_read(zip, name)
          next if data == nil
          text = html_to_text(decode_html(data))
          parts << text if text.strip != ""
        end
      end
      parts.join("\n\n")
    end

    # Text of an RTF document. Destinations which are not text (fonts, colours,
    # styles, pictures, document information, field instructions) are skipped;
    # table cells are separated by tabs, rows end a line.
    def rtf_to_text(data)
      RtfReader.new(data.to_s.b).text
    end

    private

    def detect(path)
      ext = File.extname(path).downcase
      kind = {
        ".txt" => :txt, ".htm" => :html, ".html" => :html, ".xhtml" => :html,
        ".docx" => :docx, ".odt" => :odt, ".epub" => :epub, ".rtf" => :rtf, ".pdf" => :pdf
      }[ext]
      head = File.binread(path, 8).to_s.b
      return :pdf if head.start_with?("%PDF")
      return :rtf if head.start_with?("{\\rtf")
      kind
    end

    def utf8(text)
      text.valid_encoding? ? text : text.encode(Encoding::UTF_8, Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def convert(data, encoding)
      data.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def utf16_without_bom(data)
      sample = data.byteslice(0, 4096).to_s
      return nil if sample.bytesize < 4
      even = 0
      odd = 0
      sample.bytes.each_with_index { |byte, index| byte == 0 ? (index.even? ? even += 1 : odd += 1) : nil }
      half = sample.bytesize / 2
      return Encoding::UTF_16LE if odd > half * 0.4 && even < half * 0.05
      return Encoding::UTF_16BE if even > half * 0.4 && odd < half * 0.05
      nil
    end

    # HTML files declare their charset in a meta tag; Nokogiri gets a UTF-8
    # string, so the bytes are decoded here first.
    def decode_html(data)
      data = data.to_s.b
      return decode_text(data) if data.start_with?("\xEF\xBB\xBF".b, "\xFF\xFE".b, "\xFE\xFF".b)
      head = data.byteslice(0, 2048).to_s
      charset = head[/<\?xml[^>]*encoding=["']([A-Za-z0-9_\-]+)/i, 1] || head[/charset=["']?([A-Za-z0-9_\-]+)/i, 1]
      if charset != nil && charset.downcase !~ /\Autf-?8\z/
        encoding = Encoding.find(charset) rescue nil
        return convert(data, encoding) if encoding != nil
      end
      decode_text(data)
    end

    def tidy(text)
      text = text.to_s
      text = text[0, MAX_TEXT_CHARACTERS] if text.length > MAX_TEXT_CHARACTERS
      text = text.gsub(/\r\n?/, "\n").tr(" ", " ").delete("­﻿")
      lines = text.split("\n", -1).map(&:rstrip)
      lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
    end

    # ------------------------------------------------------------------ zip

    def with_zip(path)
      require "zip"
      Zip::File.open(path) { |zip| yield zip }
    rescue Zip::Error => e
      raise MalformedDocument, "Damaged archive: #{e.message}"
    end

    def zip_entry(zip, name)
      entry = zip.find_entry(name) rescue nil
      return entry if entry != nil
      # rubyzip keeps names as raw bytes; compare bytes, ignoring ASCII case.
      wanted = name.to_s.b.downcase
      zip.entries.find { |item| item.name.to_s.b.downcase == wanted }
    end

    def zip_read(zip, name)
      entry = zip_entry(zip, name)
      return nil if entry == nil || entry.directory?
      raise MalformedDocument, "Archive entry too large" if entry.size.to_i > MAX_ENTRY_BYTES
      stream = entry.get_input_stream
      data = stream.read(MAX_ENTRY_BYTES + 1).to_s
      raise MalformedDocument, "Archive entry too large" if data.bytesize > MAX_ENTRY_BYTES
      data.b
    ensure
      stream.close if stream.respond_to?(:close) rescue nil
    end

    def zip_join(base, href)
      href = href.to_s.split("#", 2)[0].to_s
      href = href.gsub(/%([0-9A-Fa-f]{2})/) { [$1].pack("H2") }.force_encoding(Encoding::UTF_8)
      parts = (base.to_s == "" ? [] : base.split("/")) + href.split("/")
      result = []
      parts.each do |part|
        next if part == "" || part == "."
        part == ".." ? result.pop : result << part
      end
      result.join("/")
    end

    def xml_document(data)
      require "nokogiri"
      Nokogiri::XML(data.to_s) { |config| config.nonet.recover }
    end

    # ----------------------------------------------------------------- html

    HTML_SKIP = %w[script style head noscript template svg math object iframe select].freeze
    HTML_BLOCK = %w[
      p div section article aside header footer nav main h1 h2 h3 h4 h5 h6 ul ol dl dt dd
      blockquote pre address figure figcaption table thead tbody tfoot caption form fieldset
      legend hr details summary center
    ].freeze

    def html_node(node, writer, pre)
      node.children.each do |child|
        if child.text? || child.cdata?
          pre ? writer.raw(child.text) : writer.inline(child.text)
          next
        end
        next if !child.element?
        name = child.name.downcase
        next if HTML_SKIP.include?(name)
        case name
        when "br"
          writer.line_break
        when "img"
          alt = child["alt"].to_s.strip
          writer.inline(" #{alt} ") if alt != ""
        when "li"
          writer.block
          writer.inline("- ")
          html_node(child, writer, pre)
          writer.block
        when "tr"
          writer.block
          html_node(child, writer, pre)
          writer.end_row
        when "td", "th"
          writer.cell_start
          html_node(child, writer, pre)
          writer.cell
        else
          block = HTML_BLOCK.include?(name)
          writer.block if block
          writer.paragraph if name =~ /\Ah[1-6]\z/
          html_node(child, writer, pre || name == "pre")
          writer.block if block
        end
      end
    end

    # ----------------------------------------------------------------- docx

    def docx_node(node, writer)
      return if node == nil
      node.children.each do |child|
        next if !child.element?
        case child.name
        when "p"
          writer.block
          docx_node(child, writer)
          writer.block
        when "t"
          writer.raw(child.text)
        when "tab"
          writer.raw("\t") if child.parent != nil && child.parent.name == "r"
        when "br", "cr"
          writer.line_break
        when "noBreakHyphen"
          writer.raw("-")
        when "tr"
          writer.block
          docx_node(child, writer)
          writer.end_row
        when "tc"
          writer.cell_start
          docx_node(child, writer)
          writer.cell
        when "delText", "instrText", "pPr", "rPr", "sectPr", "tblPr", "trPr", "tcPr", "drawing", "pict", "object", "footnoteRef", "endnoteRef"
          next
        else
          docx_node(child, writer)
        end
      end
    end

    # ------------------------------------------------------------------ odt

    def odt_node(node, writer, in_paragraph = false)
      return if node == nil
      node.children.each do |child|
        if child.text?
          # White space between elements outside paragraphs is only layout.
          writer.raw(child.text.gsub(/\s+/, " ")) if in_paragraph
          next
        end
        next if !child.element?
        case child.name
        when "p", "h"
          writer.block
          odt_node(child, writer, true)
          writer.block
        when "s"
          count = [child["c"].to_i, 1].max
          writer.raw(" " * [count, 200].min)
        when "tab"
          writer.raw("\t")
        when "line-break"
          writer.line_break
        when "table-row"
          writer.block
          odt_node(child, writer)
          writer.end_row
        when "table-cell", "covered-table-cell"
          writer.cell_start
          odt_node(child, writer)
          writer.cell
        when "note-citation", "annotation", "tracked-changes", "sequence-decls", "forms", "font-face-decls", "automatic-styles", "scripts"
          next
        else
          odt_node(child, writer, in_paragraph)
        end
      end
    end
  end

  # Collects text with block and table structure. Inline text collapses white
  # space like a browser; raw text is taken as is (XML text runs).
  class TextWriter
    def initialize
      @out = +""
      @in_cell = false
    end

    def text
      @out.dup
    end

    def raw(value)
      @out << value.to_s
    end

    def inline(value)
      value = value.to_s.gsub(/[ \t\r\n\f ]+/, " ")
      return if value == ""
      value = value.lstrip if @out.end_with?("\n", "\t", " ") || @out.empty?
      @out << value
    end

    def line_break
      @out << "\n"
    end

    # Starts a new line unless already at the start of one. Inside a table cell
    # paragraphs are separated by a space instead, to keep the row on one line.
    def block
      return if @out.empty?
      if @in_cell
        @out << " " if !@out.end_with?(" ", "\t")
      else
        @out.sub!(/ +\z/, "")
        @out << "\n" if !@out.end_with?("\n")
      end
    end

    def paragraph
      block
      @out << "\n" if !@out.empty? && !@out.end_with?("\n\n")
    end

    def cell_start
      @in_cell = true
    end

    def cell
      @in_cell = false
      @out.sub!(/ +\z/, "")
      @out << "\t"
    end

    def end_row
      @in_cell = false
      @out.sub!(/[ \t]+\z/, "")
      @out << "\n"
    end
  end

  # Strips an RTF document down to its text.
  class RtfReader
    SKIP_DESTINATIONS = %w[
      fonttbl colortbl stylesheet info pict object header footer headerl headerr headerf
      footerl footerr footerf ftnsep ftnsepc aftnsep aftnsepc themedata colorschememapping
      datastore latentstyles listtable listoverridetable rsidtbl generator xmlnstbl mmathPr
      fldinst filetbl revtbl pgdsctbl xe tc bkmkstart bkmkend nonshppict userprops docvar
      operator author title subject keywords comment
    ].freeze
    SYMBOLS = {
      "emdash" => "—", "endash" => "–", "bullet" => "•", "lquote" => "‘",
      "rquote" => "’", "ldblquote" => "“", "rdblquote" => "”", "emspace" => " ",
      "enspace" => " ", "qmspace" => " "
    }.freeze

    def initialize(data)
      @data = data
      @out = +""
      @pending = "".b
    end

    def text
      state = { skip: false, uc: 1 }
      stack = []
      codepage = Encoding::Windows_1252
      skip_chars = 0
      group_start = false
      pos = 0
      size = @data.bytesize
      while pos < size
        char = @data.getbyte(pos)
        if char == 0x7B # {
          flush(codepage)
          stack << state.dup
          group_start = true
          pos += 1
          next
        elsif char == 0x7D # }
          flush(codepage)
          state = stack.pop || { skip: false, uc: 1 }
          skip_chars = 0
          pos += 1
          next
        elsif char == 0x5C # backslash
          nxt = @data.getbyte(pos + 1)
          if nxt == nil
            break
          elsif letter?(nxt)
            start = pos + 1
            stop = start
            stop += 1 while stop < size && letter?(@data.getbyte(stop))
            word = @data.byteslice(start, stop - start)
            num_start = stop
            stop += 1 if stop < size && @data.getbyte(stop) == 0x2D
            stop += 1 while stop < size && digit?(@data.getbyte(stop))
            number = stop > num_start ? @data.byteslice(num_start, stop - num_start).to_i : nil
            number = nil if stop == num_start + 1 && @data.getbyte(num_start) == 0x2D
            stop += 1 if stop < size && @data.getbyte(stop) == 0x20
            pos = stop
            if word != "bin" && word != "u" && skip_chars > 0
              skip_chars -= 1
              group_start = false
              next
            end
            case word
            when "bin"
              pos += number.to_i if number.to_i > 0
            when "u"
              flush(codepage)
              value = number.to_i
              value += 65536 if value < 0
              emit([value].pack("U"), state) rescue nil
              skip_chars = state[:uc]
            when "uc"
              state[:uc] = number.to_i
            when "ansicpg"
              codepage = (Encoding.find("CP#{number}") rescue Encoding::Windows_1252)
            when "par", "line", "sect", "page", "outlinelevel"
              flush(codepage)
              emit("\n", state) if word != "outlinelevel"
            when "tab", "cell", "nestcell"
              flush(codepage)
              emit("\t", state)
            when "row", "nestrow"
              flush(codepage)
              @out.sub!(/[ \t]+\z/, "") if !state[:skip]
              emit("\n", state)
            else
              if SYMBOLS.key?(word)
                flush(codepage)
                emit(SYMBOLS[word], state)
              elsif SKIP_DESTINATIONS.include?(word) && group_start
                state[:skip] = true
              end
            end
            group_start = false
            next
          else
            pos += 2
            case nxt
            when 0x27 # \'hh
              hex = @data.byteslice(pos, 2).to_s
              pos += 2
              if skip_chars > 0
                skip_chars -= 1
              elsif !state[:skip] && hex.match?(/\A[0-9A-Fa-f]{2}\z/)
                @pending << [hex].pack("H2")
              end
            when 0x2A # \*
              state[:skip] = true
            when 0x5C, 0x7B, 0x7D
              flush(codepage)
              emit(nxt.chr, state)
            when 0x7E # \~
              flush(codepage)
              emit(" ", state)
            when 0x5F # \_
              flush(codepage)
              emit("-", state)
            when 0x0A, 0x0D
              flush(codepage)
              emit("\n", state)
            end
            group_start = false
            next
          end
        elsif char == 0x0A || char == 0x0D
          pos += 1
          next
        end
        group_start = false
        if skip_chars > 0
          skip_chars -= 1
        elsif !state[:skip]
          @pending << char.chr
        end
        pos += 1
      end
      flush(codepage)
      @out
    end

    private

    def letter?(byte)
      byte != nil && ((byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A))
    end

    def digit?(byte)
      byte != nil && byte >= 0x30 && byte <= 0x39
    end

    def emit(value, state)
      @out << value if !state[:skip]
    end

    def flush(codepage)
      return if @pending.empty?
      @out << @pending.force_encoding(codepage).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      @pending = "".b
    end
  end

  # A small PDF text extractor (see the comment at the top of the file).
  class PdfReader
    Ref = Struct.new(:num, :gen)
    Stream = Struct.new(:dict, :raw, :num, :gen)
    Keyword = Struct.new(:name)

    WHITESPACE = [0, 9, 10, 12, 13, 32].freeze
    DELIMITERS = "()<>[]{}/%".bytes.freeze
    MAX_DEPTH = 12
    PASSWORD_PADDING = [
      "28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A"
    ].pack("H*").freeze

    def initialize(data, token: nil)
      @data = data.b
      @token = token
      @objects = {}
      @streams_seen = {}
      @trailer = {}
      @crypt = nil
      @fonts = {}
      raise MalformedDocument, "Not a PDF file" if !@data.include?("%PDF")
      scan_objects
      setup_encryption
      expand_object_streams
    end

    def text
      pages = page_list
      parts = []
      pages.each_with_index do |page, index|
        @token.raise_if_cancelled! if @token != nil
        page_text = page_text(page)
        parts << page_text if page_text.strip != ""
      end
      parts.join("\n\n")
    end

    private

    # ------------------------------------------------------------- objects

    def scan_objects
      pos = 0
      pattern = /(\d{1,10})[ \t\r\n\f\0]+(\d{1,5})[ \t\r\n\f\0]+obj\b/
      while (match = pattern.match(@data, pos))
        num = match[1].to_i
        gen = match[2].to_i
        start = match.end(0)
        begin
          object, after = parse_object(@data, start)
          after = skip_ws(@data, after)
          if object.is_a?(Hash) && @data.byteslice(after, 6) == "stream"
            raw, after = read_stream_data(object, after + 6)
            object = Stream.new(object, raw, num, gen)
          end
          @objects[num] = object
          pos = [after, start].max
        rescue StandardError
          pos = start
        end
      end
      @data.scan(/trailer[\s\0]*<</) do
        offset = Regexp.last_match.end(0) - 2
        dict, = parse_object(@data, offset) rescue nil
        @trailer.merge!(dict) if dict.is_a?(Hash)
      end
      @objects.each_value do |object|
        next if !object.is_a?(Stream) || object.dict[:Type] != :XRef
        object.dict.each { |key, value| @trailer[key] = value if [:Root, :Encrypt, :ID, :Info].include?(key) }
      end
    end

    def read_stream_data(dict, pos)
      pos += 1 if @data.getbyte(pos) == 13
      pos += 1 if @data.getbyte(pos) == 10
      length = dict[:Length]
      if length.is_a?(Integer) && length >= 0 && pos + length <= @data.bytesize
        tail = @data.byteslice(pos + length, 32).to_s
        if tail.lstrip.start_with?("endstream")
          return [@data.byteslice(pos, length), pos + length + tail.index("endstream") + 9]
        end
      end
      stop = @data.index("endstream", pos)
      raise MalformedDocument, "Unterminated stream" if stop == nil
      raw = @data.byteslice(pos, stop - pos)
      raw = raw.chomp("\n").chomp("\r") if raw.end_with?("\n", "\r")
      [raw, stop + 9]
    end

    def expand_object_streams
      @objects.values.each do |object|
        next if !object.is_a?(Stream) || object.dict[:Type] != :ObjStm
        data = decode_stream(object) rescue nil
        next if data == nil
        first = resolve(object.dict[:First]).to_i
        count = resolve(object.dict[:N]).to_i
        header = data.byteslice(0, first).to_s.split(/[\s\0]+/).reject(&:empty?).map(&:to_i)
        count.times do |index|
          num = header[index * 2]
          offset = header[index * 2 + 1]
          next if num == nil || offset == nil || @objects.key?(num)
          begin
            value, = parse_object(data, first + offset)
            @objects[num] = value
          rescue StandardError
            next
          end
        end
      end
    end

    def resolve(value, depth = 0)
      while value.is_a?(Ref) && depth < 32
        value = @objects[value.num]
        depth += 1
      end
      value
    end

    def dict_of(value)
      value = resolve(value)
      return value.dict if value.is_a?(Stream)
      value.is_a?(Hash) ? value : {}
    end

    # -------------------------------------------------------------- parser

    def skip_ws(data, pos)
      size = data.bytesize
      while pos < size
        byte = data.getbyte(pos)
        if WHITESPACE.include?(byte)
          pos += 1
        elsif byte == 37 # %
          pos += 1 while pos < size && data.getbyte(pos) != 10 && data.getbyte(pos) != 13
        else
          break
        end
      end
      pos
    end

    def parse_object(data, pos, depth = 0)
      raise MalformedDocument, "Nesting too deep" if depth > 64
      pos = skip_ws(data, pos)
      byte = data.getbyte(pos)
      raise MalformedDocument, "Unexpected end" if byte == nil
      case byte
      when 60 # <
        if data.getbyte(pos + 1) == 60
          parse_dict(data, pos + 2, depth)
        else
          stop = data.index(">", pos)
          raise MalformedDocument, "Bad hex string" if stop == nil
          hex = data.byteslice(pos + 1, stop - pos - 1).gsub(/[^0-9A-Fa-f]/, "")
          hex << "0" if hex.size.odd?
          [[hex].pack("H*"), stop + 1]
        end
      when 91 # [
        array = []
        pos += 1
        loop do
          pos = skip_ws(data, pos)
          raise MalformedDocument, "Unterminated array" if pos >= data.bytesize
          if data.getbyte(pos) == 93
            pos += 1
            break
          end
          value, pos = parse_object(data, pos, depth + 1)
          array << value
        end
        [array, pos]
      when 40 # (
        parse_literal(data, pos + 1)
      when 47 # /
        parse_name(data, pos + 1)
      else
        parse_atom(data, pos)
      end
    end

    def parse_dict(data, pos, depth)
      dict = {}
      loop do
        pos = skip_ws(data, pos)
        raise MalformedDocument, "Unterminated dictionary" if pos >= data.bytesize
        if data.getbyte(pos) == 62 && data.getbyte(pos + 1) == 62
          return [dict, pos + 2]
        end
        key, pos = parse_object(data, pos, depth + 1)
        value, pos = parse_object(data, pos, depth + 1)
        dict[key.to_sym] = value if key.is_a?(Symbol) || key.is_a?(String)
      end
    end

    def parse_literal(data, pos)
      out = "".b
      level = 1
      size = data.bytesize
      while pos < size
        byte = data.getbyte(pos)
        pos += 1
        case byte
        when 92 # backslash
          nxt = data.getbyte(pos)
          pos += 1
          case nxt
          when 110 then out << "\n"
          when 114 then out << "\r"
          when 116 then out << "\t"
          when 98 then out << "\b"
          when 102 then out << "\f"
          when 13
            pos += 1 if data.getbyte(pos) == 10
          when 10
            nil
          when 48..55
            digits = nxt.chr
            2.times do
              d = data.getbyte(pos)
              break if d == nil || d < 48 || d > 55
              digits << d.chr
              pos += 1
            end
            out << (digits.to_i(8) & 0xFF).chr
          when nil
            break
          else
            out << nxt.chr
          end
        when 40
          level += 1
          out << byte.chr
        when 41
          level -= 1
          return [out, pos] if level == 0
          out << byte.chr
        else
          out << byte.chr
        end
      end
      [out, pos]
    end

    def parse_name(data, pos)
      stop = pos
      size = data.bytesize
      stop += 1 while stop < size && !WHITESPACE.include?(data.getbyte(stop)) && !DELIMITERS.include?(data.getbyte(stop))
      name = data.byteslice(pos, stop - pos).gsub(/#([0-9A-Fa-f]{2})/) { [$1].pack("H2") }
      [name.force_encoding(Encoding::UTF_8).to_sym, stop]
    end

    def parse_atom(data, pos)
      stop = pos
      size = data.bytesize
      stop += 1 while stop < size && !WHITESPACE.include?(data.getbyte(stop)) && !DELIMITERS.include?(data.getbyte(stop))
      stop = pos + 1 if stop == pos
      token = data.byteslice(pos, stop - pos)
      if token.match?(/\A[+-]?\d+\z/)
        value = token.to_i
        # "num gen R" is a reference.
        if (match = /\A[\s\0]+(\d+)[\s\0]+R(?=[\s\0\/\[\]<>()%]|\z)/.match(data.byteslice(stop, 24).to_s))
          return [Ref.new(value, match[1].to_i), stop + match.end(0)]
        end
        [value, stop]
      elsif token.match?(/\A[+-]?(\d+\.\d*|\.\d+|\d+\.)\z/)
        [token.to_f, stop]
      elsif token == "true"
        [true, stop]
      elsif token == "false"
        [false, stop]
      elsif token == "null"
        [nil, stop]
      else
        [Keyword.new(token), stop]
      end
    end

    # ------------------------------------------------------------ streams

    def decode_stream(stream, decrypt: true)
      data = stream.raw
      data = decrypt_data(data, stream.num, stream.gen) if decrypt && @crypt != nil && stream.dict[:Type] != :XRef
      filters = Array(resolve(stream.dict[:Filter])).map { |item| resolve(item) }
      params = Array(resolve(stream.dict[:DecodeParms] || stream.dict[:DP])).map { |item| dict_of(item) }
      filters.each_with_index do |filter, index|
        data = apply_filter(filter, data, params[index] || {})
      end
      data
    end

    def apply_filter(filter, data, params)
      case filter
      when :FlateDecode, :Fl
        predict(inflate(data), params)
      when :LZWDecode, :LZW
        predict(lzw_decode(data), params)
      when :ASCIIHexDecode, :AHx
        hex = data[/\A[^>]*/].to_s.gsub(/[^0-9A-Fa-f]/, "")
        hex << "0" if hex.size.odd?
        [hex].pack("H*")
      when :ASCII85Decode, :A85
        ascii85_decode(data)
      when :RunLengthDecode, :RL
        run_length_decode(data)
      else
        raise UnsupportedFormat, "Unsupported stream filter #{filter}"
      end
    end

    def inflate(data)
      zstream = Zlib::Inflate.new
      out = "".b
      begin
        out << zstream.inflate(data)
      rescue Zlib::BufError, Zlib::DataError
        # Truncated or slightly damaged streams: keep what was decoded.
        begin
          out << zstream.flush_next_out.to_s
        rescue StandardError
          nil
        end
        raise MalformedDocument, "Damaged compressed stream" if out.empty?
      ensure
        zstream.close rescue nil
      end
      out
    end

    # PNG predictors (Predictor >= 10), as used by object and xref streams.
    def predict(data, params)
      predictor = resolve(params[:Predictor]).to_i
      return data if predictor < 10
      colors = [resolve(params[:Colors] || 1).to_i, 1].max
      bpc = [resolve(params[:BitsPerComponent] || 8).to_i, 1].max
      columns = [resolve(params[:Columns] || 1).to_i, 1].max
      bpp = [(colors * bpc + 7) / 8, 1].max
      row_size = (colors * bpc * columns + 7) / 8
      out = "".b
      previous = Array.new(row_size, 0)
      pos = 0
      while pos + 1 <= data.bytesize
        type = data.getbyte(pos)
        row = data.byteslice(pos + 1, row_size).to_s.bytes
        pos += row_size + 1
        row.each_index do |i|
          left = i >= bpp ? row[i - bpp] : 0
          up = previous[i] || 0
          up_left = i >= bpp ? (previous[i - bpp] || 0) : 0
          row[i] = case type
          when 1 then (row[i] + left) & 0xFF
          when 2 then (row[i] + up) & 0xFF
          when 3 then (row[i] + (left + up) / 2) & 0xFF
          when 4
            p = left + up - up_left
            pa = (p - left).abs
            pb = (p - up).abs
            pc = (p - up_left).abs
            (row[i] + (pa <= pb && pa <= pc ? left : (pb <= pc ? up : up_left))) & 0xFF
          else row[i]
          end
        end
        out << row.pack("C*")
        previous = row
      end
      out
    end

    # LZW with the PDF default EarlyChange of 1.
    def lzw_decode(data)
      out = "".b
      fresh = proc { (0..255).map { |i| i.chr.b } + [nil, nil] }
      table = fresh.call
      code_size = 9
      buffer = 0
      bits = 0
      previous = nil
      data.each_byte do |byte|
        buffer = (buffer << 8) | byte
        bits += 8
        while bits >= code_size
          code = (buffer >> (bits - code_size)) & ((1 << code_size) - 1)
          bits -= code_size
          buffer &= (1 << bits) - 1
          if code == 256
            table = fresh.call
            code_size = 9
            previous = nil
            next
          end
          return out if code == 257
          if previous == nil
            entry = table[code]
            return out if entry == nil
          elsif code < table.size && table[code] != nil
            entry = table[code]
            table << (previous + entry[0])
          elsif code == table.size
            entry = previous + previous[0]
            table << entry
          else
            return out
          end
          out << entry
          previous = entry
          code_size += 1 if code_size < 12 && table.size + 1 >= (1 << code_size)
        end
      end
      out
    end

    def ascii85_decode(data)
      data = data.to_s.sub(/\A<~/, "")
      data = data[0, data.index("~>")] if data.include?("~>")
      data = data.gsub(/[\s\0]/, "")
      out = "".b
      group = []
      data.each_char do |char|
        if char == "z" && group.empty?
          out << "\0\0\0\0"
          next
        end
        code = char.ord - 33
        next if code < 0 || code > 84
        group << code
        next if group.size < 5
        value = group.inject(0) { |sum, digit| sum * 85 + digit }
        out << [value & 0xFFFFFFFF].pack("N")
        group = []
      end
      if group.size > 1
        missing = 5 - group.size
        value = (group + [84] * missing).inject(0) { |sum, digit| sum * 85 + digit }
        out << [value & 0xFFFFFFFF].pack("N").byteslice(0, 4 - missing)
      end
      out
    end

    def run_length_decode(data)
      out = "".b
      pos = 0
      while pos < data.bytesize
        length = data.getbyte(pos)
        pos += 1
        break if length == 128
        if length < 128
          out << data.byteslice(pos, length + 1).to_s
          pos += length + 1
        else
          out << (data.byteslice(pos, 1).to_s * (257 - length))
          pos += 1
        end
      end
      out
    end

    # ---------------------------------------------------------- encryption

    def setup_encryption
      encrypt = dict_of(@trailer[:Encrypt])
      return if encrypt.empty?
      raise EncryptedDocument, "Unsupported security handler" if resolve(encrypt[:Filter]) != :Standard
      version = resolve(encrypt[:V]).to_i
      revision = resolve(encrypt[:R]).to_i
      owner = resolve(encrypt[:O]).to_s.b
      user = resolve(encrypt[:U]).to_s.b
      method = :rc4
      if version >= 4
        filters = dict_of(encrypt[:CF])
        stream_filter = resolve(encrypt[:StmF]) || :Identity
        crypt_filter = dict_of(filters[stream_filter])
        cfm = resolve(crypt_filter[:CFM])
        method = case cfm
        when :AESV2 then :aes128
        when :AESV3 then :aes256
        when :None then :none
        else :rc4
        end
        method = :none if stream_filter == :Identity
      end
      key = if revision >= 5
        aes256_file_key(encrypt, user)
      else
        rc4_file_key(encrypt, owner, user, revision)
      end
      raise EncryptedDocument, "A password is required" if key == nil
      @crypt = { key: key, method: method, revision: revision }
      # Strings inside the objects are decrypted on use; the few stream
      # dictionaries that matter (fonts, contents) hold no encrypted strings.
    end

    def first_id
      ids = resolve(@trailer[:ID])
      ids.is_a?(Array) ? resolve(ids[0]).to_s.b : "".b
    end

    def rc4_file_key(encrypt, owner, user, revision)
      length = revision == 2 ? 5 : [resolve(encrypt[:Length] || 40).to_i / 8, 5].max
      length = [length, 16].min
      permissions = [resolve(encrypt[:P]).to_i].pack("l<")
      input = PASSWORD_PADDING + owner.byteslice(0, 32).to_s + permissions + first_id
      input << "\xFF\xFF\xFF\xFF".b if revision >= 4 && resolve(encrypt[:EncryptMetadata]) == false
      hash = Digest::MD5.digest(input)
      50.times { hash = Digest::MD5.digest(hash.byteslice(0, length)) } if revision >= 3
      key = hash.byteslice(0, length)
      # Check the empty user password against /U.
      check = if revision == 2
        rc4(key, PASSWORD_PADDING) == user.byteslice(0, 32)
      else
        value = rc4(key, Digest::MD5.digest(PASSWORD_PADDING + first_id))
        1.upto(19) { |i| value = rc4(key.bytes.map { |b| b ^ i }.pack("C*"), value) }
        value.byteslice(0, 16) == user.byteslice(0, 16)
      end
      check ? key : nil
    end

    def aes256_file_key(encrypt, user)
      revision = resolve(encrypt[:R]).to_i
      validation_salt = user.byteslice(32, 8).to_s
      key_salt = user.byteslice(40, 8).to_s
      hash = revision == 5 ? Digest::SHA256.digest(validation_salt) : hash_2b("".b, validation_salt, "".b)
      return nil if hash != user.byteslice(0, 32)
      intermediate = revision == 5 ? Digest::SHA256.digest(key_salt) : hash_2b("".b, key_salt, "".b)
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = intermediate
      cipher.iv = "\0".b * 16
      cipher.padding = 0
      cipher.update(resolve(encrypt[:UE]).to_s.b) + cipher.final
    rescue OpenSSL::Cipher::CipherError
      nil
    end

    # Algorithm 2.B of ISO 32000-2 (revision 6 password hash).
    def hash_2b(password, salt, user_key)
      k = Digest::SHA256.digest(password + salt + user_key)
      round = 0
      loop do
        k1 = (password + k + user_key) * 64
        cipher = OpenSSL::Cipher.new("aes-128-cbc")
        cipher.encrypt
        cipher.key = k.byteslice(0, 16)
        cipher.iv = k.byteslice(16, 16)
        cipher.padding = 0
        e = cipher.update(k1) + cipher.final
        sum = e.byteslice(0, 16).bytes.sum % 3
        k = case sum
        when 0 then Digest::SHA256.digest(e)
        when 1 then Digest::SHA384.digest(e)
        else Digest::SHA512.digest(e)
        end
        round += 1
        break if round >= 64 && e.getbyte(e.bytesize - 1) <= round - 32
      end
      k.byteslice(0, 32)
    end

    def object_key(num, gen)
      return @crypt[:key] if @crypt[:method] == :aes256
      input = @crypt[:key] + [num].pack("V").byteslice(0, 3) + [gen].pack("v")
      input << "sAlT".b if @crypt[:method] == :aes128
      Digest::MD5.digest(input).byteslice(0, [@crypt[:key].bytesize + 5, 16].min)
    end

    def decrypt_data(data, num, gen)
      return data if @crypt == nil || @crypt[:method] == :none || num == nil
      key = object_key(num, gen)
      case @crypt[:method]
      when :aes128, :aes256
        return "".b if data.bytesize < 32
        cipher = OpenSSL::Cipher.new(@crypt[:method] == :aes256 ? "aes-256-cbc" : "aes-128-cbc")
        cipher.decrypt
        cipher.key = key
        cipher.iv = data.byteslice(0, 16)
        begin
          cipher.update(data.byteslice(16..)) + cipher.final
        rescue OpenSSL::Cipher::CipherError
          data
        end
      else
        rc4(key, data)
      end
    end

    def rc4(key, data)
      s = (0..255).to_a
      keys = key.bytes
      j = 0
      256.times do |i|
        j = (j + s[i] + keys[i % keys.size]) & 0xFF
        s[i], s[j] = s[j], s[i]
      end
      i = j = 0
      out = data.bytes.map do |byte|
        i = (i + 1) & 0xFF
        j = (j + s[i]) & 0xFF
        s[i], s[j] = s[j], s[i]
        byte ^ s[(s[i] + s[j]) & 0xFF]
      end
      out.pack("C*")
    end

    # Strings of fonts (ToUnicode is a stream, decrypted with decode_stream);
    # literal text in content streams is part of the decrypted stream itself.

    # ---------------------------------------------------------------- pages

    def page_list
      root = dict_of(@trailer[:Root])
      root = @objects.values.find { |object| object.is_a?(Hash) && object[:Type] == :Catalog } || {} if root.empty?
      pages = []
      collect_pages(root[:Pages], {}, pages, {}, 0)
      if pages.empty?
        pages = @objects.keys.sort.filter_map do |num|
          object = @objects[num]
          object.is_a?(Hash) && object[:Type] == :Page ? [object, object[:Resources]] : nil
        end
      end
      pages
    end

    def collect_pages(node_ref, inherited, pages, seen, depth)
      return if depth > 64
      key = node_ref.is_a?(Ref) ? node_ref.num : node_ref.object_id
      return if seen[key]
      seen[key] = true
      node = dict_of(node_ref)
      return if node.empty?
      resources = node[:Resources] || inherited[:Resources]
      kids = resolve(node[:Kids])
      if kids.is_a?(Array) && node[:Type] != :Page
        kids.each { |kid| collect_pages(kid, { Resources: resources }, pages, seen, depth + 1) }
      else
        pages << [node, resources]
      end
    end

    def page_text(page)
      node, resources = page
      contents = resolve(node[:Contents])
      streams = contents.is_a?(Array) ? contents.map { |item| resolve(item) } : [contents]
      data = streams.filter_map do |stream|
        next if !stream.is_a?(Stream)
        decode_stream(stream) rescue nil
      end.join("\n")
      state = TextState.new
      run_content(data, dict_of(resources), state, 0)
      state.text
    end

    # ------------------------------------------------------------- content

    class TextState
      attr_accessor :font, :size, :line_y, :line_x, :pen_x, :end_x, :last_y, :scale, :moved

      def initialize
        @out = +""
        @font = nil
        @size = 12.0
        @scale = 1.0
        @line_y = 0.0
        @line_x = 0.0
        @pen_x = 0.0
        @end_x = nil
        @last_y = nil
        @moved = false
      end

      def text
        @out
      end

      def add(value)
        @out << value
      end

      def newline
        @out.sub!(/ +\z/, "")
        @out << "\n" if !@out.empty? && !@out.end_with?("\n")
      end

      def space
        @out << " " if !@out.empty? && !@out.end_with?(" ", "\n", "\t")
      end
    end

    def run_content(data, resources, state, depth)
      return if depth > MAX_DEPTH || data.to_s == ""
      operands = []
      pos = 0
      size = data.bytesize
      ops = 0
      while pos < size
        pos = skip_ws(data, pos)
        break if pos >= size
        byte = data.getbyte(pos)
        if byte == 93 || byte == 41 || byte == 62 || byte == 123 || byte == 125
          pos += 1
          next
        end
        begin
          value, pos = parse_object(data, pos)
        rescue MalformedDocument
          pos += 1
          operands.clear
          next
        end
        if !value.is_a?(Keyword)
          operands << value
          next
        end
        ops += 1
        @token.raise_if_cancelled! if @token != nil && (ops % 2000) == 0
        if value.name == "BI"
          stop = data.index(/[\s\0]EI(?=[\s\0]|\z)/, pos)
          pos = stop == nil ? size : stop + 3
        else
          operator(value.name, operands, resources, state, depth)
        end
        operands.clear
      end
    end

    def operator(name, operands, resources, state, depth)
      case name
      when "BT"
        # The text matrix starts as the identity in every text object; the
        # position of the last shown text is kept to see line changes.
        state.line_x = state.line_y = state.pen_x = 0.0
        state.scale = 1.0
        state.moved = true
      when "ET"
        nil
      when "Tf"
        state.font = font(resources, operands[0])
        state.size = operands[1].to_f.abs
        state.size = 12.0 if state.size == 0
      when "Td", "TD"
        move_text(state, operands[0].to_f, operands[1].to_f, relative: true)
      when "Tm"
        state.scale = [operands[0].to_f.abs, operands[3].to_f.abs].max
        state.scale = 1.0 if state.scale == 0
        move_text(state, operands[4].to_f, operands[5].to_f, relative: false)
      when "T*"
        state.newline
        state.end_x = nil
        state.moved = true
      when "Tj"
        show(state, operands[0])
      when "'"
        state.newline
        show(state, operands[0])
      when "\""
        state.newline
        show(state, operands[2])
      when "TJ"
        Array(operands[0]).each do |item|
          if item.is_a?(String)
            show(state, item)
          elsif item.is_a?(Numeric)
            # A big negative adjustment is a gap between words.
            if item < -180
              state.space
            else
              state.pen_x -= item / 1000.0 * state.size * state.scale
              state.end_x = state.pen_x
            end
          end
        end
      when "Do"
        xobject = dict_of(dict_of(resources[:XObject])[operands[0]]) rescue {}
        stream = resolve(dict_of(resources[:XObject])[operands[0]]) rescue nil
        if stream.is_a?(Stream) && xobject[:Subtype] == :Form
          inner = dict_of(xobject[:Resources])
          inner = resources if inner.empty?
          data = decode_stream(stream) rescue nil
          run_content(data, inner, state, depth + 1)
        end
      end
    end

    def move_text(state, x, y, relative:)
      if relative
        state.line_x += x * state.scale
        state.line_y += y * state.scale
      else
        state.line_x = x
        state.line_y = y
      end
      state.pen_x = state.line_x
      state.moved = true
    end

    def show(state, string)
      return if !string.is_a?(String)
      font = state.font || default_font
      text, width = font.decode(string)
      if state.moved
        height = state.size * state.scale
        if state.last_y != nil && (state.line_y - state.last_y).abs > height * 0.3
          state.newline
        elsif state.end_x != nil && (state.pen_x > state.end_x + height * 0.15 || state.pen_x < state.end_x - height * 2)
          state.space
        end
      end
      state.add(text)
      state.pen_x += width * state.size * state.scale
      state.end_x = state.pen_x
      state.last_y = state.line_y
      state.moved = false
    end

    # --------------------------------------------------------------- fonts

    def default_font
      @default_font ||= Font.new(nil, {}, self)
    end

    def font(resources, name)
      fonts = dict_of(resources[:Font])
      ref = fonts[name]
      key = ref.is_a?(Ref) ? [:ref, ref.num] : [:inline, name, fonts.object_id]
      @fonts[key] ||= Font.new(ref, dict_of(ref), self)
    end

    public

    # Used by Font.
    def resolve_value(value)
      resolve(value)
    end

    def dict_value(value)
      dict_of(value)
    end

    def stream_data(value)
      stream = resolve(value)
      stream.is_a?(Stream) ? (decode_stream(stream) rescue nil) : nil
    end

    private

    class Font
      def initialize(ref, dict, reader)
        @reader = reader
        @dict = dict
        @subtype = reader.resolve_value(dict[:Subtype])
        @two_byte = @subtype == :Type0
        @to_unicode = nil
        @code_lengths = nil
        @widths = {}
        @default_width = 0.5
        load_to_unicode
        load_encoding if !@two_byte
        load_widths
      end

      # [UTF-8 text, width in text space units per point of font size]
      def decode(string)
        out = +""
        width = 0.0
        codes(string).each do |code, length|
          char = if @to_unicode != nil && @to_unicode.key?(code)
            @to_unicode[code]
          elsif !@two_byte
            @encoding[code] || ""
          else
            ""
          end
          out << char
          width += @widths.fetch(code, @default_width)
        end
        [out, width]
      end

      private

      def codes(string)
        bytes = string.b.bytes
        result = []
        pos = 0
        while pos < bytes.size
          length = code_length(bytes, pos)
          code = 0
          length.times { |i| code = (code << 8) | (bytes[pos + i] || 0) }
          result << [code, length]
          pos += length
        end
        result
      end

      def code_length(bytes, pos)
        if @code_lengths != nil && !@code_lengths.empty?
          @code_lengths.each do |length, low, high|
            next if pos + length > bytes.size
            code = 0
            length.times { |i| code = (code << 8) | bytes[pos + i] }
            return length if code >= low && code <= high
          end
        end
        @two_byte ? 2 : 1
      end

      def load_to_unicode
        data = @reader.stream_data(@dict[:ToUnicode])
        return if data == nil
        @to_unicode = {}
        lengths = []
        data.scan(/begincodespacerange(.*?)endcodespacerange/m) do |body,|
          body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |low, high|
            lengths << [low.size / 2, low.to_i(16), high.to_i(16)]
          end
        end
        @code_lengths = lengths.sort_by { |length, _l, _h| -length } if !lengths.empty?
        data.scan(/beginbfchar(.*?)endbfchar/m) do |body,|
          body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/) do |code, target|
            @to_unicode[code.to_i(16)] = utf16_hex(target)
          end
        end
        data.scan(/beginbfrange(.*?)endbfrange/m) do |body,|
          body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]*>|\[[^\]]*\])/) do |low, high, target|
            first = low.to_i(16)
            last = [high.to_i(16), first + 65_535].min
            if target.start_with?("[")
              target.scan(/<([0-9A-Fa-f]*)>/).each_with_index do |(item), index|
                break if first + index > last
                @to_unicode[first + index] = utf16_hex(item)
              end
            else
              hex = target[1..-2]
              base = [hex].pack("H*")
              (first..last).each_with_index do |code, offset|
                value = base.dup
                if value.bytesize >= 2
                  last_unit = value.byteslice(-2, 2).unpack1("n") + offset
                  value = value.byteslice(0, value.bytesize - 2) + [last_unit & 0xFFFF].pack("n")
                elsif value.bytesize == 1
                  value = [value.getbyte(0) + offset].pack("n")
                end
                @to_unicode[code] = utf16_bytes(value)
              end
            end
          end
        end
      rescue StandardError
        @to_unicode = nil if @to_unicode != nil && @to_unicode.empty?
      end

      def utf16_hex(hex)
        utf16_bytes([hex.to_s].pack("H*"))
      end

      def utf16_bytes(bytes)
        bytes = "\0".b + bytes if bytes.bytesize.odd?
        bytes.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      rescue StandardError
        ""
      end

      def load_encoding
        encoding = @reader.resolve_value(@dict[:Encoding])
        base = :StandardEncoding
        base = :WinAnsiEncoding if @subtype == :TrueType
        differences = nil
        if encoding.is_a?(Symbol)
          base = encoding
        elsif encoding.is_a?(Hash)
          base = @reader.resolve_value(encoding[:BaseEncoding]) || base
          differences = @reader.resolve_value(encoding[:Differences])
        end
        symbolic = [:Symbol, :ZapfDingbats].include?(base_font_name)
        @encoding = Encodings.table(symbolic ? :Symbolic : base)
        if differences.is_a?(Array)
          @encoding = @encoding.dup
          code = 0
          differences.each do |item|
            item = @reader.resolve_value(item)
            if item.is_a?(Integer)
              code = item
            elsif item.is_a?(Symbol)
              @encoding[code] = Encodings.glyph(item.to_s)
              code += 1
            end
          end
        end
      end

      def base_font_name
        name = @reader.resolve_value(@dict[:BaseFont]).to_s.sub(/\A[A-Z]{6}\+/, "")
        name.to_sym
      end

      def load_widths
        if @two_byte
          descendant = @reader.resolve_value(@dict[:DescendantFonts])
          descendant = @reader.dict_value(descendant.is_a?(Array) ? descendant[0] : descendant)
          dw = @reader.resolve_value(descendant[:DW])
          @default_width = (dw.is_a?(Numeric) ? dw : 1000) / 1000.0
          widths = @reader.resolve_value(descendant[:W])
          return if !widths.is_a?(Array)
          index = 0
          while index < widths.size
            first = @reader.resolve_value(widths[index])
            second = @reader.resolve_value(widths[index + 1])
            break if !first.is_a?(Integer)
            if second.is_a?(Array)
              second.each_with_index { |w, i| @widths[first + i] = @reader.resolve_value(w).to_f / 1000.0 }
              index += 2
            else
              last = second.to_i
              w = @reader.resolve_value(widths[index + 2]).to_f / 1000.0
              (first..[last, first + 65_535].min).each { |code| @widths[code] = w }
              index += 3
            end
          end
        else
          first = @reader.resolve_value(@dict[:FirstChar]).to_i
          widths = @reader.resolve_value(@dict[:Widths])
          return if !widths.is_a?(Array)
          widths.each_with_index { |w, i| @widths[first + i] = @reader.resolve_value(w).to_f / 1000.0 }
        end
      rescue StandardError
        nil
      end
    end

    # Single-byte encodings and glyph names.
    module Encodings
      ACCENTS = {
        "acute" => "́", "grave" => "̀", "circumflex" => "̂", "dieresis" => "̈",
        "tilde" => "̃", "ring" => "̊", "cedilla" => "̧", "caron" => "̌",
        "ogonek" => "̨", "dotaccent" => "̇", "macron" => "̄", "breve" => "̆",
        "hungarumlaut" => "̋", "commaaccent" => "̦"
      }.freeze
      NAMES = {
        "space" => " ", "exclam" => "!", "quotedbl" => "\"", "numbersign" => "#", "dollar" => "$",
        "percent" => "%", "ampersand" => "&", "quotesingle" => "'", "quoteright" => "’",
        "parenleft" => "(", "parenright" => ")", "asterisk" => "*", "plus" => "+", "comma" => ",",
        "hyphen" => "-", "minus" => "−", "period" => ".", "slash" => "/", "colon" => ":",
        "semicolon" => ";", "less" => "<", "equal" => "=", "greater" => ">", "question" => "?",
        "at" => "@", "bracketleft" => "[", "backslash" => "\\", "bracketright" => "]",
        "asciicircum" => "^", "underscore" => "_", "grave" => "`", "quoteleft" => "‘",
        "braceleft" => "{", "bar" => "|", "braceright" => "}", "asciitilde" => "~",
        "zero" => "0", "one" => "1", "two" => "2", "three" => "3", "four" => "4", "five" => "5",
        "six" => "6", "seven" => "7", "eight" => "8", "nine" => "9",
        "exclamdown" => "¡", "cent" => "¢", "sterling" => "£", "currency" => "¤",
        "yen" => "¥", "brokenbar" => "¦", "section" => "§", "copyright" => "©",
        "ordfeminine" => "ª", "guillemotleft" => "«", "guillemetleft" => "«",
        "logicalnot" => "¬", "registered" => "®", "degree" => "°",
        "plusminus" => "±", "twosuperior" => "²", "threesuperior" => "³",
        "mu" => "µ", "paragraph" => "¶", "periodcentered" => "·",
        "onesuperior" => "¹", "ordmasculine" => "º", "guillemotright" => "»",
        "guillemetright" => "»", "onequarter" => "¼", "onehalf" => "½",
        "threequarters" => "¾", "questiondown" => "¿", "multiply" => "×",
        "divide" => "÷", "germandbls" => "ß", "AE" => "Æ", "ae" => "æ",
        "OE" => "Œ", "oe" => "œ", "Oslash" => "Ø", "oslash" => "ø",
        "Lslash" => "Ł", "lslash" => "ł", "Eth" => "Ð", "eth" => "ð",
        "Thorn" => "Þ", "thorn" => "þ", "dotlessi" => "ı", "fi" => "fi", "fl" => "fl",
        "ff" => "ff", "ffi" => "ffi", "ffl" => "ffl", "quotesinglbase" => "‚",
        "quotedblbase" => "„", "quotedblleft" => "“", "quotedblright" => "”",
        "guilsinglleft" => "‹", "guilsinglright" => "›", "endash" => "–",
        "emdash" => "—", "bullet" => "•", "ellipsis" => "…", "dagger" => "†",
        "daggerdbl" => "‡", "perthousand" => "‰", "trademark" => "™",
        "Euro" => "€", "florin" => "ƒ", "fraction" => "⁄", "nbspace" => " ",
        "nonbreakingspace" => " ", "sfthyphen" => "", "softhyphen" => "", "circumflex" => "^",
        "tilde" => "~", "dieresis" => "¨", "acute" => "´", "cedilla" => "¸",
        "macron" => "¯", "ring" => "˚", "caron" => "ˇ", "breve" => "˘",
        "ogonek" => "˛", "dotaccent" => "˙", "hungarumlaut" => "˝",
        "Delta" => "Δ", "Omega" => "Ω", "pi" => "π", "infinity" => "∞",
        "lessequal" => "≤", "greaterequal" => "≥", "notequal" => "≠",
        "approxequal" => "≈", "summation" => "∑", "product" => "∏",
        "radical" => "√", "integral" => "∫", "partialdiff" => "∂",
        "lozenge" => "◊", "apple" => ""
      }.freeze

      # StandardEncoding differs from ASCII in a few places and in the upper half.
      STANDARD_UPPER = {
        0xA1 => "exclamdown", 0xA2 => "cent", 0xA3 => "sterling", 0xA4 => "fraction", 0xA5 => "yen",
        0xA6 => "florin", 0xA7 => "section", 0xA8 => "currency", 0xA9 => "quotesingle",
        0xAA => "quotedblleft", 0xAB => "guillemotleft", 0xAC => "guilsinglleft",
        0xAD => "guilsinglright", 0xAE => "fi", 0xAF => "fl", 0xB1 => "endash", 0xB2 => "dagger",
        0xB3 => "daggerdbl", 0xB4 => "periodcentered", 0xB6 => "paragraph", 0xB7 => "bullet",
        0xB8 => "quotesinglbase", 0xB9 => "quotedblbase", 0xBA => "quotedblright",
        0xBB => "guillemotright", 0xBC => "ellipsis", 0xBD => "perthousand", 0xBF => "questiondown",
        0xC1 => "grave", 0xC2 => "acute", 0xC3 => "circumflex", 0xC4 => "tilde", 0xC5 => "macron",
        0xC6 => "breve", 0xC7 => "dotaccent", 0xC8 => "dieresis", 0xCA => "ring", 0xCB => "cedilla",
        0xCD => "hungarumlaut", 0xCE => "ogonek", 0xCF => "caron", 0xD0 => "emdash", 0xE1 => "AE",
        0xE3 => "ordfeminine", 0xE8 => "Lslash", 0xE9 => "Oslash", 0xEA => "OE",
        0xEB => "ordmasculine", 0xF1 => "ae", 0xF5 => "dotlessi", 0xF8 => "lslash", 0xF9 => "oslash",
        0xFA => "oe", 0xFB => "germandbls"
      }.freeze

      @tables = {}
      @glyphs = {}

      class << self
        def table(name)
          @tables[name] ||= build(name)
        end

        # Unicode text of a glyph name: the names above, uniXXXX, uXXXX[XX],
        # accented letters (e.g. "adieresis"), single letters; otherwise "".
        def glyph(name)
          @glyphs[name] ||= begin
            base = name.split(".", 2)[0].to_s.split("_").map { |part| glyph_part(part) }.join
            base
          end
        end

        private

        def glyph_part(name)
          return NAMES[name] if NAMES.key?(name)
          return name if name.match?(/\A[A-Za-z]\z/)
          if (match = /\Auni((?:[0-9A-Fa-f]{4})+)\z/.match(name))
            return match[1].scan(/.{4}/).map { |hex| hex.to_i(16) }.reject { |cp| cp >= 0xD800 && cp <= 0xDFFF }.pack("U*")
          end
          if (match = /\Au([0-9A-Fa-f]{4,6})\z/.match(name))
            value = match[1].to_i(16)
            return value <= 0x10FFFF ? [value].pack("U") : ""
          end
          if (match = /\A([A-Za-z])(acute|grave|circumflex|dieresis|tilde|ring|cedilla|caron|ogonek|dotaccent|macron|breve|hungarumlaut|commaaccent)\z/.match(name))
            letter = match[1]
            letter = "ı" if letter == "i" && match[2] == "dotaccent"
            return (letter + ACCENTS[match[2]]).unicode_normalize(:nfc) rescue letter
          end
          ""
        end

        def build(name)
          table = {}
          (32..126).each { |code| table[code] = code.chr }
          case name
          when :WinAnsiEncoding, :Symbolic
            (128..255).each { |code| table[code] = byte_in(code, Encoding::Windows_1252) }
            table[0x27] = "'"
            table[0x60] = "`"
          when :MacRomanEncoding
            (128..255).each { |code| table[code] = byte_in(code, Encoding::MacRoman) }
          when :PDFDocEncoding
            (160..255).each { |code| table[code] = byte_in(code, Encoding::ISO_8859_1) }
          else
            table[0x27] = "’"
            table[0x60] = "‘"
            STANDARD_UPPER.each { |code, glyph_name| table[code] = glyph(glyph_name) }
          end
          table
        end

        def byte_in(code, encoding)
          code.chr.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
        rescue StandardError
          ""
        end
      end
    end
  end
end
