# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# Bridge from the embedded Ruby core to the native Swift host.
#
# The host (ios/Elten) links a set of C entry points (elten_host_*) into the app
# executable and owns AVSpeechSynthesizer, UIPasteboard, the audio session, URL
# opening and permissions. Ruby reaches them here through Fiddle by resolving the
# symbols from the main image (Fiddle.dlopen(nil)). When the symbols are absent
# (headless tooling, unit tests, or a host that does not provide a capability),
# every accessor degrades to "unavailable" so the Ruby platform layer falls back
# gracefully instead of crashing.
#
# Input flows the other way: the host calls IOSWindowNative / IOSTouchInput over
# the Ruby C API, so it is not represented here.

module IOSHostBridge
  class << self
    def available?
      resolve!
      @available == true
    end

    # --- speech (AVSpeechSynthesizer, owned by the host) ------------------

    def speech_available?
      call_int(:speech_available) == 1
    end

    def speech_voices
      json = call_string(:speech_voices_json)
      return [] if json == ""
      require "json" unless defined?(JSON)
      Array(JSON.parse(json)).map do |voice|
        { id: voice["id"].to_s, name: voice["name"].to_s, language: voice["language"].to_s }
      end
    rescue Exception
      []
    end

    def speech_speak(text, voice_id, rate, volume, pitch, interrupt)
      call_speak(text.to_s, voice_id.to_s, rate.to_i, volume.to_i, pitch.to_i, interrupt ? 1 : 0)
      true
    end

    def speech_stop
      call_void(:speech_stop)
    end

    def speech_speaking?
      call_int(:speech_speaking) == 1
    end

    def speech_pause
      call_void(:speech_pause)
    end

    def speech_resume
      call_void(:speech_resume)
    end

    # --- clipboard (UIPasteboard) -----------------------------------------

    def clipboard_text
      call_string(:clipboard_get)
    end

    def clipboard_text=(value)
      call_set_string(:clipboard_set, value.to_s)
      value
    end

    # --- misc system integration ------------------------------------------

    def open_url(url)
      call_set_string_int(:open_url, url.to_s) == 1
    end

    def request_microphone_access(timeout = 15.0)
      fn = func(:microphone_request, [Fiddle::TYPE_DOUBLE], Fiddle::TYPE_INT)
      return true if fn == nil
      fn.call(timeout.to_f).to_i != 0
    rescue Exception
      true
    end

    def current_locale_name
      call_string(:locale)
    end

    def os_version
      call_string(:os_version)
    end

    def frameworks_path
      call_string(:frameworks_path)
    end

    def message_box(text, caption)
      call_two_strings_int(:message_box, caption.to_s, text.to_s) == 1
    end

    # --- system on-screen keyboard ----------------------------------------
    # The host owns a hidden text field; showing it raises the native iOS
    # on-screen keyboard. Typed text comes back through the input queue as a
    # "ktext:<text>" token when the user presses Return (which also dismisses
    # the keyboard).

    def system_keyboard_available?
      func(:system_keyboard_show, [], Fiddle::TYPE_VOID) != nil
    rescue Exception
      false
    end

    def system_keyboard_show
      call_void(:system_keyboard_show)
    end

    def system_keyboard_hide
      call_void(:system_keyboard_hide)
    end

    def system_keyboard_visible?
      call_int(:system_keyboard_visible) == 1
    end

    # --- host -> Ruby input queue -----------------------------------------
    # The host pushes recognised gestures / keyboard-explore events into a
    # native queue; Ruby drains one token at a time from its own thread (so the
    # GVL is respected). "" means the queue is empty.
    def next_input
      call_string(:next_input)
    end

    private

    def resolve!
      return if defined?(@resolved)
      @resolved = true
      @available = false
      @functions = {}
      unless defined?(Fiddle)
        verbose = $VERBOSE
        $VERBOSE = nil
        begin
          require "fiddle"
        ensure
          $VERBOSE = verbose
        end
      end
      @image = Fiddle.dlopen(nil)
      # Presence of the speech entry point means a host is attached.
      @available = symbol?("elten_host_speech_available")
    rescue Exception
      @available = false
      @image = nil
    end

    def symbol?(name)
      @image != nil && @image[name] != nil
    rescue Exception
      false
    end

    def func(suffix, args, ret)
      resolve!
      return nil if @image == nil
      name = "elten_host_#{suffix}"
      key = [name, args, ret]
      @functions[key] ||= begin
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

    def call_void(suffix)
      fn = func(suffix, [], Fiddle::TYPE_VOID)
      fn.call if fn != nil
      true
    rescue Exception
      false
    end

    def call_string(suffix)
      fn = func(suffix, [], Fiddle::TYPE_VOIDP)
      return "" if fn == nil
      pointer = fn.call
      return "" if pointer == nil || pointer.to_i == 0
      Fiddle::Pointer.new(pointer.to_i).to_s.force_encoding("UTF-8")
    rescue Exception
      ""
    end

    def call_set_string(suffix, value)
      fn = func(suffix, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      fn.call(cstr(value)) if fn != nil
      true
    rescue Exception
      false
    end

    def call_set_string_int(suffix, value)
      fn = func(suffix, [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      fn == nil ? 0 : fn.call(cstr(value)).to_i
    rescue Exception
      0
    end

    def call_two_strings_int(suffix, a, b)
      fn = func(suffix, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      fn == nil ? 0 : fn.call(cstr(a), cstr(b)).to_i
    rescue Exception
      0
    end

    def call_speak(text, voice, rate, volume, pitch, interrupt)
      fn = func(:speech_speak, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_VOID)
      fn.call(cstr(text), cstr(voice), rate, volume, pitch, interrupt) if fn != nil
      true
    rescue Exception
      false
    end

    def cstr(value)
      bytes = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace).b + "\0".b
      pointer = Fiddle::Pointer.malloc(bytes.bytesize)
      pointer[0, bytes.bytesize] = bytes
      pointer
    end
  end
end
