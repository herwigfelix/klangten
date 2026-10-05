# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Native MP3 encoding through BASSenc_MP3, which ships with Klangten on every
# platform (bin/<target>, the iOS frameworks and the Android jniLibs).
#
# The encoder sits on a decoding "dummy" stream (STREAMPROC_DUMMY): such a
# stream has no data of its own, so the PCM is handed to the encoder directly
# with BASS_Encode_Write. BASSenc_MP3 writes the result into a temporary file,
# which is copied into the RecorderOutput when the session finishes. Going
# through a file instead of an ENCODEPROC callback keeps native callbacks out of
# the picture (iOS does not allow writable code for libffi closures, and the
# callback would arrive on whatever thread BASS chooses).

module KlangtenMp3
  BASS_UNICODE = 0x80000000
  BASS_STREAM_DECODE = 0x200000
  STREAMPROC_DUMMY = 0
  DEFAULT_BITRATE = 128
  BITRATES = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320].freeze
  # MPEG-1/2/2.5 sample rates LAME accepts without resampling.
  SAMPLE_RATES = [44_100, 48_000, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000].freeze
  WRITE_CHUNK = 1_048_576
  TAG_OPTIONS = { "TITLE" => "--tt", "ARTIST" => "--ta", "ALBUM" => "--tl", "TRACKNUMBER" => "--tn", "DATE" => "--ty", "COMMENT" => "--tc" }.freeze

  class << self
    def available?
      return @available if @available != nil
      @available = load_functions
    rescue Exception
      @available = false
    end

    def start_file
      @start_file
    end

    # The nearest bitrate LAME supports in constant bitrate mode.
    def normalize_bitrate(bitrate)
      value = bitrate.to_i
      value = DEFAULT_BITRATE if value <= 0
      BITRATES.min_by { |item| [(item - value).abs, -item] }
    end

    def options(bitrate, tags)
      parts = ["-b", normalize_bitrate(bitrate).to_s]
      tagged = false
      (tags || {}).each do |key, value|
        option = TAG_OPTIONS[key.to_s.upcase]
        text = value.to_s
        next if option == nil || text.strip == ""
        parts << option << quote(text)
        tagged = true
      end
      # Unicode tags only fit into an ID3v2 block; ask for one whenever tags exist.
      parts << "--add-id3v2" if tagged
      parts.join(" ")
    end

    def temporary_file
      base = (defined?(Dirs) && Dirs.respond_to?(:temp) && Dirs.temp.to_s != "") ? Dirs.temp.to_s : Dir.tmpdir
      Dir.mkdir(base) if !File.directory?(base)
      File.join(base, "klangten-mp3-#{$$}-#{Thread.current.object_id}-#{rand(36**8).to_s(36)}.mp3")
    end

    private

    def load_functions
      return false if !defined?(Bass) || Bass::BASSENC == nil || Bass::BASSENCMP3 == nil
      @start_file = Fiddle::Function.new(Bass::BASSENCMP3["BASS_Encode_MP3_StartFile"], [Bass::F_UINT, Bass::F_PTR, Bass::F_UINT, Bass::F_PTR], Bass::F_UINT, Bass::BASS_ABI)
      Bass::BASS_Encode_Write.is_a?(Fiddle::Function) && Bass::BASS_Encode_Stop.is_a?(Fiddle::Function)
    end

    def quote(text)
      value = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).delete("\0\r\n")
      "\"" + value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"") + "\""
    end
  end
end

