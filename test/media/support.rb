# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Test doubles for the media modules (background player, recordings,
# bookmarks, Internet Archive, global player keys). The modules are loaded
# from src/ as they are; everything around them - speech, configuration,
# sounds - is replaced here, so the tests need neither a window nor sound nor
# network. This file defines top-level constants (Log, Dirs, Sound ...) and
# must therefore only be loaded in a process of its own (see
# test/test_media.rb).

require "json"
require "fileutils"
require "monitor"
require "tmpdir"

ROOT = File.expand_path("../..", __dir__)
TEST_DATA = Dir.mktmpdir("klangten-media-test")
at_exit { FileUtils.rm_rf(TEST_DATA) }

# ------------------------------------------------------------------ spoken
module Spoken
  @lines = []
  @sounds = []
  @lock = Mutex.new
  class << self
    attr_reader :lines, :sounds

    def add(text)
      @lock.synchronize { @lines << text.to_s }
    end

    def sound(name)
      @lock.synchronize { @sounds << name.to_s }
    end

    def clear
      @lock.synchronize do
        @lines.clear
        @sounds.clear
      end
    end
  end
end

def p_(_context, text)
  text
end

def np_(_context, one, many, count)
  count == 1 ? one : many
end

def _(text)
  text
end

def alert(text, _wait = true)
  Spoken.add(text)
end

def speak(text, **_options)
  Spoken.add(text)
end

def play_sound(name)
  Spoken.sound(name)
end

$test_config = {}

def readconfig(group, key, default = "")
  value = $test_config[[group, key]]
  if value == nil
    $test_config[[group, key]] = default.to_s
    return default
  end
  value
end

def writeconfig(group, key, value)
  $test_config[[group, key]] = value.to_s
end

def unicode(text)
  (text.to_s.encode("UTF-16LE") + "\0".encode("UTF-16LE")).b
end

$inserted_scenes = []
def insert_scene(scene, *_args, **_options)
  $inserted_scenes << scene
end

module Log
  class << self
    def messages
      @messages ||= []
    end

    %i[debug info warning error].each do |level|
      define_method(level) { |message| messages << [level, message.to_s] }
    end
  end
end

module Dirs
  class << self
    def eltendata
      File.join(TEST_DATA, "data")
    end

    def documents
      File.join(TEST_DATA, "documents")
    end

    def user
      File.join(TEST_DATA, "user")
    end

    def music
      File.join(TEST_DATA, "music")
    end

    def temp
      File.join(TEST_DATA, "temp")
    end
  end
end
FileUtils.mkdir_p([Dirs.eltendata, Dirs.documents, Dirs.temp])

module EltenSystemHelpers
  class << self
    attr_writer :platform_os

    def platform_os
      @platform_os || "osx"
    end
  end
end

module Klangten
  module Config
    def self.user_agent
      "KlangtenTest"
    end
  end
end

module EltenLink
  module Client
    def self.absolute_api_url(url)
      "http://api.invalid#{url}"
    end
  end
end

module LocalConfig
  @values = {}
  class << self
    def [](key, _default = nil, type: nil)
      @values[key]
    end

    def []=(key, value)
      @values[key] = value
    end

    def clear
      @values.clear
    end
  end
end

module EltenAPI
  module QuickActions
    Action = Struct.new(:action, :label, :key)
    @procs = []
    @actions = []
    class << self
      attr_reader :procs, :actions

      def register_proc(program, ident, label, proc)
        @procs << [program, "#{program}__#{ident}".to_sym, label, proc]
      end

      def get
        @actions.dup
      end

      def assign_hotkey(key, action, label = "", _params = [])
        @actions << Action.new(action, label, key)
        true
      end

      def call(symbol)
        entry = @procs.find { |item| item[1] == symbol }
        entry[3].call
      end
    end
  end
end

class MediaFinder; end
class MediaExtractor; end
module MediaFinders
  @list = []
  class << self
    attr_reader :list

    def register(finder)
      @list << finder
    end
  end
end

# A sound that plays nothing: tests move its position and end it by hand.
class Sound
  @opened = []
  @fail = []
  class << self
    attr_reader :opened
    # Locations that cannot be opened.
    attr_reader :fail
    # Seconds downloaded when a sound is opened (nil: all of it).
    attr_accessor :default_downloaded

    def reset
      @opened.clear
      @fail.clear
      @default_downloaded = nil
    end
  end

  attr_accessor :volume, :length, :downloaded, :finished, :status
  attr_reader :file, :position, :plays, :pauses

  def initialize(file = nil, **_options)
    raise "cannot open" if self.class.fail.include?(file)
    @file = file
    @volume = 0.8
    @position = 0.0
    @length = 600.0
    @downloaded = self.class.default_downloaded
    @finished = false
    @closed = false
    @status = :stopped
    @plays = 0
    @pauses = 0
    self.class.opened << self
  end

  def opened?
    !@closed
  end

  def closed?
    @closed
  end

  def close
    @closed = true
    @status = :stopped
  end

  def play
    @plays += 1
    @status = :playing
  end

  def pause
    @pauses += 1
    @status = :paused
  end

  def stop
    @status = :stopped
  end

  def playing?
    @status == :playing
  end

  def finished?
    @closed || @finished
  end

  # Positions beyond @downloaded (seconds) cannot be reached yet.
  def position=(value)
    value = value.to_f
    return if @downloaded != nil && value > @downloaded
    @position = value
  end

  DownloadStatus = Struct.new(:complete) do
    def download_complete?
      complete
    end
  end

  # Like an internet file stream while @downloaded is set, like a local file
  # (no download status) otherwise.
  def download_status
    return nil if @downloaded == nil
    DownloadStatus.new(@downloaded >= @length)
  end

  def channel
    0
  end
end

# Waits (up to timeout seconds) until the block is true.
def wait_until(timeout = 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep(0.02)
  end
  true
end

load File.join(ROOT, "src/eapi/playlist.rb")
load File.join(ROOT, "src/eapi/mediarecordings.rb")
load File.join(ROOT, "src/eapi/mediabookmarks.rb")
load File.join(ROOT, "src/eapi/backgroundplayer.rb")
load File.join(ROOT, "src/eapi/internetarchive.rb")
load File.join(ROOT, "src/eapi/globalkeys.rb")
