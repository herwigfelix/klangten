# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.

# iOS desktop runtime.
#
# On Windows and macOS the EltenWindow / EltenKeyboard layer captures *physical*
# keyboard events from a native window. iOS has no physical keyboard model and
# no windowing that the app owns, so instead this runtime exposes the exact same
# public contract but is fed from an *injection queue*: the touch-gesture layer
# (src/platforms/ios/ui/touchinput.rb) and the accessible on-screen keyboard
# (src/ui/controls/onscreen_keyboard.rb) synthesise virtual key events and typed
# characters, which the unchanged scene/UI code then consumes as if they came
# from a real keyboard.
#
# The native Swift host (see ios/) drives the same injection API over the
# embedded Ruby C API (rb_funcall on IOSWindowNative), so a hardware keyboard,
# VoiceOver focus changes and app foreground/background transitions all funnel
# through here as well.

module IOSWindowNative
  MAX_KEY_EVENT_QUEUE = 4096

  class << self
    def available?
      true
    end

    # --- foreground / focus state (host driven) ---------------------------

    # The native host calls this on scene phase changes (foreground/background,
    # protected windows, etc.). Defaults to active so headless tooling works.
    def set_active(active)
      @active = (active == true)
      clear_state unless @active
      @active
    end

    def active?
      @active != false
    end

    # --- injection API (called by the touch layer and the native host) ----

    # Press a virtual key and leave it held until release_key. Used for
    # modifiers that must stay down across a gesture (Ctrl, Shift, Alt).
    def press_key(vk, repeat = false)
      vk = normalize_key(vk)
      return false if vk == nil
      ensure_state
      down_before = key_down?(@state, vk)
      schedule(@frame, vk, repeat ? :repeat : true)
      true
    end

    def release_key(vk)
      vk = normalize_key(vk)
      return false if vk == nil
      ensure_state
      schedule(@frame, vk, false)
      true
    end

    # Discrete key press: press this frame, release the next frame, so the app
    # observes a clean first_pressed -> released transition. This is what a swipe
    # or tap gesture maps to (arrow, enter, escape, tab, context menu, ...).
    def tap_key(vk)
      vk = normalize_key(vk)
      return false if vk == nil
      ensure_state
      schedule(@frame, vk, true)
      schedule(@frame + 1, vk, false)
      true
    end

    # Press a key, keep it held for `frames` app loop iterations, then release.
    # Needed for keys whose handlers require the key to be observed held across
    # intermediate frames (e.g. Alt, which only opens the main menu after being
    # held and then released, mirroring a real key press/hold/release).
    def hold_key(vk, frames = 3)
      vk = normalize_key(vk)
      return false if vk == nil
      ensure_state
      span = frames.to_i < 2 ? 2 : frames.to_i
      schedule(@frame, vk, true)
      schedule(@frame + span, vk, false)
      true
    end

    # Hold one or more modifiers, tap a key while they are down, then release
    # them. Spread across frames so a real Ctrl+key / Shift+key chord is seen.
    def tap_chord(modifiers, vk)
      vk = normalize_key(vk)
      return false if vk == nil
      mods = Array(modifiers).map { |m| normalize_key(m) }.compact
      ensure_state
      mods.each { |m| schedule(@frame, m, true) }
      schedule(@frame + 1, vk, true)
      schedule(@frame + 2, vk, false)
      mods.each { |m| schedule(@frame + 3, m, false) }
      true
    end

    # Enqueue typed characters (UTF-8). Consumed by getkeychar via take_character.
    def type_character(text)
      ensure_state
      value = text.to_s
      return true if value == ""
      value = value.dup.force_encoding("UTF-8")
      value = value.encode("UTF-8", invalid: :replace, undef: :replace) unless value.valid_encoding?
      @char_buffer << value
      true
    end

    # --- consumption API (called by the unchanged input layer) ------------

    def consume_key_events
      ensure_state
      events = @scheduled.delete(@frame) || []
      events.each do |vk, down|
        apply_event_to_state(vk, down)
      end
      @frame += 1
      prune_scheduled
      events.map { |vk, down| [vk, down] }
    rescue Exception
      []
    end

    def take_character(_multi = false)
      ensure_state
      return "" if @char_buffer.empty?
      value = @char_buffer.dup
      @char_buffer = +""
      value
    rescue Exception
      ""
    end

    def keyboard_state
      ensure_state
      return "\0" * 256 unless active?
      @state.dup
    rescue Exception
      "\0" * 256
    end

    def keyboard_active?
      active?
    end

    def clear_state
      @state = "\0" * 256
      @scheduled = {}
      @char_buffer = +""
      @frame = 0
      true
    end

    # host-driven one-shot requests ---------------------------------------

    def request_close
      @close_requested = true
    end

    def consume_close_request
      requested = @close_requested == true
      @close_requested = false
      requested
    end

    def request_minimize
      @minimize_requested = true
    end

    def consume_minimize_request
      requested = @minimize_requested == true
      @minimize_requested = false
      requested
    end

    private

    def ensure_state
      @state ||= "\0" * 256
      @scheduled ||= {}
      @char_buffer ||= +""
      @frame ||= 0
    end

    def schedule(frame, vk, down)
      ensure_state
      list = (@scheduled[frame] ||= [])
      list << [vk, down]
      trim_scheduled
      true
    end

    def trim_scheduled
      total = @scheduled.values.reduce(0) { |sum, list| sum + list.size }
      return if total <= MAX_KEY_EVENT_QUEUE
      # drop the oldest frame buckets first
      @scheduled.keys.sort.each do |frame|
        break if @scheduled.values.reduce(0) { |sum, list| sum + list.size } <= MAX_KEY_EVENT_QUEUE
        @scheduled.delete(frame)
      end
    end

    def prune_scheduled
      @scheduled.keys.each { |frame| @scheduled.delete(frame) if frame < @frame }
    end

    def apply_event_to_state(vk, down)
      vk = vk.to_i & 0xff
      byte = @state.getbyte(vk).to_i
      if down == false
        @state.setbyte(vk, byte & 0x7f)
      else
        @state.setbyte(vk, byte | 0x80)
      end
    end

    def key_down?(state, vk)
      (state.to_s.getbyte(vk.to_i & 0xff).to_i & 0x80) != 0
    end

    def normalize_key(vk)
      return nil if vk == nil
      value = vk.to_i
      return nil if value <= 0 || value > 255
      value & 0xff
    end
  end
