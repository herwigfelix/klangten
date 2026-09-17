# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: feed tools removed (the Elten feed does not exist in Klangten).

module EltenMCP
  module DomainSocial
    def register_social_tools
      register_notification_tools
    end

    private

    def register_notification_tools
      register_domain_tool(
        "notifications_read", "Read notifications",
        "Read current or historical notification text and normalized categories, including safe application-provided name, title and body for installed programs. Opaque payload, application UUID, action routing, sound names and unknown server fields are discarded.",
        :notifications, :read, action_schema(%w[list], :notifications)
      ) do |args|
        historical = args["include_history"] == true
        notifications = known_list(EltenLink::Notifications.list(
          network_client,
          :all => historical,
          :app_uuids => notification_app_uuids
        ), :notification)
        response("list", "Returned #{notifications.size} notifications.", "notifications" => notifications, "count" => notifications.size, "includes_history" => historical)
      end

      register_domain_tool(
        "notifications_write", "Mark notifications read",
        "Mark many notifications read in one server request or mark all read. Group IDs in one call; do not send one request per notification.",
        :notifications, :write, action_schema(%w[mark_read mark_all_read], :notifications),
        destructive_annotations
      ) do |args|
        client = network_client
        if args["action"] == "mark_read"
          ids = require_ids(positive_ids(required_array(args, "notification_ids", 500)))
          EltenLink::Notifications.revoke_many(client, ids)
          completed("mark_read", "Marked #{ids.size} notifications as read in one network request.",
            "notification_ids" => ids, "count" => ids.size, "network_requests" => 1)
        elsif args["action"] == "mark_all_read"
          EltenLink::Notifications.revoke_all(client, :app_uuids => notification_app_uuids)
          completed("mark_all_read", "Marked all current notifications as read in one network request.", "network_requests" => 1)
        else
          invalid_action(args["action"])
        end
      end
    end

    def notification_app_uuids
      values = Programs.notification_app_uuids
      raise ToolError, "Unexpected installed notification application contract" if !values.is_a?(Array) || !values.all? { |value| value.is_a?(String) }
      values
    end
  end
end
