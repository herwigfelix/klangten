# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Runs the Klangten test suite (or the files given):
#
#   ruby test/run.rb                          # everything under test/
#   ruby test/run.rb test/flows/test_login.rb # one file
#   ruby test/run.rb -n /forum/               # minitest options pass through
#
# Uses test/Gemfile (application gems + minitest) without touching the
# top-level bundle. Online tests need KLANGTEN_SERVER_DIR, see docs/testing.md.

ENV["BUNDLE_GEMFILE"] = File.expand_path("Gemfile", __dir__)
require "bundler/setup"

files, options = ARGV.partition { |arg| arg.end_with?(".rb") && File.file?(arg) }
files = Dir[File.join(__dir__, "**", "test_*.rb")].sort if files.empty?
ARGV.replace(options)
$LOAD_PATH.unshift(__dir__)
files.each { |file| require File.expand_path(file) }