end

# EltenKeyboard: character translation and raw-state helpers. Mirrors the public
# surface used across the app; state is sourced from the injection queue.
module EltenKeyboard
  VK_SHIFT = 0x10
  VK_CONTROL = 0x11
  VK_MENU = 0x12
  MODIFIER_KEYS = [VK_SHIFT, VK_CONTROL, VK_MENU, 0x5B, 0x5C, 0x5D]

  CHAR_BY_VK = {
    0x20 => [" ", " "], 0x30 => ["0", ")"], 0x31 => ["1", "!"], 0x32 => ["2", "@"],
    0x33 => ["3", "#"], 0x34 => ["4", "$"], 0x35 => ["5", "%"], 0x36 => ["6", "^"],
    0x37 => ["7", "&"], 0x38 => ["8", "*"], 0x39 => ["9", "("], 0xBA => [";", ":"],
    0xBB => ["=", "+"], 0xBC => [",", "<"], 0xBD => ["-", "_"], 0xBE => [".", ">"],
    0xBF => ["/", "?"], 0xC0 => ["`", "~"], 0xDB => ["[", "{"], 0xDC => ["\\", "|"],
    0xDD => ["]", "}"], 0xDE => ["'", "\""]
  }

  class << self
    def fill_flags(buffer)
      return 0 unless buffer.respond_to?(:setbyte)
      state = raw_state
      for key in 0..255
        buffer.setbyte(key, (state.getbyte(key).to_i & 0x80) != 0 ? 1 : 0)
      end
      0
    rescue Exception
      0
    end

    def flags_state
      raw_state
    end

    def raw_state
      EltenWindow.keyboard_state.to_s.byteslice(0, 256).to_s.ljust(256, "\0")
    rescue Exception
      "\0" * 256
    end

    def sync_physical_state
      true
    end

    def clear_state
      EltenWindow.clear_input_state if defined?(EltenWindow)
      IOSWindowNative.clear_state
      true
    rescue Exception
      false
    end

    def active_pressed_keys
      state = raw_state
      keys = Array.new(256, false)
      for key in 0..255
        keys[key] = (state.getbyte(key).to_i & 0x80) != 0
      end
      keys
    rescue Exception
      Array.new(256, false)
    end

    def async_key_down?(key)
      key = key.to_i & 0xff
      (raw_state.getbyte(key).to_i & 0x80) != 0
    rescue Exception
      false
    end

    def translate_virtual_key(key, state = nil, _flags = 4)
      key = key.to_i
      state = normalize_keyboard_state(state == nil ? raw_state : state)
      return "" if key_down?(state, VK_CONTROL) || key_down?(state, VK_MENU)
      shift = key_down?(state, VK_SHIFT)
      if key >= 0x41 && key <= 0x5A
        char = key.chr
        return shift ? char : char.downcase
      end
      chars = CHAR_BY_VK[key]
      chars ? chars[shift ? 1 : 0] : ""
    rescue Exception
      ""
    end

    private

    def capture_keyboard_state_raw
      raw_state
    end

    def key_down?(state, key)
      (state.to_s.getbyte(key.to_i & 0xff).to_i & 0x80) != 0
    end

    def normalize_keyboard_state(state)
      if state.is_a?(Array)
        state.map { |key| key ? 255 : 0 }.pack("C*")
      else
        state.to_s
      end.byteslice(0, 256).to_s.ljust(256, "\0")
    rescue Exception
      "\0" * 256
    end
  end
