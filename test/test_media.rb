# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The media tests (test/media/) replace speech, configuration and sound with
# doubles defined at the top level, so each file runs in a Ruby process of its
# own; this file starts them and reports their result.
#
#   ruby test/test_media.rb          # both
#   ruby test/media/units.rb         # one of them directly

require "minitest/autorun"
require "rbconfig"
require "open3"

class MediaTestFiles < Minitest::Test
  DIR = File.join(__dir__, "media")

  def run_file(name)
    output, status = Open3.capture2e(RbConfig.ruby, File.join(DIR, name), chdir: DIR)
    assert status.success?, "#{name} failed:\n#{output}"
  end

  def test_units
    run_file("units.rb")
  end

  def test_stream_recording_with_bass
    run_file("bass_recording.rb")
  end

  def test_stream_playlists
    run_file("stream_playlists.rb")
  end
end
