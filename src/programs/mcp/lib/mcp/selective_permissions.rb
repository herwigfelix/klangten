# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: note grants replace organizer grants; calendars and task projects removed.

module EltenMCP
  # Resource-scoped grants which complement (and never replace) Authorization's
  # domain-wide grants. Authorization may optionally persist their public form
  # in an explicitly enabled, account/key/client-scoped permission profile.
  class SelectivePermissions
    MAX_REQUESTS = 100
    DEFINITIONS = {
      :forum => {
        :resource_types => [:group, :forum, :thread],
        :levels => [:read, :write, :moderate]
      },
      :messages => {
        :resource_types => [:user, :group, :custom],
        :levels => [:read, :write, :moderate]
      },
      :notes => {
        :resource_types => [:note, :note_creation],
        :levels => [:read, :write]
      },
      :blogs => {
        :resource_types => [:blog, :post, :blog_creation, :post_creation],
        :levels => [:read, :write]
      }
    }.freeze

    def initialize(bridge)
      @bridge = bridge
      @grants = Hash.new { |hash, key| hash[key] = {} }
      @forum_labels = {}
      @forum_forums = {}
      @forum_threads = {}
      @forum_post_threads = {}
      @message_labels = {}
      @message_types = {}
      @message_participants = {}
      @message_ids = {}
      @note_labels = {}
      @blog_ids = {}
      @blog_labels = {}
      @blog_mentions = {}
    end

    def clear_all
      @grants.clear
      clear_catalogs
      true
    end

    def count
      @grants.values.map(&:size).sum
    end

    def authorized_client_ids
      @grants.select { |_client_id, grants| !grants.empty? }.keys
    end

    def definitions
      DEFINITIONS.each_with_object({}) do |(aspect, definition), result|
        result[aspect.to_s] = {
          "resource_types" => definition[:resource_types].map(&:to_s),
          "levels" => definition[:levels].map(&:to_s),
          "inheritance" => inheritance_description(aspect)
        }
      end
    end

    def summary_for(client_id)
      @grants[client_id].map do |(aspect, type, canonical_id), level|
        public_grant(aspect, type, canonical_id, level)
      end.sort_by { |grant| [grant["aspect"], grant["resource_type"], grant["label"].downcase] }
    end

    def replace_for(client_id, grants)
      @grants.delete(client_id)
      Array(grants).first(MAX_REQUESTS).each do |grant|
        request = normalize_request(grant)
        set(client_id, request, request[:level])
      rescue EltenMCP::Error => e
        Log.warning("Ignoring invalid remembered selective MCP permission: #{e.message}") if defined?(Log)
      end
      summary_for(client_id)
    end

    def clear_client(client_id)
      @grants.delete(client_id)
      true
    end

    def remember_forum_structure(structure)
      Array(structure.groups).each do |group|
        id = positive_identifier(group.id)
        @forum_labels[[:group, id]] = group.name.to_s
      end
      Array(structure.forums).each do |forum|
        id = positive_identifier(forum.id)
        group = forum.respond_to?(:group) ? forum.group : nil
        group_id = group == nil ? nil : positive_identifier(group.id)
        @forum_forums[id] = group_id if group_id != nil
        @forum_labels[[:forum, id]] = forum.fullname.to_s
      end
      Array(structure.threads).each do |thread|
        id = positive_identifier(thread.id)
        forum = thread.respond_to?(:forum) ? thread.forum : nil
        forum_id = forum == nil ? nil : positive_identifier(forum.id)
        group = forum != nil && forum.respond_to?(:group) ? forum.group : nil
        group_id = group == nil ? nil : positive_identifier(group.id)
        @forum_threads[id] = [forum_id, group_id]
        @forum_labels[[:thread, id]] = thread.name.to_s
      end
      true
    end

    def remember_forum_trash_threads(group_id, threads)
      group_id = positive_identifier(group_id)
      return false if group_id == nil
      Array(threads).each do |thread|
        id = positive_identifier(thread.id)
        forum_id = positive_identifier(thread.forum_id)
        next if id == nil || forum_id == nil
        # A trash result establishes the parent group even when the deleted
        # forum or thread is absent from the ordinary discovery hierarchy.
        @forum_forums[forum_id] = group_id
        @forum_threads[id] = [forum_id, group_id]
        @forum_labels[[:forum, forum_id]] = thread.forum_fullname.to_s
        @forum_labels[[:thread, id]] = thread.name.to_s
      end
      true
    end

    def remember_forum_posts(thread_id, posts)
      thread_id = positive_identifier(thread_id)
      return false if thread_id == nil
      Array(posts).each do |post|
        id = post.respond_to?(:id) ? positive_identifier(post.id) : nil
        @forum_post_threads[id] = thread_id if id != nil
      end
      true
    end

    def remember_forum_thread(thread_id, forum_id, title = nil)
      thread_id = positive_identifier(thread_id)
      forum_id = positive_identifier(forum_id)
      return false if thread_id == nil || forum_id == nil
      @forum_threads[thread_id] = [forum_id, @forum_forums[forum_id]]
      @forum_labels[[:thread, thread_id]] = title.to_s if title != nil
      true
    end

    def remember_forum_post(thread_id, post_id)
      thread_id = positive_identifier(thread_id)
      post_id = positive_identifier(post_id)
      return false if thread_id == nil || post_id == nil
      @forum_post_threads[post_id] = thread_id
      true
    end

    def remember_message_participants(participants)
      Array(participants).each do |participant|
        id = participant.respond_to?(:user) ? participant.user.to_s : ""
        next if id.strip == ""
        type = message_object_type(participant)
        canonical = canonical_message_id(id)
        @message_types[canonical] = type
        @message_participants[canonical] = id
        name = participant.respond_to?(:name) ? participant.name.to_s.strip : ""
        @message_labels[[type, canonical]] = name == "" ? id : name
      end
      true
    end

    def remember_messages(participant, messages)
      canonical = canonical_message_id(participant)
      Array(messages).each do |message|
        id = message.respond_to?(:id) ? positive_identifier(message.id) : nil
        @message_ids[id] = canonical if id != nil
      end
      true
    end

    def remember_notes_scope(notes)
      Array(notes).each do |note|
        id = note.respond_to?(:id) ? positive_identifier(note.id) : nil
        @note_labels[[:note, id]] = note.name.to_s if id != nil
      end
      true
    end

    def remember_blogs(blogs)
      Array(blogs).each do |blog|
        id = blog.respond_to?(:id) ? normalize_blog_identifier(blog.id) : nil
        next if id == nil
        canonical = canonical_blog_id(id)
        @blog_ids[canonical] = id
        name = blog.respond_to?(:name) ? blog.name.to_s.strip : ""
        @blog_labels[[:blog, canonical]] = name if name != ""
      end
      true
    end

    def remember_blog_posts(blog, posts)
      blog_id = normalize_blog_identifier(blog)
      Array(posts).each do |post|
        id = post.respond_to?(:id) ? positive_identifier(post.id) : nil
        name = post.respond_to?(:name) ? post.name.to_s.strip : ""
        remember_blog_post(blog_id, id, name)
      end
      true
    end

    def remember_blog_post(blog, post_id, name = nil)
      blog_id = normalize_blog_identifier(blog)
      post = positive_identifier(post_id)
      return false if blog_id == nil || post == nil
      canonical_blog = canonical_blog_id(blog_id)
      canonical_post = [canonical_blog, post].freeze
      @blog_ids[canonical_blog] = blog_id
      @blog_labels[[:post, canonical_post]] = name.to_s.strip if name != nil && name.to_s.strip != ""
      true
    end

    def remember_blog_mentions(mentions)
      Array(mentions).each do |mention|
        id = mention.respond_to?(:id) ? positive_identifier(mention.id) : nil
        blog = mention.respond_to?(:blog) ? normalize_blog_identifier(mention.blog) : nil
        post = mention.respond_to?(:post) ? positive_identifier(mention.post) : nil
        @blog_mentions[id] = blog_post_id(blog, post) if id != nil && blog != nil && post != nil
      end
      true
    end

    def request_many(client_id, client_label, requests)
      raise InvalidParamsError, "requests must be a non-empty array" if !requests.is_a?(Array) || requests.empty?
      raise InvalidParamsError, "At most #{MAX_REQUESTS} selective permissions can be requested together" if requests.size > MAX_REQUESTS
      normalized = requests.map { |request| normalize_request(request) }
      duplicate = normalized.group_by { |item| grant_key(item) }.find { |_key, values| values.size > 1 }
      raise InvalidParamsError, "Duplicate selective permission in one request" if duplicate != nil
      normalized = normalized.reject do |request|
        target_granted?(client_id, request[:aspect], request[:level], { :type => request[:type], :id => request[:id] })
      end
      if normalized.empty?
        return {
          "applied" => true,
          "cancelled" => false,
          "reviewed_count" => 0,
          "already_granted" => true,
          "grants" => summary_for(client_id)
        }
      end

      rows = normalized.map do |request|
        levels = selectable_levels(request)
        label = request_label(request)
        options = levels.map { |level| translated_level(level) }
        [label, options, levels.index(request[:level]) || 0]
      end
      header = "MCP client %{client} requests %{count} selective permissions in one batch. Review every row; Left and Right change its level, Enter applies the complete list, and Escape cancels."
      header = @bridge.translate("MCP", header)
        .gsub("%{client}", client_label.to_s)
        .gsub("%{count}", normalized.size.to_s)
      @bridge.prepare_permission_prompt if @bridge.respond_to?(:prepare_permission_prompt)
      values = @bridge.choose_permission(rows, header)
      return { "applied" => false, "cancelled" => true, "grants" => summary_for(client_id) } if values == nil

      normalized.each_with_index do |request, index|
        levels = selectable_levels(request)
        set(client_id, request, levels[values[index].to_i] || :none)
      end
      {
        "applied" => true,
        "cancelled" => false,
        "reviewed_count" => normalized.size,
        "grants" => summary_for(client_id)
      }
    end

    def targets_for(tool_name, arguments)
      case tool_name.to_s
      when "forum_read" then forum_read_targets(arguments)
      when "forum_write" then forum_write_targets(arguments)
      when "forum_moderation_read" then forum_moderation_read_targets(arguments)
      when "forum_moderate_batch" then forum_moderate_targets(arguments)
      when "messages_read" then message_read_targets(arguments)
      when "messages_write" then message_write_targets(arguments)
      when "messages_moderate" then message_moderate_targets(arguments)
      when "notes_read" then notes_read_targets(arguments)
      when "notes_write" then notes_write_targets(arguments)
      when "blogs_read" then blogs_read_targets(arguments)
      when "blogs_write" then blogs_write_targets(arguments)
      else { :general_required => true, :reason => "This tool has no selective scope resolver." }
      end
    end

    def missing(client_id, aspect, level, targets)
      Array(targets).reject { |target| target_granted?(client_id, aspect.to_sym, level.to_sym, target) }
    end

    def request_items(aspect, level, targets)
      Array(targets).map do |target|
        item = {
          "aspect" => aspect.to_s,
          "resource_type" => target[:type].to_s,
          "level" => level.to_s
        }
        item["resource_id"] = target[:id] if target[:id] != nil
        item
      end.uniq
    end

    def manage(client_id, client_label)
      loop do
        grants = summary_for(client_id)
        options = [
          @bridge.translate("MCP", "Close"),
          @bridge.translate("MCP", "Add forum selective permission"),
          @bridge.translate("MCP", "Add message-correspondent selective permission"),
          @bridge.translate("MCP", "Add note selective permission"),
          @bridge.translate("MCP", "Add blog selective permission")
        ]
        options.concat(grants.map do |grant|
          @bridge.translate("MCP", "Remove: %{scope}, %{level}")
            .gsub("%{scope}", grant["label"])
            .gsub("%{level}", translated_level(grant["level"].to_sym))
        end)
        header = @bridge.translate("MCP", "Selective permissions for %{client}. Choose an entry to remove it, or add a new scope. Changes are remembered only when permission memory is enabled in the main MCP settings.")
          .gsub("%{client}", client_label.to_s)
        selected = @bridge.choose_form(options, header, 0).to_i
        return true if selected <= 0
        if selected == 1
          add_manually(client_id, :forum)
        elsif selected == 2
          add_manually(client_id, :messages)
        elsif selected == 3
          add_manually(client_id, :notes)
        elsif selected == 4
          add_manually(client_id, :blogs)
        else
          grant = grants[selected - 5]
          next if grant == nil
          request = normalize_request(grant)
          set(client_id, request, :none)
          @bridge.notify(@bridge.translate("MCP", "Selective permission removed."), false)
        end
      end
    end

    private

    def clear_catalogs
      @forum_labels.clear
      @forum_forums.clear
      @forum_threads.clear
      @forum_post_threads.clear
      @message_labels.clear
      @message_types.clear
      @message_participants.clear
      @message_ids.clear
      @note_labels.clear
      @blog_ids.clear
      @blog_labels.clear
      @blog_mentions.clear
    end

    def normalize_request(request)
      raise InvalidParamsError, "Each selective permission request must be an object" if !request.is_a?(Hash)
      aspect = request["aspect"].to_s.to_sym
      definition = DEFINITIONS[aspect]
      raise InvalidParamsError, "Unsupported selective permission aspect" if definition == nil
      type = request["resource_type"].to_s.to_sym
      raise InvalidParamsError, "Invalid selective resource type for #{aspect}" if !definition[:resource_types].include?(type)
      level = request["level"].to_s.to_sym
      raise InvalidParamsError, "Invalid selective level for #{aspect}" if !definition[:levels].include?(level) && level != :none
      if creation_type?(type) && level != :write && level != :none
        raise InvalidParamsError, "Creation permissions support only write access"
      end
      id = case aspect
      when :forum
        positive_identifier(request["resource_id"]) || raise(InvalidParamsError, "Forum selective resource_id must be a positive integer")
      when :messages
        normalize_message_identifier(request["resource_id"])
      when :notes
        normalize_note_resource(type, request["resource_id"])
      when :blogs
        normalize_blog_resource(type, request["resource_id"])
      end
      if aspect == :messages
        known_type = @message_types[canonical_message_id(id)]
        if known_type != nil && known_type != type
          raise InvalidParamsError, "The discovered message correspondent is #{known_type}, not #{type}"
        end
      end
      { :aspect => aspect, :type => type, :id => id, :level => level }
    end

    def grant_key(request)
      id = canonical_resource_id(request[:aspect], request[:type], request[:id])
      [request[:aspect], request[:type], id]
    end

    def set(client_id, request, level)
      key = grant_key(request)
      if level.to_sym == :none
        @grants[client_id].delete(key)
      else
        @grants[client_id][key] = level.to_sym
        if request[:aspect] == :messages
          canonical = canonical_message_id(request[:id])
          @message_participants[canonical] ||= request[:id].to_s
          @message_types[canonical] ||= request[:type]
        elsif request[:aspect] == :blogs && [:blog, :post_creation].include?(request[:type])
          canonical = canonical_blog_id(request[:id])
          @blog_ids[canonical] ||= request[:id].to_s
        elsif request[:aspect] == :blogs && request[:type] == :post
          canonical = canonical_blog_id(request[:id]["blog"])
          @blog_ids[canonical] ||= request[:id]["blog"]
        end
      end
      true
    end

    def public_grant(aspect, type, canonical_id, level)
      public_id = public_resource_id(aspect, type, canonical_id)
      {
        "aspect" => aspect.to_s,
        "resource_type" => type.to_s,
        "resource_id" => public_id,
        "label" => scope_label(aspect, type, canonical_id),
        "level" => level.to_s
      }
    end

    def scope_label(aspect, type, canonical_id)
      case aspect
      when :forum
        name = @forum_labels[[type, canonical_id]].to_s
        prefix = "Forum #{type} #{canonical_id}"
      when :messages
        public_id = @message_participants[canonical_id] || canonical_id
        name = @message_labels[[type, canonical_id]].to_s
        prefix = "Messages #{type} #{public_id}"
      when :notes
        name = @note_labels[[type, canonical_id]].to_s
        prefix = creation_type?(type) ? "Note creation" : "Note #{canonical_id}"
      when :blogs
        if type == :post
          blog, post = canonical_id
          public_blog = @blog_ids[blog] || blog
          name = @blog_labels[[:post, canonical_id]].to_s
          prefix = "Blog post #{public_blog}/#{post}"
        elsif type == :blog_creation
          name = ""
          prefix = "Blog creation"
        elsif type == :post_creation
          public_blog = @blog_ids[canonical_id] || canonical_id
          name = @blog_labels[[:blog, canonical_id]].to_s
          prefix = "Post creation in blog #{public_blog}"
        else
          public_blog = @blog_ids[canonical_id] || canonical_id
          name = @blog_labels[[:blog, canonical_id]].to_s
          prefix = "Blog #{public_blog}"
        end
      end
      name == "" ? prefix : "#{prefix}: #{name}"
    end

    def request_label(request)
      canonical = canonical_resource_id(request[:aspect], request[:type], request[:id])
      "#{scope_label(request[:aspect], request[:type], canonical)} - requested #{request[:level]}"
    end

    def translated_level(level)
      labels = {
        :none => "Disabled",
        :read => "Read",
        :write => "Read and write",
        :moderate => "Read, write and moderate"
      }
      @bridge.translate("MCP", labels.fetch(level))
    end

    def selectable_levels(request)
      creation_type?(request[:type]) ? [:none, :write] : [:none] + DEFINITIONS.fetch(request[:aspect])[:levels]
    end

    def target_granted?(client_id, aspect, level, target)
      candidates = grant_candidates(aspect, target)
      candidates.any? do |type, id|
        key_id = canonical_resource_id(aspect, type, id)
        granted = @grants[client_id][[aspect, type, key_id]]
        level_rank(aspect, granted) >= level_rank(aspect, level)
      end
    end

    def grant_candidates(aspect, target)
      return message_candidates(target) if aspect == :messages
      return note_candidates(target) if aspect == :notes
      return blog_candidates(target) if aspect == :blogs
      type = target[:type]
      id = positive_identifier(target[:id])
      return [] if id == nil
      case type
      when :group
        [[:group, id]]
      when :forum
        values = [[:forum, id]]
        values << [:group, @forum_forums[id]] if @forum_forums[id] != nil
        values
      when :thread
        values = [[:thread, id]]
        forum_id, group_id = @forum_threads[id]
        values << [:forum, forum_id] if forum_id != nil
        values << [:group, group_id] if group_id != nil
        values
      else []
      end
    end

    def message_candidates(target)
      id = target[:id].to_s
      canonical = canonical_message_id(id)
      type = target[:type] || @message_types[canonical] || (id.start_with?("[") ? :group : :user)
      [[type, canonical]]
    end

    def note_candidates(target)
      type = target[:type]
      id = creation_type?(type) ? nil : note_identifier(type, target[:id])
      return [] if !creation_type?(type) && id == nil
      [[type, id]]
    end

    def blog_candidates(target)
      type = target[:type]
      case type
      when :blog_creation
        [[:blog_creation, nil]]
      when :post_creation
        blog = normalize_blog_identifier(target[:id])
        blog == nil ? [] : [[:post_creation, blog]]
      when :blog
        blog = normalize_blog_identifier(target[:id])
        blog == nil ? [] : [[:blog, blog]]
      when :post
        post = normalize_blog_resource(:post, target[:id])
        [[:post, post], [:blog, post["blog"]]]
      else []
      end
    rescue EltenMCP::Error
      []
    end

    def level_rank(aspect, level)
      return 0 if level == nil || level.to_sym == :none
      index = DEFINITIONS.fetch(aspect)[:levels].index(level.to_sym)
      index == nil ? 0 : index + 1
    end

    def forum_read_targets(args)
      action = args["action"].to_s
      case action
      when "thread", "thread_stats" then one_target(:thread, args["thread_id"])
      when "tags" then one_target(:forum, args["forum_id"])
      when "group_members", "group_activity", "group_storage", "group_motd", "group_regulations"
        one_target(:group, args["group_id"])
      when "posted_in_threads" then many_targets(:thread, args["thread_ids"])
      when "bookmarks"
        args["thread_id"] == nil ? general("Listing bookmarks across all threads is global.") : one_target(:thread, args["thread_id"])
      when "post_likes", "original_post" then forum_post_target(args["post_id"])
      else
        general("This forum read action spans the domain; obtain forum/scope and use forum_scope for the hierarchy, or request full forum/read.")
      end
    end

    def forum_write_targets(args)
      action = args["action"].to_s
      case action
      when "create_thread", "follow_forum", "unfollow_forum", "mark_forum_read"
        one_target(:forum, args["forum_id"])
      when "create_post", "follow_thread", "unfollow_thread", "mark_thread_read", "set_thread_bookmarked"
        one_target(:thread, args["thread_id"])
      when "join_group", "leave_group", "mark_group_read"
        one_target(:group, args["group_id"])
      when "edit_post", "delete_post", "like_post", "unlike_post", "report_post"
        forum_post_target(args["post_id"])
      when "create_bookmark", "create_mentions"
        combine_targets(one_target(:thread, args["thread_id"]), forum_post_target(args["post_id"]))
      else
        general("This forum write action cannot be bound safely to one discovered group, forum or thread; request full forum/write.")
      end
    end

    def forum_moderation_read_targets(args)
      case args["action"].to_s
      when "reports", "moderator_log", "group_configuration", "trash_threads"
        one_target(:group, args["group_id"])
      when "trash_thread"
        one_target(:thread, args["thread_id"])
      else
        general("This moderation read action requires full forum/moderate.")
      end
    end

    def forum_moderate_targets(args)
      actions = args["actions"]
      return general("A moderation batch must contain actions.") if !actions.is_a?(Array) || actions.empty?
      results = actions.map do |action|
        return general("Creating a new top-level forum group is not scoped to an existing resource; request full forum/moderate.") if action["action"].to_s == "create_group"
        collect_forum_identifiers(action)
      end
      results.reduce({ :targets => [] }) { |combined, item| combine_targets(combined, item) }
    end

    def collect_forum_identifiers(value)
      targets = []
      unresolved = []
      walk = lambda do |item|
        if item.is_a?(Hash)
          item.each do |key, child|
            case key.to_s
            when "group_id", "target_group_id"
              targets << target(:group, child)
            when "forum_id", "target_forum_id"
              targets << target(:forum, child)
            when "forum_ids"
              Array(child).each { |id| targets << target(:forum, id) }
            when "thread_id", "target_thread_id"
              targets << target(:thread, child)
            when "thread_ids"
              Array(child).each { |id| targets << target(:thread, id) }
            when "post_id", "before_post_id"
              next if child == nil
              mapped = mapped_post_target(child)
              mapped == nil ? unresolved << child : targets << mapped
            when "post_ids"
              Array(child).each do |id|
                mapped = mapped_post_target(id)
                mapped == nil ? unresolved << id : targets << mapped
              end
            else
              walk.call(child) if child.is_a?(Hash) || child.is_a?(Array)
            end
          end
        elsif item.is_a?(Array)
          item.each { |child| walk.call(child) }
        end
      end
      walk.call(value)
      return unresolved_posts(unresolved) if !unresolved.empty?
      return general("This moderation action has no existing group, forum or thread target.") if targets.empty?
      { :targets => compact_targets(targets) }
    end

    def message_read_targets(args)
      case args["action"].to_s
      when "conversations", "messages"
        message_participant_target(args["user"])
      when "group_members"
        message_participant_target(args["group_id"], :group)
      else
        general("This messages read action spans all correspondents; obtain messages/scope and use messages_scope for the correspondent list, or request full messages/read.")
      end
    end

    def message_write_targets(args)
      case args["action"].to_s
      when "send"
        message_participant_target(args["to"])
      when "update_group"
        message_participant_target(args["group_id"], :group)
      when "forward"
        general("Forwarding spans a source message and destination correspondent; request full messages/write.")
      else
        general("This messages write action is not bound to an existing correspondent; request full messages/write.")
      end
    end

    def message_moderate_targets(args)
      case args["action"].to_s
      when "mark_all_read"
        args["user"] == nil ? general("Marking every conversation read is global; request full messages/moderate.") : message_participant_target(args["user"])
      when "delete_conversation", "remove_participant"
        message_participant_target(args["user"])
      when "leave_group", "mute_group", "unmute_group"
        message_participant_target(args["group_id"], :group)
      when "set_flagged", "set_deletion_protected", "delete_message"
        message_id_target(args["message_id"], :moderate)
      else
        general("This messages moderation action is not bound to an existing correspondent; request full messages/moderate.")
      end
    end

    def message_participant_target(identifier, forced_type = nil)
      id = normalize_message_identifier(identifier)
      canonical = canonical_message_id(id)
      type = forced_type || @message_types[canonical] || (id.start_with?("[") ? :group : :user)
      { :targets => [{ :type => type, :id => id }] }
    end

    def message_id_target(identifier, required_level)
      id = positive_identifier(identifier)
      canonical = @message_ids[id]
      return { :unresolved => true, :reason => "Message #{id} is not mapped to a selectively granted correspondent. Read that correspondent's messages first or request full messages/#{required_level}." } if canonical == nil
      public_id = @message_participants[canonical] || canonical
      type = @message_types[canonical] || (public_id.start_with?("[") ? :group : :user)
      { :targets => [{ :type => type, :id => public_id }] }
    end

    def notes_read_targets(args)
      case args["action"].to_s
      when "note", "note_shares" then note_target(:note, args["note_id"])
      else
        general("This notes read action spans multiple notes; use notes_scope to discover IDs or request full notes/read.")
      end
    end

    def notes_write_targets(args)
      case args["action"].to_s
      when "note_create" then creation_target(:note_creation)
      when "note_update", "note_rename", "note_delete", "note_share_add", "note_share_delete"
        note_target(:note, args["note_id"])
      else
        general("This notes write action is not bound safely to one selective note; request full notes/write.")
      end
    end

    def blogs_read_targets(args)
      action = args["action"].to_s
      case action
      when "exists", "details", "categories", "posts", "comments", "followers", "tags", "owners"
        blog_target(args["blog"])
      when "post", "post_details", "post_followed"
        blog_post_target(args["blog"], args["post_id"])
      else
        general("This blog read action spans blogs; use blogs_scope to discover blog/post IDs or request full blogs/read.")
      end
    end

    def blogs_write_targets(args)
      action = args["action"].to_s
      case action
      when "create_blog"
        creation_target(:blog_creation)
      when "create_post"
        { :targets => [{ :type => :post_creation, :id => normalize_blog_identifier(args["blog"]) }] }
      when "update_post", "delete_post", "create_comment", "follow_post", "unfollow_post", "send_mentions"
        blog_post_target(args["blog"], args["post_id"])
      when "acknowledge_mention"
        blog_mention_target(args["mention_id"])
      when "delete_blog", "follow", "unfollow", "mark_read", "create_category", "rename_category", "delete_category",
           "create_tag", "delete_tag", "set_comment_status", "delete_comment", "add_coworker", "remove_coworker", "leave_coworkers"
        blog_target(args["blog"])
      else
        general("This blog write action is not bound safely to one selective resource; request full blogs/write.")
      end
    end

    def note_target(type, identifier)
      id = note_identifier(type, identifier)
      raise InvalidParamsError, "#{type}_id must be a positive integer" if id == nil
      { :targets => [{ :type => type, :id => id }] }
    end

    def creation_target(type)
      { :targets => [{ :type => type, :id => nil }] }
    end

    def blog_target(identifier)
      blog = normalize_blog_identifier(identifier)
      raise InvalidParamsError, "blog must be a non-empty identifier" if blog == nil
      { :targets => [{ :type => :blog, :id => blog }] }
    end

    def blog_post_target(blog, post)
      id = blog_post_id(blog, post)
      raise InvalidParamsError, "blog and a positive post_id are required" if id == nil
      { :targets => [{ :type => :post, :id => id }] }
    end

    def blog_mention_target(identifier)
      mention = positive_identifier(identifier)
      post = @blog_mentions[mention]
      return { :unresolved => true, :reason => "Blog mention #{mention} is not mapped to a post. Read the mention list first or request full blogs/write." } if post == nil
      { :targets => [{ :type => :post, :id => post }] }
    end

    def forum_post_target(identifier)
      mapped = mapped_post_target(identifier)
      return unresolved_posts([identifier]) if mapped == nil
      { :targets => [mapped] }
    end

    def mapped_post_target(identifier)
      post_id = positive_identifier(identifier)
      thread_id = @forum_post_threads[post_id]
      thread_id == nil ? nil : target(:thread, thread_id)
    end

    def unresolved_posts(ids)
      {
        :unresolved => true,
        :reason => "Forum post IDs #{ids.map(&:to_s).join(", ")} are not mapped to threads. Read the containing selectively granted thread first or request the full forum level."
      }
    end

    def one_target(type, identifier)
      { :targets => [target(type, identifier)] }
    end

    def many_targets(type, identifiers)
      { :targets => compact_targets(Array(identifiers).map { |identifier| target(type, identifier) }) }
    end

    def target(type, identifier)
      id = positive_identifier(identifier)
      raise InvalidParamsError, "#{type}_id must be a positive integer" if id == nil
      { :type => type, :id => id }
    end

    def combine_targets(left, right)
      return left if left[:general_required] || left[:unresolved]
      return right if right[:general_required] || right[:unresolved]
      { :targets => compact_targets(Array(left[:targets]) + Array(right[:targets])) }
    end

    def compact_targets(targets)
      targets.uniq { |item| [item[:type], item[:id]] }
    end

    def general(reason)
      { :general_required => true, :reason => reason }
    end

    def inheritance_description(aspect)
      case aspect
      when :forum
        "A group grant covers its forums and threads; a forum grant covers its threads."
      when :messages
        "Each grant covers exactly one discovered user, group or custom correspondent."
      when :notes
        "Note grants are exact. Note creation only allows creating a note and does not grant later access to the created note."
      when :blogs
        "A blog grant covers its existing posts; a post grant is exact. Blog and post creation are separate scopes and do not grant later access to created objects."
      end
    end

    def creation_type?(type)
      [:note_creation, :blog_creation, :post_creation].include?(type.to_sym)
    end

    def normalize_note_resource(type, value)
      return nil if creation_type?(type)
      id = note_identifier(type, value)
      raise InvalidParamsError, "Note resource_id must be a positive integer" if id == nil
      id
    end

    def note_identifier(type, value)
      type.to_sym == :note ? positive_identifier(value) : nil
    end

    def normalize_blog_resource(type, value)
      case type.to_sym
      when :blog_creation
        nil
      when :blog, :post_creation
        normalize_blog_identifier(value) || raise(InvalidParamsError, "Blog resource_id must be a non-empty identifier")
      when :post
        raise InvalidParamsError, "Post resource_id must contain blog and post_id" if !value.is_a?(Hash)
        blog = normalize_blog_identifier(value["blog"] || value[:blog])
        post = positive_identifier(value["post_id"] || value[:post_id])
        raise InvalidParamsError, "Post resource_id must contain blog and a positive post_id" if blog == nil || post == nil
        { "blog" => blog, "post_id" => post }
      else
        raise InvalidParamsError, "Invalid blog selective resource type"
      end
    end

    def normalize_blog_identifier(value)
      return nil if !value.is_a?(String)
      id = value.strip
      return nil if id == "" || id.each_char.count > 200 || id.match?(/[[:cntrl:]]/)
      id
    end

    def canonical_blog_id(value)
      value.to_s.strip.downcase
    end

    def canonical_resource_id(aspect, type, id)
      case aspect.to_sym
      when :messages
        canonical_message_id(id)
      when :blogs
        case type.to_sym
        when :post
          post = normalize_blog_resource(:post, id)
          [canonical_blog_id(post["blog"]), post["post_id"]].freeze
        when :blog, :post_creation
          canonical_blog_id(id)
        when :blog_creation
          nil
        end
      when :notes
        creation_type?(type) ? nil : note_identifier(type, id)
      else
        id
      end
    end

    def public_resource_id(aspect, type, canonical_id)
      case aspect.to_sym
      when :messages
        @message_participants[canonical_id] || canonical_id
      when :blogs
        case type.to_sym
        when :post
          blog, post = canonical_id
          { "blog" => (@blog_ids[blog] || blog), "post_id" => post }
        when :blog, :post_creation
          @blog_ids[canonical_id] || canonical_id
        when :blog_creation
          "create"
        end
      when :notes
        creation_type?(type) ? "create" : canonical_id
      else
        canonical_id
      end
    end

    def blog_post_id(blog, post)
      blog_id = normalize_blog_identifier(blog)
      post_id = positive_identifier(post)
      return nil if blog_id == nil || post_id == nil
      { "blog" => blog_id, "post_id" => post_id }
    end

    def positive_identifier(value)
      return nil if !value.is_a?(Integer) && value.to_s !~ /\A[0-9]+\z/
      id = value.to_i
      id > 0 ? id : nil
    end

    def normalize_message_identifier(value)
      raise InvalidParamsError, "Message correspondent identifier must be text" if !value.is_a?(String)
      id = value.strip
      raise InvalidParamsError, "Message correspondent identifier cannot be empty" if id == ""
      raise InvalidParamsError, "Message correspondent identifier is too long" if id.each_char.count > 200
      raise InvalidParamsError, "Message correspondent identifier contains control characters" if id.match?(/[[:cntrl:]]/)
      id
    end

    def canonical_message_id(value)
      value.to_s.strip.downcase
    end

    def message_object_type(participant)
      id = participant.user.to_s
      return :group if id.start_with?("[")
      participant.respond_to?(:is_user) && participant.is_user == true ? :user : :custom
    end

    def add_manually(client_id, aspect)
      types = DEFINITIONS.fetch(aspect)[:resource_types]
      type_index = @bridge.choose_form(
        [@bridge.translate("MCP", "Cancel")] + types.map { |type| @bridge.translate("MCP", type.to_s.tr("_", " ").capitalize) },
        @bridge.translate("MCP", "Choose the selective resource type for %{aspect}.").gsub("%{aspect}", aspect.to_s),
        0
      ).to_i
      return false if type_index <= 0
      type = types[type_index - 1]
      raw_id = manual_resource_id(aspect, type)
      return false if raw_id == :cancelled
      levels = creation_type?(type) ? [:write] : DEFINITIONS.fetch(aspect)[:levels]
      level_index = @bridge.choose_form(
        [@bridge.translate("MCP", "Cancel")] + levels.map { |level| translated_level(level) },
        @bridge.translate("MCP", "Choose the selective access level."),
        0
      ).to_i
      return false if level_index <= 0
      request = normalize_request(
        "aspect" => aspect.to_s,
        "resource_type" => type.to_s,
        "resource_id" => raw_id,
        "level" => levels[level_index - 1].to_s
      )
      set(client_id, request, request[:level])
      @bridge.notify(@bridge.translate("MCP", "Selective permission added."), false)
      true
    rescue EltenMCP::Error => e
      @bridge.notify(e.message, false)
      false
    end

    def manual_resource_id(aspect, type)
      return nil if creation_type?(type) && type != :post_creation
      if aspect == :blogs && type == :post
        blog = @bridge.ask_text(@bridge.translate("MCP", "Enter the exact blog identifier."))
        return :cancelled if blog == nil
        post = @bridge.ask_text(@bridge.translate("MCP", "Enter the positive numeric post ID."))
        return :cancelled if post == nil
        return { "blog" => blog.to_s, "post_id" => post.to_i }
      end
      prompt = case aspect
      when :forum then "Enter the positive numeric resource ID."
      when :messages then "Enter the exact correspondent identifier."
      when :notes then "Enter the positive numeric note ID."
      when :blogs then "Enter the exact blog identifier."
      end
      raw = @bridge.ask_text(@bridge.translate("MCP", prompt))
      return :cancelled if raw == nil
      [:forum, :notes].include?(aspect) ? raw.to_i : raw.to_s
    end
  end
end
