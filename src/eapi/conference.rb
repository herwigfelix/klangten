# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: Elten's own VoIP engine was replaced by TeamConference, the conference system of Klango.

# Conferences and calls on top of TeamConference (src/eapi/teamconference.rb).
#
# Threads:
# - the TeamConference worker thread owns the native library (single caller
#   thread), polls its events, reconnects and pushes the received PCM into a
#   BASS push stream (AudioSink);
# - a short-lived thread fetches the login token from the Klango REST API;
# - the main thread runs Conference.tick from loop_update: it starts or stops
#   the connection with the Elten session and turns queued events into sounds,
#   speech, call windows and call history entries.
#
# The connection is kept for the whole session (like Klango does), so that
# incoming calls ring everywhere in the program.

require "json"
require_relative "teamconference" unless defined?(::TeamConference::Client)

module EltenAPI
  class Conference
    # Received PCM (48 kHz, stereo, s16le) -> BASS push stream.
    class AudioSink
      BYTES_PER_SECOND = 48_000 * 4
      MAX_QUEUED = BYTES_PER_SECOND / 2

      def initialize
        @handle = 0
        @mutex = Mutex.new
        @next_volume_check = 0.0
        @next_reopen = 0.0
      end

      def open?
        @mutex.synchronize { @handle != 0 }
      end

      def open
        @mutex.synchronize { open_locked }
      end

      def close
        @mutex.synchronize { close_locked }
      end

      def write(bytes)
        @mutex.synchronize do
          if @handle == 0
            now = TeamConference.monotonic
            return if now < @next_reopen
            @next_reopen = now + 1.0
            open_locked
            return if @handle == 0
          end
          queued = Bass::BASS_StreamPutData.call(@handle, bytes, bytes.bytesize).to_i
          if queued < 0
            # The output device was reinitialised (settings) and the handle is gone.
            Log.warning("Conference audio stream lost: #{Bass.error_name}") if defined?(Log)
            @handle = 0
          elsif queued > MAX_QUEUED
            # Played too late is worse than a gap: drop the backlog.
            Bass::BASS_ChannelPlay.call(@handle, 1)
          end
          now = TeamConference.monotonic
          if now >= @next_volume_check
            @next_volume_check = now + 1.0
            apply_volume
          end
        end
      rescue Exception => e
        Log.error("Conference audio write: #{e.class}: #{e.message}") if defined?(Log)
      end

      private

      def open_locked
        return if @handle != 0
        return unless defined?(::Bass) && Bass.respond_to?(:initialized?) && Bass.initialized?
        Bass.with_output_device(nil) do
          @handle = Bass::BASS_StreamCreate.call(48_000, 2, 0, Bass::STREAMPROC_PUSH, nil).to_i
        end
        if @handle == 0
          Log.error("Conference audio stream: #{Bass.error_name}") if defined?(Log)
          return
        end
        apply_volume
        Bass::BASS_ChannelPlay.call(@handle, 0)
      rescue Exception => e
        @handle = 0
        Log.error("Conference audio open: #{e.class}: #{e.message}") if defined?(Log)
      end

      def close_locked
        return if @handle == 0
        Bass::BASS_StreamFree.call(@handle)
        @handle = 0
      rescue Exception
        @handle = 0
      end

      def apply_volume
        volume = Configuration.volume.to_f / 100.0
        volume = 1.0 if volume <= 0 && Configuration.volume == nil
        Bass::BASS_ChannelSetAttribute.call(@handle, Bass::BASS_ATTRIB_VOL, [[volume, 0.0].max, 1.0].min)
      rescue Exception
        nil
      end
    end

    HISTORY_FILE = "callhistory.json".freeze
    HISTORY_LIMIT = 200
    UI_EVENTS = %w[
      room_user_joined room_user_left chat_room chat_private chat_server stream_file_status
      klangten_room klangten_call klangten_call_ended klangten_state
    ].freeze

    @@client = nil
    @@library_error = nil
    @@library_checked = false
    @@started_for = nil
    @@ui_events = Queue.new
    @@microphone_requested = false
    @@announced_state = nil

    class << self
      # ---------------------------------------------------------- lifecycle

      def available?
        client != nil
      end

      def unavailable_reason
        client
        @@library_error
      end

      def client
        return @@client if @@library_checked
        @@library_checked = true
        root = EltenRuntimePaths.root
        platform = EltenRuntimePaths.platform
        runtime = EltenRuntimePaths.runtime_directory_name
        if platform.to_s == "osx" && EltenRuntimePaths.architecture != "arm64"
          @@library_error = "TeamConference library is only shipped for Apple silicon"
          return nil
        end
        candidates = TeamConference::Library.candidates(root: root, platform: platform, runtime_dir: runtime)
        library, error = TeamConference::Library.open(candidates)
        if library == nil
          @@library_error = error
          Log.warning("Conferences unavailable: #{error}")
          return nil
        end
        Log.info("TeamConference loaded: #{library.path} (#{library.version})")
        @@client = TeamConference::Client.new(
          library: library,
          token_provider: -> { EltenLink::Conference.token(EltenLink::Client.new(nil)) },
          audio: AudioSink.new,
          logger: ->(level, message) { log_message(level, message) },
          before_connect: -> { request_microphone },
          input_device: -> { Configuration.microphone.to_s }
        )
        @@client.volume = LocalConfig["ConferenceVolume", 100, type: :numeric].to_f / 100.0
        @@client.on_event { |type, data, info| @@ui_events << [type, data, info] if UI_EVENTS.include?(type) }
        @@client
      rescue Exception => e
        @@library_error = "#{e.class}: #{e.message}"
        Log.error("TeamConference setup: #{@@library_error}")
        @@client = nil
      end

      # Called from loop_update.
      def tick
        return if $mainthread != nil && Thread.current != $mainthread
        manage_session
        count = 0
        while count < 50
          event = begin
            @@ui_events.pop(true)
          rescue ThreadError
            nil
          end
          break if event == nil
          count += 1
          begin
            handle_ui_event(*event)
          rescue Exception => e
            Log.error("Conference UI event #{event[0]}: #{e.class}: #{e.message}")
          end
        end
      rescue Exception => e
        Log.error("Conference tick: #{e.class}: #{e.message}")
      end

      def shutdown
        EltenAPI::UI::CallUI.reset if defined?(EltenAPI::UI::CallUI)
        @@client.shutdown if @@client != nil
      rescue Exception => e
        Log.error("Conference shutdown: #{e.class}: #{e.message}")
      end

      # Waits (with loop_update) until connected; returns true when connected.
      def wait_connected(timeout = 10)
        c = client
        return false if c == nil
        manage_session
        c.reconnect if c.state == :replaced || c.state == :disabled
        deadline = Time.now.to_f + timeout
        while Time.now.to_f < deadline
          return true if c.connected?
          break if c.state == :disabled || c.state == :stopped
          loop_update
        end
        c.connected?
      end

      # Waits for one of the given event types sent after mark.
      def wait_event(mark, types, timeout = 10)
        deadline = Time.now.to_f + timeout
        while Time.now.to_f < deadline
          event = client&.find_event(mark, types)
          return event if event != nil
          loop_update
          break if key_pressed?(:key_escape)
        end
        nil
      end

      # ----------------------------------------------------- compatibility

      def opened?
        client != nil && client.in_room?
      end

      def state
        client&.state
      end

      def connected?
        client != nil && client.connected?
      end

      def room_id
        client&.room_id
      end

      def muted
        client != nil && client.muted?
      end

      def muted=(value)
        client.mute = value if client != nil
      end

      def deafened
        client != nil && client.deafened?
      end

      def deafened=(value)
        client.deafen = value if client != nil
      end

      def streaming?
        client != nil && client.streaming?
      end

      def set_stream(file)
        return false if client == nil || !client.in_room?
        ok = client.stream_file(file)
        client.stream_volume = LocalConfig["ConferenceStreamVolume", 100, type: :numeric].to_f / 100.0 if ok
        ok
      end

      def remove_stream
        client&.stream_stop
      end

      def output_volume
        LocalConfig["ConferenceVolume", 100, type: :numeric].to_i
      end

      def output_volume=(value)
        value = [[value.to_i, 0].max, 200].min
        LocalConfig["ConferenceVolume"] = value
        client.volume = value / 100.0 if client != nil
      end

      def stream_volume
        LocalConfig["ConferenceStreamVolume", 100, type: :numeric].to_i
      end

      def stream_volume=(value)
        value = [[value.to_i, 0].max, 200].min
        LocalConfig["ConferenceStreamVolume"] = value
        client.stream_volume = value / 100.0 if client != nil
      end

      # ------------------------------------------------------------- calls

      def call(username)
        c = client
        return false if c == nil
        c.call_user(username)
        true
      end

      def answer_call(accept)
        client&.answer_call(accept)
      end

      def hang_up
        client&.hang_up
      end

      def call_info
        client&.call_info
      end

      def ringtone_for(username)
        file = EltenPath.join(Dirs.eltendata, "ringtones.json")
        return "ringing" unless FileTest.exist?(file)
        json = JSON.parse(File.binread(file))
        candidate = json.find { |user, _path| user.to_s.casecmp(username.to_s) == 0 }&.last
        candidate != nil && FileTest.exist?(candidate.to_s) ? candidate.to_s : "ringing"
      rescue Exception
        "ringing"
      end

      # Local call history (the Klango server keeps none).
      def history
        file = history_file
        return [] unless FileTest.exist?(file)
        rows = JSON.parse(File.binread(file))
        rows.is_a?(Array) ? rows.select { |r| r.is_a?(Hash) } : []
      rescue Exception => e
        Log.warning("Call history read: #{e.class}: #{e.message}")
        []
      end

      def add_history(call)
        return if call == nil || call[:username].to_s == ""
        return if call[:reason].to_s == "busy_local" || call[:reason].to_s == "not_connected"
        entry = {
          "direction" => call[:direction].to_s,
          "user" => call[:username].to_s,
          "nickname" => call[:nickname].to_s,
          "answered" => call[:answered] == true,
          "result" => call[:result].to_s,
          "time" => call[:started_at].to_i,
          "duration" => call[:answered] == true ? [call[:ended_at].to_i - call[:started_at].to_i, 0].max : 0
        }
        rows = [entry] + history
        File.binwrite(history_file, JSON.generate(rows.first(HISTORY_LIMIT)))
      rescue Exception => e
        Log.warning("Call history write: #{e.class}: #{e.message}")
      end

      def clear_history
        File.delete(history_file) if FileTest.exist?(history_file)
      rescue Exception
        nil
      end

      private

      def history_file
        EltenPath.join(Dirs.eltendata, HISTORY_FILE)
      end

      def manage_session
        return unless @@library_checked || (Session.logged? rescue false)
        c = client
        return if c == nil
        logged = (Session.logged? rescue false)
        name = logged ? Session.name.to_s : nil
        if logged && name != "" && @@started_for != name
          @@started_for = name
          c.start(name)
        elsif !logged && @@started_for != nil
          @@started_for = nil
          EltenAPI::UI::CallUI.reset if defined?(EltenAPI::UI::CallUI)
          c.stop
        end
      end

      def request_microphone
        return if @@microphone_requested
        @@microphone_requested = true
        # TeamConference records through its own library, so BASS never asks for
        # the microphone here. Every platform layer knows how to ask (macOS and
        # iOS the system dialog, Android the runtime permission).
        if defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:prepare_os_microphone)
          # Linux takes no timeout.
          method = EltenSystemHelpers.method(:prepare_os_microphone)
          granted = method.arity == 0 ? method.call : method.call(15.0)
          Log.warning("Conference: microphone access denied") if granted == false
        elsif defined?(::OSXSystemNative) && OSXSystemNative.respond_to?(:request_microphone_access)
          OSXSystemNative.request_microphone_access(15.0)
        end
      rescue Exception => e
        Log.warning("Microphone permission: #{e.class}: #{e.message}")
      end

      def log_message(level, message)
        case level
        when :error then Log.error(message)
        when :warning then Log.warning(message)
        else Log.info(message)
        end
      rescue Exception
        nil
      end

      def announce(sound, text)
        play_sound(sound) if sound != nil
        speak(text, stop: false, break_sequence: false) if text.to_s != ""
      rescue ArgumentError
        speak(text)
      end

      def handle_ui_event(type, data, info)
        info ||= {}
        case type
        when "room_user_joined"
          announce("conference_userjoin", info[:nickname]) if info[:current] && !info[:me]
        when "room_user_left"
          announce("conference_userleave", info[:nickname]) if info[:current] && !info[:me]
        when "chat_room"
          announce("conference_message", "#{info[:nickname]}: #{data['message'].to_s[0, 4999]}") unless info[:me]
        when "chat_private"
          unless info[:me]
            announce("conference_whisper", p_("Conference", "Private message from %{user}: %{message}") % { user: info[:nickname].to_s, message: data["message"].to_s[0, 4999] })
          end
        when "chat_server"
          announce("conference_message", p_("Conference", "Server message: %{message}") % { message: data["message"].to_s[0, 4999] })
        when "stream_file_status"
          if !info[:me] && TeamConference.truthy?(data["playing"])
            announce(nil, p_("Conference", "%{user} is streaming %{file}") % { user: info[:nickname].to_s, file: data["filename"].to_s })
          end
        when "klangten_room"
          room_changed(data)
        when "klangten_call"
          call_changed(data["call"])
        when "klangten_call_ended"
          call_ended(data["call"])
        when "klangten_state"
          if data["state"] == "replaced"
            announce(nil, p_("Conference", "Your conference session was taken over by another login of your account."))
          end
        end
      end

      def room_changed(data)
        case data["reason"].to_s
        when "room_kicked", "user_kicked"
          play_sound("conference_userleave")
          alert(p_("Conference", "You have been removed from the room."), false)
        when "room_banned", "user_banned"
          play_sound("conference_userleave")
          alert(p_("Conference", "You have been banned from the room."), false)
        when "room_closed"
          play_sound("conference_userleave")
          alert(p_("Conference", "The room has been closed."), false)
        when "connection_lost"
          alert(p_("Conference", "The connection to the conference server was lost."), false) if data["previous_room_id"] != nil
        when "session_replaced"
          alert(p_("Conference", "Your conference session was taken over by another login of your account."), false) if data["previous_room_id"] != nil
        end
      end

      def call_changed(call)
        return if call == nil
        if call[:direction] == :incoming && call[:state] == :ringing
          EltenAPI::UI::CallUI.incoming(call, ringtone_for(call[:username]))
        elsif call[:direction] == :outgoing && call[:state] == :ringing
          call_sound_start("calling")
        elsif call[:state] == :active
          call_sound_stop
          EltenAPI::UI::CallUI.close_incoming
          if call[:direction] == :outgoing
            announce("conference_userjoin", p_("Conference", "%{user} has answered the call") % { user: call[:nickname].to_s })
          end
        end
      end

      def call_ended(call)
        return if call == nil
        call_sound_stop
        EltenAPI::UI::CallUI.close_incoming
        add_history(call)
        name = call[:nickname].to_s == "" ? call[:username].to_s : call[:nickname].to_s
        if call[:direction] == :incoming
          if call[:result] == :missed
            EltenAPI::UI::CallUI.missed(call[:username].to_s)
          elsif call[:result] == :finished
            announce("conference_userleave", p_("Conference", "Call ended"))
          end
          return
        end
        case call[:result]
        when :finished
          announce("conference_userleave", p_("Conference", "Call ended"))
        when :declined
          alert(p_("Conference", "%{user} has declined the call") % { user: name }, false)
        when :unanswered
          alert(p_("Conference", "%{user} did not answer the call") % { user: name }, false)
        when :failed
          case call[:reason].to_s
          when "offline"
            alert(p_("Conference", "%{user} is not online") % { user: name }, false)
          when "busy"
            alert(p_("Conference", "%{user} is busy") % { user: name }, false)
          when "busy_local"
            alert(p_("Conference", "You are already in a call"), false)
          when "not_connected"
            alert(p_("Conference", "You are not connected to the conference server."), false)
          else
            alert(p_("Conference", "The call could not be established.") + (call[:reason].to_s == "" ? "" : " (#{call[:reason]})"), false)
          end
        end
      end
    end
  end
end
