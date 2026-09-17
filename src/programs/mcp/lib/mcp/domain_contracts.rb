# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: notes contracts replace organizer; calendars, tasks, feed and sponsor wording removed.

module EltenMCP
  module DomainContracts
    Action = Struct.new(:title, :description, :required, :optional, keyword_init: true)

    GROUP_MEMBERSHIPS = {
      0 => "not_a_member", 1 => "member", 2 => "moderator",
      3 => "banned", 4 => "membership_requested", 5 => "invited"
    }.freeze
    PROFILE_GENDERS = { -1 => "unspecified", 0 => "female", 1 => "male" }.freeze
    FORUM_CONTENT_FORMATS = { 0 => "plain_text", 1 => "markdown" }.freeze
    FORUM_CONTENT_MODES = { 0 => "text", 1 => "voice", 2 => "mixed" }.freeze
    REPORT_STATUSES = { 0 => "unresolved", 1 => "accepted", 2 => "rejected" }.freeze
    REPORT_STATUS_INPUT = { "rejected" => 2, "accepted" => 1 }.freeze
    MEMBER_ACTIONS = {
      "grant_moderator" => "moderationgrant",
      "remove_moderator" => "moderationdeny",
      "resign_moderator" => "moderationresign",
      "transfer_ownership" => "passadmin",
      "set_role_inheritance" => "inherit",
      "ban" => "ban", "remove" => "kick", "unban" => "unban",
      "accept_membership_request" => "accept",
      "reject_membership_request" => "refuse",
      "cancel_invitation" => "cancel"
    }.freeze
    NOTIFICATION_CATEGORIES = {
      "message" => "private_messages",
      "followedthread" => "followed_threads",
      "followedforum" => "followed_forums",
      "followedforumpost" => "followed_forums",
      "mention" => "forum_mentions",
      "friend" => "contacts",
      "birthday" => "birthdays",
      "followedblog" => "followed_blogs",
      "blogcomment" => "blog_comments",
      "followedblogpost" => "followed_blog_posts",
      "blogfollower" => "blog_followers",
      "blogmention" => "blog_mentions",
      "groupinvitation" => "forum_group_invitations",
      "mtr" => "online_monitors",
      "program_updates" => "program_updates",
      "update" => "elten_updates",
      "app" => "application"
    }.freeze
    BLOG_SORTS = {
      "recently_updated" => nil,
      "frequently_updated" => 1,
      "frequently_commented" => 2,
      "followed" => 3,
      "popular_with_contacts" => 4
    }.freeze
    BLOG_COMMENT_STATUSES = {
      "pending" => "hold", "spam" => "spam", "approved" => "approve"
    }.freeze

    ACTIONS = {
      :account => {
        "profile" => ["Read public profile", "Returns the user's full name, named gender, birth date, location and profile visibility.", [], %w[user]],
        "visiting_card" => ["Read visiting card", "Returns the free-form visiting-card text for one user.", [], %w[user]],
        "status" => ["Read status", "Returns status text together with online state.", [], %w[user]],
        "signature" => ["Read forum signature", "Returns the signature displayed below this user's forum posts.", [], %w[user]],
        "user_info" => ["Read public account summary", "Returns named public activity, relationship and availability fields; no positional values.", [], %w[user]],
        "contacts" => ["List contacts", "Lists usernames in the signed-in user's contacts.", [], []],
        "birthday_contacts" => ["List birthday contacts", "Lists contacts for whom Klangten currently has a birthday notice.", [], []],
        "contacts_added_me" => ["List people who added me", "Lists users who added the signed-in user to contacts.", [], %w[only_unacknowledged]],
        "search" => ["Search users", "Case-insensitive server user search. Use the returned exact username in later calls.", %w[query], []],
        "online" => ["List currently online users", "Lists users currently reported online by Elten.", [], []],
        "exists" => ["Check user existence", "Checks whether an exact Klango username exists.", %w[user], []],
        "banned" => ["Check global ban state", "Checks whether an exact user is globally banned.", %w[user], []],
        "recently_registered" => ["List newly registered users", "Lists the newest accounts, newest first.", [], %w[limit]],
        "recently_active" => ["List recently active users", "Lists users active during approximately the last 24 hours.", [], []],
        "honors" => ["Read user honors", "Returns honors with the awarded level already resolved to its name.", [], %w[user]],
        "honor_users" => ["List recipients of an honor", "Returns recipients and resolves every numeric level to the honor's named level.", %w[honor_id], []],
        "update_profile" => ["Update my profile", "Updates only supplied fields of the signed-in user's public profile.", [], %w[full_name gender birthdate location visible_to_others]],
        "update_visiting_card" => ["Update my visiting card", "Replaces the signed-in user's visiting-card text.", %w[text], []],
        "update_status" => ["Update my status", "Replaces the signed-in user's status text; an empty string clears it.", %w[text], []],
        "update_signature" => ["Update my forum signature", "Replaces the signed-in user's forum signature; an empty string clears it.", %w[text], []],
        "add_contact" => ["Add contact", "Adds one exact username to contacts.", %w[user], []],
        "remove_contact" => ["Remove contact", "Removes one exact username from contacts.", %w[user], []],
        "acknowledge_birthdays" => ["Acknowledge birthday notices", "Marks current birthday-contact notices as seen.", [], []],
        "acknowledge_added_me" => ["Acknowledge contact notices", "Marks current 'added me to contacts' notices as seen.", [], []],
        "set_main_honor" => ["Select main honor", "Selects one of the signed-in user's honors as the main honor.", %w[honor_id], []],
        "add_online_monitor" => ["Add online monitor", "Requests online-state notifications for one user.", %w[user permanent], []],
        "remove_online_monitor" => ["Remove online monitor", "Stops online-state notifications for one user.", %w[user], []]
      },
      :forum => {
        "structure" => ["Read forum structure", "Returns groups containing their forums and threads, with named membership/access states and unread counts.", [], []],
        "thread" => ["Read a thread", "Returns thread metadata and posts. This can mark unread posts as read and therefore requires acknowledgement.", %w[thread_id acknowledge_read_state], []],
        "search" => ["Search the forum", "Searches post content, post authors or thread titles and returns resolved group/forum/thread names, not bare IDs.", %w[query], %w[search_in include_audio_transcriptions]],
        "user_posts" => ["List a user's posts", "Returns a page of posts by an exact username. Pass next_before from the prior response to continue.", %w[user], %w[before limit]],
        "popular_threads" => ["List popular threads", "Returns full thread references for currently popular threads.", [], []],
        "posted_in_threads" => ["Check authored threads", "Checks in one request whether the signed-in user has posted in each supplied thread.", %w[thread_ids], []],
        "thread_stats" => ["Read thread statistics", "Returns named follower, author and reader-completion counts.", %w[thread_id], []],
        "post_likes" => ["List users who liked a post", "Returns exact usernames for one post.", %w[post_id], []],
        "original_post" => ["Read original post text", "Returns the original unedited text for one post.", %w[post_id], []],
        "bookmarks" => ["List forum bookmarks", "Lists all bookmarks or only bookmarks for one thread.", [], %w[thread_id]],
        "mentions" => ["List forum mentions", "Lists unread mentions by default; include_seen=true includes history.", [], %w[include_seen]],
        "tags" => ["List forum tags", "Lists tags defined for one forum.", %w[forum_id], []],
        "group_members" => ["List group members", "Returns named roles such as member, moderator, banned, invited or membership_requested.", %w[group_id], []],
        "group_activity" => ["List most active group members", "Returns usernames ordered by group activity.", %w[group_id], []],
        "group_storage" => ["Read group storage usage", "Returns audio, attachment and text usage in bytes with a combined total.", %w[group_id], []],
        "group_motd" => ["Read group message of the day", "Returns the group's message of the day.", %w[group_id], []],
        "group_regulations" => ["Read group regulations", "Returns the group's regulations.", %w[group_id], []],
        "create_group" => ["Create forum group", "Creates a group using named visibility and join policy; the program derives the server's public/open flags.", %w[name description language visibility join_policy], []],
        "create_thread" => ["Create thread", "Creates a text thread in one forum and returns its new ID.", %w[forum_id name text], %w[follow poll_ids content_format]],
        "create_post" => ["Reply to thread", "Creates a text reply in one thread and returns its new ID.", %w[thread_id text], %w[content_format]],
        "edit_post" => ["Edit post", "Replaces the text and format of one post, subject to server ownership/moderation rules.", %w[post_id text], %w[content_format]],
        "delete_post" => ["Delete own post", "Deletes one post using ordinary author permissions. Moderators should batch moderation instead.", %w[post_id], []],
        "follow_thread" => ["Follow thread", "Enables notifications for updates to one thread.", %w[thread_id], []],
        "unfollow_thread" => ["Unfollow thread", "Disables notifications for updates to one thread.", %w[thread_id], []],
        "follow_forum" => ["Follow forum", "Enables notifications for updates to one forum.", %w[forum_id], []],
        "unfollow_forum" => ["Unfollow forum", "Disables notifications for updates to one forum.", %w[forum_id], []],
        "join_group" => ["Join or request group membership", "Joins an open group or submits a request when the group is moderated.", %w[group_id], []],
        "leave_group" => ["Leave or decline group", "Leaves membership, withdraws a request or declines an invitation as allowed by the server.", %w[group_id], []],
        "mark_thread_read" => ["Mark thread read", "Marks every current post in one thread as read.", %w[thread_id], []],
        "mark_forum_read" => ["Mark forum read", "Marks every current post in one forum as read.", %w[forum_id], []],
        "mark_group_read" => ["Mark group read", "Marks every current post in one group as read.", %w[group_id], []],
        "set_thread_bookmarked" => ["Set thread marked state", "Sets or clears Klangten's personal marked-thread state.", %w[thread_id bookmarked], []],
        "like_post" => ["Like post", "Adds the signed-in user's like to one post.", %w[post_id], []],
        "unlike_post" => ["Unlike post", "Removes the signed-in user's like from one post.", %w[post_id], []],
        "create_bookmark" => ["Create forum bookmark", "Bookmarks a specific post in a thread with an optional description.", %w[thread_id post_id], %w[description]],
        "delete_bookmark" => ["Delete forum bookmark", "Deletes one personal forum bookmark.", %w[bookmark_id], []],
        "create_mentions" => ["Mention users", "Creates mentions for several users pointing to one existing post.", %w[users thread_id post_id], %w[message]],
        "acknowledge_mention" => ["Acknowledge mention", "Marks one forum mention as seen.", %w[mention_id], []],
        "report_post" => ["Report post", "Submits one post to its group moderators with an optional comment and a semantic suggested moderation action.", %w[post_id], %w[comment suggestion]],
        "reports" => ["Read moderation reports", "Returns reports with status unresolved, rejected or accepted and resolved thread names where available.", %w[group_id], []],
        "trash_threads" => ["List trashed threads", "Lists trashed threads and threads containing trashed posts for one moderated group.", %w[group_id], []],
        "trash_thread" => ["Read trashed thread", "Returns recoverable posts and the thread/forum trash state for one thread.", %w[thread_id], []],
        "moderator_log" => ["Read moderator log", "Returns humanized moderation events with named source/target objects and content changes.", %w[group_id], []],
        "group_configuration" => ["Read group configuration", "Returns only known settings translated to named booleans, visibility, report policy and featured-thread roles; unknown server fields are discarded.", %w[group_id], []]
      },
      :messages => {
        "participants" => ["List message participants", "Lists people and groups with last-message summaries and unread state.", [], %w[limit]],
        "conversations" => ["List conversations with participant", "Lists subjects exchanged with one user or group.", %w[user], %w[limit]],
        "messages" => ["Read a conversation", "Returns messages for one participant and optional exact subject. Reading can change unread state.", %w[user acknowledge_read_state], %w[subject limit]],
        "flagged" => ["List flagged messages", "Returns messages personally flagged by the signed-in user.", [], []],
        "search" => ["Search private messages", "Searches private-message text and returns complete, named message objects.", %w[query], []],
        "group_members" => ["List private-message group members", "Returns exact usernames in one message group.", %w[group_id], []],
        "send" => ["Send private message", "Sends text and optional poll links; local-file attachments are deliberately unsupported.", %w[to text], %w[subject poll_ids]],
        "forward" => ["Forward private message", "Forwards one existing message to a correspondent. Because the operation spans source and destination, it requires full messages/write rather than a selective correspondent grant.", %w[message_id to], []],
        "mark_all_read" => ["Mark private messages read", "Marks all messages read globally or for one participant.", [], %w[user]],
        "set_flagged" => ["Set message flagged state", "Sets or clears the signed-in user's flag on one message.", %w[message_id flagged], []],
        "set_deletion_protected" => ["Protect message from deletion", "Sets or clears personal deletion protection on one message.", %w[message_id deletion_protected], []],
        "delete_message" => ["Delete private message", "Deletes one message, unless protected or rejected by the server.", %w[message_id], []],
        "delete_conversation" => ["Delete conversation", "Deletes messages for one participant and exact subject.", %w[user subject], []],
        "remove_participant" => ["Remove participant history", "Removes one participant from the message list using Klangten's conversation deletion rules.", %w[user], []],
        "create_group" => ["Create message group", "Creates a named private-message group with initial members.", %w[name users], []],
        "update_group" => ["Update message group", "Renames a group and optionally adds members. The name is required because Klangten's update contract always replaces it.", %w[group_id name], %w[add_users]],
        "leave_group" => ["Leave message group", "Removes the signed-in user from one private-message group.", %w[group_id], []],
        "mute_group" => ["Mute message group", "Mutes group notifications for duration_seconds; zero means no automatic expiry.", %w[group_id duration_seconds], []],
        "unmute_group" => ["Unmute message group", "Restores notifications for one message group.", %w[group_id], []]
      },
      :blogs => {
        "list" => ["List blogs", "Lists blogs by owner or by a named ranking. sort_by defaults to recently_updated.", [], %w[owner sort_by]],
        "exists" => ["Check blog existence", "Checks an exact Klangten blog identifier.", [], %w[blog]],
        "details" => ["Read blog details", "Returns a blog's display name, description, public URL and library state.", [], %w[blog]],
        "categories" => ["List blog categories", "Returns categories with parent IDs normalized to null when absent.", [], %w[blog]],
        "posts" => ["List blog posts", "Lists post summaries; use page from 1 upward and query for server-side text search.", [], %w[blog category_id page query]],
        "post" => ["Read blog post", "Returns post/comment entries as plain readable text. Opening can update unread state.", %w[post_id acknowledge_read_state], %w[blog]],
        "managed" => ["List managed blogs", "Lists blogs owned or co-managed by the signed-in user.", [], []],
        "mentions" => ["List blog mentions", "Lists unread mentions by default; include_seen=true includes history.", [], %w[include_seen]],
        "post_details" => ["Read editable post details", "Returns title, content, excerpt, categories, tags, visibility and comment state for editing.", %w[post_id], %w[blog]],
        "comments" => ["List comments for moderation", "Lists pending, spam or approved comments using a named status.", [], %w[blog comment_status]],
        "followers" => ["List blog followers", "Lists followers of one blog.", [], %w[blog]],
        "new_followers" => ["List new blog followers", "Lists follower notices not yet handled by the signed-in user.", [], []],
        "followed_posts" => ["List followed blog posts", "Lists blog/post references followed by the signed-in user.", [], []],
        "post_followed" => ["Check post follow state", "Checks whether one blog post is followed by the signed-in user.", %w[post_id], %w[blog]],
        "library" => ["List blog library", "Lists public library entries with language and description.", [], []],
        "tags" => ["List blog tags", "Lists tags defined for one blog.", [], %w[blog]],
        "owners" => ["List blog owners", "Lists owners and coworkers for one blog.", [], %w[blog]],
        "create_blog" => ["Create blog", "Creates a personal or shared Klangten blog and returns its identifier.", %w[name], %w[shared description]],
        "delete_blog" => ["Delete blog", "Permanently deletes a blog and its posts.", [], %w[blog]],
        "create_post" => ["Create blog post", "Creates a post and returns its ID.", %w[title], %w[blog content excerpt category_ids tag_ids visibility comments_enabled publish_at]],
        "update_post" => ["Update blog post", "Updates only supplied post fields.", %w[post_id], %w[blog title content excerpt category_ids tag_ids visibility comments_enabled publish_at]],
        "delete_post" => ["Delete blog post", "Permanently deletes one blog post.", %w[post_id], %w[blog]],
        "create_comment" => ["Comment on blog post", "Adds one text comment to a post.", %w[post_id content], %w[blog]],
        "follow" => ["Follow blog", "Follows one blog.", [], %w[blog]],
        "unfollow" => ["Unfollow blog", "Stops following one blog.", [], %w[blog]],
        "mark_read" => ["Mark blog read", "Marks all current posts in one blog as read.", [], %w[blog]],
        "follow_post" => ["Follow blog post", "Follows one post for updates.", %w[post_id], %w[blog]],
        "unfollow_post" => ["Unfollow blog post", "Stops following one post.", %w[post_id], %w[blog]],
        "create_category" => ["Create blog category", "Creates a category and returns its ID.", %w[name], %w[blog]],
        "rename_category" => ["Rename blog category", "Renames one category.", %w[category_id name], %w[blog]],
        "delete_category" => ["Delete blog category", "Deletes one category.", %w[category_id], %w[blog]],
        "create_tag" => ["Create blog tag", "Creates a tag and returns its ID.", %w[name], %w[blog]],
        "delete_tag" => ["Delete blog tag", "Deletes one tag.", %w[tag_id], %w[blog]],
        "set_comment_status" => ["Moderate blog comment", "Sets a comment to pending, approved or spam.", %w[comment_id comment_status], %w[blog]],
        "delete_comment" => ["Delete blog comment", "Permanently deletes one comment.", %w[comment_id], %w[blog]],
        "add_coworker" => ["Add blog coworker", "Adds one exact username as a coworker.", %w[user], %w[blog]],
        "remove_coworker" => ["Remove blog coworker", "Removes one coworker.", %w[user], %w[blog]],
        "leave_coworkers" => ["Leave shared blog", "Removes the signed-in user from a shared blog.", [], %w[blog]],
        "send_mentions" => ["Mention users in blog post", "Creates mentions for several users pointing to one existing post.", %w[users post_id], %w[blog message]],
        "acknowledge_mention" => ["Acknowledge blog mention", "Marks one blog mention as seen.", %w[mention_id], []]
      },
      :notifications => {
        "list" => ["List notifications", "Returns readable notification text, normalized category and state. Installed application notifications add only mapped program name, title and body; opaque payload, application UUID, action and sound routing are discarded.", [], %w[include_history]],
        "mark_read" => ["Mark notifications read", "Marks several notification IDs read in one server request.", %w[notification_ids], []],
        "mark_all_read" => ["Mark all notifications read", "Marks all current notifications read in one server request.", [], []]
      },
      :notes => {
        "notes" => ["List notes", "Returns note titles, text, authors and timestamps.", [], []],
        "note" => ["Read one note", "Returns exactly one note selected by its ID. Prefer this action with selective note access.", %w[note_id], []],
        "note_shares" => ["List note shares", "Lists users who can access one note.", %w[note_id], []],
        "note_create" => ["Create note", "Creates a private note.", %w[name text], []],
        "note_update" => ["Update note text", "Replaces one note's text.", %w[note_id text], []],
        "note_rename" => ["Rename note", "Changes one note's title.", %w[note_id name], []],
        "note_delete" => ["Delete note", "Permanently deletes one note.", %w[note_id], []],
        "note_share_add" => ["Share note", "Shares one note with an exact username.", %w[note_id user], []],
        "note_share_delete" => ["Remove note share", "Removes one user's note access.", %w[note_id user], []]
      },
      :polls => {
        "list" => ["List polls", "Lists polls with readable summary fields. Optional filters are author, language and text query.", [], %w[author language query limit]],
        "get" => ["Read poll", "Returns indexed questions with kind, option indexes and maximum selections.", %w[poll_id], []],
        "results" => ["Read poll results", "Returns named questions, option text, counts, percentages and text answers; no encoded answer lines.", %w[poll_id], []],
        "voted" => ["Check my vote state", "Checks whether the signed-in user has answered one poll.", %w[poll_id], []],
        "by_me" => ["List polls created by me", "Lists polls authored by the signed-in user.", [], []],
        "answer" => ["Answer poll", "Accepts structured answers keyed by question_index. Read the poll first and use returned option_index values.", %w[poll_id answers], []],
        "create" => ["Create poll", "Accepts structured question objects; no positional arrays or numeric question types.", %w[name language questions], %w[description hidden expires_at hide_results_until_expiry]],
        "delete" => ["Delete poll", "Permanently deletes one poll created by the signed-in user.", %w[poll_id], []]
      },
      :settings => {
        "list" => ["List changeable settings", "Returns every allowed setting with label, explanation, type, current value, choices/range and restart advice.", [], []]
      }
    }.freeze

    class << self
      def action(domain, name)
        value = (ACTIONS[domain.to_sym] || {})[name.to_s]
        return nil if value == nil
        Action.new(:title => value[0], :description => value[1], :required => value[2], :optional => value[3])
      end

      def describe(domain, actions)
        Array(actions).map do |name|
          spec = action(domain, name)
          spec == nil ? nil : "#{name}: #{spec.description}"
        end.compact.join("\n")
      end

      def membership(value)
        raise ToolError, "Invalid forum membership state" if !value.is_a?(Integer)
        GROUP_MEMBERSHIPS.fetch(value) { raise ToolError, "Unknown forum membership state" }
      end

      def profile_gender(value)
        raise ToolError, "Invalid profile gender" if !value.is_a?(Integer)
        PROFILE_GENDERS.fetch(value) { raise ToolError, "Unknown profile gender value" }
      end

      def forum_format(value)
        raise ToolError, "Invalid forum content format" if !value.is_a?(Integer)
        FORUM_CONTENT_FORMATS.fetch(value) { raise ToolError, "Unknown forum content format" }
      end

      def forum_content_mode(value)
        raise ToolError, "Invalid forum content mode" if !value.is_a?(Integer)
        FORUM_CONTENT_MODES.fetch(value) { raise ToolError, "Unknown forum content mode" }
      end

      def report_status(value, solved = true)
        return "unresolved" if solved != true
        raise ToolError, "Invalid forum report status" if !value.is_a?(Integer)
        REPORT_STATUSES.fetch(value) { raise ToolError, "Unknown forum report status" }
      end

      def poll_kind(value)
        raise ToolError, "Invalid poll question type" if !value.is_a?(Integer)
        number = value
        return ["single_choice", 1] if number == 0
        return ["multiple_choice", nil] if number == 1
        return ["text", nil] if number == 2
        return ["multiple_choice", -number] if number < -1
        raise ToolError, "Unknown poll question type"
      end
    end
  end
end
