# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Klango community functions Elten does not know (Klangten API extension):
# the Klango groups of the account, a message to all members of a group,
# status history, contact comments, the contacts of a user, special users
# (roles), recently changed avatars and the public address of a forum thread.

module EltenLink
  CommunityGroup = Struct.new(:id, :name, :moderator, keyword_init: true)
  StatusEntry = Struct.new(:id, :status, :time, keyword_init: true)
  ContactEntry = Struct.new(:user, :comment, :public, keyword_init: true)
  RoleHolder = Struct.new(:user, :roles, keyword_init: true)
  Role = Struct.new(:key, :name, keyword_init: true)
  AvatarChange = Struct.new(:user, :time, keyword_init: true)
  ShareLink = Struct.new(:url, :title, :public, keyword_init: true)

  module Community
    GROUP_MESSAGE_TARGETS = %w[members moderators suspended].freeze

    class << self
      # Klango groups in which the account is a member or moderator.
      def groups(client)
        Array(client.api_data("GET", "/api/v1/community/groups")["groups"]).map do |row|
          CommunityGroup.new(id: row["id"].to_i, name: row["name"].to_s, moderator: row["moderator"] == true)
        end
      end

      # Sends a private message to the members of a group; returns the number
      # of recipients. to: "members", "moderators" or "suspended".
      def message_group(client, group_id, text, to: "members")
        data = client.api_data("POST", "/api/v1/community/groups/#{group_id.to_i}/message", { "text" => text.to_s, "to" => to.to_s })
        data["recipients"].to_i
      end

      def status_history(client, user)
        data = client.api_data("GET", "/api/v1/users/#{user.to_s.urlenc}/status-history")
        Array(data["statuses"]).map do |row|
          StatusEntry.new(id: row["id"].to_i, status: row["status"].to_s, time: row["time"].to_i)
        end
      end

      def delete_status(client, id)
        client.api_data("DELETE", "/api/v1/users/me/status-history/#{id.to_i}")
        true
      end

      # [complete?, [ContactEntry]] - complete is false for other users, whose
      # list only shows contacts with a public comment.
      def contacts_of(client, user)
        data = client.api_data("GET", "/api/v1/users/#{user.to_s.urlenc}/contacts")
        [data["complete"] == true, Array(data["contacts"]).map { |row| build_contact(row) }]
      end

      # {user => ContactEntry} for my contacts that have a comment.
      def contact_comments(client)
        Array(client.api_data("GET", "/api/v1/contacts/comments")["comments"]).each_with_object({}) do |row, out|
          entry = build_contact(row)
          out[entry.user] = entry
        end
      end

      def set_contact_comment(client, user, comment, public: false)
        data = client.api_data("PUT", "/api/v1/contacts/#{user.to_s.urlenc}/comment", { "comment" => comment.to_s, "public" => public ? 1 : 0 })
        ContactEntry.new(user: user.to_s, comment: data["comment"].to_s, public: data["public"] == true)
      end

      def delete_contact_comment(client, user)
        client.api_data("DELETE", "/api/v1/contacts/#{user.to_s.urlenc}/comment")
        true
      end

      # Special users: [RoleHolder] with their roles.
      def roles(client)
        Array(client.api_data("GET", "/api/v1/users/roles")["users"]).map do |row|
          roles = Array(row["roles"]).map { |role| Role.new(key: role["key"].to_s, name: role["name"].to_s) }
          RoleHolder.new(user: row["user"].to_s, roles: roles)
        end
      end

      def recent_avatars(client)
        Array(client.api_data("GET", "/api/v1/avatars/recent")["avatars"]).map do |row|
          AvatarChange.new(user: row["user"].to_s, time: row["time"].to_i)
        end
      end

      # Public address of a forum thread (web interface) for sharing.
      def forum_thread_link(client, thread_id)
        data = client.api_data("GET", "/api/v1/share/forum-thread/#{thread_id.to_i}")
        ShareLink.new(url: data["url"].to_s, title: data["title"].to_s, public: data["public"] == true)
      end

      private

      def build_contact(row)
        ContactEntry.new(user: row["user"].to_s, comment: row["comment"].to_s, public: row["public"] == true)
      end
    end
  end
end
