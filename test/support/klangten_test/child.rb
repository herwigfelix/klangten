# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The test process (see isolation.rb): runs one test method and hands the
# Minitest::Result back through the file descriptor in
# KLANGTEN_TEST_RESULT_FD.
#
#   ruby test/support/klangten_test/child.rb <file> <class> <method>

require "bundler/setup" if ENV["BUNDLE_GEMFILE"]
require "minitest"

file, class_name, method_name = ARGV
ARGV.clear
out = IO.new(Integer(ENV.fetch("KLANGTEN_TEST_RESULT_FD")), "wb")
$stdout.sync = true

result = nil
begin
  require File.expand_path(file)
  klass = class_name.split("::").inject(Object) { |scope, name| scope.const_get(name) }
  result = klass.new(method_name).run
rescue Exception => e
  result = Minitest::Result.new(method_name)
  result.klass = class_name
  result.source_location = [file, 0]
  result.assertions = 0
  result.failures = [Minitest::UnexpectedError.new(e)]
ensure
  begin
    KlangtenTest.cleanup if defined?(KlangtenTest) && KlangtenTest.respond_to?(:cleanup)
  rescue Exception => e
    warn "cleanup failed: #{e.class}: #{e.message}"
  end
end

# The minitest process knows neither Klangten's exception classes nor the
# harness's; failures travel as plain Minitest exceptions.
result.failures = result.failures.map do |f|
  copy = case f
         when Minitest::Skip then Minitest::Skip.new(f.message)
         when Minitest::UnexpectedError
           inner = RuntimeError.new("#{f.error.class}: #{f.error.message}")
           inner.set_backtrace(f.error.backtrace)
           Minitest::UnexpectedError.new(inner)
         else Minitest::Assertion.new(f.message)
         end
  copy.set_backtrace(f.backtrace) unless f.is_a?(Minitest::UnexpectedError)
  copy
end
data = Marshal.dump(result)
out.write(data)
out.flush
# Klangten's threads (scene, services) would keep the process alive.
exit!(0)
