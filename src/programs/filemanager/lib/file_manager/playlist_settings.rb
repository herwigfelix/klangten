module FileManagerPlaylist
  class Settings
    DEFAULT_FILE = "settings.json".freeze
    DEFAULTS = {
      "show_on_main_window" => true,
      "show_in_main_menu" => true,
      "autoplay_first_item" => false
    }.freeze

    def initialize(reader:, writer:)
      @reader = reader
      @writer = writer
      @values = load_values
    end

    def [](key)
      @values.fetch(key.to_s, DEFAULTS.fetch(key.to_s))
    end

    def []=(key, value)
      name = key.to_s
      raise ArgumentError, "Unknown playlist setting: #{name}" if !DEFAULTS.key?(name)
      @values[name] = value == true
      @writer.call(DEFAULT_FILE, @values.dup)
      @values[name]
    end

    private

    def load_values
      data = @reader.call(DEFAULT_FILE, DEFAULTS.dup)
      data = {} if !data.is_a?(Hash)
      DEFAULTS.each_with_object({}) do |(key, default), values|
        values[key] = data.key?(key) ? data[key] == true : default
      end
    rescue Exception
      DEFAULTS.dup
    end
  end
end
