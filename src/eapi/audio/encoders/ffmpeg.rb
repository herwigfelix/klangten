# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Additional output formats through an external FFmpeg process.
#
# Klangten ships no FFmpeg. Where it comes from depends on the platform:
# - Windows x64: only a copy Klangten downloaded itself into
#   <data dir>/ffmpeg (ffmpeg.exe, the build's LICENSE and a short version
#   note). The archive is a pinned "essentials" build by Gyan Doshi, checked
#   against the SHA-256 below before anything is extracted.
# - macOS and Linux: an FFmpeg installed on the system (PATH and the usual
#   package manager locations). Klangten never downloads one there.
# - Windows x86/ARM64, iOS and Android: not available.
#
# The encoders are listed in MediaEncoders.list only while an FFmpeg is found.
# They implement encode_file (input: a local file or an http(s) URL); they do
# not take part in the PCM rendering API. Playback never needs FFmpeg, BASS
# decodes MP3, AAC/M4A, Opus, FLAC and the rest itself.

require "digest"
require "fileutils"
require "tmpdir"

module KlangtenFFmpeg
  class Error < StandardError; end

  VERSION = "9.0.2".freeze
  WINDOWS_TARGET = "windows-x64".freeze
  WINDOWS_URL = "https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip".freeze
  WINDOWS_SHA256 = "60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba".freeze
  WINDOWS_ARCHIVE_SIZE = 114_768_076
  WINDOWS_ARCHIVE_ROOT = "ffmpeg-9.0.2-essentials_build/".freeze
  WINDOWS_ARCHIVE_FILES = { "bin/ffmpeg.exe" => "ffmpeg.exe", "LICENSE" => "LICENSE" }.freeze
  VERSION_NOTE = "version.txt".freeze
  SEARCH_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin", "/snap/bin"].freeze
  CACHE_SECONDS = 15
  STDERR_LIMIT = 65_536

  class << self
    # --- Where FFmpeg comes from ------------------------------------------

    def platform_os
      EltenSystemHelpers.platform_os.to_s
    rescue Exception
      "unknown"
    end

    def platform_target
      EltenSystemHelpers.respond_to?(:platform_target) ? EltenSystemHelpers.platform_target.to_s : platform_os
    rescue Exception
      platform_os
    end

    # Computers only: phones cannot start another process.
    def supported_platform?
      ["windows", "osx", "linux"].include?(platform_os) && !(defined?(EltenSystemHelpers) && EltenSystemHelpers.respond_to?(:android?) && EltenSystemHelpers.android?)
    end

    # Windows x64 is the only platform where Klangten downloads FFmpeg.
    def downloadable?
      platform_target == WINDOWS_TARGET
    end

    def system_ffmpeg?
      ["osx", "linux"].include?(platform_os)
    end

    def install_dir
      File.join(Dirs.eltendata, "ffmpeg")
    end

    def downloaded_path
      File.join(install_dir, "ffmpeg.exe")
    end

    def downloaded?
      downloadable? && File.file?(downloaded_path)
    end

    # Full path of the FFmpeg executable, or nil.
    def path
      now = monotonic_time
      return @path if @path_checked_at != nil && now - @path_checked_at < CACHE_SECONDS
      @path = locate
      @path_checked_at = now
      @path
    end

    def available?
      supported_platform? && path != nil
    rescue Exception
      false
    end

    def refresh!
      @path_checked_at = nil
      @versions = nil
      path
    end

    # First line of "ffmpeg -version" without the copyright, e.g.
    # "9.0.2-essentials_build-www.gyan.dev". Runs a process; call it off the UI thread.
    def version
      executable = path
      return nil if executable == nil
      @versions ||= {}
      return @versions[executable] if @versions.key?(executable)
      result = run([executable, "-hide_banner", "-version"], :timeout => 20)
      line = result[:stdout].to_s.lines.first.to_s.strip
      line = line.sub(/\Affmpeg version\s+/i, "").sub(/\s+Copyright.*\z/i, "")
      @versions[executable] = line == "" ? nil : line
    rescue Exception => e
      Log.warning("FFmpeg version check failed: #{e.class}: #{e.message}")
      nil
    end

    # Text of the version note written next to a downloaded copy.
    def installed_note
      file = File.join(install_dir, VERSION_NOTE)
      File.file?(file) ? File.read(file).to_s : nil
    rescue Exception
      nil
    end

    # Why FFmpeg cannot be used here, as a sentence for the user (nil when it can).
    def unavailable_reason
      return nil if available?
      if !supported_platform?
        p_("Klangten", "FFmpeg is not available on this device.")
      elsif downloadable?
        p_("Klangten", "FFmpeg has not been downloaded yet.")
      elsif platform_os == "windows"
        p_("Klangten", "FFmpeg can be downloaded by Klangten only on 64-bit Windows (x64). It is not offered for this Windows version.")
      else
        p_("Klangten", "No FFmpeg was found on this computer.")
      end
    end

    # How to install FFmpeg on macOS and Linux.
    def install_instructions
      case platform_os
      when "osx"
        p_("Klangten", "Klangten uses an FFmpeg installed on your Mac. The easiest way is Homebrew (https://brew.sh): open Terminal and enter: brew install ffmpeg. MacPorts works as well: sudo port install ffmpeg. Klangten looks in /opt/homebrew/bin, /usr/local/bin and /opt/local/bin, as well as in the search path. Open this screen again after the installation.")
      when "linux"
        p_("Klangten", "Klangten uses the FFmpeg of your Linux distribution. Install it with your package manager, for example: sudo apt install ffmpeg (Debian, Ubuntu), sudo dnf install ffmpeg (Fedora, with RPM Fusion), sudo pacman -S ffmpeg (Arch) or sudo snap install ffmpeg. Open this screen again after the installation.")
      else
        unavailable_reason.to_s
      end
    end

    # --- Windows download ---------------------------------------------------

    # Checks the downloaded archive and extracts ffmpeg.exe and LICENSE into
    # install_dir. Blocking; run it through Tasks.run.
    def install_archive(archive, cancellation_token: nil)
      raise Error, "FFmpeg can only be installed on #{WINDOWS_TARGET}" if !downloadable?
      raise Error, "Downloaded FFmpeg archive is missing" if !File.file?(archive)
      digest = Digest::SHA256.file(archive).hexdigest
      raise Error, "FFmpeg archive checksum mismatch (#{digest})" if digest != WINDOWS_SHA256
      cancellation_token.raise_if_cancelled! if cancellation_token != nil
      require "zip"
      staging = install_dir + ".new"
      FileUtils.rm_rf(staging)
      FileUtils.mkdir_p(staging)
      Zip::File.open(archive) do |zip|
        WINDOWS_ARCHIVE_FILES.each do |name, target|
          entry = zip.find_entry(WINDOWS_ARCHIVE_ROOT + name)
          raise Error, "FFmpeg archive has no #{name}" if entry == nil || entry.directory?
          File.open(File.join(staging, target), "wb") do |file|
            entry.get_input_stream { |input| IO.copy_stream(input, file) }
          end
          cancellation_token.raise_if_cancelled! if cancellation_token != nil
        end
      end
      File.write(File.join(staging, VERSION_NOTE), "FFmpeg #{VERSION} essentials build by Gyan Doshi (https://www.gyan.dev/ffmpeg/builds/)\r\nSource: #{WINDOWS_URL}\r\nSHA-256: #{WINDOWS_SHA256}\r\nInstalled: #{Time.now.strftime("%Y-%m-%d %H:%M")}\r\nLicence: GNU GPL version 3, see LICENSE\r\n")
      FileUtils.rm_rf(install_dir)
      File.rename(staging, install_dir)
      refresh!
      true
    ensure
      FileUtils.rm_rf(staging) if defined?(staging) && staging != nil && File.directory?(staging)
    end

    def uninstall
      FileUtils.rm_rf(install_dir) if File.directory?(install_dir)
      refresh!
      !File.exist?(downloaded_path)
    end

    # Interactive download (UI thread): asks first, downloads with the core
    # progress announcements (Escape cancels), then verifies and extracts.
    # Returns true when FFmpeg is usable afterwards.
    def install_interactive(ask: true)
      return false if !downloadable?
      if ask
        question = p_("Klangten", "Klangten will download FFmpeg %{version} (about %{size} MB) from GitHub (build by gyan.dev) and keep only ffmpeg.exe. FFmpeg is free software under the GNU General Public License. Download it now?") % { version: VERSION, size: (WINDOWS_ARCHIVE_SIZE / 1_048_576.0).round }
        return false if !confirm(question, default_yes: true)
      end
      base = (Dirs.respond_to?(:temp) && Dirs.temp.to_s != "") ? Dirs.temp.to_s : Dir.tmpdir
      FileUtils.mkdir_p(base)
      archive = File.join(base, "ffmpeg-#{VERSION}-essentials_build.zip")
      File.delete(archive) if File.exist?(archive)
      speak(p_("Klangten", "Downloading FFmpeg..."))
      if download_file(WINDOWS_URL, archive, override: true) != true
        alert(p_("Klangten", "FFmpeg could not be downloaded."))
        return false
      end
      EltenAPI::Tasks.run(title: p_("Klangten", "Installing FFmpeg"), cancellable: false) do |_progress, token|
        install_archive(archive, cancellation_token: token)
      end
      alert(p_("Klangten", "FFmpeg has been installed."))
      true
    rescue Exception => e
      Log.error("FFmpeg installation failed: #{e.class}: #{e.message}")
      alert(p_("Klangten", "FFmpeg could not be installed: %{error}") % { error: e.message })
      false
    ensure
      File.delete(archive) if defined?(archive) && archive != nil && File.exist?(archive) rescue nil
    end

    # Called on the UI thread once the user has picked an FFmpeg format: true
    # when FFmpeg can be used. On Windows x64 without a copy it asks and
    # downloads it now; elsewhere it only answers.
    def ensure_available(ask: true)
      return true if available?
      return false if !downloadable?
      install_interactive(ask: ask)
    end

    # --- Encoders -------------------------------------------------------------

    def encoder_classes
      [FFmpegAacEncoder, FFmpegM4aEncoder, FFmpegFlacEncoder, FFmpegWmaEncoder,
       FFmpegMp4Encoder, FFmpegMkvEncoder, FFmpegMovEncoder, FFmpegAviEncoder]
    end

    # On Windows x64 the formats are listed before FFmpeg is downloaded; the
    # download happens when one of them is chosen (MediaEncoders.prepare).
    def encoders
      (available? || (supported_platform? && downloadable?)) ? encoder_classes : []
    end

    # Runs one conversion. attempts is a list of codec argument lists, tried in
    # order (stream copy first, re-encoding next). progress, if given, is called
    # with a percentage. Raises KlangtenFFmpeg::Error with the end of FFmpeg's
    # error output when every attempt fails.
    def convert(input, output, attempts, cancellation_token: nil, progress: nil)
      executable = path
      raise Error, unavailable_reason.to_s if executable == nil
      input = input.to_s
      output = output.to_s
      raise Error, "Input and output are the same file" if !url?(input) && File.expand_path(input) == File.expand_path(output)
      temporary = temporary_output(output)
      last_error = nil
      attempts.each do |codec_args|
        args = [executable, "-hide_banner", "-nostdin", "-nostats", "-loglevel", "level+info", "-y", "-i", input] + codec_args + ["-progress", "pipe:1", temporary]
        result = run(args, :cancellation_token => cancellation_token, :progress => progress)
        if result[:status] == 0 && File.file?(temporary) && File.size(temporary) > 0
          File.delete(output) if File.exist?(output)
          File.rename(temporary, output)
          return true
        end
        last_error = error_tail(result[:stderr])
        File.delete(temporary) if File.exist?(temporary)
      end
      raise Error, (last_error.to_s == "" ? "FFmpeg failed" : last_error)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary != nil && File.exist?(temporary) rescue nil
    end

    # Starts a process and waits for it. argv is an array (quoted into one
    # command line on Windows). Returns { status:, stdout:, stderr: }.
    def run(argv, cancellation_token: nil, progress: nil, timeout: nil)
      raise Error, "FFmpeg cannot run on this device" if !supported_platform?
      command = platform_os == "windows" ? argv.map { |arg| windows_quote(arg) }.join(" ") : argv.map(&:to_s)
      directory = File.directory?(install_dir) ? install_dir : Dir.tmpdir
      process = EltenAPI::ChildProc.new(command, path: directory, cancellation_token: cancellation_token)
      stdout = "".b
      stderr = "".b
      duration = nil
      started = monotonic_time
      status = nil
      @last_percent = nil
      begin
        loop do
          running = process.running?
          stdout << process.read.to_s.b if process.avail > 0
          stderr << process.read_err.to_s.b if process.avail_err > 0
          stderr = stderr.byteslice(-STDERR_LIMIT, STDERR_LIMIT) if stderr.bytesize > STDERR_LIMIT
          if progress != nil
            duration ||= parse_duration(stderr)
            report_progress(stdout, duration, progress)
          end
          stdout = stdout.byteslice(-4096, 4096) if progress != nil && stdout.bytesize > 65_536
          break if !running
          cancellation_token.raise_if_cancelled! if cancellation_token != nil
          raise Error, "FFmpeg did not finish in time" if timeout != nil && monotonic_time - started > timeout
          sleep(0.05)
        end
        stdout << process.read.to_s.b while process.avail > 0
        stderr << process.read_err.to_s.b while process.avail_err > 0
        status = exit_status(process)
        # A cancelled token has terminated the process; report the cancellation,
        # not the failure it caused.
        cancellation_token.raise_if_cancelled! if cancellation_token != nil
      ensure
        if status == nil
          process.terminate rescue nil
        end
        process.close rescue nil
      end
      { :status => status, :stdout => stdout, :stderr => stderr }
    end

    private

    def locate
      return nil if !supported_platform?
      return (File.file?(downloaded_path) ? downloaded_path : nil) if platform_os == "windows"
      dirs = ENV["PATH"].to_s.split(File::PATH_SEPARATOR) + SEARCH_DIRS
      dirs.uniq.each do |dir|
        next if dir.to_s == ""
        candidate = File.join(dir, "ffmpeg")
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def url?(value)
      value.to_s =~ /\A[a-z][a-z0-9+.-]*:\/\//i ? true : false
    end

    def exit_status(process)
      return process.exitstatus if process.respond_to?(:exitstatus)
      if defined?(EltenAPI::GET_EXIT_CODE_PROCESS) && process.pid.to_i != 0
        buffer = [0].pack("L")
        return buffer.unpack1("L") if EltenAPI::GET_EXIT_CODE_PROCESS.call(process.pid, buffer) != 0
      end
      nil
    rescue Exception
      nil
    end

    # Quoting rules of CommandLineToArgvW / the MSVC runtime.
    def windows_quote(arg)
      text = arg.to_s
      return text if text != "" && text !~ /[\s"]/
      result = +"\""
      backslashes = 0
      text.each_char do |char|
        if char == "\\"
          backslashes += 1
        elsif char == "\""
          result << ("\\" * (backslashes * 2 + 1)) << "\""
          backslashes = 0
        else
          result << ("\\" * backslashes) << char
          backslashes = 0
        end
      end
      result << ("\\" * (backslashes * 2)) << "\""
      result
    end

    def temporary_output(output)
      directory = File.dirname(output)
      extension = File.extname(output)
      basename = File.basename(output, extension)
      File.join(directory, ".#{basename}.klangten-#{rand(36**8).to_s(36)}#{extension}")
    end

    def parse_duration(stderr)
      match = stderr.to_s.force_encoding(Encoding::BINARY).match(/Duration: (\d+):(\d\d):(\d\d(?:\.\d+)?)/)
      return nil if match == nil
      value = match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_f
      value > 0 ? value : nil
    end

    def report_progress(stdout, duration, progress)
      return if duration == nil
      times = stdout.to_s.scan(/out_time_us=(\d+)/)
      return if times.empty?
      percent = [[times.last[0].to_i / 1_000_000.0 / duration * 100.0, 0.0].max, 100.0].min.floor
      return if @last_percent != nil && percent <= @last_percent
      @last_percent = percent
      progress.call(percent)
    rescue Exception
      nil
    end

    def error_tail(stderr)
      text = stderr.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
      lines = text.lines.map(&:strip).reject(&:empty?)
      errors = lines.select { |line| line.include?("[error]") || line.include?("[fatal]") }
      errors = lines.last(4) if errors.empty?
      errors.last(4).map { |line| line.sub(/\A(\[[^\]]*\]\s*)+/, "") }.join("\n")
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

