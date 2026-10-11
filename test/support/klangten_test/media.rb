# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Looking inside audio files without playing them.
#
#   info = KlangtenTest::Media.ogg_opus(bytes)
#   info.channels, info.preskip, info.seconds, info.kbps
#   info.modes        # {celt: 92, hybrid: 0, silk: 0} - packets per Opus mode
#   info.frame_ms     # [40.0, ...] duration of each packet
#
#   KlangtenTest::Media.wav(seconds: 2, hz: 440)   # a WAV file as bytes
#
# The Opus mode comes from each packet's TOC byte (RFC 6716, 3.1): configs
# 0-11 are SILK (speech), 12-15 hybrid, 16-31 CELT (music). Opus does not
# store the encoder's "application" in the file; at 64 kbit/s an encoder in
# audio mode (OPUS_APPLICATION_AUDIO = 2049) produces CELT packets, one in
# VoIP mode (2048) mostly SILK/hybrid - that difference is what tests check.

module KlangtenTest
  module Media
    OggOpusInfo = Struct.new(:channels, :preskip, :input_rate, :packets, :granule, :tags, keyword_init: true) do
      def audio_packets
        packets
      end

      def seconds
        [(granule - preskip), 0].max / 48_000.0
      end

      def bytes
        packets.sum(&:bytesize)
      end

      # Average bitrate of the audio packets.
      def kbps
        return 0.0 if seconds <= 0
        bytes * 8 / seconds / 1000.0
      end

      def configs
        packets.map { |p| p.getbyte(0) >> 3 }
      end

      def modes
        counts = { silk: 0, hybrid: 0, celt: 0 }
        configs.each do |c|
          counts[c < 12 ? :silk : (c < 16 ? :hybrid : :celt)] += 1
        end
        counts
      end

      def stereo_packets
        packets.count { |p| (p.getbyte(0) & 0x04) != 0 }
      end

      def frame_ms
        packets.map { |p| Media.opus_packet_ms(p) }
      end
    end

    module_function

    def ogg_packets(data)
      data = data.to_s.b
      pos = 0
      packets = []
      current = +"".b
      granule = 0
      while pos < data.bytesize
        raise ArgumentError, "not an Ogg page at #{pos}" unless data.byteslice(pos, 4) == "OggS"
        granule_pos = data.byteslice(pos + 6, 8).unpack1("q<")
        granule = granule_pos if granule_pos >= 0
        count = data.getbyte(pos + 26)
        lacing = data.byteslice(pos + 27, count).bytes
        body = pos + 27 + count
        lacing.each do |len|
          current << data.byteslice(body, len)
          body += len
          if len < 255
            packets << current
            current = +"".b
          end
        end
        pos = body
      end
      [packets, granule]
    end

    def ogg_opus(data)
      packets, granule = ogg_packets(data)
      head = packets.shift
      raise ArgumentError, "no OpusHead" unless head && head.start_with?("OpusHead")
      tags = packets.shift
      OggOpusInfo.new(
        channels: head.getbyte(9),
        preskip: head.byteslice(10, 2).unpack1("v"),
        input_rate: head.byteslice(12, 4).unpack1("V"),
        packets: packets,
        granule: granule,
        tags: tags
      )
    end

    # Duration of one Opus packet in milliseconds (TOC + frame count).
    def opus_packet_ms(packet)
      toc = packet.getbyte(0)
      config = toc >> 3
      frame = if config < 12
                [10, 20, 40, 60][config % 4]
              elsif config < 16
                [10, 20][config % 2]
              else
                [2.5, 5, 10, 20][config % 4]
              end
      frames = case toc & 0x03
               when 0 then 1
               when 1, 2 then 2
               else (packet.getbyte(1).to_i & 0x3f)
               end
      frame * frames
    end

    # 16-bit PCM WAV with a sine tone.
    def wav(seconds: 1.0, hz: 440, rate: 48_000, channels: 1)
      count = (seconds * rate).round
      samples = Array.new(count) { |i| (Math.sin(2 * Math::PI * hz * i / rate) * 12_000).round }
      samples = samples.flat_map { |s| [s] * channels }
      pcm = samples.pack("s<*")
      ["RIFF", 36 + pcm.bytesize, "WAVE", "fmt ", 16, 1, channels, rate, rate * channels * 2, channels * 2, 16, "data", pcm.bytesize].pack("a4Va4a4VvvVVvva4V") + pcm
    end
  end
end