# AudioEncoder session: process_pcm takes 16-bit little-endian PCM in the format
# given to start, finish writes the MP3 file into the output.
class Mp3AudioEncoder < AudioEncoder
  def initialize(bitrate = KlangtenMp3::DEFAULT_BITRATE, tags: nil)
    @bitrate = KlangtenMp3.normalize_bitrate(bitrate)
    @tags = tags
  end

  def start(output, frequency: 44_100, channels: 2, source_channel: nil)
    super(output, :frequency => frequency, :channels => [[channels.to_i, 1].max, 2].min, :source_channel => source_channel)
    raise RuntimeError, "MP3 encoder (bassenc_mp3) is not available" if !KlangtenMp3.available?
    @sample_bytes = @channels * 2
    @queue = "".b
    @finished = false
    tags = @tags
    tags = EltenRecorderRuntime.source_tags(source_channel) if tags == nil && source_channel != nil && source_channel != 0
    @temporary = KlangtenMp3.temporary_file
    @stream = Bass::BASS_StreamCreate.call(@frequency, @channels, KlangtenMp3::BASS_STREAM_DECODE, KlangtenMp3::STREAMPROC_DUMMY, nil)
    raise RuntimeError, "Cannot create MP3 source stream: BASS error #{Bass::BASS_ErrorGetCode.call}" if @stream == 0
    @encoder = KlangtenMp3.start_file.call(@stream, unicode(KlangtenMp3.options(@bitrate, tags)), KlangtenMp3::BASS_UNICODE, unicode(@temporary))
    raise RuntimeError, "Cannot start MP3 encoder: BASS error #{Bass::BASS_ErrorGetCode.call} (frequency=#{@frequency}, channels=#{@channels}, bitrate=#{@bitrate})" if @encoder == 0
    self
  rescue Exception
    close
    raise
  end

  def feed(data)
    return 0 if data == nil || data.bytesize <= 0 || @encoder.to_i == 0
    @queue << data.to_s.b
    bytes = @queue.bytesize / @sample_bytes * @sample_bytes
    return 0 if bytes <= 0
    chunk = @queue.byteslice(0, bytes)
    @queue = @queue.byteslice(bytes..-1) || "".b
    write_pcm(chunk)
    bytes
  end

  def finish
    return if @finished || @encoder.to_i == 0
    @finished = true
    Bass::BASS_Encode_Stop.call(@encoder)
    @encoder = 0
    free_stream
    copy_result
  ensure
    close
  end

  def close
    Bass::BASS_Encode_Stop.call(@encoder) if @encoder.to_i != 0
    @encoder = 0
    free_stream
    File.delete(@temporary) if @temporary != nil && File.exist?(@temporary)
    @temporary = nil
  rescue Exception
    nil
  end

  def normalize_source?
    true
  end

  def source_frequency
    44_100
  end

  def source_channels(channel)
    EltenRecorderRuntime.source_limited_channels(channel)
  end

  private

  def write_pcm(pcm)
    offset = 0
    while offset < pcm.bytesize
      chunk = pcm.byteslice(offset, KlangtenMp3::WRITE_CHUNK)
      if Bass::BASS_Encode_Write.call(@encoder, chunk, chunk.bytesize) == 0
        raise RuntimeError, "MP3 encoder rejected data: BASS error #{Bass::BASS_ErrorGetCode.call}"
      end
      offset += chunk.bytesize
    end
  end

  def free_stream
    Bass::BASS_StreamFree.call(@stream) if @stream.to_i != 0
    @stream = 0
  end

  def copy_result
    raise RuntimeError, "MP3 encoder produced no file" if @temporary == nil || !File.file?(@temporary)
    File.open(@temporary, "rb") do |file|
      while (chunk = file.read(KlangtenMp3::WRITE_CHUNK)) != nil
        @output.write(chunk)
      end
    end
  end
end

class Mp3Encoder < MediaEncoder
  Type = :audio
  Extension = ".mp3"
  Name = "MP3"
  IsBitrateSupported = true
  SupportsPcmStream = true

  class << self
    def identifier
      :mp3
    end

    def available?
      KlangtenMp3.available?
    end

    def output_descriptor
      @output_descriptor ||= {
        :codec => :mp3,
        :container => :mp3,
        :extensions => [Extension].freeze,
        :mime_type => "audio/mpeg"
      }.freeze
    end

    def input_constraints
      @input_constraints ||= Audio::FormatConstraint.new(:sample_types => [:s16le], :sample_rates => KlangtenMp3::SAMPLE_RATES, :channels => 1..2)
    end

    def encode_file(file, output, bitrate = nil)
      Recorder.encode_file(file, output, Mp3AudioEncoder.new(bitrate || KlangtenMp3::DEFAULT_BITRATE))
      true
    end

    def audio_encoder(bitrate = nil)
      Mp3AudioEncoder.new(bitrate || KlangtenMp3::DEFAULT_BITRATE)
    end
  end

  def initialize(bitrate: KlangtenMp3::DEFAULT_BITRATE, tags: nil)
    @bitrate = Integer(bitrate)
    @tags = tags
  end

  def start(output:, input_format:, metadata: {})
    tags = @tags == nil ? metadata : @tags
    Mp3AudioEncoder.new(@bitrate, :tags => tags).start(
      output,
      :frequency => input_format.sample_rate,
      :channels => input_format.channels
    )
  end
end
