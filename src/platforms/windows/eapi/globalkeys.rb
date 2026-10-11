# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Global player keys on Windows (see src/eapi/globalkeys.rb): RegisterHotKey
# on a thread of their own, the same way the Invisible Interface keys work
# (src/platforms/windows/invisibleinterface/hotkeys.rb). A hot key belongs to
# the thread that registered it and arrives in that thread's message queue,
# so the thread registers the keys and then waits in GetMessage.

module KlangtenGlobalKeys
  module Backend
    MOD_NOREPEAT = 0x4000
    WM_HOTKEY = 0x0312
    WM_QUIT = 0x0012
    # Apart from the Invisible Interface keys (0x8000 + virtual key).
    ID_BASE = 0xA000
    MSG_SIZE = Fiddle::SIZEOF_VOIDP == 8 ? 48 : 28
    MESSAGE_OFFSET = Fiddle::SIZEOF_VOIDP
    WPARAM_OFFSET = Fiddle::SIZEOF_VOIDP == 8 ? 16 : 8
    PTR = Fiddle::SIZEOF_VOIDP == 8 ? Fiddle::TYPE_LONG_LONG : Fiddle::TYPE_INT
    START_TIMEOUT = 3.0

    class << self
      # Registers the bindings; true when at least one key could be had.
      def start(bindings, queue)
        stop
        @registered_count = nil
        @thread = Thread.new { run(bindings, queue) }
        @thread.report_on_exception = false
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT
        sleep(0.02) while @registered_count == nil && @thread.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        @registered_count.to_i > 0
      end

      def stop
        return if @thread == nil
        if @thread_id != nil
          ensure_api
          @post_thread_message.call(@thread_id, WM_QUIT, 0, 0)
        end
        @thread.join(1.0) if @thread.alive?
      rescue Exception
        nil
      ensure
        @thread = nil
        @thread_id = nil
      end

      private

      def run(bindings, queue)
        ensure_api
        @thread_id = @get_current_thread_id.call
        msg = "\0" * MSG_SIZE
        # The first PeekMessage gives the thread its message queue.
        @peek_message.call(msg, 0, 0, 0, 0)
        actions = {}
        failed = []
        bindings.each do |id, modifiers, key, action|
          hotkey = ID_BASE + id
          if @register_hotkey.call(0, hotkey, modifiers | MOD_NOREPEAT, key) != 0
            actions[hotkey] = action
          else
            failed << format("%d+0x%02X", modifiers, key)
          end
        end
        Log.info("Global player keys: #{actions.size} registered" + (failed.empty? ? "" : ", taken by others: #{failed.join(", ")}")) if defined?(Log)
        @registered_count = actions.size
        loop do
          result = @get_message.call(msg, 0, 0, 0)
          break if result.to_i <= 0
          next if EltenWin32.dword_value(msg, MESSAGE_OFFSET) != WM_HOTKEY
          action = actions[EltenWin32.pointer_value(msg, WPARAM_OFFSET).to_i]
          queue << action if action != nil
        end
      rescue Exception => e
        @registered_count ||= 0
        Log.error("Global player keys: #{e.class}: #{e.message}") if defined?(Log)
      ensure
        (actions || {}).each_key { |hotkey| @unregister_hotkey.call(0, hotkey) rescue nil }
      end

      def ensure_api
        return if @register_hotkey != nil
        kernel32 = Fiddle.dlopen("kernel32")
        user32 = Fiddle.dlopen("user32")
        @get_current_thread_id = Fiddle::Function.new(kernel32["GetCurrentThreadId"], [], Fiddle::TYPE_INT)
        @register_hotkey = Fiddle::Function.new(user32["RegisterHotKey"], [PTR, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        @unregister_hotkey = Fiddle::Function.new(user32["UnregisterHotKey"], [PTR, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        @get_message = Fiddle::Function.new(user32["GetMessageW"], [Fiddle::TYPE_VOIDP, PTR, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        @peek_message = Fiddle::Function.new(user32["PeekMessageW"], [Fiddle::TYPE_VOIDP, PTR, Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        @post_thread_message = Fiddle::Function.new(user32["PostThreadMessageW"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT, PTR, PTR], Fiddle::TYPE_INT)
      end
    end
  end
end
