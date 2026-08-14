# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS touch gesture layer.
#
# Elten's entire UI is keyboard-driven. On iOS there is no keyboard, so this
# module maps a fixed, learnable gesture vocabulary onto the exact virtual key
# codes the unchanged scenes already expect, injecting them through
# IOSWindowNative. The native Swift host recognises the raw gestures (finger
# count + direction / tap count / long press) and calls IOSTouchInput.perform
# with the matching symbol; nothing about the scene code changes.
#
# When the accessible on-screen keyboard is open (OnScreenKeyboard.active?),
# one-finger gestures are re-routed to drive the keyboard instead of scene
# navigation, so the same gestures type as they navigate.

module IOSTouchInput
  # Windows virtual key codes Elten navigates with.
  LEFT = 0x25
  UP = 0x26
  RIGHT = 0x27
  DOWN = 0x28
  ENTER = 0x0D
  ESCAPE = 0x1B
  TAB = 0x09
  CONTEXT = 0x5D
  ALT = 0x12
  CONTROL = 0x11
  SHIFT = 0x10
  HOME = 0x24
  ENDKEY = 0x23
  PAGEUP = 0x21
  PAGEDOWN = 0x22

  # gesture symbol => [action, *args]. This is the complete "everything the
  # keyboard does" surface, grouped by finger count so it stays memorable.
  GESTURES = {
    # one finger — move the selection / activate
    swipe_right:              [:tap, RIGHT],
    swipe_left:               [:tap, LEFT],
    swipe_up:                 [:tap, UP],
    swipe_down:               [:tap, DOWN],
    double_tap:               [:tap, ENTER],
    long_press:               [:tap, CONTEXT],

    # two fingers — cancel / stop / menu
    two_finger_tap:           [:stop_speech],
    two_finger_swipe_left:    [:tap, ESCAPE],
    two_finger_swipe_right:   [:tap, ESCAPE],
    two_finger_swipe_down:    [:tap, ESCAPE],
    two_finger_swipe_up:      [:tap, CONTEXT],
    two_finger_double_tap:    [:main_menu],

    # three fingers — move between controls / jump / keyboard
    three_finger_swipe_right: [:tap, TAB],
    three_finger_swipe_left:  [:chord, SHIFT, TAB],
    three_finger_swipe_up:    [:tap, HOME],
    three_finger_swipe_down:  [:tap, ENDKEY],
    three_finger_double_tap:  [:toggle_keyboard],

    # four fingers — page / keyboard fallback
    four_finger_swipe_up:     [:tap, PAGEUP],
    four_finger_swipe_down:   [:tap, PAGEDOWN],
    four_finger_double_tap:   [:toggle_keyboard]
  }

  # Short human-readable descriptions for the in-app gesture help / host hints.
  LABELS = {
    swipe_right: "Next item (Right)",
    swipe_left: "Previous item (Left)",
    swipe_up: "Up",
    swipe_down: "Down",
    double_tap: "Activate (Enter)",
    long_press: "Context menu",
    two_finger_tap: "Stop speech",
    two_finger_swipe_left: "Back (Escape)",
    two_finger_swipe_right: "Back (Escape)",
    two_finger_swipe_down: "Back (Escape)",
    two_finger_swipe_up: "Context menu",
    two_finger_double_tap: "Main menu",
    three_finger_swipe_right: "Next control (Tab)",
    three_finger_swipe_left: "Previous control (Shift+Tab)",
    three_finger_swipe_up: "First (Home)",
    three_finger_swipe_down: "Last (End)",
    three_finger_double_tap: "Toggle on-screen keyboard",
    four_finger_swipe_up: "Page up",
    four_finger_swipe_down: "Page down",
    four_finger_double_tap: "Toggle on-screen keyboard"
  }

  class << self
    # Called by the native host for every recognised gesture.
    def perform(gesture)
      gesture = gesture.to_s.to_sym
      return keyboard_gesture(gesture) if keyboard_active? && keyboard_intercepts?(gesture)
      spec = GESTURES[gesture]
      return false if spec == nil
      dispatch(spec)
      true
    rescue Exception => e
      log_warning("touch gesture #{gesture} failed: #{e.class}: #{e.message}")
      false
    end

    def gestures
      GESTURES.keys
    end

    def describe(gesture)
      LABELS[gesture.to_s.to_sym].to_s
    end

    # Ordered help text for a gesture reference screen.
    def help_lines
      GESTURES.keys.map { |gesture| "#{humanize(gesture)}: #{describe(gesture)}" }
    end

    # --- on-screen keyboard coordination --------------------------------

    def keyboard_active?
      defined?(OnScreenKeyboard) && OnScreenKeyboard.active?
    rescue Exception
      false
    end

    def toggle_keyboard
      # Prefer the native iOS on-screen keyboard when the host provides it; the
      # legacy Elten key grid (OnScreenKeyboard) remains only as a fallback for
      # hosts without the system keyboard bridge.
      if system_keyboard?
        if IOSHostBridge.system_keyboard_visible?
          IOSHostBridge.system_keyboard_hide
        else
          IOSHostBridge.system_keyboard_show
        end
        return true
      end
      return false unless defined?(OnScreenKeyboard)
      keyboard_active? ? OnScreenKeyboard.hide : OnScreenKeyboard.show
      true
    end

    def system_keyboard?
      defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:system_keyboard_available?) && IOSHostBridge.system_keyboard_available?
    rescue Exception
      false
    end

    # Explore-by-touch: host reports the normalised (0..1) finger position; the
    # keyboard speaks the key under the finger. commit types it on lift.
    def keyboard_point(x, y)
      return false unless keyboard_active?
      OnScreenKeyboard.point(x.to_f, y.to_f)
    end

    def keyboard_commit
      return false unless keyboard_active?
      OnScreenKeyboard.commit
    end

    def keyboard_cancel
      return false unless keyboard_active?
      OnScreenKeyboard.hide
      true
    end

    # Start a Ruby-side poller that drains host input tokens and dispatches
    # them. Runs on its own Ruby thread so all injection happens under the GVL.
    # Called once by the native host after the Ruby core has finished loading.
    def start_host_pump
      return false if @pump_thread != nil && @pump_thread.alive?
      return false unless defined?(IOSHostBridge)
      @pump_thread = Thread.new do
        loop do
          token = IOSHostBridge.next_input.to_s
          if token == ""
            sleep(0.01)
            next
          end
          begin
            dispatch_token(token)
          rescue Exception => e
            log_warning("host input #{token} failed: #{e.class}: #{e.message}")
          end
        end
      end
      true
    end

    # Parse and act on a host input token:
    #   "gesture:<name>"      -> perform(name)
    #   "kpoint:<x>,<y>"      -> keyboard explore
    #   "kcommit"             -> type the explored key
    #   "kcancel"             -> close the keyboard
    #   "ktext:<text>"        -> text typed on the system keyboard (Return pressed)
    #   "ksys:0" / "ksys:1"   -> system keyboard hidden / shown
    #   "active:0" / "active:1" -> host foreground state
    def dispatch_token(token)
      token = token.to_s
      kind, _, rest = token.partition(":")
      case kind
      when "gesture"
        perform(rest)
      when "kpoint"
        x, y = rest.split(",", 2)
        keyboard_point(x.to_f, y.to_f)
      when "kcommit"
        keyboard_commit
      when "kcancel"
        keyboard_cancel
      when "ktext"
        # The system keyboard was dismissed with Return; hand the collected
        # text to the focused control as typed characters.
        IOSWindowNative.type_character(rest) if rest.to_s != ""
        true
      when "ksys"
        # System keyboard visibility changed; state lives in the host, nothing
        # to track here.
        true
      when "active"
        IOSWindowNative.set_active(rest.to_s != "0")
        true
      else
        false
      end
    end

    private

    def dispatch(spec)
      case spec[0]
      when :tap
        IOSWindowNative.tap_key(spec[1])
      when :chord
        IOSWindowNative.tap_chord(spec[1], spec[2])
      when :hold
        IOSWindowNative.hold_key(spec[1], spec[2] || 3)
      when :stop_speech
        # Elten stops the current utterance when Control is first pressed.
        IOSWindowNative.tap_key(CONTROL)
      when :main_menu
        # The main menu opens when Alt is held for a moment and then released.
        IOSWindowNative.hold_key(ALT, 3)
      when :toggle_keyboard
        toggle_keyboard
      end
    end

    # Which gestures the keyboard swallows while it is open.
    def keyboard_intercepts?(gesture)
      [:swipe_left, :swipe_right, :swipe_up, :swipe_down,
       :double_tap, :long_press,
       :two_finger_swipe_left, :two_finger_swipe_right,
       :two_finger_swipe_down, :two_finger_tap].include?(gesture)
    end

    def keyboard_gesture(gesture)
      case gesture
      when :swipe_right then OnScreenKeyboard.move(:right)
      when :swipe_left then OnScreenKeyboard.move(:left)
      when :swipe_up then OnScreenKeyboard.move(:up)
      when :swipe_down then OnScreenKeyboard.move(:down)
      when :double_tap then OnScreenKeyboard.commit
      when :long_press then OnScreenKeyboard.speak_current(true)
      when :two_finger_tap then OnScreenKeyboard.backspace
      when :two_finger_swipe_left, :two_finger_swipe_right, :two_finger_swipe_down
        OnScreenKeyboard.hide
      end
      true
    end

    def humanize(gesture)
      gesture.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    def log_warning(message)
      Log.warning(message) if defined?(Log)
    end
  end
end
