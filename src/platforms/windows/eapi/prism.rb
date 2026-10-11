# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Speaking through the running screen reader - JAWS, NVDA, System Access,
# ZDSR, Narrator and others - instead of a voice of Klangten's own.
#
# NVDA keeps its own, richer path (src/platforms/windows/eapi/nvda.rb, with the
# Klangten add-on for indexes and gestures). For every other screen reader
# Klangten uses PRISM by Ethin Probst (MPL-2.0, https://github.com/ethindp/prism,
# bin/windows-x64/prism.dll, see THIRD-PARTY-NOTICES.md): one C interface in
# front of the many screen reader APIs. The user picks it as the voice
# "Screen reader" in the voice settings; PRISM finds the running screen reader
# itself, NVDA included.
#
# Rules learnt with PRISM:
# - prism_registry_acquire_best is not used: on a machine without a screen
#   reader it picks Windows OneCore speech, which is no screen reader at all.
#   SAPI and OneCore are therefore skipped, and the UI Automation backend
#   (Narrator) is only used while Narrator runs.
# - PRISM talks COM to NVDA and JAWS, so every call happens on one worker
#   thread that initialised COM. Speech calls only queue a request.
# - Until a screen reader answers, the output reports itself unusable and
#   Klangten speaks with its default voice instead (src/eapi/speech.rb):
#   choosing this voice must never leave the user in silence.

require "fiddle"

