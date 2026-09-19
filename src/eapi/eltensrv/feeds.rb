# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: the EltenLink feed helpers
# were replaced by user interface helpers for a Mastodon account (the Klango server has no feed).

module EltenAPI
  module EltenSRV
    private

    MASTODON_VISIBILITIES = ["public", "unlisted", "private", "direct"].freeze

    # --- Account and requests -------------------------------------------------

    def mastodon_account
      return nil if !Session.logged?
      record = Klangten::Mastodon::AccountStore.load(Session.name)
      record != nil && record.usable? ? record : nil
    end

    def mastodon_client(record = mastodon_account)
      return nil if record == nil
      Klangten::Mastodon::Client.new(record.instance, token: record.token)
    end

    # Runs the block in a thread while the UI keeps running; plays the waiting
    # sound for longer requests. Returns [result, exception].
    def mastodon_call
      result = nil
      error = nil
      thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          result = yield
        rescue Exception => e
          error = e
        end
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiting_shown = false
      while thread.alive?
        if !waiting_shown && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 0.4
          waiting
          waiting_shown = true
        end
        loop_update(false)
      end
      thread.join
      [result, error]
    ensure
      waiting_end if waiting_shown
    end

    # Runs a request with the client of the connected account and reports errors.
    def mastodon_request(record = nil)
      record ||= mastodon_offer_connection
      return nil if record == nil
      client = mastodon_client(record)
      result, error = mastodon_call { yield(client) }
      if error != nil
        mastodon_report_error(error)
        return nil
      end
      result
    end

    def mastodon_report_error(error)
      Log.warning("Mastodon request failed: #{error.class}: #{error.message}")
      Klangten::Mastodon::Service.refresh if error.is_a?(Klangten::Mastodon::Unauthorized) && defined?(Klangten::Mastodon::Service)
      alert(mastodon_error_text(error))
    end

    def mastodon_error_text(error)
      case error
      when Klangten::Mastodon::Unauthorized
        p_("Mastodon", "The Mastodon server no longer accepts the connection to your account. Connect the account again.")
      when Klangten::Mastodon::RateLimited
        p_("Mastodon", "The Mastodon server has temporarily limited the number of requests. Try again in a few minutes.")
      when Klangten::Mastodon::ConnectionFailed
        p_("Mastodon", "The Mastodon server could not be reached. Check your internet connection and try again later.")
      when Klangten::Mastodon::Error
        p_("Mastodon", "The Mastodon server reported an error: %{error}") % { error: error.message.to_s }
      else
        _("Error")
      end
    end

    # --- Connecting an account ------------------------------------------------

    def mastodon_offer_connection
      record = mastodon_account
      return record if record != nil
      return nil if !Session.logged?
      return nil if !confirm(p_("Mastodon", "No Mastodon account is connected to Klangten yet. Do you want to connect one now?"))
      mastodon_connect
    end

    # Connects an account: app registration, authorization in the web browser
    # (out-of-band code), token exchange and verification.
    def mastodon_connect(instance = nil)
      return nil if !Session.logged?
      instance ||= input_text(p_("Mastodon", "Address of your Mastodon server, for example mastodon.social"), escapable: true)
      return nil if instance == nil || instance.to_s.strip == ""
      client = begin
        Klangten::Mastodon::Client.new(instance)
      rescue ArgumentError
        alert(p_("Mastodon", "This is not a valid server address."))
        return nil
      end
      app, error = mastodon_call { client.register_app(website: Klangten::Config::WEBSITE_URL) }
      if error != nil
        mastodon_report_error(error)
        return nil
      end
      language = Configuration.language.to_s[0, 2].to_s.downcase
      url = client.authorize_url(app["client_id"], language: language =~ /\A[a-z]{2}\z/ ? language : nil)
      alert(p_("Mastodon", "Klangten will now open the sign-in page of %{server} in your web browser. Sign in there and allow Klangten to access your account. The server then shows an authorization code. Copy this code and paste it into the next field.") % { server: client.host })
      begin
        platform_open_url(url)
      rescue Exception => e
        Log.warning("Mastodon authorization page could not be opened: #{e.class}")
      end
      code = nil
      loop do
        code = input_text(p_("Mastodon", "Authorization code"), escapable: true)
        return nil if code == nil
        break if code.to_s.strip != ""
      end
      verified, error = mastodon_call do
        client.obtain_token(client_id: app["client_id"], client_secret: app["client_secret"], code: code)
        account = client.verify_credentials
        info = begin
          client.instance_info
        rescue Klangten::Mastodon::Error
          { "max_characters" => Klangten::Mastodon::DEFAULT_MAX_CHARACTERS }
        end
        [account, info]
      end
      if error != nil
        mastodon_report_error(error)
        return nil
      end
      account, info = verified
      previous = Klangten::Mastodon::AccountStore.load(Session.name)
      record = Klangten::Mastodon::Account_Record.new(
        user: Session.name.to_s.downcase,
        instance: client.base_url,
        client_id: app["client_id"],
        client_secret: app["client_secret"],
        token: client.token,
        account_id: account.id.to_s,
        acct: account.acct.to_s,
        display_name: account.name.to_s,
        max_characters: info["max_characters"].to_i
      )
      Klangten::Mastodon::AccountStore.save(Session.name, record)
      mastodon_revoke_record(previous) if previous != nil && previous.usable? && previous.token != record.token
      Klangten::Mastodon::Service.refresh
      Session.feeds_update
      alert(p_("Mastodon", "Your Mastodon account %{account} is now connected to Klangten.") % { account: record.label })
      record
    end

    def mastodon_revoke_record(record)
      client = mastodon_client(record)
      _result, error = mastodon_call { client.revoke_token(client_id: record.client_id, client_secret: record.client_secret) }
      Log.warning("Mastodon token revocation failed: #{error.class}") if error != nil
    end

    def mastodon_disconnect
      record = mastodon_account
      return false if record == nil
      return false if !confirm(p_("Mastodon", "Do you want to disconnect the Mastodon account %{account} from Klangten? Klangten will ask the server to revoke its access.") % { account: record.label })
      mastodon_revoke_record(record)
      Klangten::Mastodon::AccountStore.delete(Session.name)
      Session.feeds_update
      alert(p_("Mastodon", "The Mastodon account has been disconnected."))
      true
    end

    # Settings entry and feed tab option.
    def mastodon_account_dialog
      return alert(p_("Mastodon", "Sign in to Klangten first.")) if !Session.logged?
      record = mastodon_account
      if record == nil
        mastodon_connect
        return
      end
      options = [
        p_("Mastodon", "Connect a different account"),
        p_("Mastodon", "Disconnect this account"),
        _("Cancel")
      ]
      choice = selector(options, header: p_("Mastodon", "Connected Mastodon account: %{account}") % { account: record.label }, cancel_index: 2)
      case choice
      when 0 then mastodon_connect
      when 1 then mastodon_disconnect
      end
    end

    # --- Presentation ---------------------------------------------------------

    def mastodon_media_label(media)
      kind = case media.type.to_s
      when "image" then p_("Mastodon", "Image")
      when "gifv" then p_("Mastodon", "Animation")
      when "video" then p_("Mastodon", "Video")
      when "audio" then p_("Mastodon", "Audio")
      else p_("Mastodon", "Attachment")
      end
      if media.description.to_s.strip == ""
        p_("Mastodon", "%{kind} without description") % { kind: kind }
      else
        "#{kind}: #{media.description.to_s.strip}"
      end
    end

    def mastodon_visibility_label(visibility)
      case visibility.to_s
      when "public" then p_("Mastodon", "Public")
      when "unlisted" then p_("Mastodon", "Quiet public")
      when "private" then p_("Mastodon", "Followers only")
      when "direct" then p_("Mastodon", "Mentioned people only")
      else visibility.to_s
      end
    end

    def mastodon_poll_text(poll)
      options = poll.options.to_a.map do |title, votes|
        votes == nil ? title : "#{title} (#{np_("Mastodon", "%{count} vote", "%{count} votes", votes) % { count: votes }})"
      end
      text = p_("Mastodon", "Poll: %{options}") % { options: options.join(", ") }
      text += " (" + p_("Mastodon", "closed") + ")" if poll.expired
      text
    end

    # Body of a status. In lists the content behind a content warning stays hidden.
    def mastodon_status_body(status, full: true)
      target = status.target
      pieces = []
      if target.spoiler_text.to_s != ""
        pieces << p_("Mastodon", "Content warning: %{text}") % { text: target.spoiler_text }
        pieces << (full ? status.text : (touch_ui? ? p_("Mastodon", "Content hidden, double tap to read it") : p_("Mastodon", "Content hidden, press Enter to read it")))
      else
        pieces << status.text
      end
      if full || target.spoiler_text.to_s == ""
        target.media_attachments.to_a.each { |media| pieces << mastodon_media_label(media) }
        pieces << mastodon_poll_text(target.poll) if target.poll != nil
        pieces << p_("Mastodon", "Link preview: %{title}") % { title: target.card[:title] } if full && target.card != nil && target.card[:title].to_s != ""
      end
      pieces.reject { |piece| piece.to_s.strip == "" }.join(full ? "\n" : " ")
    end

    def mastodon_status_speech(status)
      target = status.target
      parts = []
      if status.boost?
        parts << p_("Mastodon", "%{user} boosted %{author}") % { user: status.account.name, author: target.account.name }
      else
        parts << target.account.name
      end
      parts << EltenAPI::SpeechCommands::SoundCommand.new("listbox_itemliked", " " + p_("EAPI_Speech", "Liked") + ": ", "(like)", immediate: true) if target.favourited
      parts << ": " + mastodon_status_body(status, full: false) + " "
      parts << "(" + np_("Mastodon", "%{count} favourite", "%{count} favourites", target.favourites_count) % { count: target.favourites_count } + ") " if target.favourites_count > 0
      parts << format_date(target.created_at) if target.created_at != nil
      parts << EltenAPI::SpeechCommands::SoundCommand.new("listbox_itemcontaining", " " + p_("EAPI_Speech", "Containing") + ": ", "->", immediate: true) if target.replies_count > 0
      EltenAPI::SpeechSequence.new(parts)
    end

    def mastodon_status_details_text(status)
      target = status.target
      lines = []
      lines << target.account.label
      lines << p_("Mastodon", "Boosted by %{user}") % { user: status.account.label } if status.boost?
      lines << format_date(target.created_at) if target.created_at != nil
      lines << p_("Mastodon", "Edited on %{date}") % { date: format_date(target.edited_at) } if target.edited_at != nil
      lines << p_("Mastodon", "Visibility: %{visibility}") % { visibility: mastodon_visibility_label(target.visibility) }
      lines << ""
      lines << mastodon_status_body(status, full: true)
      lines << ""
      lines << p_("Mastodon", "%{replies} replies, %{boosts} boosts, %{favourites} favourites") % { replies: target.replies_count, boosts: target.reblogs_count, favourites: target.favourites_count }
      lines << p_("Mastodon", "Published with %{application}") % { application: target.application } if target.application.to_s != ""
      lines << target.url.to_s if target.url.to_s != ""
      lines.join("\n")
    end

    # Elten's feed list audio, now for audio attachments of statuses.
    def feed_audio_url(feed)
      return "" if feed == nil || !feed.respond_to?(:audio_url)
      feed.audio_url.to_s
    end

    def feed_audio_status
      ListBox.item_status("file_audio", p_("FeedViewer", "Audio content") + ":", p_("FeedViewer", "Audio content"))
    end

    def configure_feed_list_audio(list, feeds)
      return if list == nil
      list.item_audio_autoplay = false
      list.item_audio_space_mode = :stop
      feeds.to_a.each_with_index do |feed, index|
        url = feed_audio_url(feed)
        next if url == ""
        list.set_item_state(index, feed_audio_status)
        list.set_item_audio(index, url)
      end
    end

    # --- Posting --------------------------------------------------------------

    # Quick action "Publish to a feed" and older callers.
    def compose_feed(_users = [], _response = 0)
      mastodon_compose != nil
    end

    def mastodon_reply_text(status, record)
      target = status.target
      own = [record.acct.to_s.downcase, "#{record.acct}@#{record.host}".downcase]
      accounts = [target.account.acct.to_s] + target.mentions.to_a.map { |mention| mention[:acct].to_s }
      accounts = accounts.reject { |acct| acct == "" || own.include?(acct.downcase) }.uniq(&:downcase)
      accounts.empty? ? "" : accounts.map { |acct| "@#{acct}" }.join(" ") + " "
    end

    # Publishes a text post without a dialog (Invisible Interface).
    def mastodon_publish_text(text, in_reply_to_id: nil)
      record = mastodon_account
      return false if record == nil || text.to_s.strip == ""
      client = mastodon_client(record)
      client.post_status(text.to_s, in_reply_to_id: in_reply_to_id)
      Klangten::Mastodon::Service.refresh
      true
    end

    # Compose dialog: text, content warning, visibility, language and an
    # optional audio recording made with Elten's recording control.
    def mastodon_compose(reply_to: nil, text: nil)
      record = mastodon_offer_connection
      return nil if record == nil
      max_length = record.max_characters.to_i > 0 ? record.max_characters.to_i : Klangten::Mastodon::DEFAULT_MAX_CHARACTERS
      initial = text || (reply_to == nil ? "" : mastodon_reply_text(reply_to, record))
      header = reply_to == nil ? p_("Mastodon", "New post") : p_("Mastodon", "Reply to %{user}") % { user: reply_to.target.account.name }
      edit = EditBox.new(header, type: EditBox::Flags::MultiLine, text: initial, max_length: max_length)
      edit.index = edit.check = initial.length
      update_header = lambda do
        count = edit.text.to_s.chrsize
        edit.header = count > 0 ? header + ": " + (p_("EAPI_Form", "%{count} of %{maximum} characters") % { count: count, maximum: max_length }) : header
      end
      edit.on(:change) { update_header.call }
      update_header.call
      warning = EditBox.new(p_("Mastodon", "Content warning (optional)"), text: reply_to == nil ? "" : reply_to.target.spoiler_text.to_s, max_length: max_length)
      visibility = reply_to == nil ? "public" : reply_to.target.visibility.to_s
      visibility_index = MASTODON_VISIBILITIES.index(visibility) || 0
      visibility_list = ListBox.new(MASTODON_VISIBILITIES.map { |value| mastodon_visibility_label(value) }, header: p_("Mastodon", "Visibility"), index: visibility_index)
      language_default = Configuration.language.to_s[0, 2].to_s.downcase
      language_default = reply_to.target.language.to_s if reply_to != nil && reply_to.target.language.to_s =~ /\A[a-z]{2,3}\z/
      language = EditBox.new(p_("Mastodon", "Language of the post (two-letter code, for example en)"), text: language_default, max_length: 3)
      filename = EltenPath.join(Dirs.temp, "mastodon_#{rand(36**16).to_s(36)}.opus")
      recorder = OpusRecordButton.new(p_("FeedViewer", "Attach audio"), filename, max_bitrate: 128, bitrate: 64, time_limit: 0)
      audio_description = EditBox.new(p_("Mastodon", "Description of the audio (optional)"), max_length: 1500)
      send_button = Button.new(p_("Messages", "Send"))
      cancel_button = Button.new(_("Cancel"))
      form = Form.new([edit, warning, visibility_list, language, recorder, audio_description, send_button, cancel_button], index: 0)
      action = nil
      send_button.on(:press) do
        action = :send
        form.resume
      end
      cancel_button.on(:press) do
        action = :cancel
        form.resume
      end
      form.accept_button = send_button
      form.cancel_button = cancel_button
      dialog_open
      loop do
        action = nil
        form.wait
        if action != :send
          return nil if recorder.delete_audio
          form.focus
          next
        end
        if edit.text.to_s.strip == "" && recorder.empty?
          alert(p_("Mastodon", "A post must contain text or audio."))
          form.focus
          next
        end
        audio = nil
        if !recorder.empty?
          recording = recorder.get_recording_file(true)
          if recording == nil || !File.file?(recording)
            alert(p_("FeedViewer", "The audio recording could not be prepared."))
            form.focus
            next
          end
          audio = File.binread(recording)
        end
        language_code = language.text.to_s.strip.downcase
        language_code = nil if language_code !~ /\A[a-z]{2,3}\z/
        spoiler = warning.text.to_s.strip
        post_visibility = MASTODON_VISIBILITIES[visibility_list.index] || "public"
        description = audio_description.text.to_s.strip
        post_text = edit.text.to_s
        client = mastodon_client(record)
        idempotency_key = SecureRandom.hex(16)
        status, error = mastodon_call do
          media_ids = []
          if audio != nil
            media = client.upload_media(audio, filename: "audio.opus", content_type: "audio/ogg", description: description)
            media_ids << media.id
          end
          client.post_status(
            post_text,
            in_reply_to_id: reply_to == nil ? nil : reply_to.target.id,
            visibility: post_visibility,
            spoiler_text: spoiler,
            sensitive: spoiler != "" ? true : nil,
            language: language_code,
            media_ids: media_ids,
            idempotency_key: idempotency_key
          )
        end
        if error != nil
          mastodon_report_error(error)
          form.focus
          next
        end
        recorder.delete_audio(true)
        Klangten::Mastodon::Service.refresh
        alert(p_("Mastodon", "Post published."))
        return status
      end
    ensure
      dialog_close
    end

    # --- Actions on statuses --------------------------------------------------

    def mastodon_own_status?(status, record = mastodon_account)
      record != nil && status.target.account.id.to_s == record.account_id.to_s
    end

    def mastodon_apply_counts(status, updated)
      return if updated == nil
      target = status.target
      source = updated.target
      target.favourited = source.favourited
      target.favourites_count = source.favourites_count
      target.reblogged = source.reblogged
      target.reblogs_count = source.reblogs_count
      target.bookmarked = source.bookmarked
      Klangten::Mastodon::Service.update_status(status)
    end

    def mastodon_toggle_favourite(status, quiet: false)
      on = !status.target.favourited
      updated = mastodon_request { |client| client.favourite(status.target.id, on) }
      return false if updated == nil
      mastodon_apply_counts(status, updated)
      alert(on ? p_("Mastodon", "Added to favourites") : p_("Mastodon", "Removed from favourites")) if !quiet
      true
    end

    def mastodon_toggle_boost(status)
      on = !status.target.reblogged
      updated = mastodon_request { |client| client.reblog(status.target.id, on) }
      return false if updated == nil
      mastodon_apply_counts(status, updated)
      alert(on ? p_("Mastodon", "Post boosted") : p_("Mastodon", "Boost removed"))
      true
    end

    def mastodon_toggle_bookmark(status)
      on = !status.target.bookmarked
      updated = mastodon_request { |client| client.bookmark(status.target.id, on) }
      return false if updated == nil
      mastodon_apply_counts(status, updated)
      alert(on ? p_("Mastodon", "Bookmark added") : p_("Mastodon", "Bookmark removed"))
      true
    end

    def mastodon_delete_status(status)
      return false if !confirm(p_("FeedViewer", "Are you sure you want to delete this post?"))
      done = mastodon_request { |client| client.delete_status(status.target.id) }
      return false if done != true
      Klangten::Mastodon::Service.remove_status(status.target.id)
      play_sound("editbox_delete")
      true
    end

    def mastodon_return_scene
      $scene.is_a?(Scene_Main) ? Scene_Main.new(notification_focus: :keep_current) : $scene
    end

    def mastodon_open_timeline(kind, param = nil)
      $scene = Scene_MastodonTimeline.new(kind, param, mastodon_return_scene)
    end

    def mastodon_open_thread(status)
      mastodon_open_timeline(:thread, status)
    end

    def mastodon_open_links(status)
      links = status.links
      links << { text: p_("Mastodon", "This post on the web"), url: status.target.url.to_s, kind: :link } if status.target.url.to_s != ""
      return alert(p_("Mastodon", "This post contains no links.")) if links.empty?
      labels = links.map { |link| link[:kind] == :link && link[:text] != link[:url] ? "#{link[:text]} (#{link[:url]})" : link[:text] }
      choice = selector(labels + [_("Cancel")], header: p_("Mastodon", "Links"), cancel_index: labels.size)
      return if choice < 0 || choice >= links.size
      link = links[choice]
      case link[:kind]
      when :hashtag
        mastodon_open_timeline(:hashtag, link[:text].sub(/\A#/, ""))
      when :mention
        account = mastodon_request { |client| client.lookup_account(link[:text].sub(/\A@/, "")) rescue client.search_accounts(link[:url], limit: 1).first }
        account != nil ? mastodon_show_account(account) : platform_open_url(link[:url])
      else
        platform_open_url(link[:url])
      end
    end

    def mastodon_show_favourites(status)
      accounts = mastodon_request { |client| client.favourited_by(status.target.id) }
      return if accounts == nil
      mastodon_account_list(accounts, p_("FeedViewer", "Users who like this post"))
    end

    def mastodon_account_list(accounts, header)
      return alert(p_("Mastodon", "No accounts found.")) if accounts.empty?
      dialog_open
      list = ListBox.new(accounts.map(&:label), header: header, index: 0, flags: 0, quiet: false)
      loop do
        loop_update
        list.update
        break if key_pressed?(:key_escape)
        if list.selected?
          mastodon_show_account(accounts[list.index])
          list.focus
        end
      end
      dialog_close
    end

    def mastodon_search_account
      query = input_text(p_("Mastodon", "Search for an account (name or address such as user@example.social)"), escapable: true)
      return if query == nil || query.strip == ""
      accounts = mastodon_request { |client| client.search_accounts(query.strip) }
      mastodon_account_list(accounts, p_("Mastodon", "Accounts")) if accounts != nil
    end

    def mastodon_open_hashtag
      tag = input_text(p_("Mastodon", "Hashtag"), escapable: true)
      return if tag == nil || tag.strip.sub(/\A#/, "") == ""
      mastodon_open_timeline(:hashtag, tag.strip.sub(/\A#/, ""))
    end

    # Status context menu, shared by the feed tab and the timeline scenes.
    def mastodon_status_menu(menu, status, show_thread: true)
      record = mastodon_account
      target = status.target
      menu.option(p_("Mastodon", "Profile of %{user}") % { user: target.account.name }, nil, "p") { mastodon_show_account(target.account) }
      menu.option(p_("Mastodon", "Profile of %{user}") % { user: status.account.name }) { mastodon_show_account(status.account) } if status.boost?
      if show_thread
        menu.option(p_("FeedViewer", "Show conversation"), nil, "d") { mastodon_open_thread(status) }
      end
      return if record == nil
      menu.option(p_("FeedViewer", "Reply"), nil, "r") { mastodon_compose(reply_to: status) }
      menu.option(target.favourited ? p_("Mastodon", "Remove from favourites") : p_("Mastodon", "Add to favourites"), nil, "k") { mastodon_toggle_favourite(status) }
      if ["public", "unlisted"].include?(target.visibility.to_s) || (target.visibility.to_s == "private" && mastodon_own_status?(status, record))
        menu.option(target.reblogged ? p_("Mastodon", "Remove boost") : p_("Mastodon", "Boost"), nil, "b") { mastodon_toggle_boost(status) }
      end
      menu.option(target.bookmarked ? p_("Mastodon", "Remove bookmark") : p_("Mastodon", "Add bookmark"), nil, "m") { mastodon_toggle_bookmark(status) }
      menu.option(p_("FeedViewer", "Show likes"), nil, "K") { mastodon_show_favourites(status) } if target.favourites_count > 0
      menu.option(p_("Mastodon", "Links"), nil, "l") { mastodon_open_links(status) }
      menu.option(_("Delete"), nil, :del) { mastodon_delete_status(status) } if mastodon_own_status?(status, record)
    end

    # Other lists and account options, shared by the feed tab and the timeline scenes.
    def mastodon_general_menu(menu)
      record = mastodon_account
      if record != nil
        menu.option(p_("Mastodon", "New post"), nil, "n") { mastodon_compose }
        menu.submenu(p_("Mastodon", "Timelines and lists")) do |m|
          m.option(p_("Mastodon", "Home timeline")) { mastodon_open_timeline(:home) }
          m.option(p_("Mastodon", "Notifications")) { mastodon_open_timeline(:notifications) }
          m.option(p_("Mastodon", "Mentions")) { mastodon_open_timeline(:mentions) }
          m.option(p_("Mastodon", "Local timeline")) { mastodon_open_timeline(:local) }
          m.option(p_("Mastodon", "Federated timeline")) { mastodon_open_timeline(:public) }
          m.option(p_("Mastodon", "Hashtag...")) { mastodon_open_hashtag }
          m.option(p_("Mastodon", "Bookmarks")) { mastodon_open_timeline(:bookmarks) }
          m.option(p_("Mastodon", "Favourites")) { mastodon_open_timeline(:favourites) }
          m.option(p_("Mastodon", "My posts")) { mastodon_open_timeline(:own) }
          m.option(p_("Mastodon", "Search for an account...")) { mastodon_search_account }
        end
      end
      menu.option(p_("Mastodon", "Mastodon account...")) { mastodon_account_dialog }
    end

    # Status details, in the place of Elten's feed message dialog.
    def mastodon_show_status(status)
      return if status == nil
      fields = [
        text_field = EditBox.new(p_("EAPI_Common", "Message"), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: mastodon_status_details_text(status), quiet: true)
      ]
      players = status.audio_attachments.map do |media|
        player = Player.new(media.playable_url, label: mastodon_media_label(media), autoplay: false, quiet: true, lazy: true)
        player.on(:key_space) { player.paused? ? player.play : player.pause }
        player
      end
      fields.concat(players)
      fields << (reply_button = Button.new(p_("FeedViewer", "Reply"))) if mastodon_account != nil
      fields << (thread_button = Button.new(p_("FeedViewer", "Show conversation")))
      fields << (close_button = Button.new(p_("EAPI_Common", "Close")))
      form = Form.new(fields, index: 0, silent: false, quiet: true)
      action = nil
      reply_button&.on(:press) do
        action = :reply
        form.resume
      end
      thread_button.on(:press) do
        action = :thread
        form.resume
      end
      close_button.on(:press) { form.resume }
      text_field.bind_context { |menu| mastodon_status_menu(menu, status, show_thread: false) }
      form.cancel_button = close_button
      dialog_open
      begin
        form.wait
      ensure
        players.each { |player| player.close rescue nil }
        dialog_close
      end
      case action
      when :reply then mastodon_compose(reply_to: status)
      when :thread then mastodon_open_thread(status)
      end
    end

    # Profile dialog with follow, mute and block actions.
    def mastodon_show_account(account)
      return if account == nil
      record = mastodon_account
      own = record != nil && account.id.to_s == record.account_id.to_s
      loop do
        relationship = nil
        if record != nil && !own
          relationship = mastodon_request(record) { |client| client.relationship(account.id) }
        end
        lines = [account.label]
        lines << account.note_text if account.note_text != ""
        account.fields.to_a.each { |name, value| lines << "#{name}: #{value}" }
        lines << p_("Mastodon", "%{posts} posts, %{following} following, %{followers} followers") % { posts: account.statuses_count, following: account.following_count, followers: account.followers_count }
        lines << p_("Mastodon", "Automated account") if account.bot
        lines << p_("Mastodon", "Follow requests to this account are reviewed") if account.locked
        lines << p_("Mastodon", "Follows you") if relationship&.followed_by
        lines << account.url.to_s if account.url.to_s != ""
        fields = [EditBox.new(p_("Mastodon", "Profile"), type: EditBox::Flags::ReadOnly | EditBox::Flags::MultiLine, text: lines.join("\n"), quiet: true)]
        buttons = {}
        buttons[:posts] = Button.new(p_("Mastodon", "Show posts"))
        if relationship != nil
          follow_label = if relationship.following
            p_("Mastodon", "Unfollow")
          elsif relationship.requested
            p_("Mastodon", "Withdraw follow request")
          else
            p_("Mastodon", "Follow")
          end
          buttons[:follow] = Button.new(follow_label)
          buttons[:mention] = Button.new(p_("Mastodon", "Mention"))
          buttons[:mute] = Button.new(relationship.muting ? p_("Mastodon", "Unmute") : p_("Mastodon", "Mute"))
          buttons[:block] = Button.new(relationship.blocking ? p_("Mastodon", "Unblock") : p_("Mastodon", "Block"))
        end
        buttons[:web] = Button.new(p_("Mastodon", "Open in web browser")) if account.url.to_s != ""
        buttons[:close] = Button.new(p_("EAPI_Common", "Close"))
        form = Form.new(fields + buttons.values, index: 0, silent: false, quiet: false)
        action = nil
        buttons.each do |key, button|
          button.on(:press) do
            action = key
            form.resume
          end
        end
        form.cancel_button = buttons[:close]
        dialog_open
        begin
          form.wait
        ensure
          dialog_close
        end
        case action
        when :posts
          mastodon_open_timeline(:account, account)
          return
        when :mention
          mastodon_compose(text: "@#{account.acct} ")
          return
        when :web
          platform_open_url(account.url.to_s)
          return
        when :follow
          result = mastodon_request(record) { |client| client.follow(account.id, !(relationship.following || relationship.requested)) }
          if result != nil
            Klangten::Mastodon::Service.refresh
            alert(result.following ? p_("Mastodon", "You now follow this account.") : (result.requested ? p_("Mastodon", "Follow request sent.") : p_("Mastodon", "You no longer follow this account.")))
          end
        when :mute
          result = mastodon_request(record) { |client| client.mute(account.id, !relationship.muting) }
          alert(result.muting ? p_("Mastodon", "Account muted.") : p_("Mastodon", "Account unmuted.")) if result != nil
        when :block
          if relationship.blocking || confirm(p_("Mastodon", "Do you want to block %{user}? You will no longer see each other's posts.") % { user: account.label })
            result = mastodon_request(record) { |client| client.block(account.id, !relationship.blocking) }
            alert(result.blocking ? p_("Mastodon", "Account blocked.") : p_("Mastodon", "Account unblocked.")) if result != nil
          end
        else
          return
        end
      end
    end

    # --- Notifications tab ----------------------------------------------------

    # Unread mentions as a virtual group in Elten's notifications tab.
    def mastodon_notification_groups
      return [] if !defined?(Klangten::Mastodon::Service) || !Session.logged?
      mentions = Klangten::Mastodon::Service.unread_mentions
      return [] if mentions.empty?
      latest = mentions.first
      count = mentions.size
      title = if count == 1
        p_("Mastodon", "%{user} mentioned you") % { user: latest.account.name }
      else
        np_("Mastodon", "%{count} new mention", "%{count} new mentions", count) % { count: count }
      end
      key = "virtual:mastodon:mentions:#{latest.id}"
      [
        NotificationGroups::NotificationGroup.new(
          key: key,
          cat: "mastodon",
          category: p_("Mastodon", "Mastodon mentions"),
          date: latest.created_at.to_i,
          revoked: false,
          ids: [],
          payload: { "title" => title, "count" => count },
          fallback_text: title,
          virtual: true,
          action: Proc.new do
            Klangten::Mastodon::Service.mark_mentions_read
            insert_scene(Scene_MastodonTimeline.new(:mentions), true, return_to_main: true)
          end
        )
      ]
    rescue Exception => e
      Log.warning("Mastodon notification groups: #{e.class}: #{e.message}")
      []
    end
  end
end
