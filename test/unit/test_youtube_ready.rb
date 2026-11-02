# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# YouTube refuses freshly issued stream addresses of some clients for the
# first seconds (HTTP 403). A fresh resolution waits until the best stream
# answers; without that every format failed at once ("This video has no
# audio stream that can be played"). No network, no yt-dlp, virtual time.
#
#   ruby test/unit/test_youtube_ready.rb

require "minitest/autorun"

module EltenAPI
  module HTTPClient; end
end

# The media finder/extractor base classes live in other files.
class MediaFinder; end unless defined?(MediaFinder)
class MediaExtractor; end unless defined?(MediaExtractor)

module Log
  @warnings = []
  class << self
    attr_reader :warnings
    def warning(text) = @warnings << text
    def debug(_text) = nil
  end
end

require_relative "../../src/eapi/youtube"

class TestYouTubeReady < Minitest::Test
  URL = "https://rr2---sn-x.googlevideo.com/videoplayback?c=TVHTML5&clen=3504082".freeze

  def setup
    @clock = 0.0
    @answers = []
    @requests = []
    clock = -> { @clock }
    advance = ->(seconds) { @clock += seconds }
    answers = @answers
    requests = @requests
    yt = KlangtenYouTube
    yt.instance_variable_set(:@video_cache, {})
    yt.define_singleton_method(:monotonic) { clock.call }
    yt.define_singleton_method(:pause) { |seconds, _token| advance.call(seconds) }
    yt.define_singleton_method(:desktop?) { true }
    yt.define_singleton_method(:desktop_video) do |id, _token|
      KlangtenYouTube::Video.new(id: id, url: KlangtenYouTube.video_url(id), title: "t", streams: [
        KlangtenYouTube::Stream.new(url: URL, codec: "Opus", container: "webm", bitrate: 142, format_id: "251")
      ])
    end
    EltenAPI::HTTPClient.define_singleton_method(:readurl) do |url, _method, _body, headers, _data, cancellation_token: nil, &block|
      requests << [url, headers]
      answer = answers.empty? ? "x" : answers.shift
      Thread.new { block.call(answer, nil, {}) }
    end
    Log.warnings.clear
  end

  def test_waits_until_a_refused_stream_answers
    @answers.concat([:error, :error, :error, "x"])     # 403, 403, 403, 206
    video = KlangtenYouTube.video("A9IaEX333Bs", cached: false)
    assert_equal "A9IaEX333Bs", video.id
    assert_equal 4, @requests.size
    assert(@requests.all? { |url, headers| url == URL && headers["Range"] == "bytes=0-0" })
    assert_in_delta 3.0, @clock, 0.001                 # three pauses of one second
    assert_empty Log.warnings
  end

  def test_cached_video_is_not_probed_again
    KlangtenYouTube.video("A9IaEX333Bs", cached: false)
    @requests.clear
    KlangtenYouTube.video("A9IaEX333Bs", cached: true)
    assert_empty @requests
  end

  def test_gives_up_after_the_limit_and_still_returns_the_video
    @answers.concat([:error] * 100)
    video = KlangtenYouTube.video("A9IaEX333Bs", cached: false)
    refute_nil video
    assert_operator @clock, :>=, KlangtenYouTube::STREAM_READY_SECONDS
    assert_operator @clock, :<, KlangtenYouTube::STREAM_READY_SECONDS + 2
    assert_equal 1, Log.warnings.size
  end
end
