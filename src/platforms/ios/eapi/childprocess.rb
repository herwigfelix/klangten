# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS child-process layer. iOS sandboxes forbid fork/exec entirely, so there is
# no real child-process support. The one thing that survives is the native
# "open" command (open a URL/document), which is handled by the host. Every other
# entry point degrades safely and the ChildProc class is kept as an inert stub so
# code that references it does not raise NameError.

class ChildProcessUnsupportedError < StandardError; end unless defined?(ChildProcessUnsupportedError)

module EltenAPI
  private

  def run(file, _hide = false, _path = nil, _addToProcs = true)
    if native_open_command?(file)
      target = file[1].to_s
      raise Errno::ENOENT, target if target == "" || !EltenSystemHelpers.open_url(target)
      return 0
    end
    Log.warning("Child processes are not available on iOS (requested: #{file.inspect})") if defined?(Log)
    0
  end

  def executeprocess(_cmdline, _hide = false, _tmax = 0, _update = true, _path = nil)
    Log.warning("executeprocess is not available on iOS") if defined?(Log)
    -1
  end

  def terminate_process_handle(_handle)
    nil
  end

  def exit_process(code = 0)
    exit(code.to_i)
  end

  class ChildProc
    attr_reader :pid, :process_id

    def initialize(_file, _path = nil)
      @pid = 0
      @process_id = 0
      raise ChildProcessUnsupportedError, "Child processes are not available on iOS"
    end

    def running?
      false
    end

    def exitstatus
      nil
    end

    def terminate
      nil
    end

    def avail
      0
    end

    def read(_size = nil)
      ""
    end

    def avail_err
      0
    end

    def read_err(_size = nil)
      ""
    end

    def write(_text)
      0
    end

    def close
      @pid = 0
      true
    end
  end

  def native_open_command?(command)
    command.is_a?(Array) && defined?(EltenSystemHelpers) && command[0].to_s == EltenSystemHelpers::NATIVE_OPEN_COMMAND
  rescue Exception
    false
  end

  def child_process_arguments(command)
    return command.map(&:to_s) if command.is_a?(Array)
    text = command.to_s
    return [] if text == ""
    [text]
  rescue Exception
    [command.to_s]
  end
  module_function :child_process_arguments
end
