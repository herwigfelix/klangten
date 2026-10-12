# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Spotify (Media menu): sign in with the web browser, search, the user's
# library and playlists, artists, albums, song radio, audiobooks and
# podcasts. The data comes from KlangtenSpotify (src/eapi/spotify.rb,
# src/eapi/spotify_host.rb); every query runs in EltenAPI::Tasks.run, so a busy indicator appears after half a
# second and Escape cancels.
#
# Like in Klango, a chosen list (playlist, album, the artist's popular tracks,
# similar tracks) plays in Klangten's playlist (Scene_Playlist), with its keys
# for tempo, pitch and balance; KlangtenSpotify::PlaylistSound plays the
# tracks. Playback continues in the background. Nothing can be recorded or
# saved: Spotify's terms do not allow it.
#
# In track lists Enter plays the list from the chosen track; the context menu
# leads to the artist, the album and similar tracks.

class Scene_Spotify
  # Search field that steps through earlier searches with Up and Down.
  class SearchField < EltenAPI::Controls::EditBox
    def initialize(header, history)
      super(header, text: "")
      @history = history
      @history_index = -1
    end

    def history=(entries)
      @history = entries
      @history_index = -1
    end

    def update
      if !@history.empty? && !raw_key_held?(:key_shift) && !modifier_held?(:main_modifier) && (key_pressed?(:key_up) || key_pressed?(:key_down))
        step = key_pressed?(:key_up) ? 1 : -1
        index = @history_index + step
        if index >= @history.size || index < -1
          play_sound("border")
        else
          @history_index = index
          text = index < 0 ? "" : @history[index].to_s
          set_text(text)
          self.index = self.check = text.length
          text == "" ? play_sound("border") : speak(text)
        end
        $activecontrols.push(self) if $activecontrols.is_a?(Array)
        return
      end
      super
    end
  end

  KINDS = [nil, "track", "artist", "album", "playlist", "audiobook", "podcast"].freeze

  def self.available?
    defined?(KlangtenSpotify) && KlangtenSpotify.available?
  rescue Exception
    false
  end

  def initialize
    @owner = nil
    @last_sync = 0.0
  end

  def main
    @owner = self
    @client = KlangtenSpotify.client
    if @client == nil
      alert(p_("Spotify", "Spotify is not available on this system."))
    elsif connect
      home
    end
  ensure
    leave_playback
    $scene = Scene_Main.new if $scene == self
  end

  # ------------------------------------------------------------------ player

  def player
    KlangtenSpotify.player
  end

  # Called from every loop of the Spotify screens: announces new tracks and
  # problems, and keeps the stored login in step with the library.
  def tick
    say_notice
    now = KlangtenSpotify.monotonic
    if now - @last_sync > 5
      @last_sync = now
      @client.sync_credentials
    end
  end

  # Problems of the track that plays (Premium, not available, no
  # connection) - the playlist only skips such a track.
  def say_notice
    text = KlangtenSpotify.take_notice_text
    alert(text, false) if text != nil
  end

  # Like in Klango, a Spotify list plays in Klangten's playlist: it opens with
  # the chosen track, playback goes on in the background when it is closed.
  # Spotify's lists are not saved (Spotify's terms).
  def play_list(tracks, index, header)
    tracks = Array(tracks).reject { |t| t.uri.to_s == "" }
    if tracks.empty?
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    entries = tracks.map do |track|
      KlangtenPlaylist::Entry.new(track.uri, track.label, track.seconds.to_i > 0 ? track.seconds.to_f : nil)
    end
    list = KlangtenPlaylist::List.new(entries)
    list.title = header.to_s == "" ? p_("Spotify", "Track list") : header
    list.unsaveable = true
    index = [[index.to_i, 0].max, entries.size - 1].min
    KlangtenPlaylist.play(list, index)
    playlist_screen
  end

  def spotify_list_playing?
    list = KlangtenPlaylist.current_list
    list != nil && list.unsaveable && KlangtenPlaylist.current_entry != nil
  end

  def playlist_screen
    list = KlangtenPlaylist.current_list
    return if list == nil
    Scene_Playlist.new(list).main
  end

  def leave_playback
    @client.sync_credentials if @client != nil
  rescue Exception => e
    Log.warning("Spotify: syncing the login failed: #{e.class}: #{e.message}")
  end

  # ------------------------------------------------------------------- login

  def connect
    return true if @client.logged_in?
    if !@client.stored_login?
      text = p_("Spotify", "To listen to Spotify in Klangten, sign in with your Spotify account. The sign-in page opens in your web browser; after signing in, return to Klangten. Playback needs Spotify Premium. Do you want to sign in now?")
      return false unless confirm(text, default_yes: true)
      title = p_("Spotify", "Waiting for the sign-in in the web browser. Press Escape to cancel.")
      show_after = 0
    else
      title = p_("Spotify", "Connecting to Spotify...")
      show_after = 0.5
    end
    state = begin
      EltenAPI::Tasks.run(title: title, show_after: show_after) do |_progress, token|
        @client.start_login
        @client.wait_for_login { token.cancelled? ? :cancel : nil }
      end
    rescue EltenAPI::Tasks::Cancelled
      @client.cancel_login
      :cancelled
    end
    case state
    when KlangtenSpotify::STATE_OK
      play_sound("signal") rescue nil
      speak(p_("Spotify", "Connected to Spotify."))
      true
    when :cancelled
      false
    when KlangtenSpotify::STATE_NO_PREMIUM
      alert(p_("Spotify", "Your Spotify account has no Premium subscription. Spotify allows playback in other programs only with Premium."))
      false
    else
      alert(p_("Spotify", "Signing in to Spotify failed. Check your internet connection and try again."))
      false
    end
  end

  def sign_out
    return unless confirm(p_("Spotify", "Do you want to sign out of Spotify? Klangten then forgets your Spotify login."))
    KlangtenPlaylist.stop if spotify_list_playing?
    player.stop if KlangtenSpotify.player?
    EltenAPI::Tasks.run(title: p_("Spotify", "Signing out...")) { @client.logout }
    alert(p_("Spotify", "You have signed out of Spotify."))
  rescue EltenAPI::Tasks::Cancelled
    nil
  end

  # -------------------------------------------------------------------- home

  def home
    entries = [
      [:search, p_("Spotify", "Search")],
      [:library, p_("Spotify", "Liked songs")],
      [:playlists, p_("Spotify", "My playlists")],
      [:player, p_("Spotify", "Now playing")],
      [:signout, p_("Spotify", "Sign out of Spotify")]
    ]
    visible = proc { entries.reject { |key, _| key == :player && !spotify_list_playing? } }
    shown = visible.call
    list = ListBox.new(shown.map { |e| e[1] }, header: "Spotify", index: 0, quiet: false)
    loop do
      loop_update
      tick
      list.update
      break if key_pressed?(:key_escape) || left?
      now = visible.call
      if now != shown
        key = shown[list.index] && shown[list.index][0]
        shown = now
        list.options = shown.map { |e| e[1] }
        list.index = [shown.index { |e| e[0] == key } || 0, 0].max
      end
      next unless key_pressed?(:key_enter)
      case shown[list.index] && shown[list.index][0]
      when :search then search_screen
      when :library then open_library
      when :playlists then open_playlists
      when :player then playlist_screen
      when :signout
        sign_out
        break unless @client.logged_in?
      end
      break if left?
      list.focus
    end
  end

  # ------------------------------------------------------------------ queries

  # Returned by fetch when the user cancelled or the query failed (the
  # failure has been announced); nil means Spotify found nothing.
  FAILED = Object.new.freeze

  # Runs a blocking query with a busy indicator.
  def fetch(title)
    EltenAPI::Tasks.run(title: title) do |_progress, token|
      @client.call_async(token) { yield }
    end
  rescue EltenAPI::Tasks::Cancelled
    FAILED
  rescue StandardError => e
    Log.warning("Spotify request failed: #{e.class}: #{e.message}")
    alert(p_("Spotify", "Spotify did not answer as expected. Try again later."))
    FAILED
  end

  def failed?(value)
    value.equal?(FAILED)
  end

  def left?
    $scene != @owner
  end

  def searches_path
    File.join(KlangtenSpotify.data_dir, "searches.json")
  end

  def recent_searches
    list = File.file?(searches_path) ? JSON.parse(File.read(searches_path, encoding: "UTF-8")) : []
    list.is_a?(Array) ? list.map(&:to_s) : []
  rescue StandardError
    []
  end

  def remember_search(text)
    list = [text] + recent_searches.reject { |s| s.casecmp?(text) }
    File.write(searches_path, JSON.generate(list.first(30)))
  rescue StandardError
    nil
  end

  def search_screen
    query = SearchField.new(p_("Spotify", "Search Spotify"), recent_searches)
    kinds = ListBox.new([
      p_("Spotify", "Everything"), p_("Spotify", "Tracks"), p_("Spotify", "Artists"), p_("Spotify", "Albums"),
      p_("Spotify", "Playlists"), p_("Spotify", "Audiobooks"), p_("Spotify", "Podcasts")
    ], header: p_("Spotify", "Search for"))
    search = Button.new(p_("Spotify", "Search"))
    close = Button.new(_("Close"))
    form = Form.new([query, kinds, search, close])
    form.accept_button = search
    form.cancel_button = close
    done = false
    search.on(:press) do
      text = query.text.to_s.strip
      if text == ""
        alert(p_("Spotify", "Enter what you are looking for."))
        next
      end
      remember_search(text)
      query.history = recent_searches
      show_search_results(text, KINDS[kinds.index])
      form.focus unless left?
    end
    close.on(:press) { done = true }
    loop do
      loop_update
      tick
      form.update
      break if done || left?
    end
  end

  def kind_name(kind)
    case kind
    when "track" then p_("Spotify", "Track")
    when "artist" then p_("Spotify", "Artist")
    when "album" then p_("Spotify", "Album")
    when "playlist" then p_("Spotify", "Playlist")
    when "audiobook" then p_("Spotify", "Audiobook")
    when "podcast" then p_("Spotify", "Podcast")
    else ""
    end
  end

  # In "Everything" each row says what it is - otherwise "Sherlock Holmes"
  # could be an artist, an album or an audiobook.
  def row_label(row, with_kind)
    text = row.name.to_s
    text = "#{text} - #{row.sub}" if row.sub.to_s != "" && row.kind != "playlist"
    with_kind && kind_name(row.kind) != "" ? "#{kind_name(row.kind)}: #{text}" : text
  end

  def show_search_results(text, kind)
    rows = fetch(p_("Spotify", "Searching...")) { @client.search_typed(text, 20) }
    return if failed?(rows)
    rows = rows.select { |row| row.kind == kind } if kind != nil
    if rows.empty?
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    header = p_("Spotify", "Results for %{query}") % { query: text }
    list = ListBox.new(rows.map { |row| row_label(row, kind == nil) }, header: header, index: 0, quiet: false)
    list.bind_context do |menu|
      row = rows[list.index]
      row_menu(menu, row) if row != nil
    end
    loop do
      loop_update
      tick
      list.update
      break if key_pressed?(:key_escape) || left?
      next unless key_pressed?(:key_enter)
      row = rows[list.index]
      open_row(row) if row != nil
      break if left?
      list.focus
    end
  end

  def open_row(row)
    case row.kind
    when "track" then play_radio(row.to_track)
    when "artist" then artist_page(row.uri)
    when "album" then open_album(row.uri)
    when "playlist" then open_playlist(row.uri, row.name)
    when "audiobook", "podcast" then open_show(row.uri, row.name)
    end
  end

  def row_menu(menu, row)
    menu.option(row.track? ? p_("Spotify", "Play") : p_("Spotify", "Open")) { open_row(row) }
    if row.artist_uri.to_s != "" && row.kind != "artist"
      menu.option(p_("Spotify", "Go to artist")) { artist_page(row.artist_uri) }
    end
    if row.album_uri.to_s != "" && row.kind != "album"
      menu.option(p_("Spotify", "Go to album")) { open_album(row.album_uri) }
    end
    menu.option(p_("Spotify", "Similar tracks")) { play_radio(row.to_track) } if row.track?
  end

  def track_menu(menu, track)
    menu.option(p_("Spotify", "Go to artist")) { artist_page(track.artist_uri) } if track.artist_uri.to_s != ""
    menu.option(p_("Spotify", "Go to album")) { open_album(track.album_uri) } if track.album_uri.to_s != ""
    menu.option(p_("Spotify", "Similar tracks")) { play_radio(track) } unless track.episode?
  end

  # A single track: Spotify's song radio continues after it.
  def play_radio(track)
    similar = fetch(p_("Spotify", "Looking for similar tracks...")) { @client.track_radio(track.uri, 50) }
    return if failed?(similar)
    tracks = [track] + similar.reject { |t| t.uri == track.uri }
    play_list(tracks, 0, p_("Spotify", "Similar to %{title}") % { title: track.label })
  end

  # A list of tracks; Enter plays the list from the chosen track.
  def track_list(header, tracks, index = 0)
    return if failed?(tracks)
    if tracks.empty?
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    list = ListBox.new(tracks.map(&:label), header: header, index: index, quiet: false)
    list.bind_context do |menu|
      track = tracks[list.index]
      if track != nil
        menu.option(p_("Spotify", "Play from here")) { play_list(tracks, list.index, header) }
        track_menu(menu, track)
      end
    end
    loop do
      loop_update
      tick
      list.update
      break if key_pressed?(:key_escape) || left?
      next unless key_pressed?(:key_enter)
      play_list(tracks, list.index, header)
      break if left?
      list.focus
    end
  end

  def open_library
    tracks = fetch(p_("Spotify", "Loading your liked songs...")) { @client.library_tracks }
    track_list(p_("Spotify", "Liked songs"), tracks)
  end

  def open_playlists
    lists = fetch(p_("Spotify", "Loading your playlists...")) { @client.playlists }
    return if failed?(lists)
    if lists.empty?
      alert(p_("Spotify", "You have no playlists."))
      return
    end
    list = ListBox.new(lists.map(&:name), header: p_("Spotify", "My playlists"), index: 0, quiet: false)
    loop do
      loop_update
      tick
      list.update
      break if key_pressed?(:key_escape) || left?
      next unless key_pressed?(:key_enter)
      chosen = lists[list.index]
      open_playlist(chosen.uri, chosen.name) if chosen != nil
      break if left?
      list.focus
    end
  end

  def open_playlist(uri, name)
    tracks = fetch(p_("Spotify", "Loading the playlist...")) { @client.playlist_tracks(uri) }
    track_list(name.to_s == "" ? p_("Spotify", "Playlist") : name, tracks)
  end

  def open_album(uri)
    album = fetch(p_("Spotify", "Loading the album...")) { @client.album(uri) }
    return if failed?(album)
    if album == nil
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    header = [album.name, album.artist].reject { |s| s.to_s == "" }.join(" - ")
    track_list(header, album.tracks)
  end

  # Audiobook or podcast: its chapters or episodes. "Resume" comes first
  # once Klangten knows where the user left off.
  def open_show(uri, name)
    show = fetch(p_("Spotify", "Loading...")) { @client.show(uri) }
    return if failed?(show)
    if show == nil || show.tracks.empty?
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    tracks = show.tracks
    resume = KlangtenSpotify.positions.resume_index(tracks)
    labels = tracks.map { |t| t.title.to_s }
    labels.unshift(p_("Spotify", "Resume: %{title}") % { title: tracks[resume].title }) if resume != nil
    header = show.name.to_s == "" ? name.to_s : show.name
    list = ListBox.new(labels, header: header, index: 0, quiet: false)
    loop do
      loop_update
      tick
      list.update
      break if key_pressed?(:key_escape) || left?
      next unless key_pressed?(:key_enter)
      index = list.index
      index = resume != nil ? (index == 0 ? resume : index - 1) : index
      play_list(tracks, index, header)
      break if left?
      list.focus
    end
  end

  # Artist page as a form: popular tracks, albums, related artists and the
  # biography.
  def artist_page(uri)
    artist = fetch(p_("Spotify", "Loading the artist...")) { @client.artist(uri) }
    return if failed?(artist)
    if artist == nil
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    fields = []
    top = artist.top.empty? ? nil : ListBox.new(artist.top.map(&:label), header: p_("Spotify", "Popular tracks"))
    albums = artist.albums.empty? ? nil : ListBox.new(artist.albums.map(&:name), header: p_("Spotify", "Albums"))
    related = artist.related.empty? ? nil : ListBox.new(artist.related.map(&:name), header: p_("Spotify", "Related artists"))
    bio = artist.plain_biography
    biography = bio == "" ? nil : EditBox.new(p_("Spotify", "Biography"), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: bio)
    close = Button.new(_("Close"))
    fields = [top, albums, related, biography, close].compact
    if fields.size == 1
      alert(p_("Spotify", "Nothing was found."))
      return
    end
    form = Form.new(fields)
    form.cancel_button = close
    done = false
    action = nil
    top.on(:select) { action = [:top, top.index] } if top != nil
    top.bind_context { |menu| track_menu(menu, artist.top[top.index]) if artist.top[top.index] != nil } if top != nil
    albums.on(:select) { action = [:album, albums.index] } if albums != nil
    related.on(:select) { action = [:artist, related.index] } if related != nil
    close.on(:press) { done = true }
    speak(artist.name) if artist.name.to_s != ""
    loop do
      loop_update
      tick
      form.update
      break if done || left?
      next if action == nil
      kind, index = action
      action = nil
      case kind
      when :top then play_list(artist.top, index, p_("Spotify", "Popular tracks of %{artist}") % { artist: artist.name })
      when :album then open_album(artist.albums[index].uri)
      when :artist then artist_page(artist.related[index].uri)
      end
      break if left?
      form.focus
    end
  end
end
