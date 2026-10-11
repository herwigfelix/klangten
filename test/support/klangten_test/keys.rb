# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Key names of the test API -> Windows virtual-key codes, the codes the
# platform layers hand to EltenAPI::KeyboardState (modifiers as the generic
# VK_SHIFT/VK_CONTROL/VK_MENU, both Enter keys as VK_RETURN - as on Linux).
#
#   "down", "enter", "esc", "f4", "t", "T" (= shift+t), "ctrl+t",
#   "shift+tab", "alt+f4", "cmd+q", "ctrl+shift+i", "<c-s-i>"

module KlangtenTest
  module Keys
    Key = Struct.new(:mods, :code, :text)

    NAMED = {
      "down" => 0x28, "up" => 0x26, "left" => 0x25, "right" => 0x27,
      "enter" => 0x0D, "return" => 0x0D, "renter" => 0x0D,
      "esc" => 0x1B, "escape" => 0x1B, "tab" => 0x09,
      "space" => 0x20, "bs" => 0x08, "backspace" => 0x08,
      "home" => 0x24, "end" => 0x23,
      "pgup" => 0x21, "pageup" => 0x21, "pgdown" => 0x22, "pagedown" => 0x22,
      "del" => 0x2E, "delete" => 0x2E, "ins" => 0x2D, "insert" => 0x2D,
      "apps" => 0x5D, "contextmenu" => 0x5D,
      "ctrl" => 0x11, "control" => 0x11, "shift" => 0x10, "alt" => 0x12, "option" => 0x12,
      "cmd" => 0x5B, "command" => 0x5B, "win" => 0x5B,
      "capslock" => 0x14, "pause" => 0x13
    }.merge((1..12).map { |i| ["f#{i}", 0x6F + i] }.to_h).freeze

    MODIFIERS = {
      "ctrl" => 0x11, "control" => 0x11, "c" => 0x11,
      "shift" => 0x10, "s" => 0x10,
      "alt" => 0x12, "option" => 0x12, "a" => 0x12,
      "cmd" => 0x5B, "command" => 0x5B, "win" => 0x5B, "m" => 0x5B
    }.freeze

    # Characters on the US layout (unshifted, shifted) -> virtual key.
    CHARS = {}
    {
      0x20 => [" ", " "], 0x30 => ["0", ")"], 0x31 => ["1", "!"], 0x32 => ["2", "@"],
      0x33 => ["3", "#"], 0x34 => ["4", "$"], 0x35 => ["5", "%"], 0x36 => ["6", "^"],
      0x37 => ["7", "&"], 0x38 => ["8", "*"], 0x39 => ["9", "("], 0xBA => [";", ":"],
      0xBB => ["=", "+"], 0xBC => [",", "<"], 0xBD => ["-", "_"], 0xBE => [".", ">"],
      0xBF => ["/", "?"], 0xC0 => ["`", "~"], 0xDB => ["[", "{"], 0xDC => ["\\", "|"],
      0xDD => ["]", "}"], 0xDE => ["'", "\""]
    }.each do |vk, (plain, shifted)|
      CHARS[plain] = [vk, false]
      CHARS[shifted] = [vk, true] unless CHARS.key?(shifted)
    end
    ("a".."z").each { |c| CHARS[c] = [c.upcase.ord, false]; CHARS[c.upcase] = [c.upcase.ord, true] }
    CHARS.freeze

    module_function

    # "ctrl+t" -> Key(mods: [0x11], code: 0x54, text: "")
    def parse(spec)
      spec = spec.to_s
      mods = []
      name = spec
      if spec.length > 3 && spec.start_with?("<") && spec.end_with?(">")
        inner = spec[1..-2]
        while inner.length >= 3 && inner[1] == "-" && MODIFIERS.key?(inner[0])
          mods << MODIFIERS[inner[0]]
          inner = inner[2..]
        end
        name = inner
      elsif spec.length > 1 && spec.include?("+")
        parts = spec.split("+")
        parts << "+" if spec.end_with?("+")
        name = parts.pop
        parts.each do |m|
          code = m.length > 1 ? MODIFIERS[m.downcase] : nil
          raise ArgumentError, "unknown modifier #{m.inspect} in #{spec.inspect}" if code == nil
          mods << code
        end
      end
      if name.length == 1
        entry = CHARS[name]
        raise ArgumentError, "unknown key #{spec.inspect}" if entry == nil
        code, shifted = entry
        mods << 0x10 if shifted && !mods.include?(0x10)
        plain = (mods - [0x10]).empty?
        return Key.new(mods.uniq, code, plain ? name : "")
      end
      code = NAMED[name.downcase]
      raise ArgumentError, "unknown key #{spec.inspect}" if code == nil
      text = (code == 0x20 && (mods - [0x10]).empty?) ? " " : ""
      Key.new(mods.uniq, code, text)
    end

    # Virtual key for typing one character; nil when it has none on the US
    # layout (it is then typed as text only, like an AltGr or IME character).
    def for_char(char)
      CHARS[char]
    end
  end
end
