# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: calls are TeamConference calls (call_invite / call_answer / call_cancel).

module EltenAPI
  module UI
    private

    # Shown while an incoming call rings.
    class CallWindow
      attr_reader :room_id, :username

      def initialize(call)
        @room_id = call[:room_id]
        @username = call[:username].to_s
        name = call[:nickname].to_s == "" ? @username : call[:nickname].to_s
        @handled = false
        @form = Form.new([
          @st_caller = Static.new(p_("EAPI_UI", "%{user} is calling you") % { :user => name }),
          @btn_answer = Button.new(p_("EAPI_UI", "Answer")),
          @btn_reject = Button.new(p_("EAPI_UI", "Reject"))
        ])
      end

      def update
        @form.update
        if @btn_reject.pressed?
          @handled = true
          EltenAPI::UI.call_sound_stop
          Conference.answer_call(false)
        end
        if @btn_answer.pressed?
          @handled = true
          EltenAPI::UI.call_sound_stop
          Conference.answer_call(true)
          insert_scene(Scene_Conference.new(nil, 0, { "type" => "call" }))
        end
      end

      def handled?
        @handled == true
      end
    end

    class MissedCallsWindow
      def initialize(callers=[])
        @callers = callers
        @form = Form.new([
          @lst_callers = ListBox.new(@callers, header: p_("EAPI_UI", "Unanswered calls")),
          @btn_callback = Button.new(p_("EAPI_UI", "Call back")),
          @btn_close = Button.new(p_("EAPI_UI", "Close"))
        ])
        @form.cancel_button = @btn_close
        @btn_callback.on(:press) {
          caller = @callers[@lst_callers.index]
          if caller != nil
            close
            voicecall(caller)
          end
        }
        @btn_close.on(:press) { close }
      end

      def close
        clear_callers
      end

      def active
        @callers.size > 0
      end

      def update
        @form.update
      end

      def add_caller(caller)
        @callers.delete(caller)
        @callers.push(caller)
        update_list
        focus if @callers.size == 1
      end

      def clear_callers
        @callers = []
        update_list
      end

      def update_list
        @lst_callers.options = @callers
      end

      def focus
        @form.focus
      end
    end

    # Call windows driven by EltenAPI::Conference and updated from loop_update.
    module CallUI
      @@call_window = nil
      @@missed_window = nil

      class << self
        def incoming(call, ringtone)
          return if @@call_window != nil && @@call_window.room_id == call[:room_id]
          call_sound_start(ringtone || "ringing")
          @@call_window = CallWindow.new(call)
        end

        def close_incoming
          return if @@call_window == nil
          @@call_window = nil
          $focus = true
        end

        def missed(username)
          return if username.to_s == ""
          @@missed_window ||= MissedCallsWindow.new
          @@missed_window.add_caller(username.to_s)
        end

        def reset
          call_sound_stop
          @@call_window = nil
          @@missed_window.clear_callers if @@missed_window != nil
        end

        # Returns true when a call window took the keyboard in this frame.
        def update_windows
          if @@call_window != nil
            window = @@call_window
            window.update
            @@call_window = nil if window.handled? && @@call_window.equal?(window)
            $focus = @@call_window == nil
            return true
          elsif @@missed_window != nil && @@missed_window.active == true
            @@missed_window.update
            $focus = (@@missed_window.active == false)
            return true
          end
          false
        end
      end
    end

    def update_window_tray_visibility
      return if !tray_supported?
      if $tray_restore_ignore_until != nil
        if Time.now.to_f < $tray_restore_ignore_until.to_f
          EltenWindow.consume_minimize_request
          return
        end
        $tray_restore_ignore_until = nil
      end
      minimize_requested = EltenWindow.consume_minimize_request
      return if Configuration.hidewindow != true
      return if $trayreturn == true || $window_hidden_to_tray == true
      return if minimize_requested != true && !EltenWindow.minimized?
      Log.info("Elten window minimized")
      play_sound("minimize") rescue nil
      $totray = true
    rescue Exception => e
      Log.error("Elten window auto-hide failed: #{e.class}: #{e.message}")
    end
  end
end
