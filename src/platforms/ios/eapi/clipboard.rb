# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS clipboard backed by UIPasteboard. The native Swift host is preferred when
# attached (IOSHostBridge); otherwise the Objective-C runtime is used directly
# (UIKit symbols are statically linked into the signed app). Off-device this
# degrades to an empty clipboard so load and tests still succeed.

class ClipboardError < StandardError; end unless defined?(ClipboardError)

class Clipboard
  TEXT = 1 unless const_defined?(:TEXT)
  OEMTEXT = 7 unless const_defined?(:OEMTEXT)
  UNICODETEXT = 13 unless const_defined?(:UNICODETEXT)
  HDROP = 15 unless const_defined?(:HDROP)
  NS_UTF8_STRING_ENCODING = 4 unless const_defined?(:NS_UTF8_STRING_ENCODING)

  class << self
    def available?
      return true if host_bridge?
      initialize_native
    end

    def open
      self
    end

    def close
      self
    end

    def set_data(clip_data, _format = TEXT)
      self.text = clip_data.to_s
    end

    def data(_format = TEXT)
      text
    end
    alias get_data data

    def empty
      self.text = ""
      self
    end

    def text
      return IOSHostBridge.clipboard_text.to_s if host_bridge?
      return "" unless initialize_native
      value = @msg_id.call(general_pasteboard, sel("string"))
      objc_string(value)
    rescue Exception
      ""
    end

    def text=(value)
      if host_bridge?
        IOSHostBridge.clipboard_text = value.to_s
        return value
      end
      return value unless initialize_native
      @msg_void_id.call(general_pasteboard, sel("setString:"), ns_string(value.to_s))
      value
    rescue Exception
      value
    end

    def files
      []
    end

    def files=(_paths)
      nil
    end

    private

    def host_bridge?
      defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:clipboard_text)
    rescue Exception
      false
    end

    def initialize_native
      return @native_available if defined?(@native_available)
      @native_available = false
      unless defined?(Fiddle)
        verbose = $VERBOSE
        $VERBOSE = nil
        begin
          require "fiddle"
        ensure
          $VERBOSE = verbose
        end
      end
      objc = Fiddle.dlopen(nil)
      id = Fiddle::TYPE_VOIDP
      sel_type = Fiddle::TYPE_VOIDP
      native_unsigned = Fiddle::SIZEOF_VOIDP == 8 ? Fiddle::TYPE_ULONG_LONG : Fiddle::TYPE_ULONG
      @objc_get_class = Fiddle::Function.new(objc["objc_getClass"], [Fiddle::TYPE_VOIDP], id)
      @sel_register_name = Fiddle::Function.new(objc["sel_registerName"], [Fiddle::TYPE_VOIDP], sel_type)
      msg = objc["objc_msgSend"]
      @msg_id = Fiddle::Function.new(msg, [id, sel_type], id)
      @msg_id_id = Fiddle::Function.new(msg, [id, sel_type, id], id)
      @msg_void_id = Fiddle::Function.new(msg, [id, sel_type, id], Fiddle::TYPE_VOID)
      @msg_id_bytes = Fiddle::Function.new(msg, [id, sel_type, Fiddle::TYPE_VOIDP, native_unsigned, native_unsigned], id)
      @msg_ulong_ulong = Fiddle::Function.new(msg, [id, sel_type, native_unsigned], native_unsigned)
      @native_available = cls("UIPasteboard").to_i != 0 && cls("NSString").to_i != 0
    rescue Exception
      @native_available = false
    end

    def general_pasteboard
      @msg_id.call(cls("UIPasteboard"), sel("generalPasteboard"))
    end

    def ns_string(value)
      bytes = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).b
      @msg_id_bytes.call(cls("NSString"), sel("stringWithBytes:length:encoding:"), bytes, bytes.bytesize, NS_UTF8_STRING_ENCODING)
    end

    def objc_string(object)
      return "" if object.to_i == 0
      pointer = @msg_id.call(object, sel("UTF8String"))
      return "" if pointer.to_i == 0
      length = @msg_ulong_ulong.call(object, sel("lengthOfBytesUsingEncoding:"), NS_UTF8_STRING_ENCODING).to_i
      bytes = length > 0 ? Fiddle::Pointer.new(pointer)[0, length] : ""
      bytes = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      bytes.valid_encoding? ? bytes : bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    rescue Exception
      ""
    end

    def cls(name)
      @classes ||= {}
      @classes[name] ||= @objc_get_class.call(name.to_s.b + "\0".b)
    end

    def sel(name)
      @selectors ||= {}
      @selectors[name] ||= @sel_register_name.call(name.to_s.b + "\0".b)
    end
  end
end
