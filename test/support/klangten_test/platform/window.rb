# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Test double for the desktop runtime (loaded instead of
# src/platforms/<os>/ri/desktopruntime.rb). It has the same shape as the
# Linux SDL layer: keys arrive as Windows virtual-key events, typed text as a
# character queue. Nothing is drawn and nothing is read from a real keyboard;
# the test feeds both at the start of a frame (KlangtenTest::Runtime.boundary),
# so the rest of Klangten - KeyboardState.update, take_character, the forms -
# runs exactly as with a real window that always has the focus.

module EltenKeyboard
  VK_SHIFT = 0x10
  VK_CONTROL = 0x11
  VK_MENU = 0x12

  CHAR_BY_VK = {
    0x20 => [" ", " "], 0x30 => ["0", ")"], 0x31 => ["1", "!"], 0x32 => ["2", "@"],
    0x33 => ["3", "#"], 0x34 => ["4", "$"], 0x35 => ["5", "%"], 0x36 => ["6", "^"],
    0x37 => ["7", "&"], 0x38 => ["8", "*"], 0x39 => ["9", "("], 0xBA => [";", ":"],
    0xBB => ["=", "+"], 0xBC => [",", "<"], 0xBD => ["-", "_"], 0xBE => [".", ">"],
    0xBF => ["/", "?"], 0xC0 => ["`", "~"], 0xDB => ["[", "{"], 0xDC => ["\\", "|"],
    0xDD => ["]", "}"], 0xDE => ["'", "\""]
  }

  class << self
    def clear_state
      true
    end

    def raw_state
      EltenWindow.keyboard_state
    end

    def active_pressed_keys
      state = raw_state
      (0..255).map { |key| key_down?(state, key) }
    end

    def translate_virtual_key(key, state = nil, _flags = 4)
      key = key.to_i
      state = normalize_keyboard_state(state)
      return "" if key_down?(state, VK_CONTROL) || key_down?(state, VK_MENU)
      native = EltenWindow.translated_character_for_key(key)
      return native if native != ""
      shift = key_down?(state, VK_SHIFT)
      if key >= 0x41 && key <= 0x5A
        char = key.chr
        return shift ? char : char.downcase
      end
      chars = CHAR_BY_VK[key]
      chars ? chars[shift ? 1 : 0] : ""
    end

    private

    def key_down?(state, key)
      (state.to_s.getbyte(key.to_i).to_i & 0x80) != 0
    end

    def normalize_keyboard_state(state)
      if state.is_a?(Array)
        state.map { |key| key ? 255 : 0 }.pack("C*")
      elsif state == nil
        raw_state
      else
        state.to_s
      end.byteslice(0, 256).to_s.ljust(256, "\0")
    end
  end
end

