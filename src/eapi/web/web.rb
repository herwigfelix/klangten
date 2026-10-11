# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The Klangten browser: shared state and helpers.
#
# Two browsers share this module:
#
#   the full browser   Chrome for Testing without a window, read through its
#                      accessibility tree (src/eapi/web/chrome.rb, ax.rb).
#                      Desktop only; Chrome is downloaded on first use after a
#                      question, never shipped.
#   the text browser   a plain page reader that loads the document itself and
#                      shows it in a read-only text field (textpage.rb). It is
#                      everything iOS and Android get, and the fallback when the
#                      user does not want Chrome.
#
# Everything lives in <data>/browser: Chrome's versions, its profile (cookies,
# sign-ins), and settings.json with the link preference, the "no Chrome"
# answer, bookmarks and the address history.
#
# KlangtenWeb.open_link(url) is the switch every link in Klangten goes through
# (process_url): it opens the page in the Klangten browser or in the system
# browser, as the user chose in the browser settings, or asks.

require "json"
require "fileutils"
require "uri"
require "net/http"
require "openssl"

module KlangtenWeb
  HISTORY_LIMIT = 300
  LINK_TARGETS = %w[ask klangten system].freeze

  class Error < StandardError; end

  class << self
    # ------------------------------------------------------------ platform

    def platform_os
      EltenSystemHelpers.platform_os.to_s
    rescue Exception
      RUBY_PLATFORM =~ /darwin/ ? "osx" : (Gem.win_platform? ? "windows" : "linux")
    end

    def windows?
      platform_os == "windows"
    end

    def osx?
      platform_os == "osx"
    end

    def desktop?
      %w[windows osx linux].include?(platform_os)
    end

    # The full browser needs a desktop system (Chrome runs as a child process).
    def engine_supported?
      desktop? && KlangtenWeb::Chrome.platform != nil
    rescue Exception
      false
    end

    def language
      code = defined?(Configuration) ? Configuration.language.to_s.tr("_", "-") : ""
      code == "" ? "en-US" : code
    rescue Exception
      "en-US"
    end

    # --------------------------------------------------------------- places

    def data_dir
      base = @data_dir_override || File.join(Dirs.eltendata, "browser")
      FileUtils.mkdir_p(base)
      base
    end

    # For tests and the probe tool: keep everything in another folder.
    def data_dir=(path)
      @data_dir_override = path
      @settings = nil
    end

    def downloads_dir
      dir = nil
      if desktop?
        candidate = File.join(Dirs.user, "Downloads")
        dir = candidate if File.directory?(candidate)
      end
      dir ||= File.join(Dirs.documents, "Klangten downloads")
      FileUtils.mkdir_p(dir)
      dir
    rescue Exception
      File.join(data_dir, "downloads")
    end

    # A free file name in directory: "name.ext", else "name (2).ext" and so on.
    def unique_path(directory, name)
      FileUtils.mkdir_p(directory)
      clean = name.to_s.gsub(/[\\\/:*?"<>|\x00-\x1f]/, "_").strip.gsub(/\A\.+|\.+\z/, "")
      clean = "download" if clean == ""
      path = File.join(directory, clean)
      return path unless File.exist?(path)
      ext = File.extname(clean)
      stem = ext == "" || ext == clean ? clean : clean[0...-ext.length]
      ext = "" if stem == clean
      (2..9999).each do |number|
        path = File.join(directory, "#{stem} (#{number})#{ext}")
        return path unless File.exist?(path)
      end
      File.join(directory, clean)
    end

    # File name from a Content-Disposition header, else from the address.
    def file_name_for(disposition, url)
      header = disposition.to_s
      lower = header.downcase
      if (index = lower.index("filename*=")) != nil
        value = header[(index + 10)..-1].split(";").first.to_s.strip
        value = value.split("''", 2).last.to_s.delete('"')
        decoded = URI.decode_www_form_component(value) rescue value
        return decoded if decoded != ""
      end
      if (index = lower.index("filename=")) != nil
        value = header[(index + 9)..-1].split(";").first.to_s.strip.delete('"')
        return value if value != ""
      end
      path = url.to_s.split(/[?#]/).first.to_s
      last = path.split("/").last.to_s
      last = (URI.decode_www_form_component(last) rescue last)
      last == "" || last.include?(":") ? "download" : last
    end

    # Address typed by the user: an address as it is, a host name with https://,
    # anything else is a web search.
    def normalize_url(text)
      value = text.to_s.strip
      return nil if value == ""
      return value if value =~ /\A[A-Za-z][\w+.-]*:/ && value !~ /\A[\w.-]+:\d+(\/|\z)/
      if !value.include?(" ") && (value.include?(".") || value.start_with?("localhost") || value =~ /\A[\w.-]+:\d+/)
        scheme = value.start_with?("localhost", "127.", "[::1]") ? "http://" : "https://"
        return scheme + value
      end
      "https://html.duckduckgo.com/html/?q=" + URI.encode_www_form_component(value)
    end

    def web_url?(url)
      url.to_s =~ /\Ahttps?:\/\//i ? true : false
    end

    # Media the browser offers to play instead of saving.
    MEDIA_EXTENSIONS = %w[.mp3 .ogg .oga .opus .m4a .aac .wav .flac .wma .mp4 .m4v .webm .mkv .mov .m3u .m3u8 .pls].freeze
    STREAM_TYPES = %w[audio/mpeg audio/mp3 audio/aac audio/aacp audio/ogg application/ogg audio/opus audio/x-mpegurl
                      application/x-mpegurl audio/mpegurl application/vnd.apple.mpegurl].freeze

    def media?(url, mime = nil)
      mime = mime.to_s.downcase
      return true if mime.start_with?("audio/", "video/") || STREAM_TYPES.include?(mime)
      MEDIA_EXTENSIONS.include?(File.extname(url.to_s.split(/[?#]/).first.to_s).downcase)
    end

    # ------------------------------------------------------------- settings

    def settings
      @settings ||= begin
        path = File.join(data_dir, "settings.json")
        data = File.file?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : {}
        data.is_a?(Hash) ? data : {}
      rescue StandardError => e
        log_warning("Browser: cannot read settings: #{e.class}: #{e.message}")
        {}
      end
    end

    def save_settings
      path = File.join(data_dir, "settings.json")
      temporary = path + ".tmp"
      File.write(temporary, JSON.pretty_generate(settings), encoding: "UTF-8")
      File.delete(path) if windows? && File.exist?(path)
      File.rename(temporary, path)
    rescue StandardError => e
      log_warning("Browser: cannot write settings: #{e.class}: #{e.message}")
    end

    def setting(name, default = nil)
      settings.key?(name.to_s) ? settings[name.to_s] : default
    end

    def set_setting(name, value)
      settings[name.to_s] = value
      save_settings
    end

    # Where links from Klangten texts open: "ask", "klangten" or "system".
    def link_target
      value = setting("link_target", "ask").to_s
      LINK_TARGETS.include?(value) ? value : "ask"
    end

    def link_target=(value)
      set_setting("link_target", LINK_TARGETS.include?(value.to_s) ? value.to_s : "ask")
    end

    # The user answered "no" to downloading Chrome.
    def engine_declined?
      setting("engine_declined", false) == true
    end

    def engine_declined=(value)
      set_setting("engine_declined", value == true)
    end

    # true: the full browser; false: always the text browser.
    def prefer_text_browser?
      setting("prefer_text", false) == true
    end

    def prefer_text_browser=(value)
      set_setting("prefer_text", value == true)
    end

    # ---------------------------------------------------- bookmarks, history

    def bookmarks
      Array(setting("bookmarks", [])).select { |entry| entry.is_a?(Hash) && entry["url"].to_s != "" }
    end

    def bookmarked?(url)
      bookmarks.any? { |entry| entry["url"] == url.to_s }
    end

    def add_bookmark(url, title)
      return false if url.to_s == "" || bookmarked?(url)
      set_setting("bookmarks", bookmarks + [{ "url" => url.to_s, "title" => title.to_s }])
      true
    end

    def remove_bookmark(url)
      set_setting("bookmarks", bookmarks.reject { |entry| entry["url"] == url.to_s })
    end

    def rename_bookmark(url, title)
      set_setting("bookmarks", bookmarks.map { |entry| entry["url"] == url.to_s ? entry.merge("title" => title.to_s) : entry })
    end

    def history
      Array(setting("history", [])).select { |entry| entry.is_a?(Hash) && entry["url"].to_s != "" }
    end

    def add_history(url, title)
      return if url.to_s == "" || url.to_s.start_with?("about:", "data:")
      entries = history.reject { |entry| entry["url"] == url.to_s }
      entries.unshift({ "url" => url.to_s, "title" => title.to_s, "time" => Time.now.to_i })
      set_setting("history", entries.first(HISTORY_LIMIT))
    end

    def clear_history
      set_setting("history", [])
    end

    def entry_label(entry)
      title = entry["title"].to_s.strip
      title == "" ? entry["url"].to_s : "#{title} (#{entry["url"]})"
    end

    # ------------------------------------------------------------------ HTTP

    def user_agent
      version = defined?(Klangten::Config::VERSION) ? Klangten::Config::VERSION : "0"
      "Mozilla/5.0 (compatible; Klangten/#{version}; text browser)"
    end

    def cert_store
      defined?(EltenAPI::TLS) ? EltenAPI::TLS.certificate_store : nil
    rescue Exception
      nil
    end

    # Opens a GET request and yields the Net::HTTPResponse with its body still
    # unread (read it with read_body). Redirects are followed; the final
    # address is passed as the second argument.
    def http_get(url, headers: {}, token: nil, redirects: 8, open_timeout: 15, read_timeout: 60, &block)
      uri = URI.parse(url.to_s)
      raise Error, "unsupported address #{url}" unless uri.is_a?(URI::HTTP) && uri.host.to_s != ""
      token.raise_if_cancelled! if token != nil
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        store = cert_store
        http.cert_store = store if store != nil
      end
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = user_agent
      request["Accept-Language"] = "#{language},#{language.split("-").first};q=0.9,en;q=0.5"
      headers.each { |key, value| request[key] = value }
      http.start do |connection|
        connection.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection) && response["location"].to_s != "" && redirects > 0
            target = (uri + response["location"]).to_s
            return http_get(target, headers: headers, token: token, redirects: redirects - 1, open_timeout: open_timeout, read_timeout: read_timeout, &block)
          end
          return block.call(response, uri.to_s)
        end
      end
    end

    # Downloads url to path; progress receives (bytes, total or 0).
    def http_download(url, path, token: nil, &progress)
      partial = path + ".part"
      http_get(url, token: token, read_timeout: 120) do |response, _final|
        raise Error, "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)
        total = response["content-length"].to_i
        got = 0
        File.open(partial, "wb") do |file|
          response.read_body do |chunk|
            token.raise_if_cancelled! if token != nil
            file.write(chunk)
            got += chunk.bytesize
            progress.call(got, total) if progress != nil
          end
        end
      end
      File.delete(path) if File.exist?(path)
      File.rename(partial, path)
      path
    ensure
      File.delete(partial) if partial != nil && File.exist?(partial) rescue nil
    end

    # ------------------------------------------------------------------ log

    def log_info(text)
      Log.info(text) if defined?(Log)
    rescue Exception
      nil
    end

    def log_warning(text)
      Log.warning(text) if defined?(Log)
    rescue Exception
      nil
    end
  end
end