# Common base of the FFmpeg encoders. Subclasses set the constants and
# ATTEMPTS (codec arguments; "%{bitrate}" is replaced by the bitrate in kbit/s).
class FFmpegMediaEncoder < MediaEncoder
  Type = :audio
  Extension = "."
  Name = ""
  IsBitrateSupported = true
  SupportsPcmStream = false
  DefaultBitrate = 128
  ATTEMPTS = [].freeze

  class << self
    def available?
      KlangtenFFmpeg.available? || (KlangtenFFmpeg.supported_platform? && KlangtenFFmpeg.downloadable?)
    end

    # UI thread, after the user chose this format: downloads FFmpeg if needed.
    def prepare
      KlangtenFFmpeg.ensure_available
    end

    def identifier
      ("ffmpeg_" + const_get(:Extension).to_s.delete(".")).to_sym
    end

    def default_bitrate
      const_get(:DefaultBitrate)
    end

    # bitrate in kbit/s (ignored when IsBitrateSupported is false). Extra
    # keywords: cancellation_token (EltenAPI::Tasks::CancellationToken) and
    # progress (called with a percentage).
    def encode_file(file, output, bitrate = nil, cancellation_token: nil, progress: nil)
      kbps = [[(bitrate || default_bitrate).to_i, 8].max, 512].min
      attempts = const_get(:ATTEMPTS).map { |args| args.map { |arg| arg.gsub("%{bitrate}", kbps.to_s) } }
      KlangtenFFmpeg.convert(file, output, attempts, :cancellation_token => cancellation_token, :progress => progress)
    end
  end
