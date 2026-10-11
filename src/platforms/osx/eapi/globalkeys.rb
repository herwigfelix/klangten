# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Global player keys on macOS (see src/eapi/globalkeys.rb): Carbon hot keys
# (RegisterEventHotKey). They need no accessibility permission, unlike a
# keyboard event tap. The pressed key arrives as a Carbon event at the
# application target while the window loop pumps events (always on the app
# thread), where a handler hands its action to the queue.
#
# Windows becomes Option (Option+Command for Control+Windows) - Windows
# combinations make no sense on a Mac. Option+Command+F5 switches VoiceOver
# and Option+Command+Space opens a Finder search; those two are left out.

module KlangtenGlobalKeys
  module Backend
    CARBON = "/System/Library/Frameworks/Carbon.framework/Carbon".freeze
    SIGNATURE = 0x4B4C4E54 # 'KLNT'
    EVENT_CLASS_KEYBOARD = 0x6B657962 # 'keyb'
    EVENT_HOTKEY_PRESSED = 5
    PARAM_DIRECT_OBJECT = 0x2D2D2D2D # '----'
    TYPE_HOTKEY_ID = 0x686B6964 # 'hkid'
    CMD = 256
    SHIFT = 512
    OPTION = 2048
    CONTROL = 4096
    # Windows virtual key -> macOS key code (kVK_*).
    MAC_KEYS = {
      0x20 => 0x31, 0x58 => 0x07, 0x5A => 0x06,
      0x74 => 0x60, 0x75 => 0x61, 0x76 => 0x62, 0x77 => 0x64, 0x7A => 0x67
    }.freeze

    class << self
      def start(bindings, queue)
        result = OSXWindowNative.perform_on_app_thread(true) { start_on_app_thread(bindings, queue) }
        result == true
      rescue Exception => e
        Log.error("Global player keys: #{e.class}: #{e.message}") if defined?(Log)
        false
      end

      def stop
        OSXWindowNative.perform_on_app_thread(true) { unregister_all }
      rescue Exception
        nil
      end

      # Klango's mapping of Windows modifiers to the Mac (nil: not possible).
      def mac_modifiers(modifiers, key)
        mac = 0
        if (modifiers & KlangtenGlobalKeys::MOD_WIN) != 0
          mac |= OPTION
          mac |= CMD if (modifiers & (KlangtenGlobalKeys::MOD_ALT | KlangtenGlobalKeys::MOD_CONTROL)) != 0
          mac |= SHIFT if (modifiers & KlangtenGlobalKeys::MOD_SHIFT) != 0
          return nil if mac == (OPTION | CMD) && [0x74, 0x20].include?(key)
          return mac
        end
        mac |= OPTION if (modifiers & KlangtenGlobalKeys::MOD_ALT) != 0
        mac |= CONTROL if (modifiers & KlangtenGlobalKeys::MOD_CONTROL) != 0
        mac |= SHIFT if (modifiers & KlangtenGlobalKeys::MOD_SHIFT) != 0
        mac
      end

      private

      def start_on_app_thread(bindings, queue)
        ensure_api
        unregister_all
        @queue = queue
        install_handler
        @actions = {}
        @refs = {}
        taken = []
        bindings.each do |id, modifiers, key, action|
          code = MAC_KEYS[key]
          mac = mac_modifiers(modifiers, key)
          next if code == nil || mac == nil
          # EventHotKeyID {UInt32 signature; UInt32 id} is passed by value in
          # one register on both arm64 and x86_64.
          hotkey_id = SIGNATURE | (id << 32)
          ref = "\0" * Fiddle::SIZEOF_VOIDP
          if @register.call(code, mac, hotkey_id, @target, 0, ref) == 0
            @actions[id] = action
            @refs[id] = ref.unpack1(Fiddle::SIZEOF_VOIDP == 8 ? "Q" : "L")
          else
            taken << "#{mac}+#{code}"
          end
        end
        Log.info("Global player keys: #{@actions.size} registered" + (taken.empty? ? "" : ", taken by others: #{taken.join(", ")}")) if defined?(Log)
        @actions.size > 0
      end

      def unregister_all
        (@refs || {}).each_value { |ref| @unregister.call(ref) rescue nil }
        @refs = {}
        @actions = {}
        true
      end

      def install_handler
        return if @handler != nil
        @handler = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_INT, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP]) do |_call, event, _user|
          begin
            buffer = "\0" * 8
            if @get_parameter.call(event, PARAM_DIRECT_OBJECT, TYPE_HOTKEY_ID, nil, 8, nil, buffer) == 0
              signature, id = buffer.unpack("L2")
              action = signature == SIGNATURE ? (@actions || {})[id] : nil
              @queue << action if action != nil && @queue != nil
            end
          rescue Exception
            nil
          end
          0
        end
        spec = [EVENT_CLASS_KEYBOARD, EVENT_HOTKEY_PRESSED].pack("L2")
        out = "\0" * Fiddle::SIZEOF_VOIDP
        status = @install_handler.call(@target, @handler, 1, spec, nil, out)
        raise "InstallEventHandler failed: #{status}" if status != 0
      end

      def ensure_api
        return if @register != nil
        carbon = Fiddle.dlopen(CARBON)
        ptr = Fiddle::TYPE_VOIDP
        uint = Fiddle::TYPE_UINT
        ulong = Fiddle::TYPE_ULONG
        @application_target = Fiddle::Function.new(carbon["GetApplicationEventTarget"], [], ptr)
        @install_handler = Fiddle::Function.new(carbon["InstallEventHandler"], [ptr, ptr, ulong, ptr, ptr, ptr], Fiddle::TYPE_INT)
        @register = Fiddle::Function.new(carbon["RegisterEventHotKey"], [uint, uint, Fiddle::TYPE_LONG_LONG, ptr, uint, ptr], Fiddle::TYPE_INT)
        @unregister = Fiddle::Function.new(carbon["UnregisterEventHotKey"], [ptr], Fiddle::TYPE_INT)
        @get_parameter = Fiddle::Function.new(carbon["GetEventParameter"], [ptr, uint, uint, ptr, ulong, ptr, ptr], Fiddle::TYPE_INT)
        @target = @application_target.call
      end
    end
  end
end
