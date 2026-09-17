# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# REST part of conferences: Klango issues short-lived TeamConference login
# tokens. Replaces Elten's /calls and /conference-resources endpoints, which
# the Klango server does not provide.

module EltenLink
  module Conference
    class << self
      # GET /api/v1/conference/token
      # => {"enabled"=>bool, "token"=>"...", "host"=>"...", "port"=>9500, "udp_port"=>9501, "ssl"=>bool}
      def token(client)
        data = client.api_data("GET", "/api/v1/conference/token")
        data.is_a?(Hash) ? data : {}
      end
    end
  end
end
