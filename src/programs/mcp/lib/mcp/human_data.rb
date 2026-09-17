# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; feed, calendar, task and sponsor fields removed.

# Public domain objects are rebuilt here as task-oriented data. This layer is
# intentionally independent from Klango server field names: numeric flags, roles,
# timestamps and positional contracts are translated before MCP sees them.
module EltenMCP
  module KnownData
    HUMAN_MODELS = {
      :user_status => "EltenLink::UserStatus",
      :user_info => "EltenLink::UserInfo",
      :user_profile_birthdate => "EltenLink::UserProfileBirthdate",
      :user_profile => "EltenLink::UserProfile",
      :client_state_profile => "EltenLink::ClientStateProfile",
      :client_state_chat => "EltenLink::ClientStateChat",
      :client_state_counts => "EltenLink::ClientStateCounts",
      :client_state => "EltenLink::ClientState",
      :notification => "EltenLink::Notification",
      :honor => "EltenLink::Honor", :honor_user => "EltenLink::HonorUser",
      :message_user => "EltenLink::MessageUser",
      :message_conversation => "EltenLink::MessageConversation",
      :message => "EltenLink::Message",
      :message_users_list => "EltenLink::MessageUsersList",
      :message_conversations_list => "EltenLink::MessageConversationsList",
      :messages_list => "EltenLink::MessagesList",
      :forum_group => "Struct_Forum_Group", :forum_forum => "Struct_Forum_Forum",
      :forum_thread => "Struct_Forum_Thread", :forum_post => "Struct_Forum_Post",
      :forum_thread_page => "EltenLink::ForumThreadPage",
      :forum_trash_thread => "EltenLink::ForumTrashThread", :forum_trash_page => "EltenLink::ForumTrashPage",
      :forum_user_post => "EltenLink::ForumUserPost",
      :forum_user_posts_page => "EltenLink::ForumUserPostsPage",
      :forum_thread_stats => "EltenLink::ForumThreadStats",
      :forum_search => "EltenLink::ForumSearchResult",
      :forum_member => "EltenLink::ForumMember", :forum_tag => "EltenLink::ForumTag",
      :forum_group_size => "EltenLink::ForumGroupSize",
      :forum_bookmark => "Struct_Forum_Bookmark",
      :forum_mention => "Struct_Forum_Mention", :forum_report => "Struct_Forum_Report",
      :forum_log => "Struct_Forum_LogEntry",
      :blog_category => "EltenLink::BlogCategory",
      :blog_post_summary => "EltenLink::BlogPostSummary",
      :blog_posts_result => "EltenLink::BlogPostsResult",
      :blog_read_entry => "EltenLink::BlogReadEntry",
      :blog_read_result => "EltenLink::BlogReadResult",
      :blog_library => "EltenLink::BlogLibraryEntry",
      :blog_managed => "EltenLink::BlogManagedEntry", :blog_item => "EltenLink::BlogItem",
      :blog_details => "EltenLink::BlogDetails", :blog_tag => "EltenLink::BlogTag",
      :blog_post_details => "EltenLink::BlogPostDetails",
      :blog_comment => "EltenLink::BlogComment", :blog_follower => "EltenLink::BlogFollower",
      :blog_mention => "EltenLink::BlogMention", :blog_post_follow => "EltenLink::BlogPostFollow",
      :note => "EltenLink::Note",
      :poll => "EltenLink::Poll", :poll_details => "EltenLink::PollDetails",
      :poll_results => "EltenLink::PollResults", :poll_answer => "EltenLink::PollAnswer"
    }.freeze

    class << self
      def model(value, name)
        key = name.to_sym
        expected = HUMAN_MODELS[key]
        raise ToolError, "Unknown MCP response model: #{name}" if expected == nil
        raise ToolError, "Unexpected #{name} response type: #{value.class.name}" if value == nil || value.class.name.to_s != expected
        public_send("present_#{key}", value)
      end

      def models(values, name)
        raise ToolError, "Expected an array of #{name}" if !values.is_a?(Array)
        values.map { |value| model(value, name) }
      end

      def present_user_status(value)
        object("status_text" => string(value, :text), "is_online" => boolean(value, :online))
      end

      def present_user_info(value)
        object(
          "username" => string(value, :name),
          "last_seen" => time_or_nil(value, :last_seen),
          "has_blog" => boolean(value, :has_blog),
          "people_in_user_contacts_count" => integer(value, :knows),
          "people_who_added_user_count" => integer(value, :known_by),
          "last_client_version" => string(value, :version),
          "registered_at" => time_or_nil(value, :registered),
          "polls_answered_count" => integer(value, :polls),
          "forum_post_count" => integer(value, :forum_posts),
          "is_in_my_contacts" => boolean(value, :in_contacts),
          "has_avatar" => boolean(value, :has_avatar),
          "is_globally_banned" => boolean(value, :banned),
          "honor_count" => integer(value, :honors),
          "can_receive_calls" => boolean(value, :callable),
          "online_monitored_by_me" => boolean(value, :monitored),
          "is_archived" => boolean(value, :archived)
        )
      end

      def present_user_profile_birthdate(value)
        object("year" => integer(value, :year), "month" => integer(value, :month), "day" => integer(value, :day))
      end

      def present_user_profile(value)
        birthdate = model(read(value, :birthdate), :user_profile_birthdate)
        year, month, day = %w[year month day].map { |field| birthdate[field] }
        public_profile = binary_flag(value, :public_profile)
        binary_flag(value, :public_mail) # Validate and deliberately discard email visibility.
        public_birthdate = if year <= 0 || month <= 0 || day <= 0
          nil
        else
          begin
            date = Time.local(year, month, day)
            raise ArgumentError if date.year != year || date.month != month || date.day != day
          rescue ArgumentError
            raise ToolError, "Invalid public profile birthdate contract"
          end
          birthdate
        end
        object(
          "username" => string(value, :name), "full_name" => string(value, :fullname),
          "gender" => DomainContracts.profile_gender(integer(value, :gender)),
          "birthdate" => public_birthdate, "location" => string(value, :location),
          "visible_to_others" => public_profile
        )
      end

      def present_client_state_profile(value)
        object(
          "full_name" => string(value, :fullname),
          "gender" => DomainContracts.profile_gender(integer(value, :gender))
        )
      end

      def present_client_state_chat(value)
        string(value, :last) # This internal server cursor has no stable public meaning.
        object("is_enabled" => boolean(value, :enabled))
      end

      def present_client_state_counts(value)
        object(
          "private_messages" => integer(value, :messages),
          "followed_threads" => integer(value, :followed_threads),
          "followed_blogs" => integer(value, :followed_blogs),
          "blog_comments" => integer(value, :blog_comments),
          "followed_forums" => integer(value, :followed_forums),
          "forum_posts" => integer(value, :forum_posts),
          "contacts" => integer(value, :friends), "birthdays" => integer(value, :birthdays),
          "forum_mentions" => integer(value, :mentions),
          "followed_blog_posts" => integer(value, :followed_blog_posts),
          "blog_followers" => integer(value, :blog_followers),
          "blog_mentions" => integer(value, :blog_mentions),
          "group_invitations" => integer(value, :group_invitations)
        )
      end

      # This aggregate is understood by MCP but is not registered as a tool: it
      # crosses account, message, forum and blog permission boundaries.
      def present_client_state(value)
        object(
          "server_time" => time_value(value, :time),
          "latest_client_version" => string(value, :version_string),
          "profile" => model(read(value, :profile), :client_state_profile),
          "chat" => model(read(value, :chat), :client_state_chat),
          "counts" => model(read(value, :counts), :client_state_counts)
        )
      end

      def present_notification(value)
        raw_category = string(value, :cat)
        application = raw_category == "app" ? present_app_notification(value) : nil
        object(
          "notification_id" => integer(value, :id),
          "created_at" => timestamp(read(value, :date)),
          "updated_at" => timestamp(read(value, :update_time)),
          "category" => DomainContracts::NOTIFICATION_CATEGORIES.fetch(raw_category, "other"),
          "alert_text" => (application == nil ? string(value, :alert) : application["title"]),
          "message" => (application == nil ? string(value, :notification) : application["body"]),
          "application" => application,
          "expires_at" => timestamp(read(value, :expiration)), "is_read" => boolean(value, :revoked)
        )
      end

      def present_app_notification(value)
        program, _notification, presentation = Programs.map_app_notification(value)
        return nil if program == nil || presentation == nil
        object(
          "name" => clean_string(program.name.to_s),
          "title" => clean_string(presentation.title.to_s),
          "body" => clean_string(presentation.body.to_s)
        )
      end

      def present_honor(value)
        number = integer(value, :level)
        levels = strings(value, :levels)
        english_levels = strings(value, :enlevels)
        object(
          "honor_id" => integer(value, :id), "name" => string(value, :name),
          "description" => string(value, :description),
          "english_name" => string(value, :enname), "english_description" => string(value, :endescription),
          "awarded_level" => honor_level(number, levels, english_levels),
          "available_levels" => honor_levels(levels, english_levels)
        )
      end

      def present_honor_user(value)
        object("username" => string(value, :name), "level_number" => integer(value, :level))
      end

      def present_message_user(value)
        identifier = string(value, :user)
        participant_type = if identifier.start_with?("[")
          "group"
        elsif boolean(value, :is_user)
          "user"
        else
          "custom"
        end
        object(
          "participant" => identifier, "participant_type" => participant_type,
          "display_name" => blank_nil(string(value, :name)),
          "conversation_is_read" => integer(value, :read) != 0,
          "group_is_muted" => boolean(value, :muted),
          "last_message" => object(
            "message_id" => integer(value, :lastid), "sent_at" => timestamp(read(value, :lastdate)),
            "sender" => string(value, :lastuser), "subject" => string(value, :lastsubject)
          )
        )
      end

      def present_message_conversation(value)
        object(
          "subject" => string(value, :subject), "is_read" => integer(value, :read) != 0,
          "last_message" => object(
            "message_id" => integer(value, :lastid), "sent_at" => timestamp(read(value, :lastdate)),
            "sender" => string(value, :lastuser)
          )
        )
      end

      def present_message(value)
        poll_ids = integers(value, :polls)
        poll_names = strings(value, :polls_names)
        attachment_names = strings(value, :attachments_names).reject(&:empty?)
        object(
          "message_id" => integer(value, :id), "sender" => string(value, :sender),
          "receiver" => string(value, :receiver), "subject" => string(value, :subject),
          "sent_at" => timestamp(read(value, :date)), "is_read" => integer(value, :mread) != 0,
          "is_flagged" => integer(value, :marked) != 0,
          "is_deletion_protected" => integer(value, :protected) != 0,
          "forwarded_from" => blank_nil(string(value, :forwardedfrom)),
          "text" => string(value, :text), "audio_transcription" => blank_nil(string(value, :transcription)),
          "has_audio" => string(value, :audio_url) != "",
          "attachments" => attachment_names.map { |name| object("name" => name) },
          "polls" => poll_ids.each_with_index.map { |id, index| object("poll_id" => id, "name" => blank_nil(poll_names[index].to_s)) }
        )
      end

      def present_message_users_list(value)
        users = models(array(value, :users), :message_user)
        object("participants" => users, "returned_count" => users.size, "more_available" => boolean(value, :more))
      end

      def present_message_conversations_list(value)
        conversations = models(array(value, :conversations), :message_conversation)
        object("participant_display_name" => string(value, :name), "conversations" => conversations,
          "returned_count" => conversations.size, "more_available" => boolean(value, :more))
      end

      def present_messages_list(value)
        messages = models(array(value, :messages), :message)
        object("conversation_display_name" => string(value, :name), "can_reply" => boolean(value, :can_reply),
          "messages" => messages, "returned_count" => messages.size, "more_available" => boolean(value, :more))
      end

      def present_forum_group(value)
        membership = DomainContracts.membership(integer(value, :role))
        public_state = boolean(value, :public)
        open_state = boolean(value, :open)
        report_visibility = { 0 => "disabled", 1 => "report_author_only", 2 => "accepted_reports", 3 => "all_reports" }.fetch(integer(value, :showpostreports)) { raise ToolError, "Unknown forum report visibility" }
        posts = integer(value, :posts)
        read_posts = integer(value, :readposts)
        object(
          "group_id" => integer(value, :id), "name" => string(value, :name),
          "description" => string(value, :description), "language" => string(value, :lang),
          "founder" => string(value, :founder), "created_at" => timestamp(read(value, :created)),
          "membership" => membership, "visibility" => (boolean(value, :hidden) ? "hidden" : (public_state ? "public" : "private")),
          "join_policy" => (public_state && open_state ? "open" : ((public_state || open_state) ? "membership_request" : "invitation_only")),
          "parent_group_id" => positive_nil(integer(value, :parent)),
          "globally_banned_users_blocked" => boolean(value, :applyglobalbans),
          "is_recommended" => boolean(value, :recommended),
          "counts" => object(
            "members" => integer(value, :acmembers), "forums" => integer(value, :forums),
            "threads" => integer(value, :threads), "posts" => posts,
            "read_posts" => read_posts, "unread_posts" => [posts - read_posts, 0].max
          ),
          "permissions" => object(
            "can_moderate" => membership == "moderator",
            "polls_allowed" => !boolean(value, :preventpolls),
            "file_attachments_allowed" => !boolean(value, :preventattachments),
            "post_reporting_allowed" => boolean(value, :allowpostreporting),
            "report_visibility" => report_visibility,
            "audio_post_limit_seconds" => integer(value, :audiolimit)
          ),
          "linked_blog" => blank_nil(nullable_string(value, :blog)),
          "featured_thread_ids" => object(
            "introductions" => positive_nil(integer(value, :thread_introductions)),
            "welcome" => positive_nil(integer(value, :thread_welcome)),
            "moderation_announcements" => positive_nil(integer(value, :thread_moderation)),
            "off_topic" => positive_nil(integer(value, :thread_hydepark))
          )
        )
      end

      def present_forum_forum(value)
        posts = integer(value, :posts)
        read_posts = integer(value, :readposts)
        object(
          "forum_id" => integer(value, :id), "name" => string(value, :fullname),
          "description" => string(value, :description), "thread_count" => integer(value, :threads),
          "post_count" => posts, "read_post_count" => read_posts,
          "unread_post_count" => [posts - read_posts, 0].max,
          "content_mode" => DomainContracts.forum_content_mode(integer(value, :type)),
          "visibility" => (boolean(value, :private) ? "private" : "public"),
          "is_followed" => boolean(value, :followed), "is_closed" => boolean(value, :closed)
        )
      end

      def present_forum_thread(value)
        posts = integer(value, :posts)
        read_posts = integer(value, :readposts)
        object(
          "thread_id" => integer(value, :id), "title" => string(value, :name),
          "author" => string(value, :author), "post_count" => posts,
          "read_post_count" => read_posts, "unread_post_count" => [posts - read_posts, 0].max,
          "last_updated_at" => timestamp(read(value, :lastupdate)),
          "is_followed" => boolean(value, :followed), "is_pinned" => boolean(value, :pinned),
          "is_closed" => boolean(value, :closed), "is_bookmarked" => boolean(value, :marked),
          "offered_to_group_id" => positive_nil(integer(value, :offered))
        )
      end

      def present_forum_post(value)
        attachments = strings(value, :attachments).reject(&:empty?)
        object(
          "post_id" => integer(value, :id),
          "author" => object("username" => string(value, :author), "display_name" => blank_nil(string(value, :authorname))),
          "date" => string(value, :date), "text" => string(value, :post),
          "signature" => blank_nil(string(value, :signature)),
          "content_format" => DomainContracts.forum_format(integer(value, :format)),
          "audio_transcription" => blank_nil(string(value, :transcription)),
          "has_audio" => string(value, :audio_url) != "",
          "attachment_count" => attachments.size, "poll_ids" => integers(value, :polls),
          "liked_by_me" => boolean(value, :liked), "like_count" => integer(value, :likes),
          "is_edited" => boolean(value, :edited), "is_locked" => boolean(value, :locked),
          "author_is_banned" => boolean(value, :banned), "is_archived" => boolean(value, :archived)
        )
      end

      def present_forum_thread_page(value)
        posts = models(array(value, :posts), :forum_post)
        total = integer(value, :count)
        read = integer(value, :read_posts)
        object(
          "retrieved_at" => timestamp(read(value, :time)), "total_post_count" => total,
          "read_post_count_before_open" => read, "unread_post_count_before_open" => [total - read, 0].max,
          "is_followed" => boolean(value, :followed), "posts" => posts, "returned_post_count" => posts.size
        )
      end

      def present_forum_trash_thread(value)
        object("thread_id" => integer(value, :id), "title" => string(value, :name),
          "forum_id" => integer(value, :forum_id), "forum_name" => string(value, :forum_fullname),
          "last_updated_at" => timestamp(read(value, :last_update)), "is_trashed" => boolean(value, :trashed),
          "thread_is_trashed" => boolean(value, :thread_trashed), "forum_is_trashed" => boolean(value, :forum_trashed),
          "contains_trashed_posts" => boolean(value, :contains_trashed_posts))
      end

      def present_forum_trash_page(value)
        posts = models(array(value, :posts), :forum_post)
        object("posts" => posts, "returned_post_count" => posts.size,
          "is_trashed" => boolean(value, :trashed), "thread_is_trashed" => boolean(value, :thread_trashed),
          "forum_is_trashed" => boolean(value, :forum_trashed))
      end

      def present_forum_user_post(value)
        object(
          "post_id" => integer(value, :post_id), "thread_id" => integer(value, :thread_id),
          "date" => string(value, :date), "text" => string(value, :text),
          "content_format" => DomainContracts.forum_format(integer(value, :format)),
          "audio_transcription" => blank_nil(string(value, :transcription)),
          "has_audio" => string(value, :audio_url) != ""
        )
      end

      def present_forum_user_posts_page(value)
        posts = models(array(value, :posts), :forum_user_post)
        object("posts" => posts, "returned_count" => posts.size, "more_available" => boolean(value, :more),
          "next_before" => nullable_integer(value, :next_before))
      end

      def present_forum_thread_stats(value)
        object(
          "followers" => integer(value, :followers), "mentions" => integer(value, :mentions),
          "distinct_authors" => integer(value, :authors), "readers" => integer(value, :readers),
          "readers_below_half" => integer(value, :readers_below_half),
          "readers_at_least_90_percent" => integer(value, :readers_above_90),
          "readers_all_posts" => integer(value, :readers_all)
        )
      end

      def present_forum_search(value)
        object("thread_id" => integer(value, :thread), "matching_post_count" => integer(value, :count))
      end

      def present_forum_member(value)
        object("username" => string(value, :user), "role" => DomainContracts.membership(integer(value, :role)),
          "role_inherited_by_child_groups" => boolean(value, :inherit),
          "expires_at" => timestamp(integer(value, :totime)))
      end

      def present_forum_tag(value)
        tags = string(value, :taglist).split(",").map(&:strip).reject(&:empty?)
        object("tag_id" => integer(value, :id), "label" => string(value, :label), "aliases" => tags)
      end

      def present_forum_group_size(value)
        audio = storage_size(value, :audio)
        attachments = storage_size(value, :attachments)
        text = storage_size(value, :text)
        object(
          "audio" => audio, "file_attachments" => attachments,
          "text" => text, "total" => audio + attachments + text
        )
      end

      def present_forum_bookmark(value)
        object("bookmark_id" => integer(value, :id), "description" => string(value, :description),
          "thread_id" => integer(value, :thread), "post_id" => integer(value, :post))
      end

      def present_forum_mention(value)
        object("mention_id" => integer(value, :id), "author" => string(value, :author),
          "thread_id" => integer(value, :thread), "post_id" => integer(value, :post),
          "message" => string(value, :message), "created_at" => timestamp(read(value, :time)))
      end

      def present_forum_report(value)
        solved = boolean(value, :solved)
        object(
          "report_id" => integer(value, :id), "reported_by" => string(value, :user),
          "thread_id" => integer(value, :thread), "post_id" => integer(value, :post),
          "reported_post_text" => string(value, :postvalue), "report_text" => string(value, :content),
          "reported_at" => timestamp(read(value, :creationtime)),
          "status" => DomainContracts.report_status(integer(value, :status), solved),
          "moderator_reason" => blank_nil(string(value, :reason)),
          "resolved_at" => timestamp(read(value, :solutiontime)),
          "resolved_by" => blank_nil(string(value, :moderator)),
          "suggestion" => present_forum_report_suggestion(value)
        )
      end

      def present_forum_report_suggestion(value)
        action = nullable_string(value, :suggestion)
        return nil if action == nil || action == ""
        raw_flags = read(value, :suggestion_flags)
        raise ToolError, "Unexpected forum report suggestion flags" if !raw_flags.is_a?(Hash)
        flags = raw_flags.transform_keys(&:to_s)
        known_actions = %w[thread_delete thread_move thread_rename thread_close thread_open thread_move_and_close thread_move_and_open thread_offer post_delete post_move post_edit]
        return object("action" => "unknown", "was_applied" => boolean(value, :suggestion_used)) if !known_actions.include?(action)
        suggestion = object("action" => action, "was_applied" => boolean(value, :suggestion_used))
        suggestion["target_forum_id"] = positive_nil(flags["forum"].to_i) if %w[thread_move thread_move_and_close thread_move_and_open].include?(action)
        suggestion["new_thread_title"] = clean_string(flags["name"].to_s) if action == "thread_rename"
        suggestion["target_group_id"] = positive_nil(flags["group"].to_i) if action == "thread_offer"
        suggestion["target_thread_id"] = positive_nil(flags["destination_thread"].to_i) if action == "post_move"
        suggestion["new_post_text"] = clean_string(flags["text"].to_s) if action == "post_edit"
        range = nullable_string(value, :suggestion_range)
        if range != nil && range != ""
          ids = range.split(",").map(&:strip)
          suggestion["post_ids"] = ids.all? { |id| id.match?(/\A[1-9][0-9]*\z/) } ? ids.map(&:to_i).uniq : nil
        end
        suggestion
      end

      def present_forum_log(value)
        source = log_target(value, "1")
        destination = log_target(value, "2")
        old_content = string(value, :oldcontent)
        new_content = string(value, :newcontent)
        action = string(value, :action).gsub(/[_-]+/, " ").strip
        object(
          "entry_id" => integer(value, :id), "performed_by" => string(value, :user),
          "performed_at" => timestamp(read(value, :time)), "action" => action,
          "source" => source, "destination" => destination,
          "content_change" => ((old_content == "" && new_content == "") ? nil : object("before" => old_content, "after" => new_content))
        )
      end

      def present_blog_category(value)
        object("category_id" => integer(value, :id), "name" => string(value, :name),
          "parent_category_id" => positive_nil(integer(value, :parent)), "post_count" => integer(value, :posts))
      end

      def present_blog_post_summary(value)
        object(
          "post_id" => integer(value, :id), "title" => string(value, :name),
          "blog" => string(value, :owner), "author" => string(value, :author),
          "published_at" => timestamp(read(value, :date)), "is_unread" => boolean(value, :unread),
          "has_audio" => boolean(value, :audio), "comment_count" => integer(value, :comments),
          "is_followed" => boolean(value, :followed), "category_ids" => identifiers(value, :categories)
        )
      end

      def present_blog_posts_result(value)
        posts = models(array(value, :posts), :blog_post_summary)
        object("posts" => posts, "returned_count" => posts.size, "more_pages_available" => boolean(value, :more))
      end

      def present_blog_read_entry(value)
        object(
          "entry_id" => integer(value, :id), "author" => string(value, :author),
          "author_is_elten_user" => boolean(value, :iseltenuser),
          "published_at" => timestamp(read(value, :date)), "modified_at" => timestamp(read(value, :moddate)),
          "excerpt" => plain_text(string(value, :excerpt)), "text" => plain_text(string(value, :text)),
          "has_audio" => string(value, :audio_url) != ""
        )
      end

      def present_blog_read_result(value)
        entries = models(array(value, :entries), :blog_read_entry)
        object("entries" => entries, "entry_count" => entries.size, "known_post_count" => integer(value, :known_posts),
          "comments_are_open" => boolean(value, :comments_open), "is_native_elten_blog" => boolean(value, :is_elten_blog))
      end

      def present_blog_library(value)
        object("blog" => string(value, :id), "library_owner" => string(value, :library_user),
          "language" => string(value, :lang), "name" => string(value, :name),
          "owner_description" => string(value, :user_description), "description" => string(value, :description),
          "public_url" => blank_nil(string(value, :url)))
      end

      def present_blog_managed(value)
        object("blog" => string(value, :id), "name" => string(value, :name))
      end

      def present_blog_item(value)
        object(
          "blog" => string(value, :id), "name" => string(value, :name),
          "description" => string(value, :description), "language" => string(value, :lang),
          "owners" => strings(value, :owners), "post_count" => integer(value, :cnt_posts),
          "comment_count" => integer(value, :cnt_comments), "last_post_at" => timestamp(read(value, :lastpost)),
          "is_followed" => boolean(value, :followed), "is_native_elten_blog" => boolean(value, :elten),
          "is_library_entry" => boolean(value, :library), "library_owner" => blank_nil(string(value, :library_user)),
          "public_url" => blank_nil(string(value, :url))
        )
      end

      def present_blog_details(value)
        object("name" => string(value, :name), "description" => string(value, :description),
          "public_url" => blank_nil(string(value, :url)), "is_library_entry" => boolean(value, :library))
      end

      def present_blog_tag(value)
        object("tag_id" => integer(value, :id), "name" => string(value, :name))
      end

      def present_blog_post_details(value)
        object(
          "title" => string(value, :title), "visibility" => (boolean(value, :private) ? "private" : "public"),
          "comments_enabled" => boolean(value, :comments), "category_ids" => identifiers(value, :categories),
          "tag_ids" => identifiers(value, :tags), "published_at" => timestamp(read(value, :date)),
          "content" => string(value, :content), "excerpt" => string(value, :excerpt)
        )
      end

      def present_blog_comment(value)
        object("comment_id" => integer(value, :id), "author" => string(value, :author),
          "post_title" => string(value, :postname), "text" => plain_text(string(value, :content)))
      end

      def present_blog_follower(value)
        object("blog" => string(value, :blog), "blog_name" => string(value, :blog_name), "username" => string(value, :user))
      end

      def present_blog_mention(value)
        object("mention_id" => integer(value, :id), "blog" => string(value, :blog),
          "post_id" => integer(value, :post), "author" => string(value, :author),
          "created_at" => timestamp(read(value, :time)), "message" => string(value, :message))
      end

      def present_blog_post_follow(value)
        object("blog" => string(value, :blog), "post_id" => integer(value, :post_id))
      end

      def present_note(value)
        object("note_id" => integer(value, :id), "title" => string(value, :name), "text" => string(value, :text),
          "author" => string(value, :author), "created_at" => timestamp(read(value, :created)),
          "modified_at" => timestamp(read(value, :modified)))
      end

      def present_poll(value)
        object("poll_id" => integer(value, :id), "name" => string(value, :name), "author" => string(value, :author),
          "description" => string(value, :description), "created_at" => timestamp(read(value, :created)),
          "language" => string(value, :language), "answered_by_me" => boolean(value, :voted),
          "vote_count" => integer(value, :votes))
      end

      def present_poll_details(value)
        base = present_poll(value)
        base["questions"] = poll_questions(array(value, :questions))
        base
      end

      def present_poll_results(value)
        answers = models(array(value, :answers), :poll_answer)
        object("vote_count" => integer(value, :votes), "answers" => answers)
      end

      def present_poll_answer(value)
        object("anonymous_respondent_id" => integer(value, :author), "question_index" => integer(value, :question),
          "answer_value" => string(value, :answer))
      end

      def poll_questions(values)
        raise ToolError, "Expected poll questions array" if !values.is_a?(Array)
        values.each_with_index.map do |question, index|
          raise ToolError, "Unexpected poll question contract" if !question.is_a?(Array) || question.size < 2
          raise ToolError, "Poll question text must be text" if !question[0].is_a?(String)
          text = clean_string(question[0])
          kind, maximum = DomainContracts.poll_kind(question[1])
          options = question[2..-1].to_a.each_with_index.map do |option, option_index|
            raise ToolError, "Poll option must be text" if !option.is_a?(String)
            object("option_index" => option_index, "text" => option)
          end
          object("question_index" => index, "text" => text, "kind" => kind,
            "maximum_choices" => maximum, "options" => options)
        end
      end

      private

      def read(value, field)
        raise ToolError, "Missing expected #{value.class.name}.#{field} field" if !value.respond_to?(field)
        value.public_send(field)
      end

      def string(value, field)
        item = read(value, field)
        raise ToolError, "Expected text in #{value.class.name}.#{field}" if !item.is_a?(String)
        clean_string(item)
      end

      def nullable_string(value, field)
        item = read(value, field)
        return nil if item == nil
        raise ToolError, "Expected text in #{value.class.name}.#{field}" if !item.is_a?(String)
        clean_string(item)
      end

      def integer(value, field)
        item = read(value, field)
        raise ToolError, "Expected integer in #{value.class.name}.#{field}" if !item.is_a?(Integer)
        item
      end

      def nullable_integer(value, field)
        item = read(value, field)
        return nil if item == nil
        raise ToolError, "Expected integer in #{value.class.name}.#{field}" if !item.is_a?(Integer)
        item
      end

      def boolean(value, field)
        item = read(value, field)
        raise ToolError, "Expected boolean in #{value.class.name}.#{field}" if item != true && item != false
        item
      end

      def binary_flag(value, field)
        item = integer(value, field)
        raise ToolError, "Expected zero or one in #{value.class.name}.#{field}" if ![0, 1].include?(item)
        item == 1
      end

      def time_or_nil(value, field)
        item = read(value, field)
        raise ToolError, "Expected Time or nil in #{value.class.name}.#{field}" if item != nil && !item.is_a?(Time)
        timestamp(item)
      end

      def time_value(value, field)
        item = read(value, field)
        raise ToolError, "Expected Time in #{value.class.name}.#{field}" if !item.is_a?(Time)
        timestamp(item)
      end

      def storage_size(value, field)
        item = integer(value, field)
        raise ToolError, "Expected a non-negative byte size in #{value.class.name}.#{field}" if item < 0
        item
      end

      def array(value, field)
        item = read(value, field)
        raise ToolError, "Expected array in #{value.class.name}.#{field}" if !item.is_a?(Array)
        item
      end

      def strings(value, field)
        array(value, field).map do |item|
          raise ToolError, "Expected text array in #{value.class.name}.#{field}" if !item.is_a?(String)
          clean_string(item)
        end
      end

      def integers(value, field)
        array(value, field).map do |item|
          raise ToolError, "Expected integer array in #{value.class.name}.#{field}" if !item.is_a?(Integer)
          item
        end
      end

      def identifiers(value, field)
        array(value, field).map do |item|
          next item if item.is_a?(Integer)
          next clean_string(item) if item.is_a?(String)
          raise ToolError, "Expected identifier array in #{value.class.name}.#{field}"
        end
      end

      def timestamp(value)
        return nil if value == nil
        return nil if value.is_a?(Numeric) && value.to_i <= 0
        return value.iso8601 if value.is_a?(Time)
        return Time.at(value.to_i).iso8601 if value.is_a?(Numeric)
        return clean_string(value) if value.is_a?(String) && value != ""
        return nil if value == ""
        raise ToolError, "Expected a time value"
      end

      def date_value(value)
        timestamp(value)
      end

      def blank_nil(value)
        value.to_s == "" ? nil : value
      end

      def positive_nil(value)
        value.to_i > 0 ? value.to_i : nil
      end

      def honor_level(number, levels, english_levels)
        return nil if number <= 0
        index = number - 1
        object("number" => number, "name" => blank_nil(levels[index].to_s), "english_name" => blank_nil(english_levels[index].to_s))
      end

      def honor_levels(levels, english_levels)
        [levels.size, english_levels.size].max.times.map do |index|
          object("number" => index + 1, "name" => blank_nil(levels[index].to_s), "english_name" => blank_nil(english_levels[index].to_s))
        end
      end

      def log_target(value, suffix)
        fields = %w[group forum thread post]
        values = fields.each_with_object({}) do |field, mapped|
          id = integer(value, "#{field}#{suffix}".to_sym)
          mapped["#{field}_id"] = id if id > 0
        end
        values.empty? ? nil : object(values)
      end

      def plain_text(value)
        return EltenAPI::Html.text(value, compact: false) if defined?(EltenAPI::Html)
        clean_string(value.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip)
      rescue Exception
        clean_string(value.to_s)
      end
    end
  end
end
