# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).

# YouTube data from the host, for Android.
#
# The desktop client drives yt-dlp; that needs a JavaScript runtime and a
# second process, neither of which exists on a phone. The Android host embeds
# NewPipeExtractor instead (android/app/src/main/java/it/sixdots/klangten/YouTube.java)
# and answers in JSON through the elten_host_youtube_* entry points. The YouTube
# program (src/programs/youtube/__app.rb) keeps its screens and only takes its
# data from here, so both platforms look and work the same.
#
# Every call blocks on the network and must run on a scene thread, never on the
# main thread.

module KlangtenYouTubeHost
  class << self
    def available?
      resolve!
      @available == true && call_int(:available) == 1
    rescue Exception
      false
    end

    # type: :search (videos), :channel or :playlist
    def search(query, type = :search)
      kind = case type.to_s
             when "channel" then "channel"
             when "playlist" then "playlist"
             else "video"
             end
      parse_list(call_two_strings(:search, query.to_s, kind))
    end

    def channel_videos(url)
      parse_list(call_string(:channel, url.to_s))
    end

    def playlist_videos(url)
      parse_list(call_string(:playlist, url.to_s))
    end

    # One video with its audio streams, or nil.
    def video(id)
      data = parse_json(call_string(:video, id.to_s))
      data.is_a?(Hash) && data["error"] == nil ? data : nil
    end

    private

    def resolve!
      return if defined?(@resolved)
      @resolved = true
      @available = false
      unless defined?(Fiddle)
        verbose = $VERBOSE
        $VERBOSE = nil
        begin
          require "fiddle"
        ensure
          $VERBOSE = verbose
        end
      end
      @image = Fiddle.dlopen("libklangten.so")
      @functions = {}
      @available = @image["elten_host_youtube_available"] != nil
    rescue Exception
      @available = false
      @image = nil
    end

    def parse_list(json)
      data = parse_json(json)
      data.is_a?(Array) ? data : []
    end

    def parse_json(json)
      return nil if json.to_s == ""
      require "json" unless defined?(JSON)
      JSON.parse(json)
    rescue Exception
      nil
    end

    def func(suffix, args, ret)
      resolve!
      return nil if @image == nil
      name = "elten_host_youtube_#{suffix}"
      @functions[[name, args, ret]] ||= begin
        pointer = @image[name]
        pointer == nil ? nil : Fiddle::Function.new(pointer, args, ret)
      end
    rescue Exception
      nil
    end

    def call_int(suffix)
      fn = func(suffix, [], Fiddle::TYPE_INT)
      fn == nil ? 0 : fn.call.to_i
    rescue Exception
      0
    end

    def call_string(suffix, value)
      fn = func(suffix, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      return "" if fn == nil
      read(fn.call(cstr(value)))
    rescue Exception
      ""
    end

    def call_two_strings(suffix, a, b)
      fn = func(suffix, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP)
      return "" if fn == nil
      read(fn.call(cstr(a), cstr(b)))
    rescue Exception
      ""
    end

    def read(pointer)
      return "" if pointer == nil || pointer.to_i == 0
      Fiddle::Pointer.new(pointer.to_i).to_s.force_encoding("UTF-8")
    end

    def cstr(value)
      bytes = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace).b + "\0".b
      pointer = Fiddle::Pointer.malloc(bytes.bytesize)
      pointer[0, bytes.bytesize] = bytes
      pointer
    end
  end
end
