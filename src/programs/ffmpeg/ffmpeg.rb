# FFMPEGEncoders - a former Elten component (author: pajper), Copyright (C) Dawid Pieper.
# Licensed under the GNU General Public License, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: built into Klangten; ffmpeg.exe is no
# longer shipped but downloaded on first use (Windows) from a pinned FFmpeg build with SHA-256 check, or
# taken from the system (macOS, Linux).
=begin Elten3AppInfo
{
  "id": "f2e2661b-f6b2-4b32-8c38-62e890a13c41",
  "name": "FFMPEGEncoders",
  "version": "1.0-klangten1",
  "build_id": 20260913001,
  "EltenAPIVersion": "3.0",
  "author": "pajper",
  "main_language": "en",
  "supported_languages": ["en", "pl"],
  "main_class": "ProgramFFMPEG",
  "platforms": ["all"],
  "execution": { "backend": "box" },
  "menu": {
    "hidden": true
  },
  "description": "Provides additional media encoders such as MP3 and AAC using FFMPEG executables."
}
=end Elten3AppInfo

require "digest"
require "fileutils"

class ProgramFFMPEG < Program
  # Windows build of FFmpeg by Gyan Doshi (linked from ffmpeg.org), GitHub
  # release mirror. "essentials" builds are configured with --enable-gpl
  # --enable-version3 (GPL-3.0). The checksum is the SHA-256 digest published
  # for this release asset.
  WINDOWS_BUILD_VERSION = "9.0.1".freeze
  WINDOWS_BUILD_URL = "https://github.com/GyanD/codexffmpeg/releases/download/9.0.1/ffmpeg-9.0.1-essentials_build.zip".freeze
  WINDOWS_BUILD_SHA256 = "fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9".freeze
  WINDOWS_BUILD_SIZE = 111_253_802
  WINDOWS_SOURCE_URL = "https://ffmpeg.org/download.html".freeze
  SYSTEM_SEARCH_PATHS = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin", "/snap/bin"].freeze

  def self.activate
    [
      FFMPEGMP3Encoder,
      FFMPEGAACEncoder,
      FFMPEGFLACEncoder,
      FFMPEGWMAEncoder,
      FFMPEGAVIEncoder,
      FFMPEGMP4Encoder,
      FFMPEGMOVEncoder,
      FFMPEGMPGEncoder
    ].each { |encoder| MediaEncoders.register(encoder) }
  end

  def self.windows?
    Programs.platform_family == "windows"
  end

  def self.downloaded_path
    data_path(EltenPath.join("ffmpeg", "ffmpeg.exe"))
  end

  # Path of a usable ffmpeg executable or nil.
  def self.ffmpeg_path
    return (File.file?(downloaded_path) ? downloaded_path : nil) if windows?
    system_ffmpeg_path
  end

  def self.system_ffmpeg_path
    directories = ENV["PATH"].to_s.split(File::PATH_SEPARATOR) + SYSTEM_SEARCH_PATHS
    directories.uniq.each do |directory|
      next if directory.to_s == ""
      candidate = File.join(directory, "ffmpeg")
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  def self.available?
    ffmpeg_path != nil
  end

  # Makes sure ffmpeg can be used, asking to download it on Windows.
  # Returns the executable path or nil.
  def self.ensure_ffmpeg
    path = ffmpeg_path
    return path if path != nil
    if !windows?
      alert(p_("Klangten", "FFmpeg was not found on this computer. Install FFmpeg with your package manager (for example Homebrew on macOS or apt on Linux) and try again."))
      return nil
    end
    if Programs.platform_target.to_s.downcase == "windows-x86"
      alert(p_("Klangten", "FFmpeg is not available for 32-bit Windows."))
      return nil
    end
    text = p_("Klangten", "The FFmpeg encoders need FFmpeg %{version}, which is downloaded once from %{url} (about %{size} MB). FFmpeg is free software licensed under the GNU General Public License, version 3; its source code is available at %{source}. Do you want to download it now?") % {
      version: WINDOWS_BUILD_VERSION,
      url: "github.com/GyanD/codexffmpeg",
      size: (WINDOWS_BUILD_SIZE / 1_048_576.0).round,
      source: WINDOWS_SOURCE_URL
    }
    return nil if !confirm(text)
    install_windows_build
    File.file?(downloaded_path) ? downloaded_path : nil
  rescue StandardError => e
    Log.warning("FFmpeg setup failed: #{e.class}: #{e.message}")
    alert(p_("Klangten", "FFmpeg could not be installed: %{error}") % { error: e.message })
    nil
  end

  def self.install_windows_build
    require "zip"
    target_dir = File.dirname(downloaded_path)
    FileUtils.mkdir_p(target_dir)
    archive = EltenPath.join(target_dir, "ffmpeg-build.zip.download")
    executable = downloaded_path + ".download"
    waiting
    begin
      success = download_file(WINDOWS_BUILD_URL, archive, use_waiting: false, can_cancel: true, override: true)
      raise RuntimeError, "download failed or was cancelled" if !success || !File.file?(archive)
      digest = Digest::SHA256.file(archive).hexdigest
      raise RuntimeError, "checksum mismatch" if digest.downcase != WINDOWS_BUILD_SHA256
      Zip::File.open(archive) do |zip|
        exe = zip.entries.find { |item| !item.directory? && item.name.tr("\\", "/").downcase.end_with?("/bin/ffmpeg.exe") }
        raise RuntimeError, "ffmpeg.exe not found in the archive" if exe == nil
        extract_zip_entry(exe, executable)
        licence = zip.entries.find { |item| !item.directory? && File.basename(item.name).casecmp?("LICENSE") }
        extract_zip_entry(licence, EltenPath.join(target_dir, "LICENSE.txt")) if licence != nil
      end
      raise RuntimeError, "extracted ffmpeg.exe is empty" if !File.file?(executable) || File.size(executable) <= 0
      FileUtils.mv(executable, downloaded_path)
      File.binwrite(EltenPath.join(target_dir, "VERSION.txt"), "FFmpeg #{WINDOWS_BUILD_VERSION}\n#{WINDOWS_BUILD_URL}\nSHA-256 #{WINDOWS_BUILD_SHA256}\nSource: #{WINDOWS_SOURCE_URL}\n")
    ensure
      waiting_end
      File.delete(archive) if File.file?(archive) rescue nil
      File.delete(executable) if File.file?(executable) rescue nil
    end
    alert(p_("Klangten", "FFmpeg has been installed."))
  end

  def self.extract_zip_entry(entry, output)
    entry.get_input_stream do |input|
      File.open(output, "wb") do |file|
        while (chunk = input.read(64 * 1024))
          file.write(chunk)
        end
      end
    end
  end

  def self.remove_download
    FileUtils.rm_rf(File.dirname(downloaded_path))
  end

  # Status and setup dialog, reachable from the Files menu.
  def self.show_status
    path = ffmpeg_path
    if path != nil
      text = p_("Klangten", "The FFmpeg encoders are ready. FFmpeg: %{path}") % { path: path }
      if windows?
        action = select_action({ ok: _("OK"), remove: p_("Klangten", "Remove downloaded FFmpeg") }, header: text, cancel: :ok, flags: 1)
        if action == :remove && confirm(p_("Klangten", "Remove the downloaded copy of FFmpeg?"))
          remove_download
          alert(p_("Klangten", "FFmpeg has been removed."))
        end
      else
        alert(text)
      end
    else
      ensure_ffmpeg
    end
  end

  def main
    self.class.show_status
  ensure
    finish
  end
