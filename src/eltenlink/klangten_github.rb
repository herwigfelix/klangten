# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The rolling release update channel.
#
# Klangten knows two sources of updates:
#
#   stable / rc / beta   the Klango server (/api/v1/system/build-id, /updates,
#                        /installer), see src/eltenlink/system.rb
#   rolling              the GitHub releases of the public Klangten repository
#
# The rolling channel exists because the fork is built publicly: every tagged
# build produced by .github/workflows is available there before it is published
# on the Klango server. It is meant for testers, not for the general public.
#
# A release carries, besides the installers themselves, one checksum file per
# installer ("<installer>.sha256", the output format of sha256sum/shasum) and a
# file "build-id.txt" holding the build id that was compiled into those
# installers. The build id is what decides whether an update is offered - the
# same rule the server based channels use - so both sources stay comparable and
# a downgrade from rolling back to stable is a normal update again.
#
# This module deliberately performs no I/O: it only builds URLs, parses
# responses and decides what may be downloaded. The HTTP calls belong to the
# caller (src/eapi/network.rb, src/scenes/loading.rb), which owns the event loop
# and the cancellation handling.

require "json"
require "uri"

unless defined?(::Klangten::GitHub)
module Klangten
  module GitHub
    # The public repository of the fork. The updater never follows a URL that
    # does not belong to it.
    REPO = "herwigfelix/klangten".freeze
    RELEASES_API = "https://api.github.com/repos/#{REPO}/releases/latest".freeze
    RELEASES_PAGE = "https://github.com/#{REPO}/releases".freeze

    # Assets every release built by the workflows contains.
    BUILD_ID_ASSET = "build-id.txt".freeze
    CHECKSUM_SUFFIX = ".sha256".freeze

    # GitHub answers a download with a redirect to its asset storage, so the
    # hosts below are all part of one download. Everything else is refused, the
    # same way Klangten::Updates.trusted_url? refuses hosts outside the
    # configured Klango server.
    DOWNLOAD_HOSTS = %w[
      github.com
      api.github.com
      codeload.github.com
      objects.githubusercontent.com
      release-assets.githubusercontent.com
    ].freeze
    DOWNLOAD_HOST_SUFFIX = ".githubusercontent.com".freeze

    # Value of the branch setting that selects this channel. It is never sent to
    # the Klango server; get_updatesbranch maps it away (src/eapi/core/cache.rb).
    BRANCH = "rolling".freeze

    Asset = Struct.new(:name, :size, :url, keyword_init: true) do
      def valid?
        name.to_s != "" && size.to_i > 0 && url.to_s != ""
      end
    end

    Release = Struct.new(:tag, :version_string, :assets, keyword_init: true) do
      def asset(name)
        assets.to_a.find { |a| a.name.to_s.downcase == name.to_s.downcase }
      end
    end

    class << self
      # True when the user selected the rolling channel.
      def selected?(branch)
        branch.to_s == BRANCH
      end

      def user_agent
        "Klangten/#{Config::VERSION} (+#{RELEASES_PAGE})"
      end

      # GitHub serves the REST API only with an explicit accept header; the
      # version pin keeps the response shape stable.
      def api_headers
        {
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => "2022-11-28",
          "User-Agent" => user_agent
        }
      end

      def download_headers
        { "User-Agent" => user_agent }
      end

      # Only https and only GitHub's own hosts.
      def trusted_url?(url)
        uri = URI.parse(url.to_s)
        return false unless uri.is_a?(URI::HTTPS)
        host = uri.host.to_s.downcase
        return true if DOWNLOAD_HOSTS.include?(host)
        host.end_with?(DOWNLOAD_HOST_SUFFIX)
      rescue URI::InvalidURIError
        false
      end

      # Parses the answer of /releases/latest. Drafts are never published by the
      # workflows; a prerelease is accepted, because the rolling channel is where
      # test builds belong.
      def parse_release(body)
        data = JSON.parse(body.to_s)
        return nil unless data.is_a?(Hash)
        return nil if data["draft"] == true
        assets = data["assets"].to_a.map do |row|
          next nil unless row.is_a?(Hash)
          url = row["browser_download_url"].to_s
          next nil unless trusted_url?(url)
          Asset.new(name: row["name"].to_s, size: row["size"].to_i, url: url)
        end.compact
        return nil if assets.empty?
        tag = data["tag_name"].to_s
        Release.new(tag: tag, version_string: version_string(data), assets: assets)
      rescue JSON::ParserError
        nil
      end

      # "v0.1.1" and "Klangten 0.1.1" both become "0.1.1"; the release name wins
      # when it carries more than the bare tag.
      def version_string(data)
        name = data["name"].to_s.strip
        tag = data["tag_name"].to_s.strip
        value = name != "" ? name : tag
        value = value.sub(/\A[Kk]langten\s+/, "")
        value.sub(/\Av(?=\d)/, "")
      end

      # The installer of this platform, e.g. "KlangtenSetup.exe".
      def installer_asset(release, platform)
        return nil if release == nil
        asset = release.asset(Updates.installer_filename(platform))
        asset != nil && asset.valid? ? asset : nil
      end

      def checksum_asset(release, installer_asset)
        return nil if release == nil || installer_asset == nil
        release.asset(installer_asset.name.to_s + CHECKSUM_SUFFIX)
      end

      def build_id_asset(release)
        release == nil ? nil : release.asset(BUILD_ID_ASSET)
      end

      # Content of a "<sha256>  <file>" line, as written by sha256sum, shasum -a
      # 256 and CertUtil post-processing in the workflows. A file holding nothing
      # but the digest is accepted too.
      def parse_checksum(body, filename = nil)
        text = body.to_s
        text.each_line do |line|
          parts = line.strip.split(/\s+/, 2)
          digest = parts[0].to_s.downcase
          next unless digest.match?(/\A[0-9a-f]{64}\z/)
          name = parts[1].to_s.strip.sub(/\A\*/, "")
          return digest if filename.to_s == "" || name == "" || File.basename(name) == File.basename(filename.to_s)
        end
        nil
      end

      # The build id compiled into the installers of this release.
      def parse_build_id(body)
        value = body.to_s.strip.lines.first.to_s.strip
        return nil if value == "" || value == "0"
        return nil unless value.match?(/\A[A-Za-z0-9._+-]{1,64}\z/)
        value
      end

      # Same rule as the server channels: a build id that merely differs is an
      # update, so that a rollback is possible as well.
      def update?(current_build_id, release_build_id)
        current = current_build_id.to_s
        offered = release_build_id.to_s
        current != "" && offered != "" && current != offered
      end
    end
  end
end
end
