# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# A page for the text browser: the document is fetched directly (no
# JavaScript), its character set decoded and the HTML reduced to what a
# read-only Klangten text field shows well: headings, paragraphs, lists,
# links (absolute), table rows as lines with " | " between the cells, images
# by their alternative text, frames as links.
#
#   page = KlangtenWeb::TextPage.load(url, token: token)   # blocks; use Tasks.run
#   page.html / page.title / page.url (after redirects) / page.links
#   page.error   nil, :not_page (page.mime tells the type) or a message
#
# TextPage.from_html(html, url) does the same for HTML already at hand.

require "nokogiri"
require "cgi"

module KlangtenWeb
  class TextPage
    MAX_BYTES = 8 * 1024 * 1024
    SKIPPED = %w[script style noscript template svg head object embed canvas map datalist].freeze
    BLOCKS = %w[p div section article header footer nav main aside blockquote pre form fieldset address figure
                figcaption dl dt dd center hr details summary caption legend].freeze

    attr_reader :url, :title, :html, :links, :error, :mime, :description, :language

    def self.load(url, token: nil)
      page = new(url)
      page.fetch(token)
      page
    end

    def self.from_html(html, url = "about:blank")
      page = new(url)
      page.convert(html.to_s)
      page
    end

    def initialize(url)
      @url = url.to_s
      @title = ""
      @html = ""
      @links = []
      @error = nil
      @mime = ""
    end

    def page?
      @error == nil
    end

    def plain_text
      Nokogiri::HTML.fragment(@html.gsub(/<br\s*\/?>/i, "\n").gsub(%r{</(p|h[1-6]|li)>}i, "\n")).text.gsub(/\n{3,}/, "\n\n").strip
    end

    def fetch(token)
      KlangtenWeb.http_get(@url, token: token, headers: { "Accept" => "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5" }) do |response, final|
        @url = final
        @mime = response["content-type"].to_s.split(";").first.to_s.strip.downcase
        unless response.is_a?(Net::HTTPSuccess)
          @error = "HTTP #{response.code}"
          return
        end
        if @mime != "" && !(@mime.start_with?("text/") || @mime.include?("html") || @mime.include?("xml"))
          @error = :not_page
          return
        end
        body = +"".b
        response.read_body do |chunk|
          token.raise_if_cancelled! if token != nil
          body << chunk
          break if body.bytesize > MAX_BYTES
        end
        text = TextPage.decode(body, response["content-type"].to_s)
        if @mime == "text/plain"
          @title = File.basename(@url.split(/[?#]/).first.to_s)
          @html = CGI.escapeHTML(text).gsub(/\r?\n/, "<br/>")
        else
          convert(text)
        end
      end
    rescue StandardError => e
      raise if defined?(EltenAPI::Tasks::Cancelled) && e.is_a?(EltenAPI::Tasks::Cancelled)
      @error = e.message.to_s == "" ? e.class.name : e.message
    end

    # Character set: header, then <meta charset>, then UTF-8 if valid, else
    # Windows-1252.
    def self.decode(bytes, content_type = "")
      charset = content_type.to_s[/charset=["']?([\w.:-]+)/i, 1]
      charset ||= bytes[0, 4096].to_s[/<meta[^>]+charset=["']?([\w.:-]+)/i, 1]
      if charset != nil
        begin
          return bytes.dup.force_encoding(charset).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        rescue ArgumentError, EncodingError
        end
      end
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return text.delete_prefix("﻿") if text.valid_encoding?
      bytes.dup.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def convert(source)
      document = Nokogiri::HTML(source)
      @title = document.at("title")&.text.to_s.gsub(/\s+/, " ").strip
      @language = document.at("html")&.[]("lang").to_s
      @description = document.at('meta[name="description"]')&.[]("content").to_s
      base = document.at("base[href]")&.[]("href")
      @base = base != nil ? absolute(base) : @url
      out = +""
      body = document.at("body") || document.root
      walk(body, out) if body != nil
      out.gsub!(/ {2,}/, " ")
      out.gsub!(/ *<br\/> */, "<br/>")
      out.gsub!(/(?:<br\/>){3,}/, "<br/><br/>")
      out.sub!(/\A(?:\s*<br\/>)+/, "")
      @html = out.strip
    end

    private

    def absolute(href)
      (URI.join(@base || @url, href.to_s.strip).to_s rescue href.to_s.strip)
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    def squeeze(text)
      text.to_s.gsub(/[­​]/, "").gsub(/\s+/, " ")
    end

    def line(out)
      out << "<br/>" unless out.empty? || out.end_with?("<br/>")
    end

    def inline_text(node)
      squeeze(node.text).strip
    end

    def walk(node, out)
      node.children.each do |child|
        if child.text?
          out << escape(squeeze(child.text))
          next
        end
        next unless child.element?
        tag = child.name.downcase
        next if SKIPPED.include?(tag)
        next if child["hidden"] != nil || child["aria-hidden"] == "true" || child["style"].to_s =~ /display\s*:\s*none/i
        case tag
        when "br"
          out << "<br/>"
        when "h1", "h2", "h3", "h4", "h5", "h6"
          text = inline_text(child)
          next if text == ""
          line(out)
          out << "<#{tag}>#{escape(text)}</#{tag}>"
        when "a"
          href = child["href"].to_s.strip
          if href == "" || href.downcase.start_with?("javascript:")
            walk(child, out)
            next
          end
          text = inline_text(child)
          text = child.at("img[alt]")&.[]("alt").to_s.strip if text == ""
          text = child["title"].to_s.strip if text == ""
          text = File.basename(href.split(/[?#]/).first.to_s) if text == ""
          next if text == ""
          target = absolute(href)
          @links << { text: text, url: target }
          out << " " unless out.empty? || out.end_with?(" ", "<br/>")
          out << "<a href=\"#{escape(target)}\">#{escape(text)}</a> "
        when "img"
          alt = child["alt"].to_s.strip
          out << "[#{escape(alt)}] " if alt != ""
        when "iframe", "frame"
          source = child["src"].to_s.strip
          next if source == "" || source.start_with?("about:", "javascript:")
          target = absolute(source)
          label = child["title"].to_s.strip
          label = child["name"].to_s.strip if label == ""
          label = target if label == ""
          @links << { text: label, url: target }
          line(out)
          out << "<a href=\"#{escape(target)}\">Frame: #{escape(label)}</a><br/>"
        when "input"
          type = child["type"].to_s.downcase
          next if %w[hidden submit image button reset].include?(type)
          label = child["placeholder"].to_s.strip
          label = child["aria-label"].to_s.strip if label == ""
          label = child["name"].to_s.strip if label == ""
          out << "[#{escape(label == "" ? (type == "" ? "text" : type) : label)}] "
        when "select", "button", "textarea"
          next
        when "ul", "ol"
          line(out)
          out << "<#{tag}>"
          walk(child, out)
          line(out)
          out << "</#{tag}>"
        when "li"
          line(out)
          out << "<li>"
          walk(child, out)
          out << "</li>"
          line(out)
        when "tr"
          cells = child.element_children.select { |cell| %w[td th].include?(cell.name.downcase) }
          line(out)
          cells.each_with_index do |cell, index|
            out << " | " if index > 0
            walk(cell, out)
          end
          line(out)
        when "table", "thead", "tbody", "tfoot"
          walk(child, out)
          line(out)
        when "strong", "b"
          inner = +""
          walk(child, inner)
          out << (inner.strip == "" ? inner : "<b>#{inner}</b>")
        when "em", "i"
          inner = +""
          walk(child, inner)
          out << (inner.strip == "" ? inner : "<i>#{inner}</i>")
        else
          if BLOCKS.include?(tag)
            line(out)
            walk(child, out)
            line(out)
          else
            walk(child, out)
          end
        end
      end
    end
  end
end
