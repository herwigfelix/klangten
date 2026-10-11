# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The message of the day (GET /api/v1/startup-info). Klangten reads it once
# after every login; an empty list means there is nothing to say.

module EltenLink
  StartupMessage = Struct.new(:id, :type, :text, keyword_init: true)

  module StartupInfo
    class << self
      def messages(client)
        data = client.api_data("GET", "/api/v1/startup-info")
        data["messages"].to_a.select { |row| row.is_a?(Hash) && row["text"].to_s.strip != "" }.map do |row|
          StartupMessage.new(id: row["id"].to_s, type: row["type"].to_s, text: row["text"].to_s)
        end
      end
    end
  end
end
