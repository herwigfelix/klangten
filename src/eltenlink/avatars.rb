# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Audio avatars (short voice recordings shared with Klango) through the
# Klangten API extension /api/v1/users/{user}/avatar.
#
# GET .../avatar/info returns a signed stream URL, so the player can fetch the
# audio without session credentials in the URL.

module EltenLink
  class AudioAvatarInfo
    attr_accessor :user, :exists, :url, :updated, :size, :content_type, :expires

    def exists?
      exists == true
    end
  end

  module Avatars
    MAX_BYTES = 10 * 1024 * 1024

    class << self
      def info(client, user)
        data = client.api_data("GET", "/api/v1/users/#{user.to_s.urlenc}/avatar/info")
        build_info(data)
      end

      # Uploads raw audio data (Opus, Ogg Vorbis, MP3, WAV, FLAC ...) as the
      # audio avatar of the signed-in user.
      def upload(client, data)
        result = client.api_binary_data(
          "PUT",
          "/api/v1/users/me/avatar",
          data,
          { "Content-Type" => "application/octet-stream" },
          nil,
          timeout: 120
        )
        build_info(result)
      end

      def delete(client)
        build_info(client.api_data("DELETE", "/api/v1/users/me/avatar"))
      end

      private

      def build_info(data)
        data = {} unless data.is_a?(Hash)
        info = AudioAvatarInfo.new
        info.user = data["user"].to_s
        info.exists = data["exists"] == true
        url = data["url"].to_s
        url = data["path"].to_s if url == ""
        info.url = url == "" ? "" : Client.absolute_api_url(url)
        info.updated = data["updated"].to_i
        info.size = data["size"].to_i
        info.content_type = data["content_type"].to_s
        info.expires = data["expires"].to_i
        info
      end
    end
  end
end
