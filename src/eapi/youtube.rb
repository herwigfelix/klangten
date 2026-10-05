# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# YouTube: finding, resolving and downloading YouTube media.
#
# Three platform paths share one data model (Item, Page, Video, Stream):
#
#   Windows, macOS, Linux   yt-dlp plus the Deno JavaScript runtime it needs for
#                           YouTube. Both are downloaded on first use from their
#                           GitHub releases into <data>/youtube/bin and verified
#                           against the checksums those releases publish.
#   Android                 KlangtenYouTubeHost (src/platforms/ios/eapi/youtube_host.rb),
#                           NewPipeExtractor inside the app; no paging, no yt-dlp.
#   iOS                     not available (no child processes, no JIT).
#
# yt-dlp is taken in its "onedir" build (a zip with the program and its
# libraries). The single-file builds unpack themselves into a temporary folder on
# every start, which cost about nine seconds per call on macOS; the onedir build
# starts in a fraction of a second once it is unpacked.
#
# Everything that talks to the network or runs yt-dlp blocks and takes a
# cancellation token; the scene calls it from EltenAPI::Tasks.run. Workers never
# call loop_update, so HTTP goes through EltenAPI::HTTPClient directly instead
# of read_url/download_file. Only the methods in the "interactive" section ask
# questions; they belong to the scene thread.
#
# History, favourites and recent searches are JSON files in <data>/youtube.

require "json"
require "fileutils"
require "digest"
require "uri"

