# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Playlist addresses of internet radio.
#
# BASS followed them by itself (BASS_CONFIG_NET_PLAYLIST); FFmpeg, which
# opens streams since Klangten 0.4, does not. Radio stations often give an
# .m3u, .pls or .asx file whose entries are the actual stream (Radio Saas in
# the media catalog: https://radio-saas.de/stream.m3u), and those stayed
# silent. Bass.create_url_stream (src/eapi/audio/bass.rb) asks here first and
# plays the first stream of the list. HLS lists (#EXT-X-...) stay with FFmpeg,
# which plays them itself.

require "uri"

module KlangtenStreamPlaylists
  EXTENSIONS = %w[.m3u .pls .asx .wax .wvx .xspf .ram].freeze
  MAX_BYTES = 64 * 1024
  TIMEOUT = 8
  DEPTH = 3

  class << self
    def address?(url)
      path = url.to_s.split(/[?#]/, 2)[0].to_s
      EXTENSIONS.include?(File.extname(path).downcase)
    end

    # The stream a playlist address points to, or nil when the address is no
    # playlist (audio, HLS) or cannot be read.
    def resolve(url, depth = 0)
      return nil if depth >= DEPTH
      text, base = fetch(url.to_s)
      return nil if text == nil
      entry = entries(text, base).first
      return nil if entry == nil
      return resolve(entry, depth + 1) || entry if address?(entry)
      entry
    rescue Exception => e
      Log.warning("Playlist address could not be read: #{url}: #{e.class}: #{e.message}") if defined?(Log)
      nil
    end

    # The beginning of a text answer (following redirects) and its final
    # address; nil for audio, so a live stream is never downloaded here.
    def fetch(url, redirects = 0)
      require "net/http"
      uri = URI.parse(url)
      return nil if !uri.is_a?(URI::HTTP) || redirects > 5
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        store = defined?(::EltenAPI::TLS) ? (::EltenAPI::TLS.certificate_store rescue nil) : nil
        http.cert_store = store if store != nil
      end
      result = nil
      http.start do |connection|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Klangten"
        connection.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection) && response["location"].to_s != ""
            result = [:redirect, URI.join(url, response["location"]).to_s]
            break
          end
          break if !response.is_a?(Net::HTTPSuccess)
          type = response["content-type"].to_s.downcase
          break if type.start_with?("audio/", "video/") && !type.match?(/mpegurl|scpls|x-ms-asf|ms-wax|ms-wvx|xspf|realaudio/)
          body = "".b
          response.read_body do |chunk|
            body << chunk
            break if body.bytesize >= MAX_BYTES
          end
          result = [body, url]
          # Leaving the block skips Net::HTTP reading the rest of the body.
          break
        end
      end
      return fetch(result[1], redirects + 1) if result != nil && result[0] == :redirect
      return nil if result == nil
      text = result[0][0, MAX_BYTES].force_encoding(Encoding::UTF_8).scrub("")
      # Binary data (an audio stream sent as text) is no playlist.
      return nil if text.include?("\0") || text.match?(/#EXT-X-/)
      [text, result[1]]
    rescue IOError, EOFError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, URI::Error
      nil
    end

    # The http(s) streams a playlist names, in order. Understands M3U, PLS,
    # ASX/WAX/WVX and XSPF; relative entries are resolved against base.
    def entries(text, base)
      entries = if text.match?(/^\s*\[playlist\]/i)
                  text.scan(/^\s*File\d+\s*=\s*(\S.*?)\s*$/i).flatten
                elsif text.match?(/<asx\b/i)
                  text.scan(/<ref\s[^>]*href\s*=\s*["']([^"']+)["']/i).flatten
                elsif text.match?(/<playlist\b[^>]*xspf/i)
                  text.scan(/<location>\s*([^<]+?)\s*<\/location>/i).flatten
                else
                  text.lines.map(&:strip).reject { |line| line == "" || line.start_with?("#") }
                end
      entries.filter_map do |entry|
        entry = entry.gsub("&amp;", "&")
        entry = URI.join(base, entry).to_s if !entry.match?(/\A[a-z][a-z0-9+.\-]*:/i)
        entry.match?(/\Ahttps?:\/\//i) ? entry : nil
      rescue URI::Error
        nil
      end
    end
  end
end