class PrismScreenReader < SpeechOutput
  VOICE_ID = "PRISM".freeze

  # prism.h
  FEATURE_SPEAK = 1 << 2
  FEATURE_BRAILLE = 1 << 4
  FEATURE_OUTPUT = 1 << 5
  FEATURE_STOP = 1 << 7
  ERROR_NOT_IMPLEMENTED = 3
  ERROR_ALREADY_INITIALIZED = 15
  # Answers that mean the screen reader is gone: not initialised, speech
  # failed, backend not available, undefined state.
  LOST_ERRORS = [1, 6, 16, 20].freeze
  # Backends that are speech engines, not screen readers.
  NOT_SCREEN_READERS = %w[onecore sapi].freeze
  UIA = "uia".freeze
  # Seconds between two attempts to find a screen reader.
  RETRY_AFTER = 5.0
  # PrismConfig is 48 bytes on x64; the buffer leaves room.
  CONFIG_SIZE = 128

  P = Fiddle::TYPE_VOIDP
  I = Fiddle::TYPE_INT
  C = Fiddle::TYPE_CHAR
  V = Fiddle::TYPE_VOID
  ULL = Fiddle::TYPE_LONG_LONG
  SIZE = Fiddle::TYPE_SIZE_T

  SIGNATURES = {
    # Returns PrismConfig by value: on x64 the caller passes the result buffer
    # as hidden first argument and gets it back.
    "prism_config_init" => [[P], P],
    "prism_init" => [[P], P],
    "prism_shutdown" => [[P], V],
    "prism_registry_count" => [[P], SIZE],
    "prism_registry_id_at" => [[P, SIZE], ULL],
    "prism_registry_name" => [[P, ULL], P],
    "prism_registry_priority" => [[P, ULL], I],
    "prism_registry_create" => [[P, ULL], P],
    "prism_backend_free" => [[P], V],
    "prism_backend_name" => [[P], P],
    "prism_backend_get_features" => [[P], ULL],
    "prism_backend_initialize" => [[P], I],
    "prism_backend_speak" => [[P, P, C], I],
    "prism_backend_output" => [[P, P, C], I],
    "prism_backend_braille" => [[P, P], I],
    "prism_backend_stop" => [[P], I],
    "prism_error_string" => [[I], P]
  }.freeze

  class << self
    # ------------------------------------------------------------ discovery

    # The DLL is only built for x64 Windows; elsewhere the voice is missing.
    def library_path
      return @library_path if defined?(@library_path)
      @library_path = begin
        candidate = EltenRuntimePaths.find_library("prism.dll")
        File.file?(candidate.to_s) ? candidate : nil
      rescue Exception
        nil
      end
    end

    def available?
      library_path != nil
    end

    def usable?
      available? && @ready == true
    end

    # Never chosen by itself: only when the user picks it.
    def default?
      false
    end

    def screen_reader?
      true
    end

    def voices
      return [] unless available?
      name = if @backend_name.to_s != ""
               p_("Speech", "Screen reader (%{name})") % { name: @backend_name }
             else
               p_("Speech", "Screen reader (JAWS, NVDA, Narrator and others)")
             end
      if @voice == nil || @voice.name != name
        @voice = SpeechOutput::Voice.new(id: VOICE_ID, name: name, output: self)
      end
      [@voice]
    end

    def matches_voice?(voice)
      voice.to_s == VOICE_ID && available?
    end

    def voice_for(voice)
      matches_voice?(voice) ? voices.first : nil
    end

    # Choosing the voice starts the search for a screen reader.
    def apply_voice(voice)
      return false unless matches_voice?(voice)
      @selected = true
      start
      true
    end

    def deactivate
      @selected = false
    end

    # Name of the screen reader PRISM talks to, "" before one was found.
    def backend_name
      @backend_name.to_s
    end

    # Why no screen reader could be reached (for the log and the settings).
    def last_error
      @last_error.to_s
    end

    def braille_supported?
      @selected == true && usable? && (@features.to_i & FEATURE_BRAILLE) != 0
    end

    def spelling_supported?
      false
    end

    def voice_dictionary_supported?
      false
    end

    # ------------------------------------------------------------ speech

    def speak_text(text, method: 1, spelling: false, interrupt: true, pitch: 50)
      text = text.to_s.strip
      start
      return 1 unless usable?
      enqueue([:stop]) if interrupt && method != 0 && text == ""
      return 0 if text == ""
      enqueue([:speak, text, interrupt && method != 0])
      0
    end

    def stop
      enqueue([:stop]) if usable?
      1
    end

    def braille_alert(text)
      enqueue([:braille, text.to_s]) if braille_supported? && Configuration.enablebraille != false
    end

    # Starts the worker thread (once).
    def start
      return false unless available?
      @mutex ||= Mutex.new
      @mutex.synchronize do
        return true if @thread != nil && @thread.alive?
        @queue = Queue.new
        @thread = Thread.new { run }
        @thread.name = "prism" if @thread.respond_to?(:name=)
      end
      true
    end

    # Synchronous check for diagnostics and tests: waits up to timeout
    # seconds for a screen reader. Returns its name or nil.
    def probe(timeout: 5)
      start
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep(0.05) until usable? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      usable? ? backend_name : nil
    end

    private

    def enqueue(request)
      return unless start
      # Speech that would only be interrupted again is not worth keeping.
      @queue.clear if request[0] == :stop || (request[0] == :speak && request[2])
      @queue << request
    end

    def log(level, message)
      Log.send(level, "Screen reader (PRISM): #{message}") if defined?(Log)
    rescue Exception
      nil
    end

    # ------------------------------------------------------------ worker

    def run
      Thread.current.report_on_exception = false
      com_init
      next_attempt = 0.0
      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @backend == nil && now >= next_attempt
          acquire
          next_attempt = now + RETRY_AFTER
        end
        request = begin
          @queue.pop(timeout: 0.05)
        rescue ThreadError
          nil
        end
        pump_messages
        next if request == nil || @backend == nil
        perform(request)
      end
    rescue Exception => e
      @ready = false
      log(:error, "#{e.class}: #{e.message}")
    end

    def perform(request)
      case request[0]
      when :speak
        text = cstr(request[1])
        interrupt = request[2] ? 1 : 0
        speak_only = (@features.to_i & FEATURE_SPEAK) != 0
        braille = Configuration.enablebraille != false && (@features.to_i & FEATURE_OUTPUT) != 0
        rc = ERROR_NOT_IMPLEMENTED
        rc = fn("prism_backend_output").call(@backend, text, interrupt) if (braille || !speak_only) && @output_works != false
        if rc == ERROR_NOT_IMPLEMENTED && speak_only
          @output_works = false
          rc = fn("prism_backend_speak").call(@backend, text, interrupt)
        end
        if LOST_ERRORS.include?(rc)
          lost(rc)
        elsif rc != 0
          log(:warning, "speech: #{error_text(rc)}")
        end
      when :stop
        fn("prism_backend_stop").call(@backend) if (@features.to_i & FEATURE_STOP) != 0
      when :braille
        fn("prism_backend_braille").call(@backend, cstr(request[1])) if (@features.to_i & FEATURE_BRAILLE) != 0
      end
    rescue Exception => e
      log(:warning, "#{request[0]}: #{e.class}: #{e.message}")
    end

    # A screen reader that stops answering (closed) is given up; the worker
    # looks for one again after RETRY_AFTER seconds.
    def lost(rc)
      log(:warning, "#{@backend_name} answered #{error_text(rc)}; looking for a screen reader again")
      fn("prism_backend_free").call(@backend)
      @backend = nil
      @ready = false
    end

    def load_library
      return true if @handle != nil
      @handle = Fiddle.dlopen(library_path)
      @functions = {}
      SIGNATURES.each { |name, (args, ret)| @functions[name] = Fiddle::Function.new(@handle[name], args, ret) }
      config = "\0".b * CONFIG_SIZE
      fn("prism_config_init").call(config)
      @context = fn("prism_init").call(config)
      raise "prism_init failed" if @context.null?
      true
    end

    def fn(name)
      @functions.fetch(name)
    end

    # Picks the first backend, by PRISM's priority, that really reaches a
    # running screen reader.
    def acquire
      load_library
      count = fn("prism_registry_count").call(@context).to_i
      backends = (0...count).map do |index|
        id = fn("prism_registry_id_at").call(@context, index)
        [id, c_string(fn("prism_registry_name").call(@context, id)), fn("prism_registry_priority").call(@context, id).to_i]
      end
      if @known == nil
        @known = backends.map { |b| b[1] }
        log(:info, "backends: #{@known.join(', ')}")
      end
      tried = []
      backends.sort_by { |b| -b[2] }.each do |id, name, _priority|
        lower = name.downcase
        next if NOT_SCREEN_READERS.any? { |word| lower.include?(word) }
        next if lower.include?(UIA) && !narrator_running?
        backend = fn("prism_registry_create").call(@context, id)
        if backend.null?
          tried << "#{name}: not available"
          next
        end
        rc = fn("prism_backend_initialize").call(backend)
        if rc == 0 || rc == ERROR_ALREADY_INITIALIZED
          @backend = backend
          @backend_name = name
          @output_works = nil
          @features = fn("prism_backend_get_features").call(backend).to_i
          @ready = true
          @last_error = nil
          log(:info, "speaking through #{name}")
          return true
        end
        tried << "#{name}: #{error_text(rc)}"
        fn("prism_backend_free").call(backend)
      end
      @ready = false
      message = "no running screen reader (#{tried.empty? ? 'nothing to try' : tried.join('; ')})"
      log(:info, message) if message != @last_error
      @last_error = message
      false
    rescue Exception => e
      @ready = false
      @last_error = "#{e.class}: #{e.message}"
      log(:error, @last_error)
      false
    end

    def error_text(rc)
      c_string(fn("prism_error_string").call(rc.to_i))
    rescue Exception
      rc.to_s
    end

    def c_string(pointer)
      return "" if pointer == nil || pointer.null?
      pointer.to_s.force_encoding(Encoding::UTF_8).scrub("?")
    end

    def cstr(text)
      text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).delete("\0") + "\0"
    end

    # Narrator is reached through UI Automation notifications, which any
    # program could also receive; that backend is only right while Narrator
    # itself runs.
    def narrator_running?
      require "win32ole"
      service = WIN32OLE.connect("winmgmts:\\\\.\\root\\cimv2")
      service.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name = 'Narrator.exe'").Count.to_i > 0
    rescue Exception
      false
    end

    # ------------------------------------------------------------ COM

    def com_init
      ole32 = Fiddle.dlopen("ole32.dll")
      abi = defined?(Fiddle::Function::STDCALL) ? Fiddle::Function::STDCALL : Fiddle::Function::DEFAULT
      # COINIT_APARTMENTTHREADED; S_FALSE and RPC_E_CHANGED_MODE are fine.
      Fiddle::Function.new(ole32["CoInitializeEx"], [P, I], I, abi).call(nil, 2)
      user32 = Fiddle.dlopen("user32.dll")
      @peek_message = Fiddle::Function.new(user32["PeekMessageW"], [P, P, I, I, I], I, abi)
      @translate_message = Fiddle::Function.new(user32["TranslateMessage"], [P], I, abi)
      @dispatch_message = Fiddle::Function.new(user32["DispatchMessageW"], [P], P, abi)
      @msg = "\0".b * 64
    rescue Exception => e
      log(:warning, "COM: #{e.class}: #{e.message}")
    end

    # A single-threaded apartment has to dispatch its window messages, or
    # COM calls that come back to it would wait forever.
    def pump_messages
      return if @peek_message == nil
      count = 0
      while count < 20 && @peek_message.call(@msg, nil, 0, 0, 1) != 0 # PM_REMOVE
        @translate_message.call(@msg)
        @dispatch_message.call(@msg)
        count += 1
      end
    rescue Exception
      nil
    end
  end
end
