# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# One test, one process. Klangten keeps its state in globals, class
# variables and module singletons, so two tests can never share a Ruby VM.
# FlowTest#run (in the minitest process) therefore starts
#
#   ruby test/support/klangten_test/child.rb <test file> <class> <method>
#
# with a fresh temporary directory, waits for it and reports the result the
# child hands back (a Marshal'd Minitest::Result on a pipe). The child loads
# Klangten (about half a second), runs exactly that one test and exits.
# Tests of one file run in parallel (parallelize_me!).
#
#   KLANGTEN_TEST_VERBOSE=1  print what each test process wrote (puts, warnings)
#   KLANGTEN_TEST_KEEP=1     keep the test directories (data dir, logs, server db)
#   KLANGTEN_TEST_TIMEOUT=n  real seconds one test may take (default 300)

require "rbconfig"
require "tmpdir"

module KlangtenTest
  module Isolation
    CHILD = File.join(__dir__, "child.rb")
    TIMEOUT = Integer(ENV.fetch("KLANGTEN_TEST_TIMEOUT", "300"))

    module_function

    def run_in_child(test)
      dir = Dir.mktmpdir("klangten-test-")
      keep = ENV["KLANGTEN_TEST_KEEP"] == "1"
      file = test.class.instance_method(test.name).source_location[0]
      reader, writer = IO.pipe
      log = File.join(dir, "child.log")
      env = KlangtenTestBoot.environment(dir, "http://127.0.0.1:9").select { |k, _| k.start_with?("DYLD_", "LD_", "ELTEN_") }
      env.merge!(
        "KLANGTEN_TEST_CHILD" => "1",
        "KLANGTEN_TEST_DIR" => dir,
        "KLANGTEN_TEST_RESULT_FD" => writer.fileno.to_s
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = Process.spawn(env, RbConfig.ruby, CHILD, file, test.class.name, test.name,
                          writer => writer, in: File::NULL, [:out, :err] => [log, "w"])
      writer.close
      data = read_with_timeout(reader, pid)
      _, status = Process.wait2(pid)
      result = begin
        Marshal.load(data) if data && !data.empty?
      rescue Exception
        nil
      end
      result ||= crashed_result(test, status, log)
      result.time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if ENV["KLANGTEN_TEST_VERBOSE"] == "1" && File.file?(log)
        $stderr.puts "---- #{test.class.name}##{test.name} output:", File.read(log)
      end
      if keep
        $stderr.puts "#{test.class.name}##{test.name}: kept in #{dir}"
      end
      result
    ensure
      reader&.close
      FileUtils.rm_rf(dir) if dir && !keep
    end

    def read_with_timeout(reader, pid)
      data = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if left <= 0
          Process.kill("KILL", pid) rescue nil
          return nil
        end
        next unless IO.select([reader], nil, nil, [left, 1].min)
        chunk = reader.read_nonblock(65_536, exception: false)
        break if chunk == nil
        data << chunk if chunk.is_a?(String)
      end
      data
    end

    def crashed_result(test, status, log)
      tail = File.file?(log) ? File.readlines(log).last(40).join : "(no output)"
      result = Minitest::Result.new(test.name)
      result.klass = test.class.name
      result.source_location = test.class.instance_method(test.name).source_location
      result.failures = [Minitest::UnexpectedError.new(RuntimeError.new("test process ended without a result (#{status.inspect})\n#{tail}"))]
      result.assertions = 0
      result
    end
  end
end
