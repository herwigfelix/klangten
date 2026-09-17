# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Ruby binding for TeamConference, the conference system of Klango.
#
# The native core library (teamconference_core, MIT licence, see
# THIRD-PARTY-NOTICES.md) speaks the TeamConference protocol: a JSON control
# channel over WebSocket/TLS and Opus audio over UDP. It records the
# microphone itself, but it has no speaker: it mixes everything it receives
# into a ring buffer of 48 kHz stereo 16-bit PCM that the caller drains.
#
# The library must be driven from ONE caller thread. TeamConference::Client
# therefore owns a worker thread that performs every tc_* call: it runs queued
# commands, polls events, keeps the connection alive (the library does not
# reconnect by itself) and moves the received PCM to an audio sink. Other
# threads only enqueue commands and read snapshots of the state.
#
# This file has no Elten dependencies, so the state machine can be tested
# headlessly with a fake library (see Client#step). The Elten side (token
# request, sounds, BASS playback, scenes) lives in src/eapi/conference.rb.

require "fiddle"
require "json"
require "monitor"
require "thread"
require "base64"

module TeamConference
  class Error < StandardError; end

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rescue StandardError
    Time.now.to_f
  end

  def self.truthy?(value)
    value == true || value.to_s == "1" || value.to_s.downcase == "true"
  end

  # Decodes the claims part of a Klango conference token
  # (b64url(claims) "." b64url(signature)) without verifying it. Only used to
  # decide what the menus offer; the server makes the decisions.
  def self.token_claims(token)
    body = token.to_s.split(".", 2).first.to_s
    return {} if body == ""
    body = body.tr("-_", "+/")
    body += "=" * ((4 - body.bytesize % 4) % 4)
    claims = JSON.parse(Base64.decode64(body))
    claims.is_a?(Hash) ? claims : {}
  rescue StandardError
    {}
  end

  # Thin Fiddle wrapper around the C API of lib/src/ffi.rs.
  class Library
    ENV_PATH = "KLANGTEN_TCLIB".freeze

    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID
    P = Fiddle::TYPE_VOIDP
    LL = Fiddle::TYPE_LONG_LONG
    F = Fiddle::TYPE_FLOAT

    SIGNATURES = {
      "tc_create" => [[], I],
      "tc_destroy" => [[], V],
      "tc_version" => [[], P],
      "tc_last_error" => [[], P],
      "tc_connect" => [[P, I, I, I, P], I],
      "tc_disconnect" => [[], V],
      "tc_is_connected" => [[], I],
      "tc_is_authenticated" => [[], I],
      "tc_user_id" => [[], LL],
      "tc_send" => [[P], I],
      "tc_poll_event" => [[P, I], I],
      "tc_join_room" => [[LL, P], I],
      "tc_join_group_room" => [[P, P], I],
      "tc_leave_room" => [[], V],
      "tc_current_room" => [[], LL],
      "tc_set_mute" => [[I], V],
      "tc_get_mute" => [[], I],
      "tc_set_deafen" => [[I], V],
      "tc_get_deafen" => [[], I],
      "tc_set_volume" => [[F], V],
      "tc_set_user_volume" => [[LL, F], V],
      "tc_set_input_device" => [[P], I],
      "tc_list_input_devices" => [[P, I], I],
      "tc_stream_file" => [[P], I],
      "tc_stream_stop" => [[], V],
      "tc_stream_pause" => [[I], V],
      "tc_stream_is_paused" => [[], I],
      "tc_stream_set_volume" => [[F], V],
      "tc_stream_is_active" => [[], I],
      "tc_audio_format" => [[P, P], V],
      "tc_read_audio" => [[P, I], I],
      "tc_clear_audio" => [[], V]
    }.freeze

    # Library file name for a platform, nil where no build is shipped.
    # Shipped builds: Windows x64 and macOS arm64. Windows arm64/x86 and Linux
    # need their own build of teamconference/lib (see THIRD-PARTY-NOTICES.md).
    def self.file_name(platform, runtime_dir = nil)
      case platform.to_s
      when "windows"
        runtime_dir.to_s == "windows-x64" ? "teamconference_core.dll" : nil
      when "osx"
        "libteamconference_core.dylib"
      else
        nil
      end
    end

    # Candidate paths: $KLANGTEN_TCLIB, bin/<runtime>/, bin/.
    def self.candidates(root:, platform:, runtime_dir:)
      list = []
      env = ENV[ENV_PATH].to_s
      list << env if env != ""
      name = file_name(platform, runtime_dir)
      if name != nil
        list << File.join(root, "bin", runtime_dir.to_s, name)
        list << File.join(root, "bin", name)
      end
      list.uniq
    end

    # Returns [library, nil] or [nil, "reason"].
    def self.open(candidates)
      path = candidates.find { |candidate| File.file?(candidate) }
      return [nil, "TeamConference library not available for this platform"] if path == nil
      library = new(path)
      return [nil, "tc_create failed: #{library.last_error}"] unless library.create
      [library, nil]
    rescue Fiddle::DLError, StandardError => e
      [nil, "#{e.class}: #{e.message}"]
    end

    attr_reader :path

    def initialize(path)
      @path = path
      @handle = Fiddle.dlopen(path)
      @functions = {}
      SIGNATURES.each do |name, (args, ret)|
        @functions[name] = Fiddle::Function.new(@handle[name], args, ret)
      end
      @event_buffer = "\0".b * 65_536
    end

    def create
      fn("tc_create").call == 1
    end

    def destroy
      fn("tc_destroy").call
    end

    def version
      fn("tc_version").call.to_s
    end

    def last_error
      fn("tc_last_error").call.to_s.force_encoding(Encoding::UTF_8)
    end

    def connect(host, port, udp_port, ssl, login_json)
      fn("tc_connect").call(cstr(host), port.to_i, udp_port.to_i, ssl ? 1 : 0, cstr(login_json)) == 1
    end

    def disconnect
      fn("tc_disconnect").call
    end

    def connected?
      fn("tc_is_connected").call == 1
    end

    def authenticated?
      fn("tc_is_authenticated").call == 1
    end

    def user_id
      fn("tc_user_id").call.to_i
    end

    def send_json(json)
      fn("tc_send").call(cstr(json)) == 1
    end

    # Next event as a JSON string, nil when none is pending.
    def poll_event
      loop do
        n = fn("tc_poll_event").call(@event_buffer, @event_buffer.bytesize)
        return nil if n == 0
        if n < 0
          @event_buffer = "\0".b * (-n + 64)
          next
        end
        return @event_buffer.byteslice(0, n).force_encoding(Encoding::UTF_8)
      end
    end

    def join_room(room_id, password = nil)
      pw = password.to_s == "" ? nil : cstr(password)
      fn("tc_join_room").call(room_id.to_i, pw) == 1
    end

    def join_group_room(group_id, name)
      fn("tc_join_group_room").call(cstr(group_id), cstr(name)) == 1
    end

    def leave_room
      fn("tc_leave_room").call
    end

    def current_room
      fn("tc_current_room").call.to_i
    end

    def mute=(value)
      fn("tc_set_mute").call(value ? 1 : 0)
    end

    def muted?
      fn("tc_get_mute").call == 1
    end

    def deafen=(value)
      fn("tc_set_deafen").call(value ? 1 : 0)
    end

    def deafened?
      fn("tc_get_deafen").call == 1
    end

    def volume=(gain)
      fn("tc_set_volume").call(gain.to_f)
    end

    def set_user_volume(user_id, gain)
      fn("tc_set_user_volume").call(user_id.to_i, gain.to_f)
    end

    def input_device=(name)
      fn("tc_set_input_device").call(name.to_s == "" ? nil : cstr(name))
    end

    def input_devices
      buffer = "\0".b * 16_384
      loop do
        n = fn("tc_list_input_devices").call(buffer, buffer.bytesize)
        return [] if n == 0
        if n < 0
          buffer = "\0".b * (-n + 64)
          next
        end
        list = JSON.parse(buffer.byteslice(0, n).force_encoding(Encoding::UTF_8))
        return list.is_a?(Array) ? list.map(&:to_s) : []
      end
    rescue JSON::ParserError
      []
    end

    def stream_file(path)
      fn("tc_stream_file").call(cstr(path)) == 1
    end

    def stream_stop
      fn("tc_stream_stop").call
    end

    def stream_pause=(value)
      fn("tc_stream_pause").call(value ? 1 : 0)
    end

    def stream_paused?
      fn("tc_stream_is_paused").call == 1
    end

    def stream_volume=(gain)
      fn("tc_stream_set_volume").call(gain.to_f)
    end

    def stream_active?
      fn("tc_stream_is_active").call == 1
    end

    # [sample_rate, channels]
    def audio_format
      rate = [0].pack("l<")
      channels = [0].pack("l<")
      fn("tc_audio_format").call(rate, channels)
      [rate.unpack1("l<"), channels.unpack1("l<")]
    end

    # Copies received PCM into buffer, returns the number of bytes.
    def read_audio(buffer)
      fn("tc_read_audio").call(buffer, buffer.bytesize)
    end

    def clear_audio
      fn("tc_clear_audio").call
    end

    private

    def fn(name)
      @functions.fetch(name)
    end

    def cstr(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").delete("\0").b + "\0".b
    end
  end

  # Connection, state and worker thread.
  #
  # States: :stopped, :waiting (before the next connection attempt),
  # :fetching_token, :connecting (waiting for auth_response), :connected,
  # :disabled (server has no conference configured), :replaced (the session
  # was taken over by another login of the same account; not reconnected
  # automatically, see teamconference docs/klango.md 1.6).
  #
  # Listeners registered with #on_event are called in the worker thread with
  # (type, data, info) after the state was updated. Besides the server
  # messages there are synthetic events:
  #   "klangten_state"      {state, previous, reason}
  #   "klangten_room"       {room_id, previous_room_id, reason}
  #   "klangten_call"       {call} (a call started or changed)
  #   "klangten_call_ended" {call} (call[:result] tells how it ended)
  class Client
    POLL_INTERVAL = 0.01
    MAX_EVENTS_PER_STEP = 64
    TOKEN_TIMEOUT = 30.0
    CONNECT_TIMEOUT = 20.0
    LINK_CHECK_INTERVAL = 2.0
    BACKOFF_MIN = 3.0
    BACKOFF_MAX = 120.0
    DISABLED_RECHECK = 900.0
    INCOMING_RING_TIMEOUT = 65.0
    OUTGOING_INVITE_TIMEOUT = 15.0
    OUTGOING_RING_TIMEOUT = 75.0
    EVENT_LOG_SIZE = 256
    CHAT_LOG_SIZE = 500
    AUDIO_CHUNK = 19_200
    USER_VOLUME_MAX = 2.0

    attr_reader :library

    # library:        TeamConference::Library (or a fake with the same methods)
    # token_provider: callable returning the /conference/token payload
    # audio:          optional sink with open, write(bytes), close, open?
    # before_connect: optional callable run in the token thread (microphone permission)
    # input_device:   optional callable returning the preferred microphone name
    # spawner:        callable taking a block; runs it in the background (Thread.new)
    def initialize(library:, token_provider:, audio: nil, logger: nil, clock: nil, before_connect: nil,
                   input_device: nil, spawner: nil)
      @library = library
      @token_provider = token_provider
      @audio = audio
      @logger = logger
      @clock = clock || -> { TeamConference.monotonic }
      @before_connect = before_connect
      @input_device = input_device
      @spawner = spawner || ->(&block) { Thread.new { Thread.current.report_on_exception = false; block.call } }
      @monitor = Monitor.new
      @commands = Queue.new
      @listeners = []
      @thread = nil
      @thread_stop = false
      @state = :stopped
      @nickname = nil
      @backoff = BACKOFF_MIN
      @next_attempt = 0.0
      @token_generation = 0
      @last_error = nil
      @revision = 0
      @event_seq = 0
      @event_log = []
      @audio_buffer = "\0".b * AUDIO_CHUNK
      @volume = 1.0
      @user_volumes = {}
      @token_since = 0.0
      @connect_since = 0.0
      @next_link_check = 0.0
      reset_session_state
    end

    # ------------------------------------------------------------ lifecycle

    def on_event(&block)
      @monitor.synchronize { @listeners << block }
      block
    end

    # Starts (or keeps) the connection for the given user.
    def start(nickname)
      submit do
        nick = nickname.to_s
        if @nickname != nick && @state != :stopped
          disconnect_library
          reset_session_state
          set_state(:waiting, "user changed")
        end
        @nickname = nick
        if @state == :stopped
          @backoff = BACKOFF_MIN
          @next_attempt = 0.0
          set_state(:waiting, "started")
        end
      end
      ensure_thread
      true
    end

    # Disconnects and stops reconnecting. The worker thread keeps running.
    def stop
      submit do
        @token_generation += 1
        disconnect_library
        reset_session_state
        set_state(:stopped, "stopped")
      end
    end

    # Connects again now, also after :replaced or :disabled.
    def reconnect
      submit do
        next if @state == :stopped
        @token_generation += 1
        disconnect_library
        reset_session_state
        @backoff = BACKOFF_MIN
        @next_attempt = 0.0
        set_state(:waiting, "reconnect")
      end
    end

    # Stops everything, destroys the library and ends the worker thread.
    def shutdown(timeout = 2.0)
      thread = @thread
      submit do
        disconnect_library
        reset_session_state
        set_state(:stopped, "shutdown")
        @library.destroy rescue nil
        @thread_stop = true
      end
      if thread == nil
        step
      elsif thread != Thread.current
        thread.join(timeout)
      end
      @thread = nil
    end

    def ensure_thread
      return if @thread != nil && @thread.alive?
      @thread_stop = false
      @thread = Thread.new do
        Thread.current.report_on_exception = false
        Thread.current.name = "TeamConference" if Thread.current.respond_to?(:name=)
        until @thread_stop
          begin
            busy = step
          rescue Exception => e
            log(:error, "worker: #{e.class}: #{e.message} #{Array(e.backtrace).first(3).join(' | ')}")
            busy = false
          end
          sleep(POLL_INTERVAL) unless busy
        end
      end
    end

    # One iteration of the worker. Public for headless tests.
    # Returns true when there was work to do.
    def step
      now = @clock.call
      busy = run_commands
      maintain(now)
      busy = true if poll_events(now)
      check_call_timeouts(now)
      busy = true if pump_audio
      busy
    end

    # Runs a block in the worker thread. Inside the block the client's
    # internal methods can be used directly.
    def submit(&block)
      if Thread.current == @thread
        instance_exec(&block)
      else
        @commands << block
      end
      nil
    end

    # Runs a block in the worker thread and waits for its result.
    def call(timeout = 3.0, &block)
      return instance_exec(&block) if Thread.current == @thread || @thread == nil || !@thread.alive?
      result = Queue.new
      @commands << proc do
        begin
          result << [true, instance_exec(&block)]
        rescue Exception => e
          result << [false, e]
        end
      end
      deadline = TeamConference.monotonic + timeout
      loop do
        begin
          ok, value = result.pop(true)
          raise value unless ok
          return value
        rescue ThreadError
          return nil if TeamConference.monotonic > deadline
          sleep(0.005)
        end
      end
    end

    # --------------------------------------------------------------- queries

    def state
      @monitor.synchronize { @state }
    end

    def connected?
      state == :connected
    end

    def last_error
      @monitor.synchronize { @last_error }
    end

    # Increases whenever rooms, users, chat or call change.
    def revision
      @monitor.synchronize { @revision }
    end

    def user_id
      @monitor.synchronize { @user_id }
    end

    def role
      @monitor.synchronize { @role }
    end

    def nickname
      @monitor.synchronize { @nickname }
    end

    def rooms
      @monitor.synchronize { deep_copy(@rooms) }
    end

    def room_id
      @monitor.synchronize { @room_id }
    end

    def in_room?
      room_id != nil
    end

    def room(id = nil)
      @monitor.synchronize do
        id ||= @room_id
        r = find_room(id)
        r == nil ? nil : deep_copy(r)
      end
    end

    # Users of a room, sorted by nickname, with flags.
    def users(id = nil)
      @monitor.synchronize do
        id ||= @room_id
        r = find_room(id)
        next [] if r == nil
        admins = Array(r["admins"]).map(&:to_i)
        Array(r["users"]).map do |u|
          uid = u["id"].to_i
          {
            id: uid,
            username: u["username"].to_s,
            nickname: (u["nickname"].to_s == "" ? u["username"].to_s : u["nickname"].to_s),
            role: u["role"].to_s,
            muted: TeamConference.truthy?(u["muted"]),
            deafened: TeamConference.truthy?(u["deafened"]),
            admin: admins.include?(uid),
            owner: r["owner_id"].to_i == uid && uid != 0,
            streaming: @streaming_users[uid] == true,
            me: uid == @user_id,
            volume: (@user_volumes[uid] || 1.0)
          }
        end.sort_by { |u| u[:nickname].downcase }
      end
    end

    def chat
      @monitor.synchronize { @chat.map(&:dup) }
    end

    def call_info
      @monitor.synchronize { @call == nil ? nil : @call.dup }
    end

    def muted?
      @monitor.synchronize { @muted }
    end

    def deafened?
      @monitor.synchronize { @deafened }
    end

    def streaming?
      @monitor.synchronize { @streaming }
    end

    def volume
      @monitor.synchronize { @volume }
    end

    def user_volume(uid)
      @monitor.synchronize { @user_volumes[uid.to_i] || 1.0 }
    end

    def server_moderator?
      %w[admin moderator].include?(role.to_s)
    end

    # Mirrors is_room_mod of docs/klango.md 1.3 for the menus.
    def room_moderator?(room_or_id = nil, uid = nil, user_role = nil)
      @monitor.synchronize do
        r = room_or_id.is_a?(Hash) ? room_or_id : find_room(room_or_id || @room_id)
        uid ||= @user_id
        user_role ||= (uid == @user_id ? @role : nil)
        next false if r == nil
        next true if %w[admin moderator].include?(user_role.to_s)
        next true if r["owner_id"].to_i == uid.to_i && uid.to_i != 0
        next true if Array(r["admins"]).map(&:to_i).include?(uid.to_i)
        gid = r["group_id"].to_s
        next true if uid == @user_id && gid != "" && @admin_groups.include?(gid)
        false
      end
    end

    def can_manage_admins?(room_or_id = nil)
      @monitor.synchronize do
        r = room_or_id.is_a?(Hash) ? room_or_id : find_room(room_or_id || @room_id)
        next false if r == nil
        next true if @role.to_s == "admin"
        r["group_id"].to_s == "" && r["owner_id"].to_i == @user_id.to_i && @user_id.to_i != 0
      end
    end

    def group_admin?(group_id)
      @monitor.synchronize { @admin_groups.include?(group_id.to_s) }
    end

    # Position in the event log; pass it to #find_event to wait for answers.
    def event_mark
      @monitor.synchronize { @event_seq }
    end

    # First logged event after mark whose type is one of types: [seq, type, data].
    def find_event(mark, *types)
      types = types.flatten.map(&:to_s)
      @monitor.synchronize do
        entry = @event_log.find { |seq, type, _data| seq > mark && types.include?(type) }
        entry == nil ? nil : [entry[0], entry[1], deep_copy(entry[2])]
      end
    end

    # ------------------------------------------------------------- commands

    def send_message(type, data = {})
      submit { send_raw(type, data) }
    end

    def join_room(id, password = nil)
      submit do
        next unless @state == :connected
        apply_input_device
        @library.join_room(id.to_i, password) || record_error(@library.last_error)
      end
    end

    def join_group_room(group_id, name)
      submit do
        next unless @state == :connected
        apply_input_device
        @library.join_group_room(group_id.to_s, name.to_s) || record_error(@library.last_error)
      end
    end

    def leave_room
      submit do
        leaving = @room_id
        @library.leave_room
        @library.clear_audio rescue nil
        @streaming = false
        if @call != nil && @call[:direction] == :outgoing && [:inviting, :ringing].include?(@call[:state])
          send_raw("call_cancel", "room_id" => @call[:room_id]) if @call[:room_id] != nil
          end_call(:cancelled, "cancelled")
        end
        set_room(nil, "left") if leaving != nil
      end
    end

    def create_room(name, password: nil, max_users: 0)
      data = { "name" => name.to_s, "max_users" => max_users.to_i }
      data["password"] = password.to_s if password.to_s != ""
      send_message("room_create", data)
    end

    def update_room(id, name: nil, password: nil, max_users: nil)
      data = { "room_id" => id.to_i }
      data["name"] = name.to_s if name.to_s != ""
      data["password"] = password.to_s if password.to_s != ""
      data["max_users"] = max_users.to_i if max_users != nil
      send_message("room_update", data)
    end

    def delete_room(id)
      send_message("room_delete", "room_id" => id.to_i)
    end

    def send_chat(text)
      submit do
        next if @room_id == nil || text.to_s.strip == ""
        send_raw("chat_room", "room_id" => @room_id, "message" => text.to_s)
      end
    end

    def send_private(user_id, text)
      submit do
        next if text.to_s.strip == ""
        send_raw("chat_private", "to_user_id" => user_id.to_i, "message" => text.to_s)
        target = find_user(user_id)
        add_chat(:private_out, target, text.to_s)
      end
    end

    def mute=(value)
      submit do
        @library.mute = value == true
        @monitor.synchronize { @muted = value == true }
        bump
      end
    end

    def deafen=(value)
      submit do
        @library.deafen = value == true
        @monitor.synchronize { @deafened = value == true }
        bump
      end
    end

    def volume=(gain)
      submit do
        g = [[gain.to_f, 0.0].max, 3.0].min
        @library.volume = g
        @monitor.synchronize { @volume = g }
      end
    end

    def set_user_volume(uid, gain)
      submit do
        g = [[gain.to_f, 0.0].max, USER_VOLUME_MAX].min
        @library.set_user_volume(uid.to_i, g)
        @monitor.synchronize { @user_volumes[uid.to_i] = g }
        bump
      end
    end

    # Returns true when the stream started.
    def stream_file(path)
      call do
        ok = @library.stream_file(path.to_s)
        record_error(@library.last_error) unless ok
        @monitor.synchronize { @streaming = ok }
        bump
        ok
      end == true
    end

    def stream_stop
      submit do
        @library.stream_stop
        @monitor.synchronize { @streaming = false }
        bump
      end
    end

    def stream_pause=(value)
      submit { @library.stream_pause = value == true }
    end

    def stream_paused?
      call { @library.stream_paused? } == true
    end

    def stream_volume=(gain)
      submit { @library.stream_volume = gain.to_f }
    end

    def input_devices
      call { @library.input_devices } || []
    end

    def kick(uid, reason = nil)
      data = { "room_id" => room_id, "user_id" => uid.to_i }
      data["reason"] = reason.to_s if reason.to_s != ""
      send_message("room_kick", data)
    end

    def ban(uid, minutes = 0, reason = nil)
      data = { "room_id" => room_id, "user_id" => uid.to_i, "duration_minutes" => minutes.to_i }
      data["reason"] = reason.to_s if reason.to_s != ""
      send_message("room_ban", data)
    end

    def unban(uid)
      send_message("room_unban", "room_id" => room_id, "user_id" => uid.to_i)
    end

    def request_bans
      send_message("room_bans", "room_id" => room_id)
    end

    def room_mute(uid, muted)
      send_message("room_mute", "room_id" => room_id, "user_id" => uid.to_i, "muted" => muted == true)
    end

    def set_room_admin(uid, admin)
      send_message("room_admin_set", "room_id" => room_id, "user_id" => uid.to_i, "admin" => admin == true)
    end

    def lookup_user(username)
      send_message("user_lookup", "username" => username.to_s)
    end

    # Calls: at most one call at a time, see docs/klango.md 1.4.
    def call_user(username)
      submit do
        name = username.to_s.strip
        if @state != :connected
          emit_call_failure(name, "not_connected")
        elsif @call != nil
          emit_call_failure(name, "busy_local")
        else
          @monitor.synchronize do
            @call = { direction: :outgoing, state: :inviting, username: name.downcase, nickname: name,
                      room_id: nil, since: @clock.call, started_at: Time.now.to_i }
          end
          bump
          notify("klangten_call", { "call" => call_info }, {})
          send_raw("call_invite", "to_username" => name)
        end
      end
    end

    def answer_call(accept)
      submit do
        c = @call
        next if c == nil || c[:direction] != :incoming || c[:state] != :ringing
        send_raw("call_answer", "room_id" => c[:room_id], "accept" => accept == true)
        if accept == true
          @monitor.synchronize do
            @call[:state] = :active
            @call[:answered] = true
            @call[:since] = @clock.call
          end
          bump
          apply_input_device
          @library.join_room(c[:room_id].to_i, nil)
          notify("klangten_call", { "call" => call_info }, {})
        else
          end_call(:rejected, "declined")
        end
      end
    end

    # Cancels an outgoing call or hangs up an active one.
    def hang_up
      submit do
        c = @call
        next if c == nil
        if c[:direction] == :outgoing && [:inviting, :ringing].include?(c[:state])
          send_raw("call_cancel", "room_id" => c[:room_id]) if c[:room_id] != nil
          @library.leave_room if c[:room_id] != nil
          end_call(:cancelled, "cancelled")
          set_room(nil, "left") if @room_id != nil && @room_id == c[:room_id]
        elsif c[:direction] == :incoming && c[:state] == :ringing
          send_raw("call_answer", "room_id" => c[:room_id], "accept" => false)
          end_call(:rejected, "declined")
        else
          @library.leave_room
          end_call(:finished, "hangup")
          set_room(nil, "left") if @room_id != nil
        end
      end
    end

    # ------------------------------------------------------------ internals

    private

    def run_commands
      busy = false
      50.times do
        block = begin
          @commands.pop(true)
        rescue ThreadError
          nil
        end
        break if block == nil
        busy = true
        begin
          instance_exec(&block)
        rescue Exception => e
          log(:error, "command: #{e.class}: #{e.message} #{Array(e.backtrace).first(3).join(' | ')}")
        end
      end
      busy
    end

    def maintain(now)
      case @state
      when :waiting
        begin_token_fetch(now) if now >= @next_attempt && @nickname.to_s != ""
      when :disabled
        begin_token_fetch(now) if now >= @next_attempt && @nickname.to_s != ""
      when :fetching_token
        if now - @token_since > TOKEN_TIMEOUT
          @token_generation += 1
          schedule_retry(now, "token request timed out")
        end
      when :connecting
        if now - @connect_since > CONNECT_TIMEOUT
          disconnect_library
          schedule_retry(now, "login timed out")
        end
      when :connected
        if now >= @next_link_check
          @next_link_check = now + LINK_CHECK_INTERVAL
          handle_connection_lost("connection check failed") unless @library.connected?
        end
      end
    end

    # Every connection attempt asks the server for a new token. A token is only
    # needed for auth_login and expires after a few minutes ("expires"), so it
    # is never cached: reconnects always log in with a fresh one.
    def begin_token_fetch(now)
      generation = (@token_generation += 1)
      previous = @state
      @token_since = now
      set_state(:fetching_token, nil)
      provider = @token_provider
      before = @before_connect
      @spawner.call do
        result = begin
          before.call if before != nil
          [:ok, provider.call]
        rescue Exception => e
          [:error, "#{e.class}: #{e.message}"]
        end
        submit { token_result(generation, previous, result) }
      end
    end

    def token_result(generation, previous, result)
      return unless generation == @token_generation && @state == :fetching_token
      now = @clock.call
      kind, payload = result
      return schedule_retry(now, payload.to_s) if kind != :ok
      info = normalize_token(payload)
      unless info[:enabled]
        @next_attempt = now + DISABLED_RECHECK
        @monitor.synchronize { @last_error = "disabled" }
        set_state(:disabled, "conferences are disabled on the server")
        return
      end
      if info[:token] == "" || info[:host] == ""
        return schedule_retry(now, "incomplete conference token")
      end
      claims = TeamConference.token_claims(info[:token])
      @monitor.synchronize do
        @admin_groups = Array(claims["adm"]).map(&:to_s)
        @server_admin = claims["sadm"] == true
      end
      apply_input_device
      login = JSON.generate("klango_token" => info[:token], "nickname" => @nickname.to_s)
      if @library.connect(info[:host], info[:port], info[:udp_port], info[:ssl], login)
        @connect_since = now
        set_state(:connecting, nil)
      else
        schedule_retry(now, @library.last_error)
      end
    end

    def normalize_token(payload)
      data = payload.is_a?(Hash) ? payload : {}
      data = data["conference"] if data["conference"].is_a?(Hash)
      enabled = data.key?("enabled") ? TeamConference.truthy?(data["enabled"]) : data["token"].to_s != ""
      port = data["port"].to_i
      port = 9500 if port <= 0
      udp = (data["udp_port"] || data["udpport"]).to_i
      udp = port + 1 if udp <= 0
      ssl = data.key?("ssl") ? TeamConference.truthy?(data["ssl"]) : true
      { enabled: enabled, token: data["token"].to_s, host: data["host"].to_s, port: port, udp_port: udp, ssl: ssl }
    end

    def schedule_retry(now, reason)
      @monitor.synchronize { @last_error = reason.to_s }
      log(:warning, "retry in #{@backoff.round}s: #{reason}")
      @next_attempt = now + @backoff
      @backoff = [@backoff * 2, BACKOFF_MAX].min
      set_state(:waiting, reason)
    end

    def handle_connection_lost(reason)
      disconnect_library
      drop_room_and_call("connection_lost")
      schedule_retry(@clock.call, reason)
    end

    def disconnect_library
      @library.disconnect
    rescue StandardError => e
      log(:error, "disconnect: #{e.message}")
    end

    def drop_room_and_call(reason)
      if @call != nil
        c = @call
        result = if c[:state] == :active
          :finished
        elsif c[:direction] == :incoming
          :missed
        else
          :failed
        end
        end_call(result, reason)
      end
      set_room(nil, reason) if @room_id != nil
      @monitor.synchronize do
        @streaming = false
        @muted = false
        @deafened = false
      end
    end

    def reset_session_state
      @monitor.synchronize do
        @user_id = nil
        @role = nil
        @admin_groups = []
        @server_admin = false
        @rooms = []
        @room_id = nil
        @chat = []
        @call = nil
        @streaming_users = {}
        @streaming = false
        @muted = false
        @deafened = false
        @revision += 1
      end
      close_audio
    end

    def poll_events(now)
      return false if @state == :stopped
      count = 0
      while count < MAX_EVENTS_PER_STEP
        json = @library.poll_event
        break if json == nil
        count += 1
        begin
          event = JSON.parse(json)
        rescue JSON::ParserError
          log(:warning, "invalid event: #{json[0, 200]}")
          next
        end
        next unless event.is_a?(Hash)
        data = event["data"].is_a?(Hash) ? event["data"] : {}
        handle_event(event["type"].to_s, data, now)
      end
      count > 0
    end

    # Handles one event. Public via #simulate_event for tests.
    def handle_event(type, data, now)
      info = {}
      case type
      when "auth_response"
        if TeamConference.truthy?(data["success"])
          @monitor.synchronize do
            @user_id = data["user_id"].to_i
            @role = data["role"].to_s
            @rooms = data["rooms"] if data["rooms"].is_a?(Array)
            @last_error = nil
          end
          @backoff = BACKOFF_MIN
          @next_link_check = now + LINK_CHECK_INTERVAL
          apply_volume
          set_state(:connected, nil)
        else
          disconnect_library
          schedule_retry(now, "login rejected: #{data['error']}")
        end
      when "connect_failed", "connection_lost"
        handle_connection_lost(data["message"].to_s == "" ? type : data["message"].to_s) if @state != :stopped
      when "session_replaced"
        drop_room_and_call("session_replaced")
        set_state(:replaced, "session replaced")
      when "room_list"
        @monitor.synchronize { @rooms = data["rooms"] } if data["rooms"].is_a?(Array)
        bump
      when "room_joined"
        set_room(data["room_id"].to_i, "joined") if data["room_id"].to_i != 0
      when "room_user_joined"
        user = data["user"].is_a?(Hash) ? data["user"] : {}
        info[:nickname] = user["nickname"].to_s == "" ? user["username"].to_s : user["nickname"].to_s
        info[:username] = user["username"].to_s
        info[:current] = data["room_id"].to_i == @room_id.to_i
        info[:me] = user["id"].to_i == @user_id.to_i
        add_user_to_room(data["room_id"].to_i, user)
      when "room_user_left"
        u = find_user(data["user_id"], data["room_id"])
        info[:nickname] = u == nil ? "" : u[:nickname]
        info[:username] = u == nil ? "" : u[:username]
        info[:current] = data["room_id"].to_i == @room_id.to_i
        info[:me] = data["user_id"].to_i == @user_id.to_i
        remove_user_from_room(data["room_id"].to_i, data["user_id"].to_i)
        @monitor.synchronize { @streaming_users.delete(data["user_id"].to_i) }
      when "chat_room"
        from = user_from(data["from_user"])
        info[:me] = from[:id] == @user_id.to_i
        info[:nickname] = from[:nickname]
        add_chat(:room, from, data["message"].to_s) if data["room_id"].to_i == 0 || data["room_id"].to_i == @room_id.to_i
      when "chat_private"
        from = user_from(data["from_user"])
        info[:me] = from[:id] == @user_id.to_i
        info[:nickname] = from[:nickname]
        add_chat(:private, from, data["message"].to_s) unless info[:me]
      when "chat_server"
        add_chat(:server, nil, data["message"].to_s)
      when "audio_user_state"
        info[:changed] = update_user_audio(data["user_id"].to_i, TeamConference.truthy?(data["muted"]), TeamConference.truthy?(data["deafened"]))
        u = find_user(data["user_id"])
        info[:nickname] = u == nil ? "" : u[:nickname]
        info[:me] = data["user_id"].to_i == @user_id.to_i
      when "stream_file_status"
        @monitor.synchronize { @streaming_users[data["user_id"].to_i] = TeamConference.truthy?(data["playing"]) }
        u = find_user(data["user_id"])
        info[:nickname] = u == nil ? "" : u[:nickname]
        info[:me] = data["user_id"].to_i == @user_id.to_i
        bump
      when "stream_finished"
        @monitor.synchronize { @streaming = false }
        bump
      when "room_kicked", "room_banned", "room_closed", "user_kicked", "user_banned"
        if @call != nil && (@call[:room_id] == nil || @call[:room_id] == @room_id)
          end_call(@call[:state] == :active ? :finished : :failed, type)
        end
        @monitor.synchronize { @streaming = false }
        set_room(nil, type) if @room_id != nil
      when "user_moved"
        set_room(data["room_id"].to_i, "moved") if data["room_id"].to_i != 0
      when "call_incoming"
        if @call == nil
          @monitor.synchronize do
            @call = { direction: :incoming, state: :ringing, room_id: data["room_id"].to_i,
                      user_id: data["from_user_id"].to_i, username: data["from_username"].to_s,
                      nickname: (data["from_nickname"].to_s == "" ? data["from_username"].to_s : data["from_nickname"].to_s),
                      since: now, started_at: Time.now.to_i }
          end
          bump
          info[:call] = call_info
        else
          # A second call while one is open cannot happen with a correct
          # server (it answers "busy"); decline it to keep the caller informed.
          send_raw("call_answer", "room_id" => data["room_id"].to_i, "accept" => false)
          info[:ignored] = true
        end
      when "call_ringing"
        c = @call
        if c != nil && c[:direction] == :outgoing && c[:state] == :inviting
          @monitor.synchronize do
            @call[:state] = :ringing
            @call[:room_id] = data["room_id"].to_i
            @call[:user_id] = data["to_user_id"].to_i
            @call[:username] = data["to_username"].to_s if data["to_username"].to_s != ""
            @call[:since] = now
          end
          bump
          # The server already placed the caller in the call room; joining
          # again makes the library send the audio configuration.
          apply_input_device
          @library.join_room(data["room_id"].to_i, nil)
          info[:call] = call_info
        end
      when "call_failed"
        c = @call
        end_call(:failed, data["reason"].to_s) if c != nil && c[:direction] == :outgoing && c[:state] == :inviting
      when "call_answered"
        c = @call
        if c != nil && c[:direction] == :outgoing && (c[:room_id] == nil || c[:room_id] == data["room_id"].to_i)
          if TeamConference.truthy?(data["accept"])
            @monitor.synchronize do
              @call[:state] = :active
              @call[:answered] = true
              @call[:since] = now
            end
            bump
            info[:call] = call_info
          else
            reason = data["reason"].to_s == "" ? "declined" : data["reason"].to_s
            @library.leave_room
            end_call(reason == "timeout" ? :unanswered : :declined, reason)
            set_room(nil, "call_declined") if @room_id != nil && @room_id == c[:room_id]
          end
        end
      when "call_cancelled"
        c = @call
        if c != nil && c[:direction] == :incoming && c[:room_id] == data["room_id"].to_i && c[:state] == :ringing
          end_call(:missed, data["reason"].to_s == "" ? "cancelled" : data["reason"].to_s)
        end
      when "error"
        c = @call
        if c != nil && c[:direction] == :outgoing && c[:state] == :inviting
          end_call(:failed, data["message"].to_s)
        end
        @monitor.synchronize { @last_error = data["message"].to_s }
      when "client_error"
        @monitor.synchronize { @last_error = data["message"].to_s }
      end
      log_event(type, data)
      notify(type, data, info)
    end

    public

    # Feeds a server event into the state machine (headless tests).
    def simulate_event(type, data = {})
      handle_event(type.to_s, data, @clock.call)
    end

    private

    def check_call_timeouts(now)
      c = @call
      return if c == nil
      age = now - c[:since].to_f
      if c[:direction] == :incoming && c[:state] == :ringing && age > INCOMING_RING_TIMEOUT
        end_call(:missed, "timeout")
      elsif c[:direction] == :outgoing && c[:state] == :inviting && age > OUTGOING_INVITE_TIMEOUT
        end_call(:failed, "timeout")
      elsif c[:direction] == :outgoing && c[:state] == :ringing && age > OUTGOING_RING_TIMEOUT
        send_raw("call_cancel", "room_id" => c[:room_id])
        @library.leave_room
        end_call(:unanswered, "timeout")
        set_room(nil, "call_timeout") if @room_id != nil && @room_id == c[:room_id]
      end
    end

    def end_call(result, reason)
      ended = nil
      @monitor.synchronize do
        return if @call == nil
        ended = @call.merge(result: result, reason: reason.to_s, ended_at: Time.now.to_i)
        @call = nil
      end
      bump
      notify("klangten_call_ended", { "call" => ended }, {})
    end

    def emit_call_failure(name, reason)
      ended = { direction: :outgoing, state: :inviting, username: name.downcase, nickname: name, room_id: nil,
                result: :failed, reason: reason, started_at: Time.now.to_i, ended_at: Time.now.to_i }
      notify("klangten_call_ended", { "call" => ended }, {})
    end

    def set_room(id, reason)
      id = nil if id.to_i == 0
      previous = nil
      @monitor.synchronize do
        previous = @room_id
        return if previous == id
        @room_id = id
        @chat = []
        @streaming_users = {}
      end
      c = @call
      if c != nil && c[:room_id] != nil && c[:room_id] != id && (c[:state] == :active || c[:direction] == :outgoing)
        end_call(c[:state] == :active ? :finished : :cancelled, reason)
      end
      if id == nil
        close_audio
        @monitor.synchronize do
          @streaming = false
        end
      else
        open_audio
      end
      bump
      notify("klangten_room", { "room_id" => id, "previous_room_id" => previous, "reason" => reason.to_s }, {})
    end

    def set_state(new_state, reason)
      previous = nil
      @monitor.synchronize do
        previous = @state
        @state = new_state
        @revision += 1
      end
      return if previous == new_state
      log(:info, "state #{previous} -> #{new_state}#{reason.to_s == '' ? '' : " (#{reason})"}")
      notify("klangten_state", { "state" => new_state.to_s, "previous" => previous.to_s, "reason" => reason.to_s }, {})
    end

    def send_raw(type, data)
      return false unless [:connected, :replaced].include?(@state)
      ok = @library.send_json(JSON.generate("type" => type.to_s, "data" => data || {}))
      record_error(@library.last_error) unless ok
      ok
    end

    def record_error(message)
      @monitor.synchronize { @last_error = message.to_s }
      log(:warning, message.to_s)
      false
    end

    def apply_input_device
      return if @input_device == nil
      preferred = @input_device.call.to_s
      name = nil
      if preferred != ""
        devices = @library.input_devices
        name = devices.find { |d| d == preferred } ||
               devices.find { |d| d.downcase == preferred.downcase } ||
               devices.find { |d| d.downcase.include?(preferred.downcase) || preferred.downcase.include?(d.downcase) }
      end
      @library.input_device = name
    rescue StandardError => e
      log(:warning, "input device: #{e.message}")
    end

    def apply_volume
      @library.volume = @volume
      @user_volumes.each { |uid, gain| @library.set_user_volume(uid, gain) }
    rescue StandardError
      nil
    end

    def open_audio
      return if @audio == nil
      @library.clear_audio rescue nil
      @audio.open unless @audio.open?
    rescue StandardError => e
      log(:error, "audio open: #{e.class}: #{e.message}")
    end

    def close_audio
      return if @audio == nil
      @audio.close if @audio.open?
    rescue StandardError => e
      log(:error, "audio close: #{e.class}: #{e.message}")
    end

    def pump_audio
      return false if @audio == nil || @room_id == nil || !@audio.open?
      busy = false
      8.times do
        n = @library.read_audio(@audio_buffer)
        break if n.to_i <= 0
        busy = true
        @audio.write(@audio_buffer.byteslice(0, n))
        break if n < @audio_buffer.bytesize
      end
      busy
    end

    def find_room(id)
      return nil if id == nil
      @rooms.find { |r| r.is_a?(Hash) && r["id"].to_i == id.to_i }
    end

    def find_user(uid, rid = nil)
      @monitor.synchronize do
        candidates = rid.to_i != 0 ? [find_room(rid)] : [find_room(@room_id)] + @rooms
        candidates.compact.each do |r|
          u = Array(r["users"]).find { |x| x.is_a?(Hash) && x["id"].to_i == uid.to_i }
          return user_from(u) if u != nil
        end
        nil
      end
    end

    def user_from(u)
      u = {} unless u.is_a?(Hash)
      nick = u["nickname"].to_s == "" ? u["username"].to_s : u["nickname"].to_s
      { id: u["id"].to_i, username: u["username"].to_s, nickname: nick }
    end

    def add_user_to_room(rid, user)
      return if user["id"] == nil
      @monitor.synchronize do
        r = find_room(rid)
        next if r == nil
        r["users"] = [] unless r["users"].is_a?(Array)
        r["users"] << user unless r["users"].any? { |x| x.is_a?(Hash) && x["id"].to_i == user["id"].to_i }
      end
      bump
    end

    def remove_user_from_room(rid, uid)
      @monitor.synchronize do
        r = find_room(rid)
        next if r == nil || !r["users"].is_a?(Array)
        r["users"].reject! { |x| x.is_a?(Hash) && x["id"].to_i == uid }
      end
      bump
    end

    def update_user_audio(uid, muted, deafened)
      changed = []
      @monitor.synchronize do
        r = find_room(@room_id)
        u = r == nil ? nil : Array(r["users"]).find { |x| x.is_a?(Hash) && x["id"].to_i == uid }
        if u != nil
          changed << :muted if TeamConference.truthy?(u["muted"]) != muted
          changed << :deafened if TeamConference.truthy?(u["deafened"]) != deafened
          u["muted"] = muted
          u["deafened"] = deafened
        end
        if uid == @user_id.to_i
          @muted = muted
          @deafened = deafened
        end
      end
      bump
      changed
    end

    def add_chat(kind, from, message)
      @monitor.synchronize do
        from ||= {}
        @chat << { kind: kind, time: Time.now.to_i, user_id: from[:id].to_i, username: from[:username].to_s,
                   nickname: from[:nickname].to_s, message: message.to_s }
        @chat.shift while @chat.size > CHAT_LOG_SIZE
      end
      bump
    end

    def log_event(type, data)
      @monitor.synchronize do
        @event_seq += 1
        @event_log << [@event_seq, type, data]
        @event_log.shift while @event_log.size > EVENT_LOG_SIZE
      end
    end

    def notify(type, data, info)
      listeners = @monitor.synchronize { @listeners.dup }
      listeners.each do |listener|
        begin
          listener.call(type, data, info)
        rescue Exception => e
          log(:error, "listener #{type}: #{e.class}: #{e.message}")
        end
      end
    end

    def bump
      @monitor.synchronize { @revision += 1 }
    end

    def deep_copy(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k] = deep_copy(v) }
      when Array then value.map { |v| deep_copy(v) }
      else value
      end
    end

    def log(level, message)
      @logger&.call(level, "TeamConference: #{message}")
    rescue StandardError
      nil
    end
  end
end
