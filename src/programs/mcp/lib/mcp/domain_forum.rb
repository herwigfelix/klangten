# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  module DomainForum
    FORUM_READ_WARNING = "Opening a thread containing unread posts marks it as read in Elten. Ask the user first when preserving unread state matters, then retry with acknowledge_read_state=true.".freeze
    FORUM_CONTENT_MODE_INPUT = { "text" => 0, "voice" => 1, "mixed" => 2 }.freeze
    FORUM_REPORT_VISIBILITY_INPUT = {
      "disabled" => 0, "report_author_only" => 1,
      "accepted_reports" => 2, "all_reports" => 3
    }.freeze
    REPORT_SUGGESTION_RANGE_LIMIT = 4_096
    FORUM_MODERATION_ACTIONS = %w[
      move_threads delete_threads purge_threads offer_threads move_posts delete_posts purge_posts
      set_threads_closed set_threads_pinned set_posts_locked resolve_reports update_members
      rename_thread accept_thread_offer refuse_thread_offers reorder_post
      create_forum_tag create_group update_group_motd update_group_regulations
      update_group_profile create_forum update_forum set_forums_closed move_forum
      restore_threads restore_posts delete_forum_tag invite_users delete_group delete_forum
    ].freeze
    WRITABLE_GROUP_PROFILE_KEYS = %w[name description lang].freeze

    def register_forum_tools
      register_domain_tool(
        "forum_scope", "List selectable forum permission scopes",
        "Discovery protected by the minimal forum/scope level. Return the visible hierarchy of groups, forums and threads with names and IDs, but never post content. Request forum/scope first, analyze the result, then make one bulk selective request or request the necessary full forum level.",
        :forum, :scope,
        { "type" => "object", "properties" => {}, "additionalProperties" => false }
      ) { |_args| forum_scope_list(network_client) }

      register_domain_tool(
        "forum_read", "Read forum",
        "Read a nested, human-readable forum model. Group membership, content formats, report states and unread counts are named. Search results resolve all group/forum/thread names instead of returning bare IDs.",
        :forum, :read,
        action_schema(%w[structure thread search user_posts popular_threads posted_in_threads thread_stats post_likes original_post bookmarks mentions tags group_members group_activity group_storage group_motd group_regulations], :forum),
        mutating_annotations
      ) do |args|
        if args["action"] == "thread" && args["acknowledge_read_state"] != true
          next confirmation_required("thread", FORUM_READ_WARNING)
        end
        client = network_client
        case args["action"]
        when "structure" then forum_structure(client)
        when "thread"
          thread_id = positive_id(args, "thread_id")
          structure = forum_structure_value(client)
          thread = structure.threads.find { |item| known(item, :forum_thread)["thread_id"] == thread_id }
          raise InvalidParamsError, "No visible forum thread with id #{thread_id}" if thread == nil
          raw_page = EltenLink::Forum.thread(client, :thread_id => thread_id)
          @authorization.remember_forum_posts(thread_id, raw_page.posts)
          page = known(raw_page, :forum_thread_page)
          response("thread", "Returned #{page["returned_post_count"]} posts from '#{thread.name}'. Its unread state may now be updated in Elten.",
            "thread" => forum_thread_context(thread), "page" => page, "read_state_effect" => FORUM_READ_WARNING)
        when "search"
          forum_search(client, args)
        when "user_posts"
          user = required_string(args, "user")
          page = EltenLink::Forum.user_posts(client, :user => required_string(args, "user"), :before => args["before"], :limit => bounded(args["limit"], 1, 200, 50))
          mapped = known(page, :forum_user_posts_page)
          threads = forum_structure_value(client).threads.each_with_object({}) do |thread, index|
            index[known(thread, :forum_thread)["thread_id"]] = thread
          end
          mapped["posts"].each { |post| post["thread"] = forum_thread_context(threads[post["thread_id"]]) if threads[post["thread_id"]] != nil }
          response("user_posts", "Returned #{mapped["returned_count"]} posts by #{user}. Use next_before to continue when more_available is true.",
            { "user" => user }.merge(mapped))
        when "popular_threads"
          ids = integer_array(EltenLink::Forum.popular_threads(client))
          threads = forum_structure_value(client).threads.each_with_object({}) do |thread, index|
            index[known(thread, :forum_thread)["thread_id"]] = thread
          end
          values = ids.map { |id| threads[id] }.compact.map { |thread| forum_thread_context(thread) }
          response("popular_threads", "Returned #{values.size} currently popular threads.", "threads" => values, "count" => values.size)
        when "posted_in_threads"
          ids = positive_ids(required_array(args, "thread_ids", 500))
          statuses = EltenLink::Forum.posted_in_threads(client, :threads => ids)
          raise ToolError, "Unexpected authored-thread status contract" if !statuses.is_a?(Hash)
          values = ids.map do |id|
            state = statuses[id]
            raise ToolError, "Missing authored-thread status for #{id}" if state != true && state != false
            result("thread_id" => id, "posted_by_me" => state)
          end
          response("posted_in_threads", "Checked authored state for #{values.size} threads in one request.", "threads" => values, "count" => values.size)
        when "thread_stats"
          id = positive_id(args, "thread_id")
          response("thread_stats", "Returned reading and engagement statistics for thread #{id}.", "thread_id" => id,
            "statistics" => known(EltenLink::Forum.thread_stats(client, :thread_id => id), :forum_thread_stats))
        when "post_likes"
          id = positive_id(args, "post_id")
          users = string_values(EltenLink::Forum.post_likes(client, :post_id => id))
          response("post_likes", "Returned #{users.size} users who liked post #{id}.", "post_id" => id, "users" => users, "count" => users.size)
        when "original_post"
          id = positive_id(args, "post_id")
          text = EltenLink::Forum.original_post(client, :post_id => id)
          raise ToolError, "Unexpected original post contract" if !text.is_a?(String)
          response("original_post", "Returned the original text of post #{id}.", "post_id" => id, "text" => text)
        when "bookmarks"
          thread_id = optional_id(args["thread_id"])
          bookmarks = known_list(EltenLink::Forum.list_bookmarks(client, :thread_id => thread_id), :forum_bookmark)
          response("bookmarks", "Returned #{bookmarks.size} forum bookmarks.", "thread_id" => thread_id, "bookmarks" => bookmarks, "count" => bookmarks.size)
        when "mentions"
          mentions = known_list(EltenLink::Forum.list_mentions(client, :all => args["include_seen"] == true), :forum_mention)
          response("mentions", "Returned #{mentions.size} forum mentions.", "mentions" => mentions, "count" => mentions.size, "includes_seen" => args["include_seen"] == true)
        when "tags"
          id = positive_id(args, "forum_id")
          tags = known_list(EltenLink::Forum.list_forum_tags(client, :forumid => id), :forum_tag)
          response("tags", "Returned #{tags.size} tags for forum #{id}.", "forum_id" => id, "tags" => tags, "count" => tags.size)
        when "group_members"
          id = positive_id(args, "group_id")
          members = known_list(EltenLink::Forum.group_members(client, :group_id => id), :forum_member)
          response("group_members", "Returned #{members.size} members with named roles for group #{id}.", "group_id" => id, "members" => members, "count" => members.size)
        when "group_activity"
          id = positive_id(args, "group_id")
          users = string_values(EltenLink::Forum.group_most_active_members(client, :group_id => id))
          response("group_activity", "Returned #{users.size} most active members of group #{id}.", "group_id" => id, "users" => users, "count" => users.size)
        when "group_storage"
          id = positive_id(args, "group_id")
          sizes = known(EltenLink::Forum.group_size(client, :group_id => id), :forum_group_size)
          response("group_storage", "Returned storage usage for group #{id}.", "group_id" => id,
            "usage_bytes" => sizes)
        when "group_motd", "group_regulations"
          id = positive_id(args, "group_id")
          text = args["action"] == "group_motd" ? EltenLink::Forum.group_motd(client, :group_id => id) : EltenLink::Forum.group_regulations(client, :group_id => id)
          raise ToolError, "Unexpected forum group text contract" if !text.is_a?(String)
          label = args["action"] == "group_motd" ? "message of the day" : "regulations"
          response(args["action"], "Returned the #{label} for group #{id}.", "group_id" => id, "text" => text)
        else invalid_action(args["action"])
        end
      end

      register_forum_write_tool
      register_forum_moderation_tools
    end

    private

    def register_forum_write_tool
      register_domain_tool(
        "forum_write", "Write to forum",
        "Create and manage ordinary forum content through named formats and states. Local-file attachments are not accepted. Server ownership/group rules still apply; use forum_moderate_batch for moderation.",
        :forum, :write,
        action_schema(%w[create_thread create_post edit_post delete_post follow_thread unfollow_thread follow_forum unfollow_forum join_group leave_group mark_thread_read mark_forum_read mark_group_read set_thread_bookmarked like_post unlike_post create_bookmark delete_bookmark create_mentions acknowledge_mention report_post], :forum),
        mutating_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "create_thread"
          forum_id = positive_id(args, "forum_id")
          name = required_string(args, "name")
          poll_ids = args.key?("poll_ids") ? positive_ids(args["poll_ids"]) : []
          id = EltenLink::Forum.create_thread(client, :forumid => forum_id, :name => name,
            :text => required_string(args, "text", true), :follow => args["follow"] == true,
            :polls => poll_ids, :attachments => [], :format => forum_content_format(args["content_format"]))
          id = server_integer(id, "created thread id", true)
          @authorization.remember_forum_thread(id, forum_id, name)
          completed("create_thread", "Created thread '#{name}' in forum #{forum_id}.", "forum_id" => forum_id, "thread_id" => id, "title" => name)
        when "create_post"
          thread_id = positive_id(args, "thread_id")
          id = EltenLink::Forum.create_post(client, :thread_id => thread_id, :text => required_string(args, "text", true),
            :attachments => [], :format => forum_content_format(args["content_format"]))
          id = server_integer(id, "created post id", true)
          @authorization.remember_forum_post(thread_id, id)
          completed("create_post", "Created post #{id} in thread #{thread_id}.", "thread_id" => thread_id, "post_id" => id)
        when "edit_post"
          post_id = positive_id(args, "post_id")
          EltenLink::Forum.edit_post(client, :post_id => post_id, :text => required_string(args, "text", true),
            :attachments => nil, :format => forum_content_format(args["content_format"]))
          completed("edit_post", "Updated post #{post_id}.", "post_id" => post_id, "content_format" => (args["content_format"] || "plain_text"))
        when "delete_post"
          post_id = positive_id(args, "post_id")
          EltenLink::Forum.delete_post(client, :post_id => post_id)
          completed("delete_post", "Deleted post #{post_id}.", "post_id" => post_id)
        when "follow_thread", "unfollow_thread"
          id = positive_id(args, "thread_id")
          state = args["action"] == "follow_thread"
          state ? EltenLink::Forum.follow_thread(client, :thread_id => id) : EltenLink::Forum.unfollow_thread(client, :thread_id => id)
          completed(args["action"], state ? "Now following thread #{id}." : "Stopped following thread #{id}.", "thread_id" => id, "is_followed" => state)
        when "follow_forum", "unfollow_forum"
          id = positive_id(args, "forum_id")
          state = args["action"] == "follow_forum"
          state ? EltenLink::Forum.follow_forum(client, :forumid => id) : EltenLink::Forum.unfollow_forum(client, :forumid => id)
          completed(args["action"], state ? "Now following forum #{id}." : "Stopped following forum #{id}.", "forum_id" => id, "is_followed" => state)
        when "join_group", "leave_group"
          id = positive_id(args, "group_id")
          args["action"] == "join_group" ? EltenLink::Forum.join_group(client, :group_id => id) : EltenLink::Forum.leave_group(client, :group_id => id)
          completed(args["action"], args["action"] == "join_group" ? "Submitted the applicable join action for group #{id}." : "Submitted the applicable leave/decline action for group #{id}.", "group_id" => id)
        when "mark_thread_read", "mark_forum_read", "mark_group_read"
          id_key = { "mark_thread_read" => "thread_id", "mark_forum_read" => "forum_id", "mark_group_read" => "group_id" }[args["action"]]
          id = positive_id(args, id_key)
          case args["action"]
          when "mark_thread_read" then EltenLink::Forum.mark_thread_as_read(client, :thread_id => id)
          when "mark_forum_read" then EltenLink::Forum.mark_forum_as_read(client, :forumid => id)
          when "mark_group_read" then EltenLink::Forum.mark_group_as_read(client, :group_id => id)
          end
          completed(args["action"], "Marked all current posts in #{id_key.sub("_id", "")} #{id} as read.", id_key => id)
        when "set_thread_bookmarked"
          id = positive_id(args, "thread_id")
          state = boolean_arg(args, "bookmarked")
          EltenLink::Forum.set_thread_marked(client, :thread_id => id, :marked => state)
          completed("set_thread_bookmarked", "Set thread #{id} bookmarked state to #{state}.", "thread_id" => id, "is_bookmarked" => state)
        when "like_post", "unlike_post"
          id = positive_id(args, "post_id")
          state = args["action"] == "like_post"
          state ? EltenLink::Forum.like_post(client, :post_id => id) : EltenLink::Forum.unlike_post(client, :post_id => id)
          completed(args["action"], state ? "Liked post #{id}." : "Removed the like from post #{id}.", "post_id" => id, "liked_by_me" => state)
        when "create_bookmark"
          thread_id = positive_id(args, "thread_id")
          post_id = positive_id(args, "post_id")
          value = EltenLink::Forum.create_bookmark(client, :thread_id => thread_id, :post_id => post_id,
            :description => (args.key?("description") ? required_string(args, "description", true) : ""))
          bookmark_id = server_integer(value, "created bookmark id", true)
          completed("create_bookmark", "Created a bookmark for post #{post_id}.", "thread_id" => thread_id, "post_id" => post_id,
            "bookmark_id" => bookmark_id)
        when "delete_bookmark"
          id = positive_id(args, "bookmark_id")
          EltenLink::Forum.delete_bookmark(client, :bookmark_id => id)
          completed("delete_bookmark", "Deleted forum bookmark #{id}.", "bookmark_id" => id)
        when "create_mentions"
          users = string_array(args, "users", 100)
          thread_id = positive_id(args, "thread_id")
          post_id = positive_id(args, "post_id")
          value = EltenLink::Forum.create_mentions(client, :users => users, :thread_id => thread_id, :post_id => post_id,
            :message => (args.key?("message") ? required_string(args, "message", true) : ""))
          mention_ids = integer_array(value)
          completed("create_mentions", "Created mentions for #{users.size} users in one operation.",
            "users" => users, "thread_id" => thread_id, "post_id" => post_id, "mention_ids" => mention_ids)
        when "acknowledge_mention"
          id = positive_id(args, "mention_id")
          EltenLink::Forum.notice_mention(client, :mention_id => id)
          completed("acknowledge_mention", "Marked forum mention #{id} as seen.", "mention_id" => id)
        when "report_post"
          id = positive_id(args, "post_id")
          suggestion = args.key?("suggestion") ? forum_report_suggestion_input(args["suggestion"]) : {}
          EltenLink::Forum.report_post(client, :post_id => id,
            :comment => (args.key?("comment") ? required_string(args, "comment", true) : ""),
            :suggestion => suggestion["action"], :suggestion_flags => suggestion["flags"],
            :suggestion_range => suggestion["range"])
          completed("report_post", "Reported post #{id} to its group moderators.", "post_id" => id,
            "suggestion" => (args.key?("suggestion") ? result(args["suggestion"]) : nil))
        else invalid_action(args["action"])
        end
      end
    end

    def register_forum_moderation_tools
      register_domain_tool(
        "forum_moderation_read", "Read forum moderation data",
        "Read group reports and moderator history with named roles, report decisions and resolved group/forum/thread context. Raw group-settings JSON and server action codes are not exposed.",
        :forum, :moderate, action_schema(%w[reports moderator_log group_configuration trash_threads trash_thread], :forum)
      ) do |args|
        client = network_client
        case args["action"]
        when "reports"
          group_id = positive_id(args, "group_id")
          structure = forum_structure_value(client)
          reports = known_list(EltenLink::Forum.group_reports(client, :group_id => group_id), :forum_report)
          thread_index = structure.threads.each_with_object({}) do |thread, index|
            index[known(thread, :forum_thread)["thread_id"]] = thread
          end
          reports.each { |report| report["thread"] = forum_thread_context(thread_index[report["thread_id"]]) if thread_index[report["thread_id"]] != nil }
          response("reports", "Returned #{reports.size} moderation reports for group #{group_id}.", "group_id" => group_id, "reports" => reports, "count" => reports.size)
        when "moderator_log"
          group_id = positive_id(args, "group_id")
          structure = forum_structure_value(client)
          entries = known_list(EltenLink::Forum.group_log(client, :group_id => group_id), :forum_log)
          entries.each { |entry| enrich_forum_log_entry(entry, structure) }
          response("moderator_log", "Returned #{entries.size} human-readable moderator log entries for group #{group_id}.",
            "group_id" => group_id, "entries" => entries, "count" => entries.size)
        when "group_configuration"
          group_id = positive_id(args, "group_id")
          structure = forum_structure_value(client)
          group = structure.groups.find { |item| known(item, :forum_group)["group_id"] == group_id }
          raise InvalidParamsError, "No visible forum group with id #{group_id}" if group == nil
          configuration = forum_group_configuration(EltenLink::Forum.get_group_settings(client, :group_id => group_id))
          response("group_configuration", "Returned the known, named configuration for group #{group_id}; unrecognized server fields were discarded.",
            "group" => known(group, :forum_group), "configuration" => configuration)
        when "trash_threads"
          group_id = positive_id(args, "group_id")
          raw_threads = EltenLink::Forum.trash_threads(client, :group_id => group_id)
          threads = known_list(raw_threads, :forum_trash_thread)
          @authorization.remember_forum_trash_threads(group_id, raw_threads)
          response("trash_threads", "Returned #{threads.size} recoverable thread entries for group #{group_id}.",
            "group_id" => group_id, "threads" => threads, "count" => threads.size)
        when "trash_thread"
          thread_id = positive_id(args, "thread_id")
          raw_page = EltenLink::Forum.trash_thread(client, :thread_id => thread_id)
          @authorization.remember_forum_posts(thread_id, raw_page.posts)
          page = known(raw_page, :forum_trash_page)
          response("trash_thread", "Returned #{page["returned_post_count"]} recoverable posts for thread #{thread_id}.",
            "thread_id" => thread_id, "page" => page)
        else invalid_action(args["action"])
        end
      end

      ids = { "type" => "array", "items" => { "type" => "integer", "minimum" => 1 }, "minItems" => 1, "maxItems" => 500 }
      users = { "type" => "array", "items" => { "type" => "string" }, "minItems" => 1, "maxItems" => 50 }
      integer = { "type" => "integer", "minimum" => 1 }
      boolean = { "type" => "boolean" }
      text = { "type" => "string" }
      aliases = { "type" => "array", "items" => text, "maxItems" => 100 }
      content_mode = { "type" => "string", "enum" => %w[text voice mixed], "description" => "Named forum content mode; numeric type flags are not accepted." }
      visibility = { "type" => "string", "enum" => %w[private public] }
      join_policy = { "type" => "string", "enum" => %w[invitation_only membership_request open] }
      forum_position = { "oneOf" => [integer.merge("description" => "One-based position within the group."), { "type" => "string", "enum" => ["end"] }] }
      item_schema = { "oneOf" => [
        forum_moderation_schema("move_threads", "Move several threads to one forum in a single bulk request.",
          { "thread_ids" => ids, "target_forum_id" => integer }, %w[thread_ids target_forum_id]),
        forum_moderation_schema("delete_threads", "Delete several threads in a single bulk request.",
          { "thread_ids" => ids }, %w[thread_ids]),
        forum_moderation_schema("purge_threads", "Permanently delete selected trashed threads together with all their posts. This cannot be undone; each thread requires one request. Read trash_threads first to identify the targets.",
          { "thread_ids" => ids }, %w[thread_ids]),
        forum_moderation_schema("offer_threads", "Offer several threads to another group in a single bulk request.",
          { "thread_ids" => ids, "target_group_id" => integer }, %w[thread_ids target_group_id]),
        forum_moderation_schema("move_posts", "Move several posts to one thread in a single bulk request.",
          { "post_ids" => ids, "target_thread_id" => integer }, %w[post_ids target_thread_id]),
        forum_moderation_schema("delete_posts", "Delete several posts in a single bulk request.",
          { "post_ids" => ids }, %w[post_ids]),
        forum_moderation_schema("purge_posts", "Permanently delete selected trashed posts. This cannot be undone; each post requires one request. Read trash_thread first to identify the targets.",
          { "post_ids" => ids }, %w[post_ids]),
        forum_moderation_schema("set_threads_closed", "Close or reopen several threads in one bulk request.",
          { "thread_ids" => ids, "closed" => boolean }, %w[thread_ids closed]),
        forum_moderation_schema("set_threads_pinned", "Pin or unpin several threads. The server has no bulk endpoint, so this may use one request per thread.",
          { "thread_ids" => ids, "pinned" => boolean }, %w[thread_ids pinned]),
        forum_moderation_schema("set_posts_locked", "Lock or unlock several posts in one bulk request.",
          { "post_ids" => ids, "locked" => boolean }, %w[post_ids locked]),
        forum_moderation_schema("resolve_reports", "Resolve several group reports with one named decision and optional reason.",
          { "report_ids" => ids, "group_id" => integer,
            "resolution" => { "type" => "string", "enum" => %w[rejected accepted] },
            "reason" => text, "use_suggestion" => boolean }, %w[report_ids group_id resolution]),
        forum_moderation_schema("update_members", "Apply one named membership action to several users.",
          { "group_id" => integer, "users" => users,
            "member_action" => { "type" => "string", "enum" => DomainContracts::MEMBER_ACTIONS.keys },
            "inherit_to_child_groups" => boolean,
            "expires_at" => { "oneOf" => [{ "type" => "integer" }, { "type" => "string" }] } }, %w[group_id users member_action]),
        forum_moderation_schema("rename_thread", "Replace one thread title.",
          { "thread_id" => integer, "title" => text }, %w[thread_id title]),
        forum_moderation_schema("accept_thread_offer", "Accept an offered thread into a selected forum moderated by the user.",
          { "thread_id" => integer, "target_forum_id" => integer }, %w[thread_id target_forum_id]),
        forum_moderation_schema("refuse_thread_offers", "Refuse several offered threads; each thread requires one request.",
          { "thread_ids" => ids }, %w[thread_ids]),
        forum_moderation_schema("reorder_post", "Place one post before another post in the same thread; omit before_post_id to move it to the end.",
          { "post_id" => integer, "before_post_id" => integer }, %w[post_id]),
        forum_moderation_schema("create_forum_tag", "Create a named forum tag from a label and readable alias list.",
          { "forum_id" => integer, "label" => text, "aliases" => aliases }, %w[forum_id label aliases]),
        forum_moderation_schema("create_group", "Create a group that will be administered by the signed-in user. Visibility and join policy are named and validated as a pair.",
          { "name" => text, "description" => text, "language" => text, "visibility" => visibility, "join_policy" => join_policy },
          %w[name description language visibility join_policy]),
        forum_moderation_schema("update_group_motd", "Replace the group's message of the day; an empty string clears it.",
          { "group_id" => integer, "text" => text }, %w[group_id text]),
        forum_moderation_schema("update_group_regulations", "Replace the group's regulations; an empty string clears them.",
          { "group_id" => integer, "text" => text }, %w[group_id text]),
        forum_moderation_schema("update_group_profile", "Update one or more of the group name, description and language.",
          { "group_id" => integer, "name" => text, "description" => text, "language" => text }, %w[group_id]).merge("minProperties" => 3),
        forum_moderation_schema("create_forum", "Create a forum with named content mode and public/private visibility.",
          { "group_id" => integer, "name" => text, "description" => text, "content_mode" => content_mode, "visibility" => visibility }, %w[group_id name content_mode visibility]),
        forum_moderation_schema("update_forum", "Update one or more of a forum's name, description, content mode and visibility.",
          { "forum_id" => integer, "name" => text, "description" => text, "content_mode" => content_mode, "visibility" => visibility }, %w[forum_id]).merge("minProperties" => 3),
        forum_moderation_schema("set_forums_closed", "Close or reopen several forums; each forum requires one request.",
          { "forum_ids" => ids, "closed" => boolean }, %w[forum_ids closed]),
        forum_moderation_schema("move_forum", "Move a forum to a one-based position in its group or to the end.",
          { "forum_id" => integer, "position" => forum_position }, %w[forum_id position]),
        forum_moderation_schema("restore_threads", "Restore trashed threads, optionally into one selected forum; each thread requires one request.",
          { "thread_ids" => ids, "target_forum_id" => integer }, %w[thread_ids]),
        forum_moderation_schema("restore_posts", "Restore trashed posts, optionally into one selected thread; each post requires one request.",
          { "post_ids" => ids, "target_thread_id" => integer }, %w[post_ids]),
        forum_moderation_schema("delete_forum_tag", "Delete one tag from a forum.",
          { "forum_id" => integer, "tag_id" => integer }, %w[forum_id tag_id]),
        forum_moderation_schema("invite_users", "Invite several exact usernames to one forum group; each user requires one request.",
          { "group_id" => integer, "users" => users }, %w[group_id users]),
        forum_moderation_schema("delete_group", "Permanently delete one forum group.",
          { "group_id" => integer }, %w[group_id]),
        forum_moderation_schema("delete_forum", "Permanently delete one forum.",
          { "forum_id" => integer }, %w[forum_id])
      ] }
      schema = { "type" => "object", "properties" => { "actions" => { "type" => "array", "minItems" => 1, "maxItems" => 50, "items" => item_schema } }, "required" => ["actions"], "additionalProperties" => false }
      register_domain_tool(
        "forum_moderate_batch", "Moderate forum in a grouped batch",
        "Submit all related moderation actions together. Every branch uses named targets, decisions and member roles; the program translates them to private Klango server contracts. Native move/delete/offer operations are coalesced into bulk requests. Per-item operations are capped at 50 requests. Never issue one tool call per post or thread.",
        :forum, :moderate, schema, destructive_annotations
      ) { |args| moderate_forum_batch(network_client, args["actions"]) }
    end

    def forum_structure(client)
      structure = forum_structure_value(client)
      forums_by_group = structure.forums.group_by do |forum|
        raise ToolError, "Forum is missing its group context" if !forum.respond_to?(:group) || forum.group == nil
        known(forum.group, :forum_group)["group_id"]
      end
      threads_by_forum = structure.threads.group_by do |thread|
        raise ToolError, "Thread is missing its forum context" if !thread.respond_to?(:forum) || thread.forum == nil
        known(thread.forum, :forum_forum)["forum_id"]
      end
      groups = structure.groups.map do |group|
        mapped = known(group, :forum_group)
        mapped["forums"] = (forums_by_group[mapped["group_id"]] || []).map do |forum|
          forum_value = known(forum, :forum_forum)
          forum_value["threads"] = (threads_by_forum[forum_value["forum_id"]] || []).map { |thread| known(thread, :forum_thread) }
          forum_value
        end
        mapped
      end
      response("structure", "Returned #{groups.size} forum groups with nested forums and threads. Use the named IDs from this structure in later calls.",
        "groups" => groups, "group_count" => groups.size, "forum_count" => structure.forums.size,
        "thread_count" => structure.threads.size, "loaded_at" => Time.at(structure.loaded_at.to_f))
    end

    def forum_scope_list(client)
      structure = forum_structure_value(client)
      forums_by_group = structure.forums.group_by { |forum| forum.group&.id.to_i }
      threads_by_forum = structure.threads.group_by { |thread| thread.forum&.id.to_i }
      groups = structure.groups.map do |group|
        group_id = group.id.to_i
        forums = (forums_by_group[group_id] || []).map do |forum|
          forum_id = forum.id.to_i
          threads = (threads_by_forum[forum_id] || []).map do |thread|
            result("thread_id" => thread.id.to_i, "title" => thread.name.to_s)
          end
          result("forum_id" => forum_id, "name" => forum.fullname.to_s, "threads" => threads)
        end
        result("group_id" => group_id, "name" => group.name.to_s, "forums" => forums)
      end
      response("scope", "Returned #{structure.groups.size} groups, #{structure.forums.size} forums and #{structure.threads.size} threads as selectable permission scopes. No forum post content was read.",
        "groups" => groups, "group_count" => structure.groups.size,
        "forum_count" => structure.forums.size, "thread_count" => structure.threads.size)
    end

    def forum_thread_context(thread)
      raise ToolError, "Forum thread context is missing" if thread == nil || thread.forum == nil || thread.forum.group == nil
      group = known(thread.forum.group, :forum_group)
      forum = known(thread.forum, :forum_forum)
      thread_value = known(thread, :forum_thread)
      result(
        "group" => result("group_id" => group["group_id"], "name" => group["name"]),
        "forum" => result("forum_id" => forum["forum_id"], "name" => forum["name"]),
        "thread" => thread_value
      )
    end

    def forum_search(client, args)
      query = required_string(args, "query")
      search_in = args["search_in"] || "post_content"
      structure = forum_structure_value(client)
      matches = if search_in == "thread_title"
        lowered = query.downcase
        structure.threads.filter_map do |thread|
          mapped = known(thread, :forum_thread)
          mapped["title"].downcase.include?(lowered) ? [mapped["thread_id"], nil] : nil
        end
      elsif search_in == "post_content" || search_in == "post_author"
        values = EltenLink::Forum.search(client, :query => query,
          :type => (search_in == "post_author" ? "author" : nil),
          :transcriptions => (search_in == "post_content" && args["include_audio_transcriptions"] == true))
        known_list(values, :forum_search).map { |match| [match["thread_id"], match["matching_post_count"]] }
      else
        raise InvalidParamsError, "search_in must be post_content, post_author or thread_title"
      end
      index = structure.threads.each_with_object({}) do |thread, mapped|
        mapped[known(thread, :forum_thread)["thread_id"]] = thread
      end
      resolved = matches.map do |thread_id, count|
        thread = index[thread_id]
        next nil if thread == nil
        value = forum_thread_context(thread)
        value["matching_post_count"] = count if count != nil
        value
      end.compact
      response("search", "Found #{resolved.size} matching forum threads. Every result includes resolved group, forum and thread names.",
        "query" => query, "searched_in" => search_in,
        "included_audio_transcriptions" => (search_in == "post_content" && args["include_audio_transcriptions"] == true),
        "matches" => resolved, "count" => resolved.size)
    end

    def enrich_forum_log_entry(entry, structure)
      groups = structure.groups.each_with_object({}) do |group, index|
        mapped = known(group, :forum_group)
        index[mapped["group_id"]] = mapped
      end
      forums = structure.forums.each_with_object({}) do |forum, index|
        mapped = known(forum, :forum_forum)
        index[mapped["forum_id"]] = mapped
      end
      threads = structure.threads.each_with_object({}) do |thread, index|
        mapped = known(thread, :forum_thread)
        index[mapped["thread_id"]] = mapped
      end
      %w[source destination].each do |side|
        target = entry[side]
        next if !target.is_a?(Hash)
        target["group_name"] = groups[target["group_id"]]["name"] if groups[target["group_id"]] != nil
        target["forum_name"] = forums[target["forum_id"]]["name"] if forums[target["forum_id"]] != nil
        target["thread_title"] = threads[target["thread_id"]]["title"] if threads[target["thread_id"]] != nil
      end
      entry
    end

    def forum_structure_value(client)
      structure = EltenLink::Forum.structure(client)
      raise ToolError, "Unexpected forum structure contract" if !structure.instance_of?(EltenLink::ForumStructure)
      raise ToolError, "Unexpected forum structure lists" if !structure.groups.is_a?(Array) || !structure.forums.is_a?(Array) || !structure.threads.is_a?(Array)
      raise ToolError, "Unexpected forum structure timestamp" if !structure.loaded_at.is_a?(Numeric)
      @authorization.remember_forum_structure(structure)
      structure
    end

    def forum_moderation_schema(action, description, properties, required)
      {
        "title" => action.split("_").map(&:capitalize).join(" "), "description" => description,
        "type" => "object",
        "properties" => { "action" => { "type" => "string", "enum" => [action], "description" => description } }.merge(properties),
        "required" => ["action"] + required, "additionalProperties" => false
      }
    end

    def moderate_forum_batch(client, actions)
      raise InvalidParamsError, "actions must be a non-empty array" if !actions.is_a?(Array) || actions.empty?
      raise InvalidParamsError, "At most 50 grouped actions are allowed" if actions.size > 50
      grouped = {}
      actions.each_with_index do |action, index|
        raise InvalidParamsError, "Each moderation action must be an object" if !action.is_a?(Hash)
        name = action["action"]
        raise InvalidParamsError, "Unknown moderation action: #{name}" if !FORUM_MODERATION_ACTIONS.include?(name)
        normalized = normalize_forum_moderation_action(action)
        key = if %w[move_threads delete_threads purge_threads offer_threads move_posts delete_posts purge_posts set_threads_closed set_threads_pinned set_posts_locked resolve_reports update_members restore_threads restore_posts invite_users].include?(name)
          [name, normalized["target_id"], normalized["group_id"], normalized["state"],
            normalized["resolution"], normalized["reason"], normalized["member_action"], normalized["inherit"],
            normalized["use_suggestion"], normalized["expires_at"]]
        elsif name == "refuse_thread_offers"
          [name]
        elsif name == "set_forums_closed"
          [name, normalized["state"]]
        else
          ["single", index]
        end
        grouped[key] ||= normalized.merge("ids" => [], "users" => [])
        grouped[key]["ids"].concat(normalized["ids"])
        grouped[key]["users"].concat(normalized["users"])
      end
      total = grouped.values.sum { |item| item["ids"].size + item["users"].size }
      raise InvalidParamsError, "At most 500 forum objects can be moderated per call" if total > 500
      expected_requests = grouped.values.sum do |action|
        case action["action"]
        when "move_threads", "delete_threads", "offer_threads", "move_posts", "delete_posts", "set_threads_closed", "set_posts_locked" then 1
        when "set_threads_pinned", "resolve_reports", "update_members", "refuse_thread_offers", "set_forums_closed", "restore_threads", "restore_posts", "purge_threads", "purge_posts", "invite_users" then action["ids"].size + action["users"].size
        when "move_forum" then 2
        else 1
        end
      end
      raise InvalidParamsError, "This batch would require #{expected_requests} requests; the limit is 50" if expected_requests > 50
      request_count = 0
      outcomes = []
      grouped.each_value do |action|
        ids = positive_ids(action["ids"])
        users = action["users"].map(&:to_s).reject(&:empty?).uniq
        name = action["action"]
        case name
        when "move_threads" then EltenLink::Forum.move_threads(client, :thread_ids => require_ids(ids), :forum_id => positive_value(action["target_id"], "target_forum_id")); request_count += 1
        when "delete_threads" then EltenLink::Forum.delete_threads(client, :thread_ids => require_ids(ids)); request_count += 1
        when "offer_threads" then EltenLink::Forum.offer_threads(client, :thread_ids => require_ids(ids), :group_id => positive_value(action["target_id"], "target_group_id")); request_count += 1
        when "move_posts" then EltenLink::Forum.move_posts(client, :post_ids => require_ids(ids), :thread_id => positive_value(action["target_id"], "target_thread_id")); request_count += 1
        when "delete_posts" then EltenLink::Forum.delete_posts(client, :post_ids => require_ids(ids)); request_count += 1
        when "purge_threads"
          request_count = forum_serial(ids, request_count) { |id| EltenLink::Forum.delete_thread(client, :thread_id => id, :permanent => true) }
        when "purge_posts"
          request_count = forum_serial(ids, request_count) { |id| EltenLink::Forum.delete_post(client, :post_id => id, :permanent => true) }
        when "set_threads_closed"
          EltenLink::Forum.set_threads_closed(client, :thread_ids => require_ids(ids), :closed => action["state"]); request_count += 1
        when "set_threads_pinned"
          request_count = forum_serial(ids, request_count) { |id| EltenLink::Forum.set_thread_pinned(client, :thread_id => id, :pinned => action["state"]) }
        when "set_posts_locked"
          EltenLink::Forum.set_posts_locked(client, :post_ids => require_ids(ids), :locked => action["state"]); request_count += 1
        when "resolve_reports"
          group_id = positive_value(action["group_id"], "group_id")
          status = DomainContracts::REPORT_STATUS_INPUT.fetch(action["resolution"]) { raise InvalidParamsError, "resolution must be rejected or accepted" }
          request_count = forum_serial(ids, request_count) do |id|
            EltenLink::Forum.resolve_report(client, :group_id => group_id, :report_id => id, :status => status,
              :reason => action["reason"], :use_suggestion => action["use_suggestion"] == true)
          end
        when "update_members"
          raise InvalidParamsError, "users are required" if users.empty?
          group_id = positive_value(action["group_id"], "group_id")
          member_action = DomainContracts::MEMBER_ACTIONS.fetch(action["member_action"]) { raise InvalidParamsError, "Unknown member_action" }
          request_count = forum_serial(users, request_count) do |user|
            EltenLink::Forum.update_member(client, :group_id => group_id, :user => user, :action => member_action,
              :inherit => action["inherit"], :totime => action["expires_at"])
          end
        when "rename_thread"
          EltenLink::Forum.rename_thread(client, :thread_id => action["thread_id"], :name => action["title"])
          request_count += 1
        when "accept_thread_offer"
          EltenLink::Forum.accept_thread_offer(client, :thread_id => action["thread_id"], :forum_id => action["target_forum_id"])
          request_count += 1
        when "refuse_thread_offers"
          request_count = forum_serial(ids, request_count) { |id| EltenLink::Forum.refuse_thread_offer(client, :thread_id => id) }
        when "reorder_post"
          EltenLink::Forum.reorder_post(client, :post_id => action["post_id"], :before_post_id => action["before_post_id"] || 0)
          request_count += 1
        when "create_forum_tag"
          created = EltenLink::Forum.create_forum_tag(client, :forumid => action["forum_id"], :label => action["label"], :taglist => action["aliases"].join(","))
          action["created_tag_id"] = server_integer(created, "created forum tag id", true)
          request_count += 1
        when "create_group"
          created = EltenLink::Forum.create_group(client, :name => action["name"], :description => action["description"],
            :lang => action["language"], :public => action["public_state"], :open => action["open_state"])
          action["created_group_id"] = server_integer(created, "created group id", true)
          request_count += 1
        when "update_group_motd"
          EltenLink::Forum.update_group_motd(client, :group_id => action["group_id"], :text => action["text"])
          request_count += 1
        when "update_group_regulations"
          EltenLink::Forum.update_group_regulations(client, :group_id => action["group_id"], :text => action["text"])
          request_count += 1
        when "update_group_profile"
          update_known_group_settings(client, action["group_id"], action["settings"])
          request_count += 1
        when "create_forum"
          created = EltenLink::Forum.create_forum(client, :group_id => action["group_id"], :name => action["name"],
            :description => action["description"], :type => action["content_type"], :private => action["visibility"] == "private")
          action["created_forum_id"] = server_integer(created, "created forum id", true)
          request_count += 1
        when "update_forum"
          EltenLink::Forum.update_forum(client, :forumid => action["forum_id"], :name => action["name"],
            :description => action["description"], :type => action["content_type"],
            :private => (action["visibility"] == nil ? nil : action["visibility"] == "private"))
          request_count += 1
        when "set_forums_closed"
          request_count = forum_serial(ids, request_count) { |id| EltenLink::Forum.set_forum_closed(client, :forumid => id, :closed => action["state"]) }
        when "move_forum"
          position = forum_move_position(client, action["forum_id"], action["position"])
          EltenLink::Forum.move_forum(client, :forumid => action["forum_id"], :position => position)
          request_count += 2
        when "restore_threads"
          request_count = forum_serial(ids, request_count) do |id|
            EltenLink::Forum.restore_thread(client, :thread_id => id, :forum_id => action["target_id"])
          end
        when "restore_posts"
          request_count = forum_serial(ids, request_count) do |id|
            EltenLink::Forum.restore_post(client, :post_id => id, :thread_id => action["target_id"])
          end
        when "delete_forum_tag"
          EltenLink::Forum.delete_forum_tag(client, :forumid => action["forum_id"], :tag_id => action["tag_id"])
          request_count += 1
        when "invite_users"
          group_id = positive_value(action["group_id"], "group_id")
          request_count = forum_serial(users, request_count) { |user| EltenLink::Forum.invite_user(client, :group_id => group_id, :user => user) }
        when "delete_group"
          EltenLink::Forum.delete_group(client, :group_id => action["group_id"])
          request_count += 1
        when "delete_forum"
          EltenLink::Forum.delete_forum(client, :forumid => action["forum_id"])
          request_count += 1
        end
        outcomes << forum_moderation_outcome(action, ids, users)
      end
      completed("moderate_batch", "Applied #{actions.size} submitted moderation actions as #{grouped.size} coalesced groups using #{request_count} network requests.",
        "submitted_action_count" => actions.size, "coalesced_action_count" => grouped.size,
        "network_request_count" => request_count, "outcomes" => outcomes)
    end

    def normalize_forum_moderation_action(action)
      name = action["action"]
      value = {
        "action" => name, "target_id" => nil, "group_id" => nil, "state" => nil,
        "resolution" => nil, "reason" => nil, "member_action" => nil, "inherit" => nil,
        "use_suggestion" => nil, "expires_at" => nil,
        "ids" => [], "users" => []
      }
      case name
      when "move_threads"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
        value["target_id"] = positive_value(action["target_forum_id"], "target_forum_id")
      when "delete_threads", "purge_threads"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
      when "offer_threads"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
        value["target_id"] = positive_value(action["target_group_id"], "target_group_id")
      when "move_posts"
        value["ids"] = positive_ids(required_array(action, "post_ids", 500))
        value["target_id"] = positive_value(action["target_thread_id"], "target_thread_id")
      when "delete_posts", "purge_posts"
        value["ids"] = positive_ids(required_array(action, "post_ids", 500))
      when "set_threads_closed"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
        value["state"] = boolean_arg(action, "closed")
      when "set_threads_pinned"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
        value["state"] = boolean_arg(action, "pinned")
      when "set_posts_locked"
        value["ids"] = positive_ids(required_array(action, "post_ids", 500))
        value["state"] = boolean_arg(action, "locked")
      when "resolve_reports"
        value["ids"] = positive_ids(required_array(action, "report_ids", 500))
        value["group_id"] = positive_value(action["group_id"], "group_id")
        value["resolution"] = required_string(action, "resolution")
        raise InvalidParamsError, "resolution must be rejected or accepted" if !DomainContracts::REPORT_STATUS_INPUT.key?(value["resolution"])
        value["reason"] = action.key?("reason") ? required_string(action, "reason", true) : ""
        value["use_suggestion"] = action.key?("use_suggestion") ? boolean_arg(action, "use_suggestion") : false
        raise InvalidParamsError, "use_suggestion is valid only when accepting reports" if value["use_suggestion"] && value["resolution"] != "accepted"
      when "update_members"
        value["group_id"] = positive_value(action["group_id"], "group_id")
        value["users"] = string_array(action, "users", 50)
        value["member_action"] = required_string(action, "member_action")
        raise InvalidParamsError, "Unknown member_action" if !DomainContracts::MEMBER_ACTIONS.key?(value["member_action"])
        if value["member_action"] == "set_role_inheritance"
          raise InvalidParamsError, "inherit_to_child_groups is required for set_role_inheritance" if !action.key?("inherit_to_child_groups")
          value["inherit"] = boolean_arg(action, "inherit_to_child_groups")
        elsif action.key?("inherit_to_child_groups")
          raise InvalidParamsError, "inherit_to_child_groups is valid only for set_role_inheritance"
        end
        if action.key?("expires_at")
          raise InvalidParamsError, "expires_at is valid only for ban" if value["member_action"] != "ban"
          value["expires_at"] = required_time(action, "expires_at").to_i
        end
      when "rename_thread"
        value["thread_id"] = positive_value(action["thread_id"], "thread_id")
        value["title"] = limited_string(action, "title", 500)
      when "accept_thread_offer"
        value["thread_id"] = positive_value(action["thread_id"], "thread_id")
        value["target_forum_id"] = positive_value(action["target_forum_id"], "target_forum_id")
      when "refuse_thread_offers"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
      when "reorder_post"
        value["post_id"] = positive_value(action["post_id"], "post_id")
        value["before_post_id"] = action.key?("before_post_id") ? positive_value(action["before_post_id"], "before_post_id") : nil
      when "create_forum_tag"
        value["forum_id"] = positive_value(action["forum_id"], "forum_id")
        value["label"] = limited_string(action, "label", 500)
        aliases = action["aliases"]
        raise InvalidParamsError, "aliases must be an array with at most 100 items" if !aliases.is_a?(Array) || aliases.size > 100
        value["aliases"] = aliases.map do |entry|
          raise InvalidParamsError, "aliases must contain non-empty strings of at most 500 characters" if !entry.is_a?(String) || entry.strip.empty? || entry.each_char.count > 500
          entry
        end.uniq
      when "create_group"
        value["name"] = limited_string(action, "name", 500)
        value["description"] = required_string(action, "description", true)
        value["language"] = limited_string(action, "language", 64)
        value["visibility"] = required_string(action, "visibility")
        value["join_policy"] = required_string(action, "join_policy")
        value["public_state"], value["open_state"] = forum_group_access(value["visibility"], value["join_policy"])
      when "update_group_motd", "update_group_regulations"
        value["group_id"] = positive_value(action["group_id"], "group_id")
        value["text"] = required_string(action, "text", true)
      when "update_group_profile"
        value["group_id"] = positive_value(action["group_id"], "group_id")
        settings = {}
        settings["name"] = limited_string(action, "name", 500) if action.key?("name")
        settings["description"] = required_string(action, "description", true) if action.key?("description")
        settings["lang"] = limited_string(action, "language", 64) if action.key?("language")
        raise InvalidParamsError, "At least one group profile field is required" if settings.empty?
        value["settings"] = settings
        value["updated_fields"] = settings.keys.map { |key| key == "lang" ? "language" : key }
      when "create_forum"
        value["group_id"] = positive_value(action["group_id"], "group_id")
        value["name"] = limited_string(action, "name", 500)
        value["description"] = action.key?("description") ? required_string(action, "description", true) : nil
        value["content_mode"] = required_string(action, "content_mode")
        value["content_type"] = forum_content_mode_input(value["content_mode"])
        value["visibility"] = required_string(action, "visibility")
        raise InvalidParamsError, "visibility must be private or public" if !%w[private public].include?(value["visibility"])
      when "update_forum"
        value["forum_id"] = positive_value(action["forum_id"], "forum_id")
        value["name"] = limited_string(action, "name", 500) if action.key?("name")
        value["description"] = required_string(action, "description", true) if action.key?("description")
        if action.key?("content_mode")
          value["content_mode"] = required_string(action, "content_mode")
          value["content_type"] = forum_content_mode_input(value["content_mode"])
        end
        if action.key?("visibility")
          value["visibility"] = required_string(action, "visibility")
          raise InvalidParamsError, "visibility must be private or public" if !%w[private public].include?(value["visibility"])
        end
        value["updated_fields"] = action.keys & %w[name description content_mode visibility]
        raise InvalidParamsError, "At least one forum field is required" if value["updated_fields"].empty?
      when "set_forums_closed"
        value["ids"] = positive_ids(required_array(action, "forum_ids", 500))
        value["state"] = boolean_arg(action, "closed")
      when "move_forum"
        value["forum_id"] = positive_value(action["forum_id"], "forum_id")
        position = action["position"]
        raise InvalidParamsError, "position must be a positive one-based integer or 'end'" if position != "end" && (!position.is_a?(Integer) || position <= 0)
        value["position"] = position
      when "restore_threads"
        value["ids"] = positive_ids(required_array(action, "thread_ids", 500))
        value["target_id"] = action.key?("target_forum_id") ? positive_value(action["target_forum_id"], "target_forum_id") : nil
      when "restore_posts"
        value["ids"] = positive_ids(required_array(action, "post_ids", 500))
        value["target_id"] = action.key?("target_thread_id") ? positive_value(action["target_thread_id"], "target_thread_id") : nil
      when "delete_forum_tag"
        value["forum_id"] = positive_value(action["forum_id"], "forum_id")
        value["tag_id"] = positive_value(action["tag_id"], "tag_id")
      when "invite_users"
        value["group_id"] = positive_value(action["group_id"], "group_id")
        value["users"] = string_array(action, "users", 50)
      when "delete_group"
        value["group_id"] = positive_value(action["group_id"], "group_id")
      when "delete_forum"
        value["forum_id"] = positive_value(action["forum_id"], "forum_id")
      end
      value
    end

    def forum_moderation_outcome(action, ids, users)
      name = action["action"]
      values = { "action" => name }
      if %w[move_threads delete_threads purge_threads offer_threads set_threads_closed set_threads_pinned].include?(name)
        values["thread_ids"] = ids
      elsif %w[move_posts delete_posts purge_posts set_posts_locked].include?(name)
        values["post_ids"] = ids
      elsif name == "resolve_reports"
        values["report_ids"] = ids
      end
      values["users"] = users if name == "update_members"
      values["target_forum_id"] = action["target_id"] if name == "move_threads"
      values["target_group_id"] = action["target_id"] if name == "offer_threads"
      values["target_thread_id"] = action["target_id"] if name == "move_posts"
      values["group_id"] = action["group_id"] if action["group_id"] != nil
      values["closed"] = action["state"] if name == "set_threads_closed"
      values["pinned"] = action["state"] if name == "set_threads_pinned"
      values["locked"] = action["state"] if name == "set_posts_locked"
      values["resolution"] = action["resolution"] if name == "resolve_reports"
      values["used_suggestion"] = action["use_suggestion"] if name == "resolve_reports"
      values["member_action"] = action["member_action"] if name == "update_members"
      values["inherit_to_child_groups"] = action["inherit"] if name == "update_members" && action["inherit"] != nil
      values["expires_at"] = action["expires_at"] == nil ? nil : Time.at(action["expires_at"]) if name == "update_members"
      values["thread_ids"] = ids if name == "refuse_thread_offers"
      values["thread_id"] = action["thread_id"] if %w[rename_thread accept_thread_offer].include?(name)
      values["title"] = action["title"] if name == "rename_thread"
      values["target_forum_id"] = action["target_forum_id"] if name == "accept_thread_offer"
      if name == "reorder_post"
        values["post_id"] = action["post_id"]
        values["placement"] = action["before_post_id"] == nil ? "end" : "before_post"
        values["before_post_id"] = action["before_post_id"]
      end
      if name == "create_forum_tag"
        values["forum_id"] = action["forum_id"]
        values["tag"] = result("tag_id" => action["created_tag_id"], "label" => action["label"], "aliases" => action["aliases"])
      end
      if name == "create_group"
        values["group_id"] = action["created_group_id"]
        values["name"] = action["name"]
        values["language"] = action["language"]
        values["visibility"] = action["visibility"]
        values["join_policy"] = action["join_policy"]
      end
      if %w[update_group_motd update_group_regulations].include?(name)
        values["group_id"] = action["group_id"]
        values["was_cleared"] = action["text"].empty?
      end
      if name == "update_group_profile"
        values["group_id"] = action["group_id"]
        values["updated_fields"] = action["updated_fields"]
      end
      if name == "create_forum"
        values["group_id"] = action["group_id"]
        values["forum"] = result("forum_id" => action["created_forum_id"], "name" => action["name"], "content_mode" => action["content_mode"], "visibility" => action["visibility"])
      end
      if name == "update_forum"
        values["forum_id"] = action["forum_id"]
        values["updated_fields"] = action["updated_fields"]
      end
      if name == "set_forums_closed"
        values["forum_ids"] = ids
        values["closed"] = action["state"]
      end
      if name == "move_forum"
        values["forum_id"] = action["forum_id"]
        values["position"] = action["position"]
      end
      if name == "restore_threads"
        values["thread_ids"] = ids
        values["target_forum_id"] = action["target_id"]
      end
      if name == "restore_posts"
        values["post_ids"] = ids
        values["target_thread_id"] = action["target_id"]
      end
      if name == "delete_forum_tag"
        values["forum_id"] = action["forum_id"]
        values["tag_id"] = action["tag_id"]
      end
      if name == "invite_users"
        values["group_id"] = action["group_id"]
        values["users"] = users
      end
      values["group_id"] = action["group_id"] if name == "delete_group"
      values["forum_id"] = action["forum_id"] if name == "delete_forum"
      result(values)
    end

    def forum_group_access(visibility, join_policy)
      mapping = {
        ["private", "invitation_only"] => [false, false],
        ["private", "membership_request"] => [false, true],
        ["public", "membership_request"] => [true, false],
        ["public", "open"] => [true, true]
      }
      mapping.fetch([visibility, join_policy]) { raise InvalidParamsError, "Invalid visibility/join_policy combination" }
    end

    def forum_report_suggestion_input(value)
      raise InvalidParamsError, "suggestion must be an object" if !value.is_a?(Hash)
      action = required_string(value, "action")
      flags = {}
      required_field = case action
      when "thread_move", "thread_move_and_close", "thread_move_and_open"
        flags["forum"] = positive_value(value["target_forum_id"], "suggestion.target_forum_id")
        "target_forum_id"
      when "thread_rename"
        flags["name"] = limited_string(value, "new_thread_title", 500)
        "new_thread_title"
      when "thread_offer"
        flags["group"] = positive_value(value["target_group_id"], "suggestion.target_group_id")
        "target_group_id"
      when "post_move"
        flags["destination_thread"] = positive_value(value["target_thread_id"], "suggestion.target_thread_id")
        "target_thread_id"
      when "post_edit"
        flags["text"] = required_string(value, "new_post_text")
        "new_post_text"
      when "thread_delete", "thread_close", "thread_open", "post_delete"
        nil
      else
        raise InvalidParamsError, "Unknown report suggestion action"
      end
      allowed = ["action", "post_ids", required_field].compact
      unknown = value.keys.map(&:to_s) - allowed
      raise InvalidParamsError, "Fields not valid for #{action}: #{unknown.join(", ")}" if !unknown.empty?
      range = nil
      if value.key?("post_ids")
        raise InvalidParamsError, "post_ids is valid only for post suggestions" if !action.start_with?("post_")
        range = positive_ids(required_array(value, "post_ids", 500)).join(",")
        raise InvalidParamsError, "post_ids exceed Klangten's #{REPORT_SUGGESTION_RANGE_LIMIT}-character suggestion range limit" if range.length > REPORT_SUGGESTION_RANGE_LIMIT
      end
      { "action" => action, "flags" => flags.empty? ? nil : flags, "range" => range }
    end

    def forum_content_mode_input(value)
      FORUM_CONTENT_MODE_INPUT.fetch(value) { raise InvalidParamsError, "content_mode must be text, voice or mixed" }
    end

    def update_known_group_settings(client, group_id, settings)
      raise ToolError, "Internal group profile settings must be an object" if !settings.is_a?(Hash) || settings.empty?
      unknown = settings.keys.map(&:to_s) - WRITABLE_GROUP_PROFILE_KEYS
      raise ToolError, "Internal group profile contains an unknown field" if !unknown.empty?
      rebuilt = {}
      WRITABLE_GROUP_PROFILE_KEYS.each { |key| rebuilt[key] = settings[key] if settings.key?(key) }
      EltenLink::Forum.update_group_settings(client, :group_id => group_id, :settings => rebuilt)
    end

    def forum_move_position(client, forum_id, public_position)
      structure = forum_structure_value(client)
      forum = structure.forums.find { |item| known(item, :forum_forum)["forum_id"] == forum_id }
      raise InvalidParamsError, "No visible forum with id #{forum_id}" if forum == nil || forum.group == nil
      siblings = structure.forums.select { |item| item.group != nil && item.group.id == forum.group.id }
      return siblings.size if public_position == "end"
      raise InvalidParamsError, "position exceeds the number of forums in this group" if public_position > siblings.size
      public_position - 1
    end

    def forum_group_configuration(raw)
      raise ToolError, "Unexpected forum group settings contract" if !raw.instance_of?(Hash)
      public_state = forum_setting_boolean(raw, "public")
      open_state = forum_setting_boolean(raw, "open")
      visibility = public_state == nil ? nil : (public_state ? "public" : "private")
      join_policy = if public_state == nil || open_state == nil
        nil
      elsif public_state && open_state
        "open"
      elsif public_state || open_state
        "membership_request"
      else
        "invitation_only"
      end
      report_value = forum_setting_integer(raw, "show_postreports")
      report_visibility = report_value == nil ? nil : FORUM_REPORT_VISIBILITY_INPUT.key(report_value)
      raise ToolError, "Unknown forum report visibility" if report_value != nil && report_visibility == nil
      blog = forum_setting_string(raw, "blog")
      blog = nil if blog == ""
      result(
        "profile" => result("name" => forum_setting_string(raw, "name"), "description" => forum_setting_string(raw, "description"),
          "language" => forum_setting_string(raw, "lang")),
        "access" => result("visibility" => visibility, "join_policy" => join_policy,
          "parent_group_id" => forum_setting_positive(raw, "parent"),
          "block_globally_banned_users" => forum_setting_boolean(raw, "applyglobalbans")),
        "post_permissions" => result(
          "members_can_edit_posts" => negate_optional(forum_setting_boolean(raw, "prevent_editing")),
          "members_can_attach_polls" => negate_optional(forum_setting_boolean(raw, "prevent_polls")),
          "members_can_attach_files" => negate_optional(forum_setting_boolean(raw, "prevent_attachments")),
          "show_edit_information" => negate_optional(forum_setting_boolean(raw, "hide_editinfo")),
          "show_edit_history" => negate_optional(forum_setting_boolean(raw, "hide_edithistory")),
          "members_can_report_posts" => forum_setting_boolean(raw, "allow_postreporting"),
          "report_visibility" => report_visibility,
          "audio_post_limit_seconds" => forum_setting_integer(raw, "audiolimit")),
        "featured_thread_ids" => result(
          "introductions" => forum_setting_positive(raw, "thread_introductions"),
          "welcome" => forum_setting_positive(raw, "thread_welcome"),
          "moderation_announcements" => forum_setting_positive(raw, "thread_moderation"),
          "off_topic" => forum_setting_positive(raw, "thread_hydepark")),
        "linked_blog" => blog,
        "conference_channel_enabled" => forum_setting_boolean(raw, "conference_channel")
      )
    end

    def forum_setting_string(raw, key)
      return nil if !raw.key?(key) || raw[key] == nil
      raise ToolError, "Unexpected forum group setting type" if !raw[key].is_a?(String)
      raw[key]
    end

    def forum_setting_integer(raw, key)
      return nil if !raw.key?(key) || raw[key] == nil || raw[key] == ""
      value = raw[key]
      return value if value.is_a?(Integer)
      return value.to_i if value.is_a?(String) && value.match?(/\A-?[0-9]+\z/)
      raise ToolError, "Unexpected forum group setting type"
    end

    def forum_setting_positive(raw, key)
      value = forum_setting_integer(raw, key)
      return nil if value == nil || value == 0
      raise ToolError, "Unexpected forum group setting value" if value < 0
      value
    end

    def forum_setting_boolean(raw, key)
      return nil if !raw.key?(key) || raw[key] == nil || raw[key] == ""
      value = raw[key]
      return value if value == true || value == false
      return value == 1 if value.is_a?(Integer) && (value == 0 || value == 1)
      return value == "1" if value.is_a?(String) && %w[0 1].include?(value)
      raise ToolError, "Unexpected forum group setting type"
    end

    def negate_optional(value)
      value == nil ? nil : !value
    end

    def forum_serial(items, current_count)
      raise InvalidParamsError, "At least one item is required" if items.empty?
      raise InvalidParamsError, "Per-item moderation is capped at 50 network requests" if current_count + items.size > 50
      items.each { |item| yield item }
      current_count + items.size
    end
  end
end
