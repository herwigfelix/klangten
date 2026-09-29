# A part of Klangten, a fork of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2020 Dawid Pieper (Scene_WhatsNew in Elten 2)
# Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.
#
# The classic "What's new" overview of Elten 2, brought back for Klangten:
# one fixed list of categories with a counter each (new messages, new posts
# in followed threads, mentions, ...), categories without news greyed out,
# Enter opens the matching view. Elten 2 read the counters from its "agent"
# call; Klangten counts the active notifications per category, so both
# views always agree. The grouped notifications stay available next to it
# (main screen, notification history).

class Scene_WhatsNew
  include NotificationGroups

  # [notification categories, label, opener]
  def self.categories
    [
      [["message"], p_("WhatsNew", "New messages"), :messages],
      [["followedthread"], p_("WhatsNew", "New posts in followed threads"), :forum_followed_threads],
      [["followedblog"], p_("WhatsNew", "New posts on the followed blogs"), :blog_followed_blogs],
      [["blogcomment"], p_("WhatsNew", "New comments on your blog"), :blog_comments],
      [["followedforum"], p_("WhatsNew", "New threads on followed forums"), :forum_new_threads],
      [["followedforumpost"], p_("WhatsNew", "New posts on followed forums"), :forum_followed_forums],
      [["friend"], p_("WhatsNew", "New friends"), :friends],
      [["birthday"], p_("WhatsNew", "Friends' birthday"), :birthdays],
      [["mention"], p_("WhatsNew", "Mentions"), :forum_mentions],
      [["followedblogpost"], p_("WhatsNew", "New comments to followed blog posts"), :blog_followed_posts],
      [["blogfollower"], p_("WhatsNew", "New blog followers"), :blog_followers],
      [["blogmention"], p_("WhatsNew", "Blog mentions"), :blog_mentions],
      [["groupinvitation"], p_("WhatsNew", "Awaiting group invitations"), :group_invitations],
      [["update", "program_updates"], p_("WhatsNew", "Updates available"), :notifications],
      [nil, p_("WhatsNew", "Other notifications"), :notifications],
    ]
  end

  # The scene, or nil when there is nothing new (quick action and start-up).
  def self.whatsnew
    scene = new
    scene.prepare ? scene : nil
  end

  def initialize(quiet=false)
    @quiet = quiet
    @index = nil
  end

  # Counts the active notifications per category. true = something is new.
  def prepare
    @notifications = EltenAPI::NotificationService.active_notifications.to_a.reject { |n| n.revoked }
    known = self.class.categories.map { |c| c[0] }.compact.flatten
    @counts = self.class.categories.map do |cats, _label, _opener|
      if cats == nil
        @notifications.count { |n| !known.include?(n.cat.to_s) }
      else
        @notifications.count { |n| cats.include?(n.cat.to_s) }
      end
    end
    @counts.any? { |c| c > 0 }
  end

  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests")) if @quiet != true
      $scene = Scene_Main.new
      return
    end
    if !prepare
      alert(p_("WhatsNew", "There is nothing new.")) if @quiet != true
      $scene = Scene_Main.new
      return
    end
    cats = self.class.categories
    first = @counts.index { |c| c > 0 } || 0
    index = (@index != nil && @counts[@index].to_i > 0) ? @index : first
    @sel = ListBox.new(cats.each_with_index.map { |c, i| "#{c[1]} (#{@counts[i]})" },
                       header: p_("WhatsNew", "What's new"), index: index, quiet: false)
    # Greyed-out items are hidden in Elten 3: only categories with news remain.
    cats.each_index { |i| @sel.disable_item(i) if @counts[i] <= 0 }
    @sel.focus
    loop do
      loop_update
      @sel.update
      # Elten 3 keys (Elten 2's escape/enter/arrow_right helpers are gone).
      if key_pressed?(:key_escape) || @sel.collapsed?
        $scene = Scene_Main.new
      elsif @sel.selected? || @sel.expanded?
        @index = @sel.index
        open_category(@sel.index)
      end
      break if $scene != self
    end
  end

  private

  # Opens the view for a category and marks its notifications as read — the
  # counters come from them, and they would otherwise stay up forever.
  def open_category(index)
    cats, _label, opener = self.class.categories[index]
    return if @counts[index].to_i <= 0

    back = Scene_WhatsNew.new
    # Only the views that return through whatsnew_return_scene need the mark.
    $whatsnew_origin = [:messages, :blog_followed_blogs, :blog_comments, :blog_followed_posts, :blog_mentions].include?(opener)
    case opener
    when :messages
      $scene = Scene_Messages.new(true)
    when :forum_followed_threads
      $scene = Scene_Forum.new(0, -2, return_scene: back)
    when :forum_new_threads
      $scene = Scene_Forum.new(0, -4, return_scene: back)
    when :forum_followed_forums
      $scene = Scene_Forum.new(0, -6, return_scene: back)
    when :forum_mentions
      $scene = Scene_Forum.new(0, -7, return_scene: back)
    when :group_invitations
      $scene = Scene_Forum.new(nil, nil, 4, return_scene: back)
    when :blog_followed_blogs
      $scene = Scene_Blog_Posts.new(Session.name, "NEWFOLLOWEDBLOGS")
    when :blog_comments
      $scene = Scene_Blog_Posts.new(Session.name, "NEW")
    when :blog_followed_posts
      $scene = Scene_Blog_Posts.new(Session.name, "NEWFOLLOWED")
    when :blog_mentions
      $scene = Scene_Blog_Posts.new(Session.name, "NEWMENTIONED")
    when :blog_followers
      $scene = Scene_Blog_Followers.new(nil, back)
    when :friends
      $scene = Scene_Users_AddedMeToContacts.new(true, back)
    when :birthdays
      $scene = Scene_Contacts.new(1)
    else
      # Updates and everything without a view of its own: the notifications.
      scene = Scene_Notifications.whatsnew
      $scene = scene || Scene_Main.new
      return
    end
    ids = @notifications.select { |n| cats.to_a.include?(n.cat.to_s) }.map { |n| n.id.to_i }.select(&:positive?)
    revoke_ids(ids)
  end

  def revoke_ids(ids)
    return if ids.empty?

    EltenLink::Notifications.revoke_many(elten_link, ids)
    EltenAPI::NotificationService.revoke_active_notifications(ids)
    $main_notifications_changed = true
    Session.notifications_update if defined?(Session)
  rescue EltenLink::Error => e
    Log.warning("What's new: revoking notifications failed: #{e.message}")
  end
end

# Where the "new ..." views (new messages, new blog comments, ...) return to:
# "What's new" when they were opened from there, otherwise the notifications
# as in Elten 3.
def whatsnew_return_scene
  if $whatsnew_origin == true
    $whatsnew_origin = false
    return Scene_WhatsNew.new
  end
  Scene_Notifications.new
end
