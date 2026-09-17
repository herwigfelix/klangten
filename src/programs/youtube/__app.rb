# YouTube - a former Elten component (author: pajper), Copyright (C) Dawid Pieper.
# Licensed under the GNU General Public License, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: built into Klangten and opened from the
# Media menu (hidden from the Programs menu); Linux support; yt-dlp downloads verified against the
# release's SHA2-256SUMS; own user agent.
=begin Elten3AppInfo
{
  "id": "7c8e3f91-40a7-45af-8758-99d67a602e41",
  "name": "Youtube",
  "menu": { "hidden": true },
  "version": "1.0.1-klangten1",
  "build_id": 20260913001,
  "EltenAPIVersion": "3.0",
  "author": "pajper",
  "main_language": "en",
  "supported_languages": ["en", "de", "es", "pl", "ro", "ru", "tr"],
  "main_class": "ProgramYoutube",
  "platforms": ["windows", "osx", "linux"],
  "execution": { "backend": "box" },
  "description": "Simple Youtube client based on yt-dlp."
}
=end Elten3AppInfo

require "fileutils"
require "json"
require "uri"

module Youtube
  class Error < StandardError
  end

  class AudioStream
    attr_accessor :url, :bitrate, :codec, :container, :format_id

    def label
      bitrate_text = bitrate.to_i > 0 ? "#{(bitrate.to_i / 1000.0).round} kbps" : "? kbps"
      [codec, bitrate_text, container].compact.reject { |part| part.to_s == "" }.join(": ")
    end
  end

  class Video
    attr_accessor :title, :id, :author, :duration, :keywords, :views, :likes, :dislikes, :rating, :description, :url, :date, :channel

    def audiostream
      Youtube.stream_url(self, "ba/bestaudio/best")
    end

    def videostream
      Youtube.stream_url(self, "best")
    end

    def audiostreams
      Youtube.audio_streams(self)
    rescue Exception
      []
    end
  end

  class Channel
    attr_accessor :title, :id, :url
  end

  class Playlist
    attr_accessor :title, :id, :url, :author
  end

  class << self
    attr_accessor :binary, :js_runtimes

    def available?
      binary.to_s != "" && File.file?(binary.to_s) && js_runtimes.to_s != ""
    end

    def ensure_available!
      raise Error, "yt-dlp not found" if !available?
    end

    def search(query, results = 50, type = :search)
      case type
      when :channel
        channel_search(query, results)
      when :playlist
        playlist_search(query, results)
      else
        data = dump_single("ytsearch#{results.to_i}:#{query}", :flat => true)
        entries(data).map { |entry| video_from_entry(entry) }.compact
      end
    end

    def channel_search(query, results = 50)
      data = dump_single(search_url(query, :channel), :flat => true, :playlist_items => "1:#{results.to_i}")
      items = entries(data).map { |entry| channel_from_entry(entry) }.compact
      unique_by(items) { |channel| channel.id.to_s == "" ? channel.url : channel.id }
    end

    def playlist_search(query, results = 50)
      data = dump_single(search_url(query, :playlist), :flat => true, :playlist_items => "1:#{results.to_i}")
      items = entries(data).map { |entry| playlist_from_entry(entry) }.compact
      unique_by(items) { |playlist| playlist.id.to_s == "" ? playlist.url : playlist.id }
    end

    def channel_videos(channel, results = 50)
      url = channel.to_s
      url = "https://www.youtube.com/channel/#{url}/videos" if url !~ %r{\Ahttps?://}i
      data = dump_single(url, :flat => true, :playlist_items => "1:#{results.to_i}")
      entries(data).map { |entry| video_from_entry(entry) }.compact
    end

    def playlist_videos(playlist, results = 50)
      url = playlist.to_s
      url = "https://www.youtube.com/playlist?list=#{url}" if url !~ %r{\Ahttps?://}i
      data = dump_single(url, :flat => true, :playlist_items => "1:#{results.to_i}")
      entries(data).map { |entry| video_from_entry(entry) }.compact
    end

    def video(value)
      id = video_id(value)
      url = id == nil ? value.to_s : video_url(id)
      data = dump_single(url, :flat => false, :no_playlist => true)
      video_from_entry(data)
    rescue Error
      nil
    end

    def audio_streams(video)
      data = dump_single(video_url(video.id), :flat => false, :no_playlist => true)
      Array(data["formats"]).map { |format| audio_stream_from_format(format) }.compact.sort_by { |stream| stream.bitrate.to_i }
    end

    def stream_url(video, format = "ba/bestaudio/best")
      lines = run(["-g", "-f", format, "--no-playlist", video_url(video.id)])
      lines.to_s.delete("\r").split("\n").map(&:strip).select { |line| line.start_with?("http://", "https://") }.last
    end

    def video_id(value)
      text = value.respond_to?(:url) ? value.url.to_s : value.to_s
      return text if text =~ /\A[a-zA-Z0-9_-]{11}\z/
      patterns = [
        %r{youtu\.be/([a-zA-Z0-9_-]{11})}i,
        %r{youtube\.com/watch\?[^#]*v=([a-zA-Z0-9_-]{11})}i,
        %r{youtube\.com/embed/([a-zA-Z0-9_-]{11})}i,
        %r{youtube\.com/shorts/([a-zA-Z0-9_-]{11})}i
      ]
      patterns.each do |pattern|
        match = text.match(pattern)
        return match[1] if match != nil
      end
      nil
    end

    def playlist_id(value)
      text = value.respond_to?(:url) ? value.url.to_s : value.to_s
      match = text.match(/[?&]list=([a-zA-Z0-9_-]+)/)
      match && match[1]
    end

    def channel_id(value)
      text = value.respond_to?(:url) ? value.url.to_s : value.to_s
      match = text.match(%r{youtube\.com/channel/([a-zA-Z0-9_-]+)}i)
      match && match[1]
    end

    private

    def dump_single(url, flat:, no_playlist: false, playlist_items: nil)
      args = ["-J", "--no-warnings", "--skip-download"]
      args << "--flat-playlist" if flat
      args << "--no-playlist" if no_playlist
      args += ["--playlist-items", playlist_items.to_s] if playlist_items != nil
      args << url.to_s
      parse_json(run(args))
    end

    def run(args)
      ensure_available!
      command_args = []
      command_args += ["--js-runtimes", js_runtimes.to_s] if js_runtimes.to_s != ""
      command_args += args
      command = quote(binary) + " " + command_args.map { |arg| quote(arg) }.join(" ")
      process = ChildProc.new(command, File.dirname(binary))
      output = +"".b
      error = +"".b
      wait_open = false
      runner = Runner.new
      runner.after(2) do
        if process.running?
          waiting
          wait_open = true
        end
      end
      runner.on_key(:key_escape) do |current|
        next if !wait_open
        process.terminate
        current.stop
      end
      runner.on_tick do |current|
        output << process.read.to_s.b if process.avail.to_i > 0
        error << process.read_err.to_s.b if process.avail_err.to_i > 0
        current.stop if !process.running?
      end
      runner.run
      output << process.read.to_s.b if process.avail.to_i > 0 rescue nil
      error << process.read_err.to_s.b if process.avail_err.to_i > 0 rescue nil
      if output.strip == ""
        log_empty_output(command, error, process)
        message = clean_error(error)
        message = "yt-dlp returned no JSON output" if message == ""
        raise Error, message
      end
      output.force_encoding(Encoding::UTF_8)
      output.valid_encoding? ? output : output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    ensure
      waiting_end if wait_open rescue nil
      process.terminate if process != nil && process.running? rescue nil
      process.close if process != nil rescue nil
    end

    def parse_json(text)
      raw = text.to_s
      JSON.parse(raw)
    rescue JSON::ParserError => first_error
      lines = raw.split(/\r?\n/).map(&:strip).reject(&:empty?)
      if lines.size > 1
        parsed = []
        lines.each_with_index do |line, index|
          begin
            parsed << JSON.parse(line)
          rescue JSON::ParserError => e
            log_invalid_json(raw, e, line: line, line_index: index + 1, first_error: first_error)
            raise Error, "Invalid yt-dlp JSON response"
          end
        end
        return parsed
      end
      log_invalid_json(raw, first_error)
      raise Error, "Invalid yt-dlp JSON response"
    end

    def log_invalid_json(raw, error, line: nil, line_index: nil, first_error: nil)
      message = "Invalid yt-dlp JSON response: #{error.class}: #{error.message}; bytes=#{raw.to_s.bytesize}; excerpt=#{json_excerpt(raw)}"
      message += "; initial=#{first_error.message}" if first_error != nil && first_error != error
      message += "; line=#{line_index}; line_excerpt=#{json_excerpt(line)}" if line != nil
      Log.warning(message)
    rescue Exception
    end

    def log_empty_output(command, error, process)
      status = process.respond_to?(:exitstatus) ? process.exitstatus : nil
      message = "yt-dlp returned empty stdout"
      message += "; exit=#{status}" if status != nil
      message += "; stderr=#{json_excerpt(error)}" if error.to_s != ""
      message += "; command=#{json_excerpt(command, 500)}"
      Log.warning(message)
    rescue Exception
    end

    def json_excerpt(value, limit = 2000)
      text = value.to_s
      text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      text = text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "?")
      text.length > limit ? text[0, limit] + "...<truncated>" : text
    end

    def entries(data)
      return data if data.is_a?(Array)
      Array(data["entries"])
    end

    def video_from_entry(entry)
      return nil if !entry.is_a?(Hash)
      id = entry["id"].to_s
      id = video_id(entry["url"]) if id == "" || id !~ /\A[a-zA-Z0-9_-]{11}\z/
      id = video_id(entry["webpage_url"]) if id == nil
      return nil if id == nil || id == ""
      video = Video.new
      video.id = id
      video.url = entry["webpage_url"].to_s
      video.url = video_url(id) if video.url == ""
      video.title = clean_text(entry["title"])
      video.author = clean_text(entry["channel"] || entry["uploader"] || entry["creator"])
      video.channel = entry["channel_id"].to_s
      video.channel = channel_id(entry["channel_url"]) if video.channel == ""
      video.description = clean_text(entry["description"])
      video.duration = format_duration(entry["duration"])
      video.date = parse_date(entry["upload_date"] || entry["release_date"] || entry["timestamp"])
      video.views = entry["view_count"].to_i if entry.key?("view_count")
      video.likes = entry["like_count"].to_i if entry.key?("like_count")
      video.dislikes = entry["dislike_count"].to_i if entry.key?("dislike_count")
      video.rating = entry["average_rating"].to_f if entry.key?("average_rating")
      video.keywords = Array(entry["tags"])
      video
    end

    def channel_from_entry(entry)
      return nil if !entry.is_a?(Hash)
      url = entry["url"].to_s
      url = entry["webpage_url"].to_s if url == ""
      url = entry["channel_url"].to_s if url == ""
      id = entry["channel_id"].to_s
      id = channel_id(url).to_s if id == ""
      return nil if url == "" && id == ""
      channel = Channel.new
      channel.id = id
      channel.url = url == "" ? "https://www.youtube.com/channel/#{id}" : absolute_youtube_url(url)
      channel.title = clean_text(entry["title"] || entry["channel"] || entry["uploader"])
      channel.title = channel.id if channel.title == ""
      channel
    end

    def playlist_from_entry(entry)
      return nil if !entry.is_a?(Hash)
      url = entry["url"].to_s
      url = entry["webpage_url"].to_s if url == ""
      id = entry["playlist_id"].to_s
      id = playlist_id(url).to_s if id == ""
      return nil if url == "" && id == ""
      playlist = Playlist.new
      playlist.id = id
      playlist.url = url == "" ? "https://www.youtube.com/playlist?list=#{id}" : absolute_youtube_url(url)
      playlist.title = clean_text(entry["title"] || entry["playlist_title"])
      playlist.author = clean_text(entry["channel"] || entry["uploader"])
      playlist
    end

    def audio_stream_from_format(format)
      return nil if !format.is_a?(Hash)
      return nil if format["url"].to_s == ""
      return nil if format["acodec"].to_s == "none"
      return nil if format["vcodec"].to_s != "none"
      stream = AudioStream.new
      stream.url = format["url"].to_s
      stream.codec = format["acodec"].to_s
      stream.container = (format["ext"] || format["container"]).to_s
      stream.format_id = format["format_id"].to_s
      bitrate = format["abr"] || format["tbr"] || 0
      stream.bitrate = (bitrate.to_f * 1000).to_i
      stream
    end

    def search_url(query, type)
      filter = case type
      when :channel
        "EgIQAg%3D%3D"
      when :playlist
        "EgIQAw%3D%3D"
      else
        "EgIQAQ%3D%3D"
      end
      "https://www.youtube.com/results?search_query=#{URI.encode_www_form_component(query.to_s)}&sp=#{filter}"
    end

    def video_url(id)
      "https://www.youtube.com/watch?v=#{id}"
    end

    def absolute_youtube_url(url)
      text = url.to_s
      return text if text =~ %r{\Ahttps?://}i
      return "https://www.youtube.com#{text}" if text.start_with?("/")
      text
    end

    def parse_date(value)
      return Time.at(value.to_i) if value.is_a?(Integer) || value.to_s =~ /\A\d{10,}\z/
      text = value.to_s
      return nil if text == ""
      if text =~ /\A(\d{4})(\d{2})(\d{2})\z/
        Time.local($1.to_i, $2.to_i, $3.to_i)
      elsif text =~ /\A(\d{4})-(\d{2})-(\d{2})/
        Time.local($1.to_i, $2.to_i, $3.to_i)
      end
    rescue Exception
      nil
    end

    def format_duration(value)
      return value.to_s if value.is_a?(String) && value !~ /\A\d+\z/
      seconds = value.to_i
      return "" if seconds <= 0
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      secs = seconds % 60
      hours > 0 ? "%d:%02d:%02d" % [hours, minutes, secs] : "%d:%02d" % [minutes, secs]
    end

    def clean_text(value)
      text = value.to_s
      text = html_decode(text)
      text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def clean_error(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).strip
    end

    def unique_by(items)
      seen = {}
      items.select do |item|
        key = yield(item).to_s
        next false if key == "" || seen[key]
        seen[key] = true
      end
    end

    def quote(value)
      "\"" + value.to_s.gsub("\\", "\\\\").gsub("\"", "\\\"") + "\""
    end
  end
end

class YoutubeMediaExtractor < MediaExtractor
  def initialize(video)
    @video = video
  end

  def proceed
    ProgramYoutube.yplayer(@video)
  end

  def title
    @video.title
  end
end

class YoutubeMediaFinder < MediaFinder
  @@cache = {}

  def self.video_ids(text)
    text.to_s.scan(%r{(?:watch\?[^#]*v=|embed/|shorts/|youtu\.be/)([a-zA-Z0-9_-]{11})}).map { |match| match[0] }.uniq
  end

  def self.possible_media?(text)
    video_ids(text).size > 0
  end

  def self.get_media(text)
    return [] if !Youtube.available?
    video_ids(text).map do |id|
      @@cache[id] ||= Youtube.video(id)
      @@cache[id] == nil ? nil : YoutubeMediaExtractor.new(@@cache[id])
    end.compact
  end
end

class ProgramYoutube < Program
  YTDLP_RELEASE_API = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest".freeze
  YTDLP_LATEST_DOWNLOAD = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/".freeze
  DENO_RELEASE_API = "https://api.github.com/repos/denoland/deno/releases/latest".freeze
  YTDLP_CHECK_INTERVAL = 86_400
  DENO_CHECK_INTERVAL = 86_400

  def self.init
    configure_youtube_runtime
  end

  def self.activate
    MediaFinders.register(YoutubeMediaFinder)
  end

  def self.ytdlp_asset_name
    case Programs.platform_target.to_s.downcase
    when "windows-x86"
      "yt-dlp_x86.exe"
    when "windows-x64"
      "yt-dlp.exe"
    when "osx-arm64", "osx-x64"
      "yt-dlp_macos"
    when "linux-x64", "linux-x86"
      "yt-dlp_linux"
    when "linux-arm64"
      "yt-dlp_linux_aarch64"
    else
      if Programs.platform_family == "osx"
        "yt-dlp_macos"
      else
        "yt-dlp.exe"
      end
    end
  end

  def self.ytdlp_path
    data_path(EltenPath.join("yt-dlp", ytdlp_asset_name))
  end

  def self.deno_asset_name
    case Programs.platform_target.to_s.downcase
    when "windows-x86"
      "deno-i686-pc-windows-msvc.zip"
    when "windows-x64"
      "deno-x86_64-pc-windows-msvc.zip"
    when "windows-arm64"
      "deno-aarch64-pc-windows-msvc.zip"
    when "osx-arm64"
      "deno-aarch64-apple-darwin.zip"
    when "osx-x64"
      "deno-x86_64-apple-darwin.zip"
    when "linux-x64", "linux-x86"
      "deno-x86_64-unknown-linux-gnu.zip"
    when "linux-arm64"
      "deno-aarch64-unknown-linux-gnu.zip"
    else
      if Programs.platform_family == "osx"
        "deno-aarch64-apple-darwin.zip"
      else
        "deno-x86_64-pc-windows-msvc.zip"
      end
    end
  end

  def self.deno_executable_name
    Programs.platform_family == "windows" ? "deno.exe" : "deno"
  end

  def self.deno_path
    data_path(EltenPath.join("deno", deno_executable_name))
  end

  def self.configure_youtube_runtime
    Youtube.binary = ytdlp_path
    Youtube.js_runtimes = File.file?(deno_path) ? "deno:#{deno_path}" : nil
  end

  def self.runtime_metadata
    data = read_json("runtime/info.json", :default => {})
    data = {} if !data.is_a?(Hash)
    data["schema_version"] = 1
    data["yt_dlp"] = {} if !data["yt_dlp"].is_a?(Hash)
    data["deno"] = {} if !data["deno"].is_a?(Hash)
    data
  end

  def self.write_runtime_metadata(data)
    data["schema_version"] = 1 if data.is_a?(Hash)
    write_json("runtime/info.json", data)
  end

  def self.ensure_runtime_ready
    configure_youtube_runtime
    if !File.file?(Youtube.binary)
      alert(_("Youtube needs to download yt-dlp before first use."))
      update_ytdlp!(:first_run => true)
    else
      check_ytdlp_update_if_needed
    end
    if !File.file?(deno_path)
      alert(_("Youtube needs to download Deno before first use."))
      update_deno!(:first_run => true)
    else
      check_deno_update_if_needed
    end
    configure_youtube_runtime
    File.file?(Youtube.binary) && File.file?(deno_path)
  rescue Exception => e
    Log.warning("Youtube runtime setup failed: #{e.class}: #{e.message}")
    alert(e.message)
    false
  end

  def self.check_ytdlp_update_if_needed
    metadata = runtime_metadata
    tool = metadata["yt_dlp"]
    return if Time.now.to_i - tool["checked_at"].to_i < YTDLP_CHECK_INTERVAL
    update_ytdlp!(:first_run => false)
  rescue Exception => e
    metadata = runtime_metadata
    metadata["yt_dlp"]["checked_at"] = Time.now.to_i
    write_runtime_metadata(metadata)
    Log.warning("yt-dlp update check failed: #{e.class}: #{e.message}")
  end

  def self.check_deno_update_if_needed
    metadata = runtime_metadata
    tool = metadata["deno"]
    return if Time.now.to_i - tool["checked_at"].to_i < DENO_CHECK_INTERVAL
    update_deno!(:first_run => false)
  rescue Exception => e
    metadata = runtime_metadata
    metadata["deno"]["checked_at"] = Time.now.to_i
    write_runtime_metadata(metadata)
    Log.warning("Deno update check failed: #{e.class}: #{e.message}")
  end

  def self.update_ytdlp!(first_run:)
    asset = ytdlp_asset_name
    metadata = runtime_metadata
    tool = metadata["yt_dlp"]
    release = latest_ytdlp_release
    version = release["tag_name"].to_s
    download_url = release_asset_url(release, asset) || (YTDLP_LATEST_DOWNLOAD + asset)
    if !first_run && File.file?(ytdlp_path) && tool["version"].to_s == version && tool["asset"].to_s == asset
      tool["checked_at"] = Time.now.to_i
      write_runtime_metadata(metadata)
      return true
    end
    if !first_run
      if !confirm(_("A new yt-dlp version is available. Do you want to update it now?"))
        return false
      end
    end
    alert(_("Downloading yt-dlp."))
    download_ytdlp(download_url, ytdlp_path, expected_sha256(release, asset))
    tool["version"] = version
    tool["asset"] = asset
    tool["download_url"] = download_url
    tool["path"] = ytdlp_path
    tool["checked_at"] = Time.now.to_i
    tool["updated_at"] = Time.now.to_i
    write_runtime_metadata(metadata)
    true
  end

  def self.update_deno!(first_run:)
    asset = deno_asset_name
    metadata = runtime_metadata
    tool = metadata["deno"]
    release = latest_deno_release
    version = release["tag_name"].to_s
    download_url = release_asset_url(release, asset)
    raise Youtube::Error, "Deno release asset not found: #{asset}" if download_url.to_s == ""
    if !first_run && File.file?(deno_path) && tool["version"].to_s == version && tool["asset"].to_s == asset
      tool["checked_at"] = Time.now.to_i
      write_runtime_metadata(metadata)
      return true
    end
    if !first_run
      if !confirm(_("A new Deno version is available. Do you want to update it now?"))
        return false
      end
    end
    alert(_("Downloading Deno."))
    download_deno(download_url, deno_path)
    tool["version"] = version
    tool["asset"] = asset
    tool["download_url"] = download_url
    tool["path"] = deno_path
    tool["checked_at"] = Time.now.to_i
    tool["updated_at"] = Time.now.to_i
    write_runtime_metadata(metadata)
    true
  end

  def self.latest_ytdlp_release
    JSON.parse(http_get(YTDLP_RELEASE_API, :accept => "application/vnd.github+json"))
  rescue JSON::ParserError => e
    raise Youtube::Error, "Invalid GitHub release response: #{e.message}"
  end

  def self.latest_deno_release
    JSON.parse(http_get(DENO_RELEASE_API, :accept => "application/vnd.github+json"))
  rescue JSON::ParserError => e
    raise Youtube::Error, "Invalid GitHub release response: #{e.message}"
  end

  def self.release_asset_url(release, asset_name)
    Array(release["assets"]).each do |asset|
      return asset["browser_download_url"].to_s if asset["name"].to_s == asset_name
    end
    nil
  end

  # Klangten: SHA-256 of a release asset from the release's SHA2-256SUMS file, or nil.
  def self.expected_sha256(release, asset_name)
    sums_url = release_asset_url(release, "SHA2-256SUMS")
    return nil if sums_url.to_s == ""
    http_get(sums_url).to_s.each_line do |line|
      digest, name = line.strip.split(/\s+\*?/, 2)
      return digest.downcase if name.to_s.strip == asset_name && digest.to_s =~ /\A[0-9a-fA-F]{64}\z/
    end
    nil
  rescue StandardError => e
    Log.warning("yt-dlp checksum list unavailable: #{e.class}: #{e.message}")
    nil
  end

  def self.download_ytdlp(url, output, sha256 = nil)
    require "digest"
    FileUtils.mkdir_p(File.dirname(output))
    tmp = output + ".download"
    http_download(url, tmp)
    raise Youtube::Error, "Downloaded yt-dlp is empty" if !File.file?(tmp) || File.size(tmp) <= 0
    if sha256 != nil && Digest::SHA256.file(tmp).hexdigest.downcase != sha256
      raise Youtube::Error, "Downloaded yt-dlp does not match its published checksum"
    end
    FileUtils.mv(tmp, output)
    File.chmod(0o755, output) if Programs.platform_family != "windows"
  ensure
    File.delete(tmp) if tmp != nil && File.file?(tmp) rescue nil
  end

  def self.download_deno(url, output)
    require "zip"
    FileUtils.mkdir_p(File.dirname(output))
    archive = output + ".zip.download"
    executable = output + ".download"
    http_download(url, archive)
    raise Youtube::Error, "Downloaded Deno archive is empty" if !File.file?(archive) || File.size(archive) <= 0
    Zip::File.open(archive) do |zip|
      entry = zip.entries.find do |zip_entry|
        !zip_entry.directory? && File.basename(zip_entry.name).casecmp?(deno_executable_name)
      end
      raise Youtube::Error, "Deno executable not found in archive" if entry == nil
      entry.get_input_stream do |input|
        File.open(executable, "wb") do |file|
          while (chunk = input.read(64 * 1024))
            file.write(chunk)
          end
        end
      end
    end
    raise Youtube::Error, "Extracted Deno executable is empty" if !File.file?(executable) || File.size(executable) <= 0
    FileUtils.mv(executable, output)
    File.chmod(0o755, output) if Programs.platform_family != "windows"
  rescue Zip::Error => e
    raise Youtube::Error, "Invalid Deno archive: #{e.message}"
  ensure
    File.delete(archive) if archive != nil && File.file?(archive) rescue nil
    File.delete(executable) if executable != nil && File.file?(executable) rescue nil
  end

  def self.http_get(url, accept: nil)
    headers = { "User-Agent" => "Klangten-Youtube/#{version}" }
    headers["Accept"] = accept if accept != nil
    body = read_url(url, headers: headers)
    raise Youtube::Error, "GitHub request failed or was cancelled" if body == nil
    body
  end

  def self.http_download(url, output)
    waiting
    success = download_file(url, output, use_waiting: false, can_cancel: false, override: true)
    raise Youtube::Error, "Dependency download failed" if !success
    true
  ensure
    waiting_end
  end

  def initialize(channel = nil)
    @channel = channel
  end

  def main
    if !self.class.ensure_runtime_ready
      alert(_("yt-dlp is unavailable."))
      return
    end
    reset_search_results
    if @channel == nil
      show_search_dialog
    else
      ysearch(@channel, 50, 0, :channel)
    end
  ensure
    finish
  end

  def show_search_dialog
    closed = false
    dialog_open
    form = Form.new([
      query = EditBox.new(_("Search Youtube")),
      type = ListBox.new([_("Video"), _("Channel"), _("Playlist")], header: _("What to search")),
      search = Button.new(_("Search")),
      cancel = Button.new(_("Cancel"))
    ])
    form.cancel_button = cancel
    form.accept_button = search
    cancel.on(:press) { form.resume }
    search.on(:press) do
      text = query.text.to_s
      dialog_close
      closed = true
      form.resume
      start_search(text, type.index)
    end
    form.wait
  ensure
    dialog_close if !closed rescue nil
  end

  def start_search(text, type)
    reset_search_results
    if Youtube.video_id(text) != nil
      self.class.yplayer(text)
    elsif Youtube.playlist_id(text) != nil
      ysearch(text, 50, 0, :playlist)
    elsif Youtube.channel_id(text) != nil || text =~ %r{\Ayoutube\.com/(?:@|c/|user/)}i || text =~ %r{\Ahttps?://(?:www\.)?youtube\.com/(?:@|c/|user/)}i
      ysearch(text, 50, 0, :channel)
    elsif type == 0
      ysearch(text)
    elsif type == 1
      ychannelsearch(text)
    else
      yplaylistsearch(text)
    end
  end

  def ysearch(query, count = 50, index = 0, type = :search)
    results = case type
    when :channel
      Youtube.channel_videos(query, count)
    when :playlist
      Youtube.playlist_videos(query, count)
    else
      Youtube.search(query, count, type)
    end
    @videos ||= []
    ids = @videos.map(&:id)
    Array(results).each do |video|
      next if video == nil || ids.include?(video.id)
      @videos << video
      ids << video.id
    end
    show_video_results(query, count, index, type)
  rescue Youtube::Error => e
    alert(e.message)
  end

  def show_video_results(query, count, index, type)
    return if @videos == nil
    dialog_open
    options = @videos.map { |video| video_option(video) } + [_("Load more")]
    list = ListBox.new(options, header: _("Search results"), index: 0, flags: 0, quiet: true)
    list.index = index if index < list.options.size
    details = EditBox.new(_("Details"), type: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, text: "", quiet: true)
    form = Form.new([list, details])
    cancel = Button.new(_("Cancel"))
    form.cancel_button = cancel
    outcome = nil
    details.on(:before_focus) { details.settext(list.index < @videos.size ? video_details(@videos[list.index]) : "") }
    list.on(:key_d) do
      if key_held?(0x11) && list.index < @videos.size
        alert(@videos[list.index].duration)
      end
    end
    list.on(:select) do
      if list.index < @videos.size
        self.class.yplayer(@videos[list.index])
        speech_wait
        list.focus
      else
        outcome = :more
        form.resume
      end
    end
    cancel.on(:press) { form.resume }
    form.wait
    return show_search_dialog if outcome == nil && @channel == nil
    ysearch(query, count + 50, list.index, type) if outcome == :more
  ensure
    dialog_close rescue nil
  end

  def ychannelsearch(query, count = 50, index = 0)
    @channels ||= []
    ids = @channels.map { |channel| channel.id.to_s == "" ? channel.url : channel.id }
    Youtube.channel_search(query, count).each do |channel|
      id = channel.id.to_s == "" ? channel.url : channel.id
      next if ids.include?(id)
      @channels << channel
      ids << id
    end
    show_channel_results(query, count, index)
  rescue Youtube::Error => e
    alert(e.message)
  end

  def show_channel_results(query, count, index)
    dialog_open
    list = ListBox.new(@channels.map(&:title) + [_("Load more")], header: _("Search results"), index: 0, flags: 0, quiet: true)
    list.index = index if index < list.options.size
    form = Form.new([list])
    cancel = Button.new(_("Cancel"))
    form.cancel_button = cancel
    outcome = nil
    list.on(:select) do
      outcome = list.index < @channels.size ? :open : :more
      form.resume
    end
    cancel.on(:press) { form.resume }
    form.wait
    return show_search_dialog if outcome == nil
    if outcome == :open
      @videos = []
      ysearch(@channels[list.index].url, 50, 0, :channel)
    else
      ychannelsearch(query, count + 50, list.index)
    end
  ensure
    dialog_close rescue nil
  end

  def yplaylistsearch(query, count = 50, index = 0)
    @playlists ||= []
    ids = @playlists.map { |playlist| playlist.id.to_s == "" ? playlist.url : playlist.id }
    Youtube.playlist_search(query, count).each do |playlist|
      id = playlist.id.to_s == "" ? playlist.url : playlist.id
      next if ids.include?(id)
      @playlists << playlist
      ids << id
    end
    show_playlist_results(query, count, index)
  rescue Youtube::Error => e
    alert(e.message)
  end

  def show_playlist_results(query, count, index)
    dialog_open
    list = ListBox.new(@playlists.map { |playlist| [playlist.title, playlist.author].reject { |part| part.to_s == "" }.join(", ") } + [_("Load more")], header: _("Search results"), index: 0, flags: 0, quiet: true)
    list.index = index if index < list.options.size
    form = Form.new([list])
    cancel = Button.new(_("Cancel"))
    form.cancel_button = cancel
    outcome = nil
    list.on(:select) do
      outcome = list.index < @playlists.size ? :open : :more
      form.resume
    end
    cancel.on(:press) { form.resume }
    form.wait
    return show_search_dialog if outcome == nil
    if outcome == :open
      @videos = []
      ysearch(@playlists[list.index].url, 50, 0, :playlist)
    else
      yplaylistsearch(query, count + 50, list.index)
    end
  ensure
    dialog_close rescue nil
  end

  def video_option(video)
    text = video.title.to_s
    text += ": #{video.author}" if video.author.to_s != ""
    text += "\n#{video.description}" if video.description.to_s != ""
    text
  end

  def reset_search_results
    @videos = []
    @channels = []
    @playlists = []
  end

  def video_details(video)
    lines = [
      video.title,
      "#{_("Author")}: #{video.author}",
      "#{_("Publication date")}: #{video.date == nil ? "" : format_date(video.date, true)}",
      "#{_("Duration")}: #{video.duration}",
      "",
      video.description
    ]
    lines.compact.join("\n")
  end

  def self.yplayer(url, _update = false)
    return if !ensure_runtime_ready
    video = url.is_a?(Youtube::Video) ? url : Youtube.video(url)
    return if video == nil
    action = select_action(
      {
        play: _("Play"),
        custom: _("Play custom quality"),
        channel: _("Show channel"),
        download: _("Download"),
        copy: _("Copy URL to the clipboard"),
        cancel: _("Cancel")
      },
      header: video.title,
      cancel: :cancel,
      flags: 1
    )
    case action
    when :play
      play_video(video)
    when :custom
      play_custom_quality(video)
    when :channel
      insert_scene(new(video.channel), true) if video.channel.to_s != ""
    when :download
      download_video(video)
    when :copy
      Clipboard.set_data(video.url)
      alert(_("Copied to clipboard."))
    end
  rescue Youtube::Error => e
    alert(e.message)
  end

  def self.play_video(video)
    url = Youtube.stream_url(video, "ba/bestaudio/best")
    player(url, label: video.title) if url != nil
  end

  def self.play_custom_quality(video)
    streams = video.audiostreams
    if streams.empty?
      alert(_("Error"))
      return
    end
    stream = select_action(streams.map { |item| [item, item.label] }, header: _("Select stream to play"))
    player(stream.url, label: video.title) if stream != nil
  end

  def self.download_video(video)
    title = safe_file_name(video.title)
    audio_encoders = MediaEncoders.list.select { |encoder| encoder::Type == :audio }
    video_encoders = MediaEncoders.list.select { |encoder| encoder::Type == :video }
    labels = audio_encoders.map { |encoder| "#{encoder::Name}( #{_("Audio")} #{encoder::Extension})" }
    labels += video_encoders.map { |encoder| "#{encoder::Name}( #{_("Video")} #{encoder::Extension})" }
    form = Form.new([
      destination = FilesTree.new(_("Destination"), path: EltenPath.join(Dirs.user, "Music"), hide_files: true, quiet: true),
      format = ListBox.new(labels, header: _("Save format")),
      name = EditBox.new(_("File name"), text: ""),
      download = Button.new(_("Download")),
      cancel = Button.new(_("Cancel"))
    ])
    format.on(:move) do
      encoder = audio_encoders[format.index] || video_encoders[format.index - audio_encoders.size]
      name.settext(title + encoder::Extension) if encoder != nil
    end
    format.trigger(:move)
    cancel.on(:press) { form.resume }
    form.cancel_button = cancel
    download.on(:press) do
      encoder = audio_encoders[format.index] || video_encoders[format.index - audio_encoders.size]
      next if encoder == nil
      output = EltenPath.join(destination.selected, safe_file_name(name.text))
      source = format.index < audio_encoders.size ? best_audio_url(video) : Youtube.stream_url(video, "best")
      if source == nil
        alert(_("Error"))
      else
        waiting
        encoder.encode_file(source, output)
        waiting_end
        alert(_("Saved"))
        form.resume
      end
    ensure
      waiting_end rescue nil
    end
    form.wait
  end

  def self.best_audio_url(video)
    streams = video.audiostreams
    preferred = streams.select { |stream| stream.codec.to_s.include?("opus") && stream.bitrate.to_i > 56_000 }.last
    (preferred || streams.last || streams.first)&.url || Youtube.stream_url(video, "ba/bestaudio/best")
  end

  def self.safe_file_name(name)
    name.to_s.delete("\r\n\\/:!@\#*?<>\'\"|+=`").strip
  end
end
