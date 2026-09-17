require_relative "playlist"

module FileManagerPlaylist
  class Store
    SCHEMA_VERSION = 1
    DEFAULT_FILE = "playlist.json"

    def initialize(reader:, writer:)
      @reader = reader
      @writer = writer
    end

    def current_playlist
      Playlist.from_h(normalized_state["playlist"]) || empty_playlist
    end

    def playback_settings
      playback = normalized_state["playback"]
      {
        "shuffle" => playback["shuffle"] == true,
        "index" => [playback["index"].to_i, 0].max,
        "volume" => normalize_volume(playback["volume"])
      }
    end

    def set_current(playlist, index: 0, shuffle: false, volume: 100)
      snapshot = internal_copy(playlist)
      update do |state|
        state["playlist"] = snapshot.to_h
        state["playback"] = {
          "shuffle" => shuffle == true,
          "index" => [index.to_i, 0].max,
          "volume" => normalize_volume(volume)
        }
      end
      snapshot
    end

    def update_current(playlist, index: nil, shuffle: nil, volume: nil)
      snapshot = internal_copy(playlist)
      update do |state|
        state["playlist"] = snapshot.to_h
        state["playback"]["index"] = [index.to_i, 0].max if index != nil
        state["playback"]["shuffle"] = shuffle == true if shuffle != nil
        state["playback"]["volume"] = normalize_volume(volume) if volume != nil
      end
      snapshot
    end

    private

    def empty_playlist
      Playlist.new(name: "Playlist")
    end

    def internal_copy(playlist)
      Playlist.new(
        id: playlist.id,
        name: playlist.name,
        entries: playlist.entries.map(&:to_h)
      )
    end

    def normalize_volume(value)
      value = 100 if value == nil
      [[value.to_i, 0].max, 100].min
    end

    def normalized_state
      normalize(@reader.call(DEFAULT_FILE, default_state))
    rescue Exception
      default_state
    end

    def update
      state = normalized_state
      yield(state)
      @writer.call(DEFAULT_FILE, state)
      state
    end

    def normalize(data)
      state = data.is_a?(Hash) ? data : {}
      playlist = Playlist.from_h(state["playlist"])
      playback = state["playback"].is_a?(Hash) ? state["playback"] : {}
      {
        "schema_version" => SCHEMA_VERSION,
        "playlist" => internal_copy(playlist || empty_playlist).to_h,
        "playback" => {
          "shuffle" => playback["shuffle"] == true,
          "index" => [playback["index"].to_i, 0].max,
          "volume" => normalize_volume(playback["volume"])
        }
      }
    end

    def default_state
      {
        "schema_version" => SCHEMA_VERSION,
        "playlist" => empty_playlist.to_h,
        "playback" => { "shuffle" => false, "index" => 0, "volume" => 100 }
      }
    end
  end
end
