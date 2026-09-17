# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Timelines, threads and notifications of the connected Mastodon account. It
# takes the place of Elten's feed viewer and keeps its interaction model:
# Enter shows an entry, the right arrow opens the conversation, the context
# menu holds the actions and Escape returns.
class Scene_MastodonTimeline
  KINDS = [:home, :notifications, :mentions, :local, :public, :hashtag, :account, :own, :thread, :bookmarks, :favourites].freeze

  def initialize(kind = :home, param = nil, scene = nil)
    kind = kind.to_sym if kind.is_a?(String)
    @kind = KINDS.include?(kind) ? kind : :home
    @param = param
    @scene = scene
    @items = nil
    @next_max_id = nil
    @complete = false
    @index = nil
  end

  def main
    @record = mastodon_offer_connection
    return leave if @record == nil
    if @items == nil
      return leave if !load_initial
    end
    mark_read if [:notifications, :mentions].include?(@kind)
    @sel = ListBox.new(item_options, header: header, index: @index || 0, flags: 0, quiet: true, empty_label: p_("Mastodon", "No entries"))
    configure_audio
    @sel.bind_context { |menu| context(menu) }
    @sel.focus
    loop do
      loop_update
      @sel.update
      break if $scene != self
      if key_pressed?(:key_escape) || (@kind == :thread && @sel.collapsed?)
        break
      end
      if @sel.selected? && @items.size > 0
        activate(@items[@sel.index])
        loop_update
      elsif @sel.expanded? && @items.size > 0
        status = item_status(@items[@sel.index])
        mastodon_open_thread(status) if status != nil && !(@kind == :thread && status.target.id == thread_root_id)
      end
      break if $scene != self
      load_more if @sel.index == @items.size - 1 && can_load_more?
    end
    @index = @sel.index
    leave if $scene == self
  end

  private

  def leave
    $scene = @scene || Scene_Main.new if $scene == self
  end

  def header
    case @kind
    when :home then p_("Mastodon", "Home timeline")
    when :notifications then p_("Mastodon", "Notifications")
    when :mentions then p_("Mastodon", "Mentions")
    when :local then p_("Mastodon", "Local timeline")
    when :public then p_("Mastodon", "Federated timeline")
    when :hashtag then "##{@param}"
    when :account then p_("Mastodon", "Posts of %{user}") % { user: @param.name }
    when :own then p_("Mastodon", "My posts")
    when :thread then p_("FeedViewer", "Show conversation")
    when :bookmarks then p_("Mastodon", "Bookmarks")
    when :favourites then p_("Mastodon", "Favourites")
    end
  end

  def thread_root_id
    @param.respond_to?(:target) ? @param.target.id : nil
  end

  def notification_list?
    [:notifications, :mentions].include?(@kind)
  end

  def load_initial
    if @kind == :thread
      root = @param.target
      context = mastodon_request(@record) { |client| client.context(root.id) }
      return false if context == nil
      @items = context[:ancestors] + [root] + context[:descendants]
      @index = context[:ancestors].size
      @complete = true
      return true
    end
    page = fetch_page(nil)
    return false if page == nil
    @items = page.items
    @next_max_id = page.next_max_id
    @complete = page.items.empty? || page.next_max_id == nil
    true
  end

  def fetch_page(max_id)
    kind = @kind
    param = @param
    own_id = @record.account_id
    mastodon_request(@record) do |client|
      case kind
      when :home then client.home_timeline(max_id: max_id)
      when :notifications then client.notifications(max_id: max_id)
      when :mentions then client.notifications(max_id: max_id, types: ["mention"])
      when :local then client.public_timeline(local: true, max_id: max_id)
      when :public then client.public_timeline(max_id: max_id)
      when :hashtag then client.hashtag_timeline(param, max_id: max_id)
      when :account then client.account_statuses(param.id, max_id: max_id)
      when :own then client.account_statuses(own_id, max_id: max_id)
      when :bookmarks then client.bookmarks(max_id: max_id)
      when :favourites then client.favourites(max_id: max_id)
      end
    end
  end

  def can_load_more?
    !@complete && @next_max_id != nil && @loading != true
  end

  def load_more
    @loading = true
    page = fetch_page(@next_max_id)
    if page == nil
      @complete = true
      return
    end
    known = @items.map(&:id)
    fresh = page.items.reject { |item| known.include?(item.id) }
    @complete = fresh.empty? || page.next_max_id == nil
    @next_max_id = page.next_max_id
    return if fresh.empty?
    index = @sel.index
    @items.concat(fresh)
    @sel.options = item_options
    @sel.index = index
    configure_audio
  ensure
    @loading = false
  end

  def reload
    @items = nil
    @next_max_id = nil
    @complete = false
    return if !load_initial
    @sel.options = item_options
    @sel.index = [[@index || 0, @items.size - 1].min, 0].max
    configure_audio
    @sel.focus
  end

  def mark_read
    Klangten::Mastodon::Service.mark_mentions_read
    $main_notifications_changed = true
    Session.notifications_update
  end

  def item_status(item)
    item.is_a?(Klangten::Mastodon::Notification) ? item.status : item
  end

  def item_options
    @items.map { |item| item.is_a?(Klangten::Mastodon::Notification) ? notification_speech(item) : mastodon_status_speech(item) }
  end

  def configure_audio
    configure_feed_list_audio(@sel, @items.map { |item| item_status(item) })
  end

  def notification_speech(notification)
    user = notification.account.name
    text = case notification.type
    when "mention" then p_("Mastodon", "%{user} mentioned you") % { user: user }
    when "status" then p_("Mastodon", "%{user} published a post") % { user: user }
    when "reblog" then p_("Mastodon", "%{user} boosted your post") % { user: user }
    when "favourite" then p_("Mastodon", "%{user} added your post to favourites") % { user: user }
    when "follow" then p_("Mastodon", "%{user} follows you now") % { user: user }
    when "follow_request" then p_("Mastodon", "%{user} asks to follow you") % { user: user }
    when "poll" then p_("Mastodon", "A poll has ended")
    when "update" then p_("Mastodon", "%{user} edited a post") % { user: user }
    else "#{user}: #{notification.type}"
    end
    text += ": " + mastodon_status_body(notification.status, full: false) if notification.status != nil
    text += " " + format_date(notification.created_at) if notification.created_at != nil
    text
  end

  def activate(item)
    status = item_status(item)
    if status != nil
      mastodon_show_status(status)
    elsif item.is_a?(Klangten::Mastodon::Notification)
      mastodon_show_account(item.account)
    end
  end

  def context(menu)
    if @items.size > 0
      item = @items[@sel.index]
      status = item_status(item)
      mastodon_status_menu(menu, status, show_thread: !(@kind == :thread && status.target.id == thread_root_id)) if status != nil
      if item.is_a?(Klangten::Mastodon::Notification) && (status == nil || item.account.id != status.target.account.id)
        menu.option(p_("Mastodon", "Profile of %{user}") % { user: item.account.name }) { mastodon_show_account(item.account) }
      end
    end
    menu.option(p_("Mastodon", "Load older entries"), nil, "o") { load_more } if can_load_more?
    menu.option(_("Refresh")) { reload }
    mastodon_general_menu(menu)
  end
end
