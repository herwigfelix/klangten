# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# Accessible on-screen keyboard for iOS.
#
# Elten self-voices, so this keyboard is not a set of native VoiceOver buttons;
# it is Elten's own key grid. The touch layer (IOSTouchInput) drives it two ways:
#   * explore-by-touch: point(x, y) speaks the key under the finger, commit types
#     it when the finger lifts;
#   * stepping: move(:left/:right/:up/:down) walks the grid speaking each key,
#     double-tap (commit) types the current one.
# Printable characters are injected as text (IOSWindowNative.type_character) so
# getkeychar picks them up via take_character; control keys (Enter, Backspace,
# arrows, Tab) are injected as virtual key taps so the scenes react exactly as
# they would to a hardware keyboard.

module OnScreenKeyboard
  BACKSPACE = 0x08
  ENTER = 0x0D
  TABKEY = 0x09
  LEFT = 0x25
  RIGHT = 0x27

  # Each key: [label, kind, value]
  #   kind :char    -> value is the string to type
  #   kind :key     -> value is a virtual key code to tap
  #   kind :command -> value is a symbol handled locally (layer switch / close)
  LAYERS = {
    lower: [
      [["q", :char, "q"], ["w", :char, "w"], ["e", :char, "e"], ["r", :char, "r"], ["t", :char, "t"], ["y", :char, "y"], ["u", :char, "u"], ["i", :char, "i"], ["o", :char, "o"], ["p", :char, "p"]],
      [["a", :char, "a"], ["s", :char, "s"], ["d", :char, "d"], ["f", :char, "f"], ["g", :char, "g"], ["h", :char, "h"], ["j", :char, "j"], ["k", :char, "k"], ["l", :char, "l"]],
      [["Shift", :command, :shift], ["z", :char, "z"], ["x", :char, "x"], ["c", :char, "c"], ["v", :char, "v"], ["b", :char, "b"], ["n", :char, "n"], ["m", :char, "m"], ["Backspace", :key, BACKSPACE]],
      [["123", :command, :numbers], ["Space", :char, " "], ["Enter", :key, ENTER], ["Close", :command, :close]]
    ],
    upper: [
      [["Q", :char, "Q"], ["W", :char, "W"], ["E", :char, "E"], ["R", :char, "R"], ["T", :char, "T"], ["Y", :char, "Y"], ["U", :char, "U"], ["I", :char, "I"], ["O", :char, "O"], ["P", :char, "P"]],
      [["A", :char, "A"], ["S", :char, "S"], ["D", :char, "D"], ["F", :char, "F"], ["G", :char, "G"], ["H", :char, "H"], ["J", :char, "J"], ["K", :char, "K"], ["L", :char, "L"]],
      [["Shift", :command, :shift], ["Z", :char, "Z"], ["X", :char, "X"], ["C", :char, "C"], ["V", :char, "V"], ["B", :char, "B"], ["N", :char, "N"], ["M", :char, "M"], ["Backspace", :key, BACKSPACE]],
      [["123", :command, :numbers], ["Space", :char, " "], ["Enter", :key, ENTER], ["Close", :command, :close]]
    ],
    numbers: [
      [["1", :char, "1"], ["2", :char, "2"], ["3", :char, "3"], ["4", :char, "4"], ["5", :char, "5"], ["6", :char, "6"], ["7", :char, "7"], ["8", :char, "8"], ["9", :char, "9"], ["0", :char, "0"]],
      [["-", :char, "-"], ["/", :char, "/"], [":", :char, ":"], [";", :char, ";"], ["(", :char, "("], [")", :char, ")"], ["@", :char, "@"], ["\"", :char, "\""], ["'", :char, "'"]],
      [["Symbols", :command, :symbols], [".", :char, "."], [",", :char, ","], ["?", :char, "?"], ["!", :char, "!"], ["_", :char, "_"], ["Backspace", :key, BACKSPACE]],
      [["ABC", :command, :letters], ["Space", :char, " "], ["Enter", :key, ENTER], ["Close", :command, :close]]
    ],
    symbols: [
      [["[", :char, "["], ["]", :char, "]"], ["{", :char, "{"], ["}", :char, "}"], ["#", :char, "#"], ["%", :char, "%"], ["^", :char, "^"], ["*", :char, "*"], ["+", :char, "+"], ["=", :char, "="]],
      [["\\", :char, "\\"], ["|", :char, "|"], ["~", :char, "~"], ["<", :char, "<"], [">", :char, ">"], ["$", :char, "$"], ["&", :char, "&"], ["`", :char, "`"]],
      [["123", :command, :numbers], ["Tab", :key, TABKEY], ["Backspace", :key, BACKSPACE]],
      [["ABC", :command, :letters], ["Space", :char, " "], ["Enter", :key, ENTER], ["Close", :command, :close]]
    ]
  }

  class << self
    def active?
      @active == true
    end

    def show
      @active = true
      @layer = :lower
      @row = 0
      @col = 0
      feedback_sound("dialog_open")
      announce("On-screen keyboard. Swipe to move between keys, double tap to type, two finger tap to delete, swipe with two fingers to close.")
      speak_current(true)
      true
    end

    def hide
      return false unless active?
      @active = false
      feedback_sound("Dialog_close")
      announce("Keyboard closed")
      true
    end

    def layer
      @layer || :lower
    end

    # Discrete stepping (one-finger swipes routed here while active).
    def move(direction)
      return false unless active?
      rows = current_rows
      case direction.to_sym
      when :up
        @row = (@row - 1) % rows.size
        @col = clamp_col(@col)
      when :down
        @row = (@row + 1) % rows.size
        @col = clamp_col(@col)
      when :left
        @col = (@col - 1) % rows[@row].size
      when :right
        @col = (@col + 1) % rows[@row].size
      end
      speak_current
      true
    end

    # Explore-by-touch: normalised x,y in 0..1 across the keyboard area.
    def point(x, y)
      return false unless active?
      rows = current_rows
      row = (y.to_f.clamp(0.0, 0.9999) * rows.size).to_i
      row = rows.size - 1 if row >= rows.size
      row = 0 if row < 0
      cols = rows[row].size
      col = (x.to_f.clamp(0.0, 0.9999) * cols).to_i
      col = cols - 1 if col >= cols
      col = 0 if col < 0
      changed = (row != @row || col != @col)
      @row = row
      @col = col
      speak_current if changed
      changed
    end

    def current_key
      current_rows[@row][@col]
    rescue Exception
      nil
    end

    def speak_current(detailed = false)
      key = current_key
      return false if key == nil
      feedback_sound("editbox_marker")
      label = key[0].to_s
      label = spoken_label(key) if detailed
      announce(label)
      true
    end

    # Type / execute the selected key (one-finger double tap or finger lift).
    def commit
      return false unless active?
      key = current_key
      return false if key == nil
      kind = key[1]
      value = key[2]
      case kind
      when :char
        IOSWindowNative.type_character(value.to_s)
        feedback_sound("editbox_bigletter")
      when :key
        IOSWindowNative.tap_key(value)
        feedback_sound("border")
      when :command
        run_command(value)
      end
      true
    end

    def backspace
      return false unless active?
      IOSWindowNative.tap_key(BACKSPACE)
      feedback_sound("editbox_delete")
      announce("Backspace")
      true
    end

    private

    def run_command(command)
      case command.to_sym
      when :shift
        @layer = (layer == :lower ? :upper : :lower)
        reset_position
        announce(layer == :upper ? "Uppercase" : "Lowercase")
      when :numbers
        @layer = :numbers
        reset_position
        announce("Numbers")
      when :symbols
        @layer = :symbols
        reset_position
        announce("Symbols")
      when :letters
        @layer = :lower
        reset_position
        announce("Letters")
      when :close
        hide
      end
      true
    end

    def reset_position
      @row = 0
      @col = 0
      speak_current
    end

    def current_rows
      LAYERS[layer] || LAYERS[:lower]
    end

    def clamp_col(col)
      size = current_rows[@row].size
      col >= size ? size - 1 : col
    end

    def spoken_label(key)
      label = key[0].to_s
      case key[1]
      when :char
        value = key[2].to_s
        return "space" if value == " "
        label
      else
        label
      end
    end

    def announce(text)
      return unless respond_to?(:speak, true)
      speak(text.to_s, stop: true)
    rescue Exception
    end

    def feedback_sound(name)
      return unless respond_to?(:play_sound, true)
      play_sound(name)
    rescue Exception
    end
  end
end