end

class FFMPEGEncoderBase < MediaEncoder
  Type = :audio
  Name = "FFMPEG"
  Extension = "."
  IsBitrateSupported = true

  def self.encode_file(file, output, bitrate = nil)
    bitrate = 128 if bitrate == nil
    binary = ProgramFFMPEG.ensure_ffmpeg
    raise RuntimeError, "ffmpeg not found" if binary == nil || !File.file?(binary)

    audio_options = ""
    audio_options = "-b:a #{bitrate.to_i}K" if self::IsBitrateSupported == true
    video_options = self::Type == :audio ? "-vn" : ""
    command = "#{quote(binary)} -y -i #{quote(file)} #{audio_options} #{video_options} #{quote(output)}"
    executeprocess(command, true)
  end

  def self.quote(value)
    "\"" + value.to_s.gsub("\"", "\\\"") + "\""
  end
end

class FFMPEGMP3Encoder < FFMPEGEncoderBase
  Type = :audio
  Name = "MP3 (FFMPEG)"
  Extension = ".mp3"
  IsBitrateSupported = true
end

class FFMPEGAACEncoder < FFMPEGEncoderBase
  Type = :audio
  Name = "AAC (FFMPEG)"
  Extension = ".aac"
  IsBitrateSupported = true
end

class FFMPEGFLACEncoder < FFMPEGEncoderBase
  Type = :audio
  Name = "FLAC (FFMPEG)"
  Extension = ".flac"
  IsBitrateSupported = false
end

class FFMPEGWMAEncoder < FFMPEGEncoderBase
  Type = :audio
  Name = "WMA (FFMPEG)"
  Extension = ".wma"
  IsBitrateSupported = true
end

class FFMPEGAVIEncoder < FFMPEGEncoderBase
  Type = :video
  Name = "AVI (FFMPEG)"
  Extension = ".avi"
  IsBitrateSupported = true
end

class FFMPEGMP4Encoder < FFMPEGEncoderBase
  Type = :video
  Name = "MP4 (FFMPEG)"
  Extension = ".mp4"
  IsBitrateSupported = true
end

class FFMPEGMOVEncoder < FFMPEGEncoderBase
  Type = :video
  Name = "MOV (FFMPEG)"
  Extension = ".mov"
  IsBitrateSupported = true
end

class FFMPEGMPGEncoder < FFMPEGEncoderBase
  Type = :video
  Name = "MPG (FFMPEG)"
  Extension = ".mpg"
  IsBitrateSupported = true
end
