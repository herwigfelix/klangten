# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded for Klangten.

module EltenMCP
  module DomainCommunication
    MESSAGE_READ_WARNING = "Fetching private-message content can update its read state in Elten. Ask the user first when preserving unread state matters, then retry with acknowledge_read_state=true.".freeze
    BLOG_READ_WARNING = "Opening a blog post can update its read state in Elten. Ask the user first when preserving unread state matters, then retry with acknowledge_read_state=true.".freeze

    def register_communication_tools
      register_message_tools
      register_blog_tools
    end

    private

    def register_message_tools
      register_domain_tool(
        "messages_scope", "List selectable message correspondents",
        "Discovery protected by the minimal messages/scope level. Return correspondent identifiers, display names and whether each is a user, group or custom conversation, but never message content. Request messages/scope first, analyze the result, then make one bulk selective request or request the necessary full messages level.",
        :messages, :scope,
        {
          "type" => "object",
          "properties" => { "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500 } },
          "additionalProperties" => false
        }
      ) do |args|
        client = network_client
        raw_page = EltenLink::Messages.users(client, :limit => bounded(args["limit"], 1, 500, 500))
        participants = (raw_page.users + EltenLink::Messages.groups(client)).uniq { |participant| participant.user.to_s.downcase }
        @authorization.remember_message_participants(participants)
        correspondents = participants.map do |participant|
          identifier = participant.user.to_s
          type = if identifier.start_with?("[")
            "group"
          elsif participant.is_user == true
            "user"
          else
            "custom"
          end
          display_name = participant.name.to_s.strip
          result(
            "participant" => identifier,
            "participant_type" => type,
            "display_name" => (display_name == "" ? nil : display_name)
          )
        end
        response("scope", "Returned #{correspondents.size} correspondents available as selective message-permission scopes. No message content or last-message metadata was returned.",
          "correspondents" => correspondents, "returned_count" => correspondents.size,
          "more_available" => raw_page.more == true)
      end

      register_domain_tool(
        "messages_read", "Read private messages",
        "Read private messages through named conversation, message and pagination fields. Message flags are translated to booleans, attachments expose names rather than server handles, and audio URLs are not forwarded.",
        :messages, :read, action_schema(%w[participants conversations messages flagged search group_members], :messages),
        mutating_annotations
      ) do |args|
        if args["action"] == "messages" && args["acknowledge_read_state"] != true
          next confirmation_required("messages", MESSAGE_READ_WARNING)
        end
        client = network_client
        case args["action"]
        when "participants"
          raw_page = EltenLink::Messages.users(client, :limit => bounded(args["limit"], 1, 500, 100))
          @authorization.remember_message_participants(raw_page.users)
          page = known(raw_page, :message_users_list)
          response("participants", "Returned #{page["returned_count"]} private-message participants.", page)
        when "conversations"
          user = required_string(args, "user")
          page = known(EltenLink::Messages.conversations(client, :user => user, :limit => bounded(args["limit"], 1, 500, 100)), :message_conversations_list)
          response("conversations", "Returned #{page["returned_count"]} conversations with #{user}.", { "participant" => user }.merge(page))
        when "messages"
          user = required_string(args, "user")
          raw_page = EltenLink::Messages.messages(client, :user => user, :subject => args["subject"], :limit => bounded(args["limit"], 1, 500, 100))
          @authorization.remember_messages(user, raw_page.messages)
          page = known(raw_page, :messages_list)
          response("messages", "Returned #{page["returned_count"]} messages. Their unread state may now be updated in Elten.",
            { "participant" => user, "subject" => args["subject"], "read_state_effect" => MESSAGE_READ_WARNING }.merge(page))
        when "flagged"
          page = known(EltenLink::Messages.flagged_messages(client), :messages_list)
          response("flagged", "Returned #{page["returned_count"]} flagged messages.", page)
        when "search"
          query = required_string(args, "query")
          page = known(EltenLink::Messages.search_messages(client, query), :messages_list)
          response("search", "Returned #{page["returned_count"]} private messages matching '#{query}'.", { "query" => query }.merge(page))
        when "group_members"
          group_id = required_string(args, "group_id")
          users = string_values(EltenLink::Messages.group_users(client, group_id))
          response("group_members", "Returned #{users.size} members of the private-message group.", "group_id" => group_id, "members" => users, "count" => users.size)
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "messages_write", "Send private messages and edit groups",
        "Send or forward messages, or create and update private-message groups. Forwarding spans a source message and destination correspondent, so it requires the full messages/write grant. This tool cannot send as an administrator or upload local files. Message-state changes, flags, protection, deletion, leaving and muting require messages/moderate through messages_moderate.",
        :messages, :write,
        action_schema(%w[send forward create_group update_group], :messages),
        destructive_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "send"
          receiver = required_string(args, "to")
          subject = args.key?("subject") ? required_string(args, "subject", true) : ""
          polls = args.key?("poll_ids") ? positive_ids(args["poll_ids"]) : []
          EltenLink::Messages.send_text(client, :to => receiver, :subject => subject,
            :text => required_string(args, "text", true), :attachments => [], :polls => polls, :admin => false)
          completed("send", "Sent a private message to #{receiver}.", "recipient" => receiver, "subject" => subject, "poll_ids" => polls)
        when "forward"
          id = positive_id(args, "message_id")
          receiver = required_string(args, "to")
          EltenLink::Messages.forward(client, id, :to => receiver)
          completed("forward", "Forwarded private message #{id} to #{receiver}.", "message_id" => id, "recipient" => receiver)
        when "create_group"
          name = required_string(args, "name")
          users = string_array(args, "users", 200)
          EltenLink::Messages.save_group(client, :name => name, :users => users)
          completed("create_group", "Created private-message group '#{name}' with #{users.size} members.", "name" => name, "members" => users)
        when "update_group"
          group_id = required_string(args, "group_id")
          name = required_string(args, "name")
          users = args.key?("add_users") ? string_array(args, "add_users", 200) : []
          EltenLink::Messages.save_group(client, :name => name, :users => [], :group_id => group_id, :addusers => users)
          completed("update_group", "Renamed private-message group #{group_id} to '#{name}'#{users.empty? ? "" : " and added #{users.size} members"}.", "group_id" => group_id, "name" => name, "added_members" => users)
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "messages_moderate", "Manage private-message state and deletion",
        "Change read, flag and deletion-protection state; delete messages, conversations or participant history; and leave, mute or unmute message groups. These personal management and destructive actions require messages/moderate.",
        :messages, :moderate,
        action_schema(%w[mark_all_read set_flagged set_deletion_protected delete_message delete_conversation remove_participant leave_group mute_group unmute_group], :messages),
        destructive_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "mark_all_read"
          EltenLink::Messages.mark_all_read(client, :user => args["user"])
          completed("mark_all_read", args["user"] == nil ? "Marked all private messages as read." : "Marked private messages with #{args["user"]} as read.", "participant" => args["user"])
        when "set_flagged"
          id = positive_id(args, "message_id")
          state = boolean_arg(args, "flagged")
          EltenLink::Messages.set_marked(client, id, state)
          completed("set_flagged", "Set message #{id} flagged state to #{state}.", "message_id" => id, "is_flagged" => state)
        when "set_deletion_protected"
          id = positive_id(args, "message_id")
          state = boolean_arg(args, "deletion_protected")
          EltenLink::Messages.set_protected(client, id, state)
          completed("set_deletion_protected", "Set message #{id} deletion protection to #{state}.", "message_id" => id, "is_deletion_protected" => state)
        when "delete_message"
          id = positive_id(args, "message_id")
          EltenLink::Messages.delete_message(client, id)
          completed("delete_message", "Deleted private message #{id}.", "message_id" => id)
        when "delete_conversation"
          user = required_string(args, "user")
          subject = required_string(args, "subject", true)
          EltenLink::Messages.delete_conversation(client, :user => user, :subject => subject)
          completed("delete_conversation", "Deleted the conversation with #{user} and subject '#{subject}'.", "participant" => user, "subject" => subject)
        when "remove_participant"
          user = required_string(args, "user")
          EltenLink::Messages.delete_user(client, user)
          completed("remove_participant", "Removed #{user} from the private-message participant history.", "participant" => user)
        when "leave_group"
          group_id = required_string(args, "group_id")
          EltenLink::Messages.leave_group(client, group_id)
          completed("leave_group", "Left private-message group #{group_id}.", "group_id" => group_id)
        when "mute_group"
          group_id = required_string(args, "group_id")
          seconds = bounded(args["duration_seconds"], 0, 31_536_000, 0)
          EltenLink::Messages.mute_group(client, group_id, :seconds => seconds)
          completed("mute_group", seconds == 0 ? "Muted group #{group_id} without automatic expiry." : "Muted group #{group_id} for #{seconds} seconds.",
            "group_id" => group_id, "duration_seconds" => seconds)
        when "unmute_group"
          group_id = required_string(args, "group_id")
          EltenLink::Messages.unmute_group(client, group_id)
          completed("unmute_group", "Unmuted private-message group #{group_id}.", "group_id" => group_id)
        else invalid_action(args["action"])
        end
      end
    end

    def register_blog_tools
      register_domain_tool(
        "blogs_scope", "Discover blog permission scopes",
        "Always-available permission discovery for blogs and posts. Returns only identifiers and names/titles, never post or comment content. Blog and post creation are separate scopes.",
        :basic, :read,
        {
          "oneOf" => [
            {
              "type" => "object", "properties" => { "action" => { "type" => "string", "enum" => %w[blogs] } },
              "required" => ["action"], "additionalProperties" => false
            },
            {
              "type" => "object", "properties" => {
              "action" => { "type" => "string", "enum" => %w[posts] },
              "blog" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
              "page" => { "type" => "integer", "minimum" => 1, "maximum" => 2_147_483_647 }
              }, "required" => %w[action blog], "additionalProperties" => false
            }
          ]
        }
      ) do |args|
        client = network_client
        case args["action"]
        when "blogs"
          raw = (EltenLink::Blog.list(client) + EltenLink::Blog.managed(client)).uniq { |blog| blog.id.to_s.downcase }
          @authorization.remember_blogs(raw)
          scopes = raw.map { |blog| result("blog" => blog.id.to_s, "name" => blog.name.to_s) }
          response("blogs", "Returned #{scopes.size} blog permission scopes without post content.",
            "blogs" => scopes, "count" => scopes.size,
            "creation_scope" => result("aspect" => "blogs", "resource_type" => "blog_creation", "level" => "write"))
        when "posts"
          blog = required_string(args, "blog")
          page_number = args["page"] || 1
          raw = EltenLink::Blog.posts(client, :blog => blog, :page => page_number)
          posts = Array(raw.posts)
          @authorization.remember_blog_posts(blog, posts)
          scopes = posts.map { |post| result("post_id" => post.id, "title" => post.name.to_s) }
          response("posts", "Returned #{scopes.size} post permission scopes from #{blog} without post content.",
            "blog" => blog, "posts" => scopes, "count" => scopes.size, "page" => page_number,
            "has_more" => raw.more == true,
            "creation_scope" => result("aspect" => "blogs", "resource_type" => "post_creation", "resource_id" => blog, "level" => "write"))
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "blogs_read", "Read blogs",
        "Read blogs through named, task-oriented models. Epoch dates, unread states and category relationships are translated; post content is returned as readable text and raw blog option/profile JSON is never exposed.",
        :blogs, :read, action_schema(%w[list exists details categories posts post managed mentions post_details comments followers new_followers followed_posts post_followed library tags owners], :blogs),
        mutating_annotations
      ) do |args|
        if args["action"] == "post" && args["acknowledge_read_state"] != true
          next confirmation_required("post", BLOG_READ_WARNING)
        end
        client = network_client
        blog = args.key?("blog") ? required_string(args, "blog") : session_name
        case args["action"]
        when "list"
          sort = args["sort_by"] || "recently_updated"
          raw = EltenLink::Blog.list(client, :owner => args["owner"], :orderby => DomainContracts::BLOG_SORTS.fetch(sort))
          @authorization.remember_blogs(raw)
          blogs = known_list(raw, :blog_item)
          response("list", "Returned #{blogs.size} blogs sorted by #{sort}.", "blogs" => blogs, "count" => blogs.size, "owner_filter" => args["owner"], "sort_by" => sort)
        when "exists"
          exists = server_boolean(EltenLink::Blog.exists?(client, :blog => blog), "blog existence")
          response("exists", exists ? "Blog #{blog} exists." : "Blog #{blog} does not exist.", "blog" => blog, "exists" => exists)
        when "details"
          response("details", "Returned details for blog #{blog}.", "blog" => blog, "details" => known(EltenLink::Blog.details(client, :blog => blog), :blog_details))
        when "categories"
          categories = blog_categories(client, blog)
          response("categories", "Returned #{categories["categories"].size} categories for #{blog}.", { "blog" => blog }.merge(categories))
        when "posts"
          raw = EltenLink::Blog.posts(client, :blog => blog, :category_id => args["category_id"], :page => args["page"], :search => args["query"])
          @authorization.remember_blog_posts(blog, raw.posts)
          page = known(raw, :blog_posts_result)
          response("posts", "Returned #{page["returned_count"]} posts from #{blog}.", { "blog" => blog, "page" => (args["page"] || 1), "query" => args["query"] }.merge(page))
        when "post"
          post_id = positive_id(args, "post_id")
          post = known(EltenLink::Blog.read_post(client, :blog => blog, :post_id => post_id), :blog_read_result)
          @authorization.remember_blog_post(blog, post_id)
          response("post", "Returned blog post #{post_id}. Its unread state may now be updated in Elten.",
            "blog" => blog, "post_id" => post_id, "read_state_effect" => BLOG_READ_WARNING, "post" => post)
        when "managed"
          raw = EltenLink::Blog.managed(client)
          @authorization.remember_blogs(raw)
          blogs = known_list(raw, :blog_managed)
          response("managed", "Returned #{blogs.size} blogs managed by the signed-in user.", "blogs" => blogs, "count" => blogs.size)
        when "mentions"
          raw = EltenLink::Blog.list_mentions(client, :all => args["include_seen"] == true)
          @authorization.remember_blog_mentions(raw)
          mentions = known_list(raw, :blog_mention)
          response("mentions", "Returned #{mentions.size} blog mentions.", "mentions" => mentions, "count" => mentions.size, "includes_seen" => args["include_seen"] == true)
        when "post_details"
          post_id = positive_id(args, "post_id")
          @authorization.remember_blog_post(blog, post_id)
          response("post_details", "Returned editable details for post #{post_id}.", "blog" => blog, "post_id" => post_id,
            "details" => known(EltenLink::Blog.post_details(client, :blog => blog, :post_id => post_id), :blog_post_details))
        when "comments"
          status = args["comment_status"] || "pending"
          comments = known_list(EltenLink::Blog.comments_list(client, :blog => blog, :status => DomainContracts::BLOG_COMMENT_STATUSES.fetch(status)), :blog_comment)
          response("comments", "Returned #{comments.size} #{status} comments for #{blog}.", "blog" => blog, "comment_status" => status, "comments" => comments, "count" => comments.size)
        when "followers"
          followers = known_list(EltenLink::Blog.followers(client, :blog => blog), :blog_follower)
          response("followers", "Returned #{followers.size} followers for #{blog}.", "blog" => blog, "followers" => followers, "count" => followers.size)
        when "new_followers"
          followers = known_list(EltenLink::Blog.new_followers(client), :blog_follower)
          response("new_followers", "Returned #{followers.size} new blog-follower notices.", "followers" => followers, "count" => followers.size)
        when "followed_posts"
          posts = known_list(EltenLink::Blog.followed_posts(client), :blog_post_follow)
          response("followed_posts", "Returned #{posts.size} followed blog posts.", "posts" => posts, "count" => posts.size)
        when "post_followed"
          post_id = positive_id(args, "post_id")
          @authorization.remember_blog_post(blog, post_id)
          followed = server_boolean(EltenLink::Blog.post_followed?(client, :blog => blog, :post_id => post_id), "blog post followed state")
          response("post_followed", followed ? "Post #{post_id} is followed." : "Post #{post_id} is not followed.", "blog" => blog, "post_id" => post_id, "is_followed" => followed)
        when "library"
          blogs = known_list(EltenLink::Blog.library_list(client), :blog_library)
          response("library", "Returned #{blogs.size} blog-library entries.", "blogs" => blogs, "count" => blogs.size)
        when "tags"
          tags = known_list(EltenLink::Blog.tags_list(client, :blog => blog), :blog_tag)
          response("tags", "Returned #{tags.size} tags for #{blog}.", "blog" => blog, "tags" => tags, "count" => tags.size)
        when "owners"
          owners = string_values(EltenLink::Blog.owners(client, :blog => blog))
          response("owners", "Returned #{owners.size} owners and coworkers for #{blog}.", "blog" => blog, "owners" => owners, "count" => owners.size)
        else invalid_action(args["action"])
        end
      end

      register_blog_write_tool
    end

    def register_blog_write_tool
      register_domain_tool(
        "blogs_write", "Write and manage blogs",
        "Create and manage blogs through semantic fields. The program translates visibility, comment states, dates and ID lists to Klango server calls; no server parameter names or raw WordPress contracts are accepted.",
        :blogs, :write,
        action_schema(%w[create_blog delete_blog create_post update_post delete_post create_comment follow unfollow mark_read follow_post unfollow_post create_category rename_category delete_category create_tag delete_tag set_comment_status delete_comment add_coworker remove_coworker leave_coworkers send_mentions acknowledge_mention], :blogs),
        destructive_annotations
      ) do |args|
        client = network_client
        blog = args.key?("blog") ? required_string(args, "blog") : session_name
        case args["action"]
        when "create_blog"
          name = required_string(args, "name")
          description = args.key?("description") ? required_string(args, "description", true) : ""
          created_blog = server_string(EltenLink::Blog.create_blog(client, :name => name, :shared => args["shared"] == true, :description => description), "created blog identifier")
          @authorization.remember_blogs([EltenLink::BlogManagedEntry.new(:id => created_blog, :name => name)])
          completed("create_blog", "Created blog '#{name}'.", "blog" => created_blog, "name" => name, "is_shared" => args["shared"] == true)
        when "delete_blog"
          EltenLink::Blog.delete_blog(client, :blog => blog)
          completed("delete_blog", "Deleted blog #{blog} and its posts.", "blog" => blog)
        when "create_post"
          post_id = EltenLink::Blog.create_post(client, **blog_post_values(args, blog, true))
          post_id = server_integer(post_id, "created blog post id", true)
          @authorization.remember_blog_post(blog, post_id, args["title"])
          completed("create_post", "Created blog post #{post_id} in #{blog}.", "blog" => blog, "post_id" => post_id)
        when "update_post"
          post_id = positive_id(args, "post_id")
          changed = blog_post_values(args, blog, false)
          EltenLink::Blog.update_post(client, **changed.merge(:post_id => post_id))
          @authorization.remember_blog_post(blog, post_id, args["title"])
          completed("update_post", "Updated post #{post_id} in #{blog}.", "blog" => blog, "post_id" => post_id, "changed_fields" => changed.keys.map(&:to_s) - ["blog"])
        when "delete_post"
          post_id = positive_id(args, "post_id")
          EltenLink::Blog.delete_post(client, :blog => blog, :post_id => post_id)
          completed("delete_post", "Deleted post #{post_id} from #{blog}.", "blog" => blog, "post_id" => post_id)
        when "create_comment"
          post_id = positive_id(args, "post_id")
          EltenLink::Blog.create_comment(client, :blog => blog, :post_id => post_id, :content => required_string(args, "content", true))
          completed("create_comment", "Added a comment to post #{post_id} in #{blog}.", "blog" => blog, "post_id" => post_id)
        when "follow", "unfollow"
          args["action"] == "follow" ? EltenLink::Blog.follow(client, :blog => blog) : EltenLink::Blog.unfollow(client, :blog => blog)
          state = args["action"] == "follow"
          completed(args["action"], state ? "Now following blog #{blog}." : "Stopped following blog #{blog}.", "blog" => blog, "is_followed" => state)
        when "mark_read"
          EltenLink::Blog.mark_as_read(client, :blog => blog)
          completed("mark_read", "Marked all current posts in #{blog} as read.", "blog" => blog)
        when "follow_post", "unfollow_post"
          post_id = positive_id(args, "post_id")
          if args["action"] == "follow_post"
            EltenLink::Blog.follow_post(client, :blog => blog, :post_id => post_id)
          else
            EltenLink::Blog.unfollow_post(client, :blog => blog, :post_id => post_id)
          end
          state = args["action"] == "follow_post"
          completed(args["action"], state ? "Now following post #{post_id}." : "Stopped following post #{post_id}.",
            "blog" => blog, "post_id" => post_id, "is_followed" => state)
        when "create_category"
          name = required_string(args, "name")
          id = EltenLink::Blog.create_category(client, :blog => blog, :name => name)
          id = server_integer(id, "created blog category id", true)
          completed("create_category", "Created category '#{name}' in #{blog}.", "blog" => blog, "category_id" => id, "name" => name)
        when "rename_category"
          id = positive_id(args, "category_id")
          name = required_string(args, "name")
          EltenLink::Blog.rename_category(client, :blog => blog, :category_id => id, :name => name)
          completed("rename_category", "Renamed category #{id} to '#{name}'.", "blog" => blog, "category_id" => id, "name" => name)
        when "delete_category"
          id = positive_id(args, "category_id")
          EltenLink::Blog.delete_category(client, :blog => blog, :category_id => id)
          completed("delete_category", "Deleted category #{id} from #{blog}.", "blog" => blog, "category_id" => id)
        when "create_tag"
          name = required_string(args, "name")
          id = EltenLink::Blog.tag_create(client, :blog => blog, :name => name)
          id = server_integer(id, "created blog tag id", true)
          completed("create_tag", "Created tag '#{name}' in #{blog}.", "blog" => blog, "tag_id" => id, "name" => name)
        when "delete_tag"
          id = positive_id(args, "tag_id")
          EltenLink::Blog.tag_delete(client, :blog => blog, :tag_id => id)
          completed("delete_tag", "Deleted tag #{id} from #{blog}.", "blog" => blog, "tag_id" => id)
        when "set_comment_status"
          id = positive_id(args, "comment_id")
          status = required_string(args, "comment_status")
          server_status = DomainContracts::BLOG_COMMENT_STATUSES.fetch(status) { raise InvalidParamsError, "Unknown comment_status" }
          EltenLink::Blog.comment_assign(client, :blog => blog, :comment_id => id, :status => server_status)
          completed("set_comment_status", "Set comment #{id} status to #{status}.", "blog" => blog, "comment_id" => id, "comment_status" => status)
        when "delete_comment"
          id = positive_id(args, "comment_id")
          EltenLink::Blog.comment_delete(client, :blog => blog, :comment_id => id)
          completed("delete_comment", "Deleted comment #{id} from #{blog}.", "blog" => blog, "comment_id" => id)
        when "add_coworker", "remove_coworker"
          user = required_string(args, "user")
          if args["action"] == "add_coworker"
            EltenLink::Blog.add_coworker(client, :blog => blog, :user => user)
          else
            EltenLink::Blog.remove_coworker(client, :blog => blog, :user => user)
          end
          completed(args["action"], args["action"] == "add_coworker" ? "Added #{user} as a coworker of #{blog}." : "Removed #{user} as a coworker of #{blog}.",
            "blog" => blog, "user" => user)
        when "leave_coworkers"
          EltenLink::Blog.leave_coworkers(client, :blog => blog)
          completed("leave_coworkers", "Left shared blog #{blog}.", "blog" => blog)
        when "send_mentions"
          users = string_array(args, "users", 100)
          post_id = positive_id(args, "post_id")
          ids = EltenLink::Blog.send_mentions(client, :users => users, :blog => blog, :post_id => post_id,
            :message => (args.key?("message") ? required_string(args, "message", true) : ""))
          ids = integer_array(ids)
          @authorization.remember_blog_mentions(ids.map { |id| EltenLink::BlogMention.new(:id => id, :blog => blog, :post => post_id) })
          completed("send_mentions", "Created #{ids.size} blog mentions in one operation.", "blog" => blog, "post_id" => post_id, "users" => users, "mention_ids" => ids)
        when "acknowledge_mention"
          id = positive_id(args, "mention_id")
          EltenLink::Blog.read_mention(client, :mention_id => id)
          completed("acknowledge_mention", "Marked blog mention #{id} as seen.", "mention_id" => id)
        else invalid_action(args["action"])
        end
      end
    end

    def blog_categories(client, blog)
      value = EltenLink::Blog.categories(client, :blog => blog)
      raise ToolError, "Unexpected blog categories contract" if !value.respond_to?(:name) || !value.respond_to?(:categories)
      result("name" => server_string(value.name, "blog category list name"), "categories" => known_list(value.categories, :blog_category))
    end

    def blog_post_values(args, blog, creating)
      values = { :blog => blog }
      values[:title] = required_string(args, "title") if args.key?("title")
      values[:content] = required_string(args, "content", true) if args.key?("content")
      values[:excerpt] = required_string(args, "excerpt", true) if args.key?("excerpt")
      values[:categories] = positive_ids(args["category_ids"]) if args.key?("category_ids")
      values[:tags] = positive_ids(args["tag_ids"]) if args.key?("tag_ids")
      if args.key?("visibility")
        values[:private] = case args["visibility"]
        when "public" then false
        when "private" then true
        else raise InvalidParamsError, "visibility must be public or private"
        end
      end
      values[:comments] = boolean_arg(args, "comments_enabled") if args.key?("comments_enabled")
      values[:date] = epoch_argument(args["publish_at"]) if args.key?("publish_at")
      values[:title] = required_string(args, "title") if creating
      raise InvalidParamsError, "At least one post field is required" if !creating && values.size == 1
      values
    end
  end
end
