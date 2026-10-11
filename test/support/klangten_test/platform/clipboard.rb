# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Test double for the clipboard: a plain string per test (app.clipboard),
# the clipboard of the machine running the tests stays untouched.

class ClipboardError < StandardError; end unless defined?(ClipboardError)

class Clipboard
  TEXT = 1 unless const_defined?(:TEXT)
  OEMTEXT = 7 unless const_defined?(:OEMTEXT)
  UNICODETEXT = 13 unless const_defined?(:UNICODETEXT)
  HDROP = 15 unless const_defined?(:HDROP)

  class << self
    def available?
      true
    end

    def open
      self
    end

    def close
      self
    end

    def set_data(clip_data, _format = TEXT)
      self.text = clip_data.to_s
    end

    def data(_format = TEXT)
      text
    end
    alias get_data data

    def empty
      self.text = ""
      self
    end

    def text
      @text.to_s
    end

    def text=(value)
      @text = value.to_s
      value
    end

    def files
      @files || []
    end

    def files=(paths)
      @files = Array(paths).map(&:to_s)
    end
  end
end
