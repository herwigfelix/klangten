# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Translation through the Klango server (POST /api/v1/translate).
#
# The server translates with the same service Klango uses and needs only the
# Klangten session. One request takes at most MAX_CHUNK characters, so longer
# texts are split at paragraph, line or sentence boundaries and translated
# piece by piece.

module EltenLink
  TranslationResult = Struct.new(:text, :from, :to, keyword_init: true)

  module Translation
    # The server accepts 8000 characters after HTML escaping; this leaves room
    # for escaped characters and line break marks.
    MAX_CHUNK = 3500
    TIMEOUT = 60

    class << self
      # from: language code, or nil/"auto"/0 to detect it. Raises EltenLink::Error.
      def translate(client, text, to:, from: nil, cancellation_token: nil)
        text = text.to_s.gsub("\r\n", "\n")
        source = from.to_s
        source = "" if source == "0" || source.downcase == "auto"
        detected = source
        pieces = split(text).map do |piece|
          core = piece.strip
          if core == ""
            piece
          else
            # The surrounding white space (paragraph breaks between pieces)
            # is kept locally; the server trims it.
            lead = piece[0, piece.index(core[0]).to_i]
            tail = piece[(lead.size + core.size)..-1].to_s
            params = { "text" => core, "to" => to.to_s }
            params["from"] = source if source != ""
            data = client.api_data("POST", "/api/v1/translate", params, timeout: TIMEOUT, cancellation_token: cancellation_token)
            detected = data["from"].to_s if detected == ""
            lead + data["text"].to_s + tail
          end
        end
        TranslationResult.new(text: pieces.join, from: detected, to: to.to_s)
      end

      # Splits a text into pieces of at most `limit` characters. Joining the
      # pieces gives the text back: separators stay at the end of a piece.
      def split(text, limit = MAX_CHUNK)
        text = text.to_s
        return [text] if text.size <= limit
        pieces = []
        rest = text
        while rest.size > limit
          window = rest[0, limit]
          cut = nil
          [/\n\s*\n/, /\n/, /[.!?]\s/, /\s/].each do |pattern|
            index = last_match_end(window, pattern)
            if index != nil && index > limit / 4
              cut = index
              break
            end
          end
          cut ||= limit
          pieces << rest[0, cut]
          rest = rest[cut..-1]
        end
        pieces << rest if rest != ""
        pieces
      end

      private

      def last_match_end(text, pattern)
        position = nil
        text.scan(pattern) { position = Regexp.last_match.end(0) }
        position
      end
    end
  end
end