module EltenWindow
  SW_HIDE = 0
  SW_SHOW = 5
  SW_RESTORE = 9

  class << self
    attr_reader :hwnd

    # -------------------------------------------------- fed by the harness
    # One frame of input: [[vk, true/false], ...] and typed characters.
    def apply_frame_input(input)
      begin_character_frame
      return if input == nil
      Array(input[:events]).each do |vk, down|
        set_key(vk, down)
        @key_events << [vk, down]
        @translated.delete(vk) if down == false
      end
      Array(input[:chars]).each do |vk, text|
        @translated[vk] = text if vk != nil
        @char_queue.concat(text.to_s.chars)
      end
      @close_requested = true if input[:close]
      @quit_shortcut_requested = true if input[:quit]
    end

    def reset_test_state
      @kbstate = ("\0" * 256).b
      @key_events = []
      @translated = {}
      @char_queue = []
      @char_frame_prefix = 0
      @char_frame_consumed = false
      @close_requested = false
      @message_boxes = []
    end

    def message_boxes
      @message_boxes
    end

    # -------------------------------------------------- window contract
    def app_window_title
      defined?(Elten) && Elten.respond_to?(:window_title) ? Elten.window_title : Klangten::Config::PRODUCT_NAME
    end

    def ensure_window
      @hwnd ||= 1
      $wnd = @hwnd
      @hwnd
    end

    def show(_command = SW_SHOW)
      @visible = true
      true
    end

    def hide
      hide_window
    end

    def show_window(_hwnd = nil, command = SW_SHOW)
      command.to_i == SW_HIDE ? hide_window : show(command)
    end

    def hide_window(_hwnd = nil)
      true
    end

    def focus(_hwnd = nil)
      true
    end

    # Native message boxes are recorded and answered with the first button.
    def message_box(text, caption = Klangten::Config::PRODUCT_NAME, flags = 0, _owner = nil)
      @message_boxes << [caption.to_s, text.to_s, flags.to_i]
      KlangtenTest.record(:message_box, "#{caption}: #{text}")
      1
    end

    def foreground_window
      ensure_window
    end

    def active_or_child?(_hwnd = nil)
      true
    end

    def minimized?
      false
    end

    def tray_supported?
      false
    end

    def hide_to_tray
      false
    end

    def restore_from_tray
      true
    end

    def keyboard_active?
      true
    end

    def pump_messages
      true
    end

    def activation_input_blocked?
      false
    end

    def close_requested?
      @close_requested == true
    end

    def consume_close_request
      requested = @close_requested == true
      @close_requested = false
      requested
    end

    def consume_quit_shortcut_request
      requested = @quit_shortcut_requested == true
      @quit_shortcut_requested = false
      requested
    end

    def consume_minimize_request
      false
    end

    def update_messages
      true
    end

    def service_window_update
      true
    end

    def keyboard_state
      (@kbstate ||= ("\0" * 256).b).dup
    end

    def clear_input_state
      @kbstate = ("\0" * 256).b
      @char_queue = []
      @translated = {}
      EltenKeyboard.clear_state
      true
    end

    def post_window_action(_wait = false, &block)
      block == nil ? false : block.call
    end

    # The frame boundary: the scene thread waits here for the test.
    def begin_input_frame
      input = KlangtenTest::Runtime.boundary
      apply_frame_input(input) if KlangtenTest::Runtime.scene_thread?
      true
    end

    def character_input_supported?
      true
    end

    def keyboard_flags_driven?
      false
    end

    def keyboard_key_held?(_key)
      false
    end

    def keyboard_event_driven?
      true
    end

    def keyboard_pressed_implies_held?
      false
    end

    def translated_character_for_key(key)
      (@translated ||= {})[key.to_i & 0xff].to_s
    end

    def take_character(multi = false)
      @char_queue ||= []
      @char_frame_consumed = true
      return "" if @char_queue.empty?
      return @char_queue.shift.to_s if multi != true
      text = @char_queue.join
      @char_queue = []
      text
    end

    def consume_key_events
      events = @key_events || []
      @key_events = []
      events
    end

    private

    # Same rule as the Linux layer: characters nobody read for a whole frame
    # are dropped.
    def begin_character_frame
      @char_queue ||= []
      @char_queue.shift(@char_frame_prefix.to_i) if @char_frame_consumed != true
      @char_frame_prefix = @char_queue.size
      @char_frame_consumed = false
    end

    def set_key(vk, down)
      @kbstate ||= ("\0" * 256).b
      byte = @kbstate.getbyte(vk).to_i
      @kbstate.setbyte(vk, down ? (byte | 0x80) : (byte & 0x7f))
    end
  end

  reset_test_state
end

module EltenTray
  class << self
    def supported?
      false
    end

    def show(_hwnd = nil)
      0
    end

    def hide
      true
    end

    def handle_message?(_message)
      false
    end

    def restore_hotkey_pressed?
      false
    end

    def request_restore(_source = nil)
      false
    end

    def handle_callback(*_args)
      false
    end
  end
end

class Bitmap
  attr_reader :filename

  def initialize(filename = nil, height = nil)
    @filename = filename
    @height = height
  end

  def dispose
    true
  end
end

class Sprite
  attr_accessor :bitmap, :x, :y, :z, :visible, :opacity

  def initialize(viewport = nil)
    @viewport = viewport
    @visible = true
    @opacity = 255
    @x = 0
    @y = 0
    @z = 0
  end

  def dispose
    @bitmap = nil
    true
  end
end

module Kernel
  def load_data(filename)
    File.open(filename, "rb") { |file| Marshal.load(file) }
  end
  private :load_data

  def save_data(object, filename)
    File.open(filename, "wb") { |file| Marshal.dump(object, file) }
    true
  end
  private :save_data
end
