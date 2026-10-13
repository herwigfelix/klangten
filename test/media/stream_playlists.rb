# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Playlist addresses of internet radio (src/eapi/audio/stream_playlists.rb),
# against a local HTTP server: M3U, PLS, ASX and XSPF lead to their stream,
# a list of a list is followed, while an endless audio stream and an HLS list
# are left alone - the audio stream without being downloaded.

require "minitest/autorun"
require "socket"
require "openssl"
require_relative "support"

load File.join(ROOT, "src/eapi/audio/stream_playlists.rb")

class StreamPlaylistsTest < Minitest::Test
  def setup
    @audio_requests = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @base = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |connection| answer(connection) }
      end
    rescue IOError
      nil
    end
  end

  def teardown
    @server.close
    @thread.kill
  end

  def pages
    {
      "/radio.m3u" => ["audio/x-mpegurl", "#EXTM3U\n#EXTINF:-1,Test\n#{@base}/stream\n"],
      "/relative.m3u" => ["audio/x-mpegurl", "# comment\n\nstream\n"],
      "/radio.pls" => ["audio/x-scpls", "[playlist]\nNumberOfEntries=2\nFile1=#{@base}/stream\nTitle1=Test\nFile2=#{@base}/other\n"],
      "/radio.asx" => ["video/x-ms-asf", "<ASX version=\"3.0\"><Entry><Ref href=\"#{@base}/stream?a=1&amp;b=2\"/></Entry></ASX>"],
      "/radio.xspf" => ["application/xspf+xml", "<?xml version=\"1.0\"?><playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\"><trackList><track><location>#{@base}/stream</location></track></trackList></playlist>"],
      "/outer.m3u" => ["audio/x-mpegurl", "#{@base}/radio.pls\n"],
      "/listen" => ["text/plain", "#{@base}/stream\n"],
      "/moved.m3u" => [:redirect, "/radio.m3u"],
      "/live.m3u8" => ["application/vnd.apple.mpegurl", "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\nsegment0.ts\n"]
    }
  end

  def answer(connection)
    path = connection.gets.to_s.split(" ")[1].to_s
    nil while (line = connection.gets) && line != "\r\n"
    if path.start_with?("/stream")
      @audio_requests += 1
      connection.write("HTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n")
      loop do
        connection.write("\xFF\xFB\x90\x00".b * 4096)
        sleep(0.05)
      end
    end
    type, body = pages[path]
    if type == :redirect
      connection.write("HTTP/1.0 302 Found\r\nLocation: #{body}\r\n\r\n")
    elsif type == nil
      connection.write("HTTP/1.0 404 Not Found\r\nContent-Type: text/html\r\n\r\nnot here")
    else
      connection.write("HTTP/1.0 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
  rescue StandardError
    nil
  ensure
    connection.close rescue nil
  end

  def test_the_usual_playlist_formats_lead_to_their_stream
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/radio.m3u")
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/radio.pls")
    assert_equal "#{@base}/stream?a=1&b=2", KlangtenStreamPlaylists.resolve("#{@base}/radio.asx")
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/radio.xspf")
  end

  def test_relative_entries_lists_of_lists_and_redirects
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/relative.m3u")
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/outer.m3u")
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/moved.m3u")
  end

  # Found only when FFmpeg could not open the address (Bass.create_url_stream).
  def test_a_playlist_without_a_telling_name
    refute KlangtenStreamPlaylists.address?("#{@base}/listen")
    assert_equal "#{@base}/stream", KlangtenStreamPlaylists.resolve("#{@base}/listen")
  end

  def test_audio_hls_and_missing_pages_are_left_alone
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil KlangtenStreamPlaylists.resolve("#{@base}/stream")
    assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 2, "the endless stream was read"
    assert_nil KlangtenStreamPlaylists.resolve("#{@base}/live.m3u8")
    assert_nil KlangtenStreamPlaylists.resolve("#{@base}/gone.m3u")
  end

  def test_which_addresses_are_playlists
    assert KlangtenStreamPlaylists.address?("https://radio-saas.de/stream.m3u")
    assert KlangtenStreamPlaylists.address?("http://example.org/Radio.PLS?x=1")
    refute KlangtenStreamPlaylists.address?("http://example.org/live.m3u8")
    refute KlangtenStreamPlaylists.address?("http://example.org/stream.mp3")
  end
end