end

class FFmpegAacEncoder < FFmpegMediaEncoder
  Extension = ".aac"
  Name = "AAC (FFmpeg)"
  DefaultBitrate = 160
  ATTEMPTS = [["-vn", "-c:a", "aac", "-b:a", "%{bitrate}k"]].freeze
end

class FFmpegM4aEncoder < FFmpegMediaEncoder
  Extension = ".m4a"
  Name = "M4A (FFmpeg)"
  DefaultBitrate = 160
  ATTEMPTS = [["-vn", "-c:a", "aac", "-b:a", "%{bitrate}k", "-movflags", "+faststart"]].freeze
end

class FFmpegFlacEncoder < FFmpegMediaEncoder
  Extension = ".flac"
  Name = "FLAC (FFmpeg)"
  IsBitrateSupported = false
  ATTEMPTS = [["-vn", "-c:a", "flac"]].freeze
end

class FFmpegWmaEncoder < FFmpegMediaEncoder
  Extension = ".wma"
  Name = "WMA (FFmpeg)"
  ATTEMPTS = [["-vn", "-c:a", "wmav2", "-b:a", "%{bitrate}k"]].freeze
end

# Video containers: keep the streams when the container takes them, otherwise
# encode H.264/AAC (MPEG-4 Part 2 as the last resort when libx264 is missing).
class FFmpegMp4Encoder < FFmpegMediaEncoder
  Type = :video
  Extension = ".mp4"
  Name = "MP4 (FFmpeg)"
  IsBitrateSupported = false
  ATTEMPTS = [
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
  ].freeze
end

class FFmpegMkvEncoder < FFmpegMediaEncoder
  Type = :video
  Extension = ".mkv"
  Name = "MKV (FFmpeg)"
  IsBitrateSupported = false
  ATTEMPTS = [
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-c:a", "aac", "-b:a", "160k"]
  ].freeze
end

class FFmpegMovEncoder < FFmpegMediaEncoder
  Type = :video
  Extension = ".mov"
  Name = "MOV (FFmpeg)"
  IsBitrateSupported = false
  ATTEMPTS = [
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
  ].freeze
end

class FFmpegAviEncoder < FFmpegMediaEncoder
  Type = :video
  Extension = ".avi"
  Name = "AVI (FFmpeg)"
  IsBitrateSupported = false
  ATTEMPTS = [
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"],
    ["-map", "0:v:0?", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "ac3", "-b:a", "192k"]
  ].freeze
end