end

module EltenWindow
  SW_HIDE = 0
  SW_SHOW = 5
  SW_RESTORE = 9

  class << self
    attr_reader :hwnd

    def ensure_window
      @window_created ||= false
      unless @window_created
        @window_created = true
        @visible = ($elten_start_hidden != true)
        @hwnd = 1
      end
      $wnd = @hwnd
      @hwnd
    end

    def show(_command = SW_SHOW)
      ensure_window
      @visible = true
      @minimized = false
      IOSWindowNative.set_active(true)
      true
    end

    def hide
      ensure_window
      @visible = false
      true
    end

    def show_window(_hwnd = nil, command = SW_SHOW)
      command.to_i == SW_HIDE ? hide : show(command)
    end

    def hide_window(_hwnd = nil)
      hide
    end

    def focus(_hwnd = nil)
      show
      true
    end

    def message_box(text, caption = "Elten", _flags = 0, _owner = nil)
      ensure_window
      if defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:message_box) && IOSHostBridge.message_box(text.to_s, caption.to_s)
        return 1
      end
      Log.info("Elten dialog [#{caption}]: #{text}") if defined?(Log)
      0
    rescue Exception
      0
    end

    def foreground_window
      keyboard_active? ? ensure_window : 0
    end

    def active_or_child?(_hwnd = nil)
      keyboard_active?
    end

    def minimized?
      @minimized == true
    end

    def tray_supported?
      false
    end

    def hide_to_tray
      false
    end

    def restore_from_tray
      show(SW_RESTORE)
      true
    end

    def keyboard_active?
      ensure_window
      return false if @visible == false
      IOSWindowNative.keyboard_active?
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
      requested || IOSWindowNative.consume_close_request
    end

    def consume_quit_shortcut_request
      false
    end

    def consume_minimize_request
      requested = @minimize_requested == true
      @minimize_requested = false
      requested || IOSWindowNative.consume_minimize_request
    end

    def update_messages
      pump_messages
      true
    end

    def service_window_update
      update_messages
    end

    def keyboard_state
      IOSWindowNative.keyboard_state.to_s
    end

    def clear_input_state
      IOSWindowNative.clear_state
      true
    end

    def post_window_action(_wait = false, &block)
      block == nil ? false : block.call
    end

    def window_thread?
      @window_thread ||= (($mainthread != nil) ? $mainthread : Thread.current)
      Thread.current == @window_thread
    end

    def begin_input_frame
      true
    end

    # iOS delivers real characters (on-screen keyboard / hardware keyboard) so
    # getkeychar takes the fast character-input path instead of decoding VKs.
    def character_input_supported?
      true
    end

    def keyboard_flags_driven?
      false
    end

    def keyboard_key_held?(key)
      (keyboard_state.getbyte(key.to_i & 0xff).to_i & 0x80) != 0
    rescue Exception
      false
    end

    def keyboard_event_driven?
      true
    end

    def keyboard_pressed_implies_held?
      false
    end

    def take_character(multi = false)
      IOSWindowNative.take_character(multi)
    end

    def consume_key_events
      IOSWindowNative.consume_key_events
    rescue Exception
      []
    end

    private

    def apple_string(text)
      text.to_s.inspect
    end
  end
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