module KlangtenYouTube
  PAGE_SIZE = 50
  HISTORY_LIMIT = 200
  SEARCH_HISTORY_LIMIT = 50
  UPDATE_INTERVAL = 24 * 60 * 60
  VIDEO_CACHE_SECONDS = 20 * 60
  PROGRESS_MARK = "@@klangten-progress ".freeze

  YTDLP_REPO = "yt-dlp/yt-dlp".freeze
  YTDLP_CHECKSUMS = "SHA2-256SUMS".freeze
  DENO_REPO = "denoland/deno".freeze

  # Search result filters of youtube.com ("sp" parameter).
  SEARCH_FILTERS = {
    video: "EgIQAQ%3D%3D",
    channel: "EgIQAg%3D%3D",
    playlist: "EgIQAw%3D%3D"
  }.freeze

  # Release asset and executable name per platform target.
  YTDLP_BUILDS = {
    "windows-x64" => ["yt-dlp_win.zip", "yt-dlp.exe"],
    "windows-x86" => ["yt-dlp_win_x86.zip", "yt-dlp_x86.exe"],
    "windows-arm64" => ["yt-dlp_win_arm64.zip", "yt-dlp_arm64.exe"],
    "osx-arm64" => ["yt-dlp_macos.zip", "yt-dlp_macos"],
    "osx-x64" => ["yt-dlp_macos.zip", "yt-dlp_macos"],
    "linux-x64" => ["yt-dlp_linux.zip", "yt-dlp_linux"],
    "linux-arm64" => ["yt-dlp_linux_aarch64.zip", "yt-dlp_linux_aarch64"],
    "linux-armhf" => ["yt-dlp_linux_armv7l.zip", "yt-dlp_linux_armv7l"]
  }.freeze

  # Deno has no build for 32-bit systems; yt-dlp then runs without a JavaScript
  # runtime and YouTube offers fewer formats.
  DENO_BUILDS = {
    "windows-x64" => "deno-x86_64-pc-windows-msvc.zip",
    "windows-arm64" => "deno-aarch64-pc-windows-msvc.zip",
    "osx-arm64" => "deno-aarch64-apple-darwin.zip",
    "osx-x64" => "deno-x86_64-apple-darwin.zip",
    "linux-x64" => "deno-x86_64-unknown-linux-gnu.zip",
    "linux-arm64" => "deno-aarch64-unknown-linux-gnu.zip"
  }.freeze

  # Interface languages YouTube accepts for translated titles (yt-dlp rejects
  # every other code with an error, so anything else sends no language at all).
  YOUTUBE_LANGUAGES = %w[
    af az id ms bs ca cs da de et en-IN en-GB en es es-419 es-US eu fil fr fr-CA gl hr zu is it sw lv lt hu
    nl no uz pl pt-PT pt ro sq sk sl sr-Latn fi sv vi tr be bg ky kk mk mn ru sr uk el hy iw ur ar fa ne mr
    hi as bn pa gu or ta te kn ml si th lo my ka am km zh-CN zh-TW zh-HK ja ko
  ].freeze

  VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/
  URL_PATTERN = %r{(?:https?://)?(?:(?:www|m|music)\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/[^\s<>"'\]\)]+}i

  # kind: :video, :channel or :playlist. id: video id, channel id or playlist id
  # (on Android the address of channels and playlists).
  Item = Struct.new(:kind, :id, :url, :title, :author, :channel_url, :duration, :views, :subscribers, :date, :description, :live, keyword_init: true) do
    def key
      "#{kind}:#{id}"
    end

    def video?
      kind == :video
    end
  end

  Page = Struct.new(:items, :more, keyword_init: true)

  # bitrate in kbit/s
  Stream = Struct.new(:url, :codec, :container, :bitrate, :format_id, keyword_init: true)

  Video = Struct.new(:id, :url, :title, :author, :channel_url, :duration, :views, :likes, :date, :description, :live, :streams, keyword_init: true)

  Release = Struct.new(:tag, :assets, keyword_init: true)

  Result = Struct.new(:status, :output, :errors, keyword_init: true)

  class Error < StandardError; end

  # yt-dlp is not installed (desktop) or the platform has no YouTube support.
  class Missing < Error; end

  class << self
    # ------------------------------------------------------------- platform

    def platform_os
      EltenSystemHelpers.platform_os.to_s
    rescue Exception
      ""
    end

    def windows?
      platform_os == "windows"
    end

    def desktop?
      %w[windows osx linux].include?(platform_os)
    end

    def android_host?
      platform_os == "android" && defined?(KlangtenYouTubeHost) && KlangtenYouTubeHost.available?
    rescue Exception
      false
    end

    def available?
      desktop? ? YTDLP_BUILDS.key?(target) : android_host?
    end

    # Platform target of the operating system. A 32-bit Klangten on 64-bit
    # Windows still gets the 64-bit yt-dlp and Deno.
    def target
      if windows?
        arch = (ENV["PROCESSOR_ARCHITEW6432"] || ENV["PROCESSOR_ARCHITECTURE"]).to_s.upcase
        return "windows-arm64" if arch == "ARM64"
        return "windows-x64" if arch == "AMD64" || arch == "X64"
      end
      EltenSystemHelpers.platform_target.to_s
    rescue Exception
      ""
    end

    # --------------------------------------------------------------- places

    def data_dir
      File.join(Dirs.eltendata, "youtube")
    end

    def bin_dir
      File.join(data_dir, "bin")
    end

    def cache_dir
      File.join(data_dir, "cache")
    end

    def temp_dir
      File.join(Dirs.temp, "youtube")
    end

    def ytdlp_path
      build = YTDLP_BUILDS[target]
      build == nil ? nil : File.join(bin_dir, "yt-dlp", build[1])
    end

    def deno_path
      File.join(bin_dir, windows? ? "deno.exe" : "deno")
    end

    def deno_supported?
      DENO_BUILDS.key?(target)
    end

    def installed?
      return true if android_host?
      path = ytdlp_path
      path != nil && File.file?(path) && (!deno_supported? || File.file?(deno_path))
    end

    # {"yt-dlp" => tag, "deno" => tag} of the installed copies.
    def installed_versions
      state = read_json("components.json", {})
      state.is_a?(Hash) ? state.select { |key, _value| %w[yt-dlp deno].include?(key) } : {}
    end

    # A new folder for one download or conversion; the caller removes it.
    def new_temp_dir
      dir = File.join(temp_dir, "job-#{Process.pid}-#{rand(36**8).to_s(36)}")
      FileUtils.mkdir_p(dir)
      dir
    end

    # ------------------------------------------------------------ addresses

    # [:video, id], [:playlist, url], [:channel, url] or nil. Accepts watch,
    # embed, shorts and live links, youtu.be, bare video ids, playlist links
    # (list=) and channel links (/channel/ID, /@handle, /c/name, /user/name).
    def parse_url(text)
      value = text.to_s.strip
      return nil if value == "" || value.match?(/\s/)
      return [:video, value] if probable_video_id?(value)
      value = "https://" + value if value.match?(%r{\A(?:(?:www|m|music)\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/}i)
      value = value.gsub(/[^\x21-\x7e]/) { |char| char.bytes.map { |byte| "%%%02X" % byte }.join }
      uri = URI.parse(value)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.to_s != ""
      host = uri.host.downcase.sub(/\A(?:www|m|music)\./, "")
      path = uri.path.to_s
      params = query_params(uri.query)
      if host == "youtu.be"
        id = path.sub(%r{\A/}, "").split("/").first.to_s
        return id.match?(VIDEO_ID) ? [:video, id] : nil
      end
      return nil unless host == "youtube.com" || host == "youtube-nocookie.com"
      case path
      when %r{\A/watch/?\z}
        return [:video, params["v"]] if params["v"].to_s.match?(VIDEO_ID)
      when %r{\A/(?:embed|shorts|live|v|e)/([A-Za-z0-9_-]{11})(?:[/?#]|\z)}
        return [:video, $1]
      when %r{\A/channel/(UC[A-Za-z0-9_-]+)}
        return [:channel, "https://www.youtube.com/channel/#{$1}"]
      when %r{\A/(@[^/?#]+)}
        return [:channel, "https://www.youtube.com/#{$1}"]
      when %r{\A/(c|user)/([^/?#]+)}
        return [:channel, "https://www.youtube.com/#{$1}/#{$2}"]
      end
      list = params["list"].to_s
      return [:playlist, playlist_url(list)] if list.match?(/\A[A-Za-z0-9_-]{10,}\z/)
      nil
    rescue URI::Error, ArgumentError
      nil
    end

    # An 11-character string counts as a video id only when it looks random
    # (both letter cases and a digit, "_" or "-"). A word that happens to be 11
    # characters long is searched for instead, and YouTube's search finds a
    # real id that this rule misses anyway.
    def probable_video_id?(value)
      value.match?(VIDEO_ID) && value.match?(/[A-Z]/) && value.match?(/[a-z]/) && value.match?(/[0-9_-]/)
    end

    # Every YouTube address in a text, unique, as [kind, value, original text].
    def find_urls(text, limit: 20)
      found = []
      text.to_s.scan(URL_PATTERN) do
        match = Regexp.last_match(0).sub(/[.,;:!?]+\z/, "")
        target = parse_url(match)
        next if target == nil || found.any? { |entry| entry[0] == target[0] && entry[1] == target[1] }
        found << [target[0], target[1], match]
        break if found.size >= limit
      end
      found
    end

    def video_url(id)
      "https://www.youtube.com/watch?v=#{id}"
    end

    def playlist_url(id)
      "https://www.youtube.com/playlist?list=#{id}"
    end

    def item_url(item)
      return item.url.to_s if item.url.to_s != ""
      case item.kind
      when :video then video_url(item.id)
      when :playlist then item.id.to_s.start_with?("http") ? item.id.to_s : playlist_url(item.id)
      else item.id.to_s.start_with?("http") ? item.id.to_s : "https://www.youtube.com/channel/#{item.id}"
      end
    end

    # ------------------------------------------------------------- browsing

    # kind: :video, :channel or :playlist. page counts from 0.
    def search(query, kind = :video, page: 0, token: nil)
      kind = :video unless SEARCH_FILTERS.key?(kind)
      if !desktop?
        return Page.new(items: [], more: false) if page > 0
        return host_page(host_call { KlangtenYouTubeHost.search(query.to_s, kind == :video ? :search : kind) })
      end
      url = "https://www.youtube.com/results?search_query=#{URI.encode_www_form_component(query.to_s)}&sp=#{SEARCH_FILTERS[kind]}"
      list_page(url, page, token)
    end

    def channel_videos(url, page: 0, token: nil)
      if !desktop?
        return Page.new(items: [], more: false) if page > 0
        return host_page(host_call { KlangtenYouTubeHost.channel_videos(url.to_s) })
      end
      base = url.to_s.sub(%r{/+\z}, "").sub(%r{/(?:videos|featured|streams|shorts|playlists|about)\z}, "")
      begin
        list_page(base + "/videos", page, token)
      rescue Error => e
        # Automatically generated "Topic" channels have no videos tab; the
        # channel address itself lists their uploads.
        raise unless e.message.include?("videos tab")
        list_page(base, page, token)
      end
    end

    def playlist_videos(url, page: 0, token: nil)
      if !desktop?
        return Page.new(items: [], more: false) if page > 0
        return host_page(host_call { KlangtenYouTubeHost.playlist_videos(url.to_s) })
      end
      list_page(url.to_s, page, token)
    end

    # Details and audio streams of one video. Stream addresses expire after a
    # few hours, so the session cache keeps them only for a short while.
    def video(id_or_url, token: nil, cached: true)
      id = video_id(id_or_url)
      @video_cache ||= {}
      entry = @video_cache[id]
      return entry[1] if cached && entry != nil && Time.now.to_f - entry[0] < VIDEO_CACHE_SECONDS
      result = desktop? ? desktop_video(id, token) : host_video(id)
      @video_cache[id] = [Time.now.to_f, result]
      result
    end

    def video_id(id_or_url)
      value = id_or_url.to_s
      return value if value.match?(VIDEO_ID)
      target = parse_url(value)
      raise Error, "Not a YouTube video: #{value}" if target == nil || target[0] != :video
      target[1]
    end

    # Audio-only streams, highest bitrate first.
    def audio_streams(video)
      video.streams.to_a.select { |stream| stream.url.to_s != "" }.sort_by { |stream| -stream.bitrate.to_f }
    end

    # Opus of at least 128 kbit/s when offered, otherwise the highest bitrate.
    def best_audio(video)
      streams = audio_streams(video)
      streams.find { |stream| stream.codec.to_s.downcase == "opus" && stream.bitrate.to_f >= 128 } || streams.first
    end

    # The stream saved without conversion: AAC in MP4 plays everywhere, so it
    # wins over Opus/WebM when the video offers it.
    def original_audio(video)
      streams = audio_streams(video)
      streams.find { |stream| stream.container.to_s.downcase == "m4a" } || streams.first
    end

    def item_from_video(video)
      Item.new(
        kind: :video, id: video.id, url: video.url, title: video.title, author: video.author,
        channel_url: video.channel_url, duration: video.duration, views: video.views,
        date: video.date, description: video.description, live: video.live
      )
    end

    # Title and author of a video or playlist without yt-dlp (oEmbed). nil
    # when YouTube does not know the address.
    def oembed(url, token: nil)
      body = http_get("https://www.youtube.com/oembed?format=json&url=#{URI.encode_www_form_component(url.to_s)}", { "Accept" => "application/json" }, token)
      data = JSON.parse(body)
      data.is_a?(Hash) && data["title"].to_s != "" ? { title: data["title"].to_s, author: data["author_name"].to_s } : nil
    rescue EltenAPI::Tasks::Cancelled, EltenAPI::Tasks::TimedOut
      raise
    rescue StandardError => e
      Log.debug("YouTube oEmbed failed for #{url}: #{e.class}: #{e.message}")
      nil
    end

    # ------------------------------------------------------------ downloads

    # Downloads a video with yt-dlp into directory and returns the file.
    # kind :audio keeps the delivered audio (AAC/M4A preferred); kind :video
    # merges the best video up to 720p with its audio into MKV, which needs
    # ffmpeg (ffmpeg: path, or nil to let yt-dlp search PATH). The block
    # receives the percentage.
    def download(url, kind, directory, token: nil, ffmpeg: nil, &progress)
      raise Missing, "yt-dlp is not installed" unless desktop? && installed?
      FileUtils.mkdir_p(directory)
      format = kind == :video ? "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b" : "bestaudio[ext=m4a]/bestaudio"
      args = [
        "--no-playlist", "-f", format, "--no-part", "--newline", "--progress",
        "--progress-template", "download:#{PROGRESS_MARK}%(progress._percent_str)s",
        "-o", native_path(File.join(directory, "download.%(ext)s"))
      ]
      if kind == :video
        args += ["--merge-output-format", "mkv"]
        args += ["--ffmpeg-location", native_path(ffmpeg)] if ffmpeg.to_s != ""
      end
      args << url.to_s
      result = ytdlp(args, token: token) do |line|
        next if progress == nil || !line.start_with?(PROGRESS_MARK)
        value = line[PROGRESS_MARK.size..-1].to_s.delete("%").strip.to_f
        progress.call(value)
      end
      file = Dir.children(directory).select { |name| name.start_with?("download.") && !name.end_with?(".part", ".ytdl", ".temp") }
                .map { |name| File.join(directory, name) }
                .select { |path| File.file?(path) && File.size(path) > 0 }
                .max_by { |path| File.size(path) }
      raise Error, failure_message(result) if file == nil
      file
    end

    # ffmpeg for merging video and audio, from the FFmpeg encoders when they
    # know one (src/eapi/audio/encoders/ffmpeg.rb). Only methods that merely
    # report a path are asked; none of them may download or ask anything.
    def ffmpeg_location
      return nil unless defined?(KlangtenFFmpeg)
      %i[path executable ffmpeg_path].each do |name|
        next unless KlangtenFFmpeg.respond_to?(name)
        value = (KlangtenFFmpeg.public_send(name) rescue nil).to_s
        return value if value != "" && File.file?(value)
      end
      nil
    end

    # ----------------------------------------------------- history, favourites

    def history
      read_json("history.json", []).map { |row| item_from_h(row) }.compact
    end

    def add_to_history(item)
      return if item == nil || item.id.to_s == ""
      rows = read_json("history.json", []).reject { |row| row_key(row) == item.key }
      rows.unshift(item_to_h(item).merge("time" => Time.now.to_i))
      write_json("history.json", rows.first(HISTORY_LIMIT))
    end

    def remove_from_history(item)
      write_json("history.json", read_json("history.json", []).reject { |row| row_key(row) == item.key })
    end

    def clear_history
      write_json("history.json", [])
    end

    def favourites
      read_json("favourites.json", []).map { |row| item_from_h(row) }.compact
    end

    def favourite?(item)
      item != nil && read_json("favourites.json", []).any? { |row| row_key(row) == item.key }
    end

    # Adds or removes; returns true when the item is a favourite afterwards.
    def toggle_favourite(item)
      rows = read_json("favourites.json", [])
      if rows.any? { |row| row_key(row) == item.key }
        write_json("favourites.json", rows.reject { |row| row_key(row) == item.key })
        false
      else
        write_json("favourites.json", rows + [item_to_h(item).merge("time" => Time.now.to_i)])
        true
      end
    end

    def recent_searches
      read_json("searches.json", []).map(&:to_s).reject { |query| query == "" }
    end

    def remember_search(query)
      query = query.to_s.strip
      return if query == ""
      rows = recent_searches.reject { |entry| entry.casecmp?(query) }
      write_json("searches.json", ([query] + rows).first(SEARCH_HISTORY_LIMIT))
    end

    def clear_searches
      write_json("searches.json", [])
    end

    def item_to_h(item)
      {
        "kind" => item.kind.to_s, "id" => item.id.to_s, "url" => item.url.to_s, "title" => item.title.to_s,
        "author" => item.author.to_s, "channel_url" => item.channel_url.to_s, "duration" => item.duration
      }
    end

    def item_from_h(row)
      return nil unless row.is_a?(Hash) && row["id"].to_s != ""
      kind = row["kind"].to_s
      kind = "video" unless %w[video channel playlist].include?(kind)
      Item.new(
        kind: kind.to_sym, id: row["id"].to_s, url: row["url"].to_s, title: row["title"].to_s,
        author: row["author"].to_s, channel_url: row["channel_url"].to_s,
        duration: row["duration"] == nil ? nil : row["duration"].to_i
      )
    end

    # ----------------------------------------------------------- formatting

    # "1:02:03" or "4:05"; nil when unknown.
    def format_duration(seconds)
      return nil if seconds == nil || seconds.to_i <= 0
      total = seconds.to_i
      hours = total / 3600
      minutes = (total % 3600) / 60
      secs = total % 60
      hours > 0 ? format("%d:%02d:%02d", hours, minutes, secs) : format("%d:%02d", minutes, secs)
    end

    # ---------------------------------------------- yt-dlp and Deno components

    # Newest releases, as {"yt-dlp" => Release, "deno" => Release or nil}.
    def latest_releases(token: nil)
      releases = { "yt-dlp" => latest_release(YTDLP_REPO, token) }
      releases["deno"] = deno_supported? ? latest_release(DENO_REPO, token) : nil
      releases
    end

    # Names of the components whose installed version differs from releases.
    def outdated(releases)
      versions = installed_versions
      names = []
      names << "yt-dlp" if releases["yt-dlp"] != nil && (versions["yt-dlp"].to_s != releases["yt-dlp"].tag || !File.file?(ytdlp_path.to_s))
      names << "deno" if releases["deno"] != nil && (versions["deno"].to_s != releases["deno"].tag || !File.file?(deno_path))
      names
    end

    # Downloads, verifies and unpacks the given components (all missing or
    # outdated ones by default).
    def install(releases, names = nil, token: nil, progress: nil)
      raise Missing, "YouTube is not available on #{target}" unless desktop? && YTDLP_BUILDS.key?(target)
      names ||= outdated(releases)
      FileUtils.mkdir_p(bin_dir)
      names.each_with_index do |name, index|
        token.raise_if_cancelled! if token != nil
        report = proc do |percent|
          next if progress == nil
          progress.update(((index + percent.to_f / 100.0) / names.size * 100.0).round, total: 100, message: name == "deno" ? "Deno" : "yt-dlp")
        end
        name == "deno" ? install_deno(releases["deno"], token, report) : install_ytdlp(releases["yt-dlp"], token, report)
      end
      store_state("checked" => Time.now.to_i)
      true
    end

    def update_check_due?
      Time.now.to_i - read_json("components.json", {}).fetch("checked", 0).to_i >= UPDATE_INTERVAL
    rescue StandardError
      true
    end

    def mark_update_checked
      store_state("checked" => Time.now.to_i)
    end

    # ---------------------------------------------------------- interactive
    # These run on the scene thread: they ask, show progress and report.

    # True when YouTube can be used now. On the desktop the first call offers
    # to download yt-dlp and Deno; later calls look for updates once a day.
    def prepare
      unless available?
        alert(p_("Klangten", "This feature is not available on this system."))
        return false
      end
      return true unless desktop?
      unless installed?
        question = p_("Klangten", "YouTube needs two helper programs, yt-dlp and Deno, which are downloaded from their official GitHub releases (about 100 MB). Download them now?")
        return false unless confirm(question, default_yes: true)
        return update_component(force: true)
      end
      update_component(force: false) if update_check_due?
      true
    end

    # "Update YouTube component". force: true installs whatever is missing or
    # outdated and reports the result; force: false is the daily check, which
    # stays silent unless there is something new and asks before installing.
    def update_component(force: true)
      releases = EltenAPI::Tasks.run(title: p_("Klangten", "Checking for updates of the YouTube component..."), show_after: force ? 0.5 : 1.5) do |_progress, token|
        latest_releases(token: token)
      end
      mark_update_checked
      names = outdated(releases)
      if names.empty?
        alert(p_("Klangten", "The YouTube component is up to date.")) if force
        return true
      end
      if !force
        return true unless confirm(p_("Klangten", "A new version of the YouTube component is available. Install it now?"), default_yes: true)
      end
      EltenAPI::Tasks.run(title: p_("Klangten", "Downloading the YouTube component...")) do |progress, token|
        install(releases, names, token: token, progress: progress)
      end
      alert(p_("Klangten", "The YouTube component has been installed."))
      true
    rescue EltenAPI::Tasks::Cancelled
      installed?
    rescue StandardError => e
      Log.error("YouTube component update failed: #{e.class}: #{e.message}")
      if force || !installed?
        alert(p_("Klangten", "The YouTube component could not be downloaded. Check your internet connection and try again."))
      end
      installed?
    end

    private

    # --------------------------------------------------------------- yt-dlp

    # Runs yt-dlp and returns its Result. Lines of standard output are passed
    # to the block as they arrive. The process is terminated on cancellation.
    def ytdlp(args, token: nil, &on_line)
      path = ytdlp_path
      raise Missing, "yt-dlp is not installed" if path == nil || !File.file?(path)
      argv = [native_path(path), "--ignore-config", "--encoding", "utf-8", "--cache-dir", native_path(cache_dir)]
      argv += ["--js-runtimes", "deno:#{native_path(deno_path)}"] if File.file?(deno_path)
      language = youtube_language
      argv += ["--extractor-args", "youtube:lang=#{language}"] if language != nil
      run_process(argv + args.map(&:to_s), token, &on_line)
    end

    def ytdlp_json(args, token)
      result = ytdlp(args, token: token)
      text = result.output.to_s.dup.force_encoding(Encoding::UTF_8)
      start = text.index("{")
      raise Error, failure_message(result) if start == nil
      JSON.parse(text[start..-1])
    rescue JSON::ParserError
      raise Error, failure_message(result)
    end

    def run_process(argv, token, &on_line)
      FileUtils.mkdir_p(data_dir)
      # Windows starts a process from one command line (CreateProcessW), the
      # other systems take the argument vector as it is.
      command = windows? ? EltenSystemHelpers.command_line_join(argv) : argv
      Log.debug("YouTube: running yt-dlp #{argv[1..-1].reject { |arg| arg.start_with?("deno:") }.join(" ")}")
      process = EltenAPI::ChildProc.new(command, path: data_dir, cancellation_token: token)
      output = +"".b
      errors = +"".b
      pending = +"".b
      loop do
        token.raise_if_cancelled! if token != nil
        running = process.running?
        received = false
        while process.avail > 0
          chunk = process.read.to_s.b
          break if chunk.empty?
          received = true
          output << chunk
          pending << chunk
          if on_line != nil
            while (index = pending.index("\n"))
              line = pending.slice!(0, index + 1).force_encoding(Encoding::UTF_8).scrub.strip
              on_line.call(line) if line != ""
            end
          end
        end
        while process.avail_err > 0
          chunk = process.read_err.to_s.b
          break if chunk.empty?
          received = true
          errors << chunk
        end
        break if !running && !received
        sleep(0.05) unless received
      end
      status = process.respond_to?(:exitstatus) ? process.exitstatus : nil
      Result.new(status: status, output: output, errors: errors.force_encoding(Encoding::UTF_8).scrub)
    ensure
      if process != nil
        begin
          process.terminate if process.running?
        rescue Exception
        end
        process.close rescue nil
      end
    end

    # yt-dlp's own error line, for the log and the exception message.
    def failure_message(result)
      return "yt-dlp failed" if result == nil
      lines = result.errors.to_s.lines.map(&:strip).reject(&:empty?)
      error = lines.reverse.find { |line| line.start_with?("ERROR:") } || lines.last
      Log.warning("YouTube: yt-dlp failed (#{result.status.inspect}): #{lines.last(5).join(" | ")}")
      error.to_s == "" ? "yt-dlp failed" : error
    end

    def youtube_language
      code = Configuration.language.to_s.tr("_", "-")
      return nil if code == ""
      return code if YOUTUBE_LANGUAGES.include?(code)
      base = code.split("-").first.to_s.downcase
      base = "iw" if base == "he"
      YOUTUBE_LANGUAGES.include?(base) ? base : nil
    rescue StandardError
      nil
    end

    def native_path(path)
      windows? ? path.to_s.tr("/", "\\") : path.to_s
    end

    # One page of a search, channel or playlist through --flat-playlist.
    def list_page(url, page, token)
      first = page.to_i * PAGE_SIZE + 1
      data = ytdlp_json(["--flat-playlist", "-J", "-I", "#{first}:#{first + PAGE_SIZE - 1}", url], token)
      entries = data["entries"].to_a
      owner = data["channel"] || data["uploader"]
      owner_url = data["channel_url"] || data["uploader_url"]
      items = entries.map { |entry| item_from_entry(entry, owner, owner_url) }.compact
      Page.new(items: items, more: entries.size >= PAGE_SIZE)
    end

    def item_from_entry(entry, owner = nil, owner_url = nil)
      return nil unless entry.is_a?(Hash)
      url = entry["url"].to_s
      id = entry["id"].to_s
      return nil if id == ""
      kind = if entry["ie_key"].to_s == "Youtube" || url.include?("/watch") || url.include?("/shorts/")
        :video
      elsif url.include?("list=") || id.match?(/\A(?:PL|OL|UU|FL|LL|RD)[A-Za-z0-9_-]+\z/)
        :playlist
      else
        :channel
      end
      title = entry["title"].to_s
      title = entry["channel"].to_s if title == "" && kind == :channel
      return nil if title == ""
      Item.new(
        kind: kind, id: id,
        url: kind == :video ? video_url(id) : (url != "" ? url : nil),
        title: title,
        author: kind == :channel ? nil : (entry["channel"] || entry["uploader"] || owner).to_s,
        channel_url: (entry["channel_url"] || entry["uploader_url"] || (kind == :video ? owner_url : nil)).to_s,
        duration: entry["duration"] == nil ? nil : entry["duration"].to_f.round,
        views: entry["view_count"],
        subscribers: entry["channel_follower_count"],
        date: parse_date(entry["upload_date"], entry["timestamp"]),
        description: entry["description"].to_s,
        live: entry["live_status"].to_s == "is_live"
      )
    end

    def desktop_video(id, token)
      data = ytdlp_json(["-J", "--no-playlist", video_url(id)], token)
      streams = data["formats"].to_a.filter_map do |format|
        next nil unless format.is_a?(Hash) && format["vcodec"].to_s == "none"
        codec = format["acodec"].to_s
        next nil if codec == "" || codec == "none"
        next nil unless %w[https http].include?(format["protocol"].to_s) && format["url"].to_s != ""
        # The "-drc" variants repeat each stream with compressed dynamics.
        next nil if format["format_id"].to_s.end_with?("-drc")
        Stream.new(url: format["url"].to_s, codec: codec_name(codec), container: format["ext"].to_s,
                   bitrate: (format["abr"] || format["tbr"]).to_f.round, format_id: format["format_id"].to_s)
      end
      Video.new(
        id: data["id"].to_s == "" ? id : data["id"].to_s,
        url: data["webpage_url"].to_s == "" ? video_url(id) : data["webpage_url"].to_s,
        title: data["title"].to_s, author: (data["channel"] || data["uploader"]).to_s,
        channel_url: (data["channel_url"] || data["uploader_url"]).to_s,
        duration: data["duration"] == nil ? nil : data["duration"].to_f.round,
        views: data["view_count"], likes: data["like_count"],
        date: parse_date(data["upload_date"], data["timestamp"]),
        description: data["description"].to_s, live: data["is_live"] == true, streams: streams
      )
    end

    def codec_name(codec)
      case codec.downcase
      when /\Aopus/ then "Opus"
      when /\Amp4a/ then "AAC"
      when /\Avorbis/ then "Vorbis"
      when /\Aac-?3|\Aec-?3/ then "Dolby"
      else codec
      end
    end

    def parse_date(upload_date, timestamp)
      return Time.at(timestamp.to_i) if timestamp.to_i > 0
      value = upload_date.to_s
      return nil unless value.match?(/\A\d{8}\z/)
      Time.new(value[0, 4].to_i, value[4, 2].to_i, value[6, 2].to_i)
    rescue StandardError
      nil
    end

    # ------------------------------------------------------- Android (host)

    def host_call
      raise Missing, "YouTube is not available" unless android_host?
      yield
    end

    def host_page(rows)
      if rows.is_a?(Hash) && rows["error"] != nil
        raise Error, rows["error"].to_s
      end
      items = rows.to_a.filter_map do |row|
        next nil unless row.is_a?(Hash)
        kind = row["type"].to_s
        kind = "video" unless %w[channel playlist].include?(kind)
        next nil if row["title"].to_s == "" || row["id"].to_s == ""
        Item.new(
          kind: kind.to_sym, id: row["id"].to_s, url: row["url"].to_s, title: row["title"].to_s,
          author: row["author"].to_s, channel_url: row["channel"].to_s,
          duration: row["duration"].to_i > 0 ? row["duration"].to_i : nil,
          views: row["views"].to_i > 0 ? row["views"].to_i : nil,
          date: nil, description: "", live: false
        )
      end
      Page.new(items: items, more: false)
    end

    def host_video(id)
      data = host_call { KlangtenYouTubeHost.video(id) }
      raise Error, "YouTube did not return the video #{id}" unless data.is_a?(Hash)
      streams = data["streams"].to_a.filter_map do |row|
        next nil unless row.is_a?(Hash) && row["url"].to_s != ""
        Stream.new(url: row["url"].to_s, codec: codec_name(row["codec"].to_s), container: row["container"].to_s,
                   bitrate: (row["bitrate"].to_f / 1000.0).round, format_id: row["id"].to_s)
      end
      Video.new(
        id: data["id"].to_s == "" ? id : data["id"].to_s, url: data["url"].to_s == "" ? video_url(id) : data["url"].to_s,
        title: data["title"].to_s, author: data["author"].to_s, channel_url: data["channel"].to_s,
        duration: data["duration"].to_i > 0 ? data["duration"].to_i : nil,
        views: data["views"].to_i > 0 ? data["views"].to_i : nil,
        likes: data["likes"].to_i > 0 ? data["likes"].to_i : nil,
        date: nil, description: data["description"].to_s, live: false, streams: streams
      )
    end

    # ------------------------------------------------------- GitHub releases

    def latest_release(repo, token)
      body = http_get("https://api.github.com/repos/#{repo}/releases/latest", Klangten::GitHub.api_headers, token)
      data = JSON.parse(body)
      raise Error, "Unexpected release data from #{repo}" unless data.is_a?(Hash) && data["tag_name"].to_s != ""
      assets = {}
      data["assets"].to_a.each do |row|
        next unless row.is_a?(Hash)
        url = row["browser_download_url"].to_s
        assets[row["name"].to_s] = url if Klangten::GitHub.trusted_url?(url)
      end
      Release.new(tag: data["tag_name"].to_s, assets: assets)
    end

    def install_ytdlp(release, token, report)
      archive_name, executable = YTDLP_BUILDS[target]
      url = release.assets[archive_name]
      sums = release.assets[YTDLP_CHECKSUMS]
      raise Error, "yt-dlp #{release.tag} has no #{archive_name}" if url == nil
      raise Error, "yt-dlp #{release.tag} publishes no checksums" if sums == nil
      expected = checksum_for(http_get(sums, Klangten::GitHub.download_headers, token), archive_name)
      raise Error, "No checksum for #{archive_name}" if expected == nil
      archive = download_verified(url, archive_name, expected, token, report)
      destination = File.join(bin_dir, "yt-dlp")
      staging = destination + ".new"
      FileUtils.rm_rf(staging)
      extract_zip(archive, staging, token)
      raise Error, "#{archive_name} does not contain #{executable}" unless File.file?(File.join(staging, executable))
      replace_path(staging, destination)
      store_state("yt-dlp" => release.tag)
    ensure
      File.delete(archive) if archive != nil && File.file?(archive) rescue nil
      FileUtils.rm_rf(staging) if staging != nil && File.exist?(staging) rescue nil
    end

    def install_deno(release, token, report)
      archive_name = DENO_BUILDS[target]
      url = release.assets[archive_name]
      raise Error, "Deno #{release.tag} has no #{archive_name}" if url == nil
      sums = release.assets[archive_name + ".sha256sum"]
      expected = sums == nil ? nil : checksum_for(http_get(sums, Klangten::GitHub.download_headers, token), archive_name)
      raise Error, "Unreadable checksum for #{archive_name}" if sums != nil && expected == nil
      Log.warning("YouTube: Deno #{release.tag} publishes no checksum for #{archive_name}") if sums == nil
      archive = download_verified(url, archive_name, expected, token, report)
      staging = File.join(bin_dir, "deno.new")
      FileUtils.rm_rf(staging)
      extract_zip(archive, staging, token, only: [File.basename(deno_path)])
      binary = File.join(staging, File.basename(deno_path))
      raise Error, "#{archive_name} does not contain #{File.basename(deno_path)}" unless File.file?(binary)
      File.chmod(0o755, binary) unless windows?
      replace_path(binary, deno_path)
      store_state("deno" => release.tag)
    ensure
      File.delete(archive) if archive != nil && File.file?(archive) rescue nil
      FileUtils.rm_rf(staging) if staging != nil && File.exist?(staging) rescue nil
    end

    # Downloads into the temporary folder and checks size > 0 and SHA-256
    # (when expected is given).
    def download_verified(url, name, expected, token, report)
      raise Error, "Untrusted download address #{url}" unless Klangten::GitHub.trusted_url?(url)
      FileUtils.mkdir_p(temp_dir)
      archive = File.join(temp_dir, name)
      File.delete(archive) if File.file?(archive)
      http_download(url, archive, token) { |percent| report.call(percent) }
      raise Error, "Empty download #{name}" unless File.file?(archive) && File.size(archive) > 0
      if expected != nil && Digest::SHA256.file(archive).hexdigest != expected
        File.delete(archive) rescue nil
        raise Error, "Checksum mismatch for #{name}"
      end
      report.call(100)
      archive
    end

    # sha256sum lines ("<digest>  <file>"); otherwise a file holding exactly one
    # digest anywhere, as Deno's Windows checksums (Get-FileHash output) do.
    def checksum_for(body, filename)
      digest = Klangten::GitHub.parse_checksum(body, filename)
      return digest if digest != nil
      found = body.to_s.scan(/\b[0-9a-fA-F]{64}\b/).map(&:downcase).uniq
      found.size == 1 ? found.first : nil
    end

    def extract_zip(archive, directory, token, only: nil)
      require "zip"
      root = File.expand_path(directory)
      FileUtils.mkdir_p(root)
      Zip::File.open(archive) do |zip|
        zip.each do |entry|
          token.raise_if_cancelled! if token != nil
          name = only == nil ? entry.name : File.basename(entry.name)
          next if only != nil && (!entry.file? || !only.include?(name))
          target = File.expand_path(name, root)
          next unless target.start_with?(root + "/") || target.start_with?(root + File::SEPARATOR)
          if entry.directory?
            FileUtils.mkdir_p(target)
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(target))
            entry.get_input_stream do |input|
              File.open(target, "wb") do |file|
                while (chunk = input.read(65_536)) && !chunk.empty?
                  file.write(chunk)
                end
              end
            end
            File.chmod(0o755, target) if !windows? && (entry.unix_perms.to_i & 0o111) != 0
          end
        end
      end
      # Files written by an application may carry the quarantine flag on
      # macOS, which would stop the unsigned helpers from starting.
      system("/usr/bin/xattr", "-dr", "com.apple.quarantine", root, out: File::NULL, err: File::NULL) if platform_os == "osx"
    end

    # Moves source to destination, replacing what was there.
    def replace_path(source, destination)
      old = destination + ".old"
      FileUtils.rm_rf(old)
      File.rename(destination, old) if File.exist?(destination)
      File.rename(source, destination)
      FileUtils.rm_rf(old) rescue nil
    end

    # ------------------------------------------------------------------ HTTP

    def http_get(url, headers, token)
      outcome = Queue.new
      worker = EltenAPI::HTTPClient.readurl(url, "get", nil, headers, nil, cancellation_token: token) do |body, _data, _headers|
        outcome << body
      end
      body = wait_for(outcome, worker, token)
      raise Error, "Request failed: #{url}" if body == nil || body == :error
      body.to_s.dup.force_encoding(Encoding::UTF_8)
    end

    def http_download(url, destination, token, &progress)
      outcome = Queue.new
      worker = EltenAPI::HTTPClient.downloadfile(url, destination, nil, cancellation_token: token) do |response, _data|
        if response.is_a?(EltenAPI::ERDownloadProgress)
          progress.call(response.percent) if progress != nil
        else
          outcome << response
        end
      end
      result = wait_for(outcome, worker, token)
      raise Error, "Download failed: #{url}" unless result.is_a?(Integer)
      result
    end

    # The HTTP client answers through a callback on its own thread; a failed
    # status ends that thread without one, so the thread is watched as well.
    def wait_for(outcome, worker, token)
      loop do
        begin
          return outcome.pop(true)
        rescue ThreadError
          token.raise_if_cancelled! if token != nil
          return nil if worker.respond_to?(:alive?) && !worker.alive? && outcome.empty?
          sleep(0.05)
        end
      end
    end

    # ----------------------------------------------------------------- files

    def read_json(name, default)
      path = File.join(data_dir, name)
      return default unless File.file?(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      data.is_a?(default.class) ? data : default
    rescue StandardError => e
      Log.warning("YouTube: cannot read #{name}: #{e.class}: #{e.message}")
      default
    end

    def write_json(name, data)
      FileUtils.mkdir_p(data_dir)
      path = File.join(data_dir, name)
      temporary = path + ".tmp"
      File.write(temporary, JSON.pretty_generate(data), encoding: "UTF-8")
      File.delete(path) if windows? && File.exist?(path)
      File.rename(temporary, path)
    rescue StandardError => e
      Log.error("YouTube: cannot write #{name}: #{e.class}: #{e.message}")
    end

    def store_state(values)
      @state_mutex ||= Mutex.new
      @state_mutex.synchronize do
        state = read_json("components.json", {})
        write_json("components.json", state.merge(values))
      end
    end

    def row_key(row)
      row.is_a?(Hash) ? "#{row["kind"].to_s == "" ? "video" : row["kind"]}:#{row["id"]}" : ""
    end

    def query_params(query)
      URI.decode_www_form(query.to_s).to_h
    rescue ArgumentError
      {}
    end
  end

  # YouTube links in any Klangten text (blog posts and the like) become
  # playable media. Titles come from oEmbed and are cached for the session.
  class Finder < MediaFinder
    @titles = {}

    class << self
      def possible_media?(text)
        KlangtenYouTube.available? && text.to_s.match?(KlangtenYouTube::URL_PATTERN) && KlangtenYouTube.find_urls(text, limit: 1).size > 0
      rescue StandardError
        false
      end

      def get_media(text)
        return [] unless KlangtenYouTube.available?
        found = KlangtenYouTube.find_urls(text)
        return [] if found.empty?
        missing = found.reject { |entry| @titles.key?(entry[2]) }
        if missing.size > 0
          begin
            EltenAPI::Tasks.run(title: p_("Klangten", "Looking up YouTube links...")) do |_progress, token|
              missing.each do |entry|
                token.raise_if_cancelled!
                info = entry[0] == :channel ? nil : KlangtenYouTube.oembed(entry[1] == entry[2] || entry[0] == :playlist ? entry[1] : KlangtenYouTube.video_url(entry[1]), token: token)
                @titles[entry[2]] = info
              end
            end
          rescue EltenAPI::Tasks::Cancelled
          end
        end
        found.map { |kind, value, original| Extractor.new(kind, value, original, @titles[original]) }
      end
    end
  end

  class Extractor < MediaExtractor
    def initialize(kind, value, original, info)
      @kind = kind
      @value = value
      @original = original
      @info = info
    end

    def title
      name = @info == nil ? @original : @info[:title]
      case @kind
      when :channel then p_("Klangten", "YouTube channel: %{name}") % { name: name }
      when :playlist then p_("Klangten", "YouTube playlist: %{name}") % { name: name }
      else p_("Klangten", "YouTube: %{name}") % { name: name }
      end
    end

    def proceed
      url = @kind == :video ? KlangtenYouTube.video_url(@value) : @value
      Scene_YouTube.open_url(url)
    end
  end
end

MediaFinders.register(KlangtenYouTube::Finder) if defined?(MediaFinders)
