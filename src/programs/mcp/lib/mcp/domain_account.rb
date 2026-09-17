# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper

module EltenMCP
  module DomainAccount
    def register_account_tools
      register_domain_tool(
        "account_read", "Read account information",
        "Read task-oriented account information. All values have named meaning; numeric profile flags and positional API arrays are translated. Email addresses, passwords, tokens and login keys are never returned.",
        :account, :read,
        action_schema(%w[profile visiting_card status signature user_info contacts birthday_contacts contacts_added_me search online exists banned recently_registered recently_active honors honor_users], :account)
      ) do |args|
        client = network_client
        user = optional_user(args)
        case args["action"]
        when "profile" then account_profile(client, user)
        when "visiting_card"
          card = EltenLink::Profiles.visiting_card(client, user)
          if card == nil
            response("visiting_card", "No visiting card is available for #{user}.", "user" => user, "text" => nil)
          else
            text = server_string(card, "visiting card")
            response("visiting_card", "Returned the visiting card for #{user}.", "user" => user, "text" => text)
          end
        when "status"
          response("status", "Returned status and presence for #{user}.", "user" => user, "status" => known(EltenLink::Users.status_info(client, user), :user_status))
        when "signature"
          signature = server_string(EltenLink::Users.signature(client, user), "forum signature")
          response("signature", "Returned the forum signature for #{user}.", "user" => user, "signature" => signature)
        when "user_info" then account_user_info(client, user)
        when "contacts" then account_user_list("contacts", "Returned contacts.", "contacts", EltenLink::Contacts.list(client))
        when "birthday_contacts" then account_user_list("birthday_contacts", "Returned contacts with current birthday notices.", "contacts", EltenLink::Contacts.list(client, :birthday => true))
        when "contacts_added_me"
          account_user_list("contacts_added_me", "Returned users who added the signed-in user to contacts.", "users",
            EltenLink::Contacts.added_me(client, :new_only => args["only_unacknowledged"] == true))
        when "search"
          query = required_string(args, "query")
          account_user_list("search", "Returned exact usernames matching '#{query}'.", "users", EltenLink::Users.search(client, query),
            "query" => query)
        when "online" then account_user_list("online", "Returned users currently online.", "users", EltenLink::Users.online(client))
        when "exists"
          exists = server_boolean(EltenLink::Users.exists?(client, user), "user existence")
          response("exists", exists ? "The user #{user} exists." : "No user named #{user} exists.", "user" => user, "exists" => exists)
        when "banned"
          banned = server_boolean(EltenLink::Users.banned?(client, user), "global ban state")
          response("banned", banned ? "#{user} is globally banned." : "#{user} is not globally banned.", "user" => user, "is_globally_banned" => banned)
        when "recently_registered"
          account_user_list("recently_registered", "Returned the newest registered users.", "users",
            EltenLink::Users.recently_registered(client, :limit => bounded(args["limit"], 1, 200, 50)))
        when "recently_active" then account_user_list("recently_active", "Returned users active during approximately the last 24 hours.", "users", EltenLink::Users.recently_active(client))
        when "honors"
          honors = known_list(EltenLink::Honors.list(client, :user => user), :honor)
          response("honors", "Returned #{honors.size} honors for #{user}.", "user" => user, "honors" => honors, "count" => honors.size)
        when "honor_users" then account_honor_users(client, positive_id(args, "honor_id"))
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "account_write", "Update account information",
        "Update only named, non-authentication account fields for the signed-in user. There is deliberately no email, password, token or login-key operation.",
        :account, :write,
        action_schema(%w[update_profile update_visiting_card update_status update_signature add_contact remove_contact acknowledge_birthdays acknowledge_added_me set_main_honor add_online_monitor remove_online_monitor], :account),
        mutating_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "update_profile"
          fields = account_profile_fields(args)
          EltenLink::Profiles.update_profile(client, **fields)
          completed("update_profile", "Updated #{fields.keys.map(&:to_s).join(", ")} in the signed-in user's profile.", "changed_fields" => fields.keys.map(&:to_s))
        when "update_visiting_card"
          EltenLink::Profiles.set_visiting_card(client, :text => required_string(args, "text", true))
          completed("update_visiting_card", "Updated the signed-in user's visiting card.")
        when "update_status"
          EltenLink::Users.set_status(client, required_string(args, "text", true))
          completed("update_status", "Updated the signed-in user's status.")
        when "update_signature"
          EltenLink::Users.set_signature(client, required_string(args, "text", true))
          completed("update_signature", "Updated the signed-in user's forum signature.")
        when "add_contact"
          user = required_string(args, "user")
          EltenLink::Contacts.add(client, user)
          completed("add_contact", "Added #{user} to contacts.", "user" => user)
        when "remove_contact"
          user = required_string(args, "user")
          EltenLink::Contacts.delete(client, user)
          completed("remove_contact", "Removed #{user} from contacts.", "user" => user)
        when "acknowledge_birthdays"
          EltenLink::Contacts.acknowledge_birthdays(client)
          completed("acknowledge_birthdays", "Marked current birthday notices as seen.")
        when "acknowledge_added_me"
          EltenLink::Contacts.acknowledge_added_me(client)
          completed("acknowledge_added_me", "Marked current contact-added notices as seen.")
        when "set_main_honor"
          honor_id = positive_id(args, "honor_id")
          EltenLink::Honors.set_main(client, honor_id)
          completed("set_main_honor", "Selected honor #{honor_id} as the main honor.", "honor_id" => honor_id)
        when "add_online_monitor"
          user = required_string(args, "user")
          permanent = boolean_arg(args, "permanent")
          EltenLink::Monitors.add(client, user, :permanent => permanent)
          completed("add_online_monitor", "Added an online monitor for #{user}.", "user" => user, "permanent" => permanent)
        when "remove_online_monitor"
          user = required_string(args, "user")
          EltenLink::Monitors.delete(client, user)
          completed("remove_online_monitor", "Removed the online monitor for #{user}.", "user" => user)
        else invalid_action(args["action"])
        end
      end
    end

    private

    def account_profile(client, user)
      values = EltenLink::Profiles.profile(client, user)
      return response("profile", "No public profile is available for #{user}.", "user" => user, "profile" => nil) if values == nil
      profile = known(values, :user_profile)
      response("profile", "Returned the public profile for #{user}.", "user" => user, "profile" => profile)
    end

    def account_user_info(client, user)
      info = known(EltenLink::Users.info(client, user), :user_info)
      response("user_info", "Returned named public account information for #{user}.", "user" => user, "info" => info)
    end

    def account_user_list(operation, summary, key, values, extra = {})
      users = string_values(values)
      response(operation, "#{summary} Count: #{users.size}.", extra.merge(key => users, "count" => users.size))
    end

    def account_honor_users(client, honor_id)
      honors = known_list(EltenLink::Honors.list(client), :honor)
      honor = honors.find { |item| item["honor_id"] == honor_id }
      raise InvalidParamsError, "No honor with id #{honor_id} exists" if honor == nil
      users = known_list(EltenLink::Honors.users(client, honor_id), :honor_user).map do |user|
        level_number = user["level_number"]
        level = honor["available_levels"].find { |candidate| candidate["number"] == level_number }
        result(
          "username" => user["username"],
          "level" => level
        )
      end
      response("honor_users", "Returned #{users.size} recipients of #{honor["name"]}.",
        "honor" => result("honor_id" => honor_id, "name" => honor["name"], "english_name" => honor["english_name"]),
        "users" => users, "count" => users.size)
    end

    def account_profile_fields(args)
      fields = {}
      fields[:fullname] = required_string(args, "full_name", true) if args.key?("full_name")
      if args.key?("gender")
        fields[:gender] = { "female" => 0, "male" => 1 }.fetch(args["gender"]) do
          raise InvalidParamsError, "gender must be female or male"
        end
      end
      if args.key?("birthdate")
        birthdate = args["birthdate"]
        raise InvalidParamsError, "birthdate must contain year, month and day" if !birthdate.is_a?(Hash)
        year = bounded(birthdate["year"], 1900, 2200, 0)
        month = bounded(birthdate["month"], 1, 12, 0)
        day = bounded(birthdate["day"], 1, 31, 0)
        begin
          date = Time.local(year, month, day)
          raise ArgumentError if date.year != year || date.month != month || date.day != day
        rescue ArgumentError
          raise InvalidParamsError, "birthdate is not a valid calendar date"
        end
        fields[:birthdate_year] = year
        fields[:birthdate_month] = month
        fields[:birthdate_day] = day
      end
      fields[:location] = required_string(args, "location", true) if args.key?("location")
      fields[:public_profile] = boolean_arg(args, "visible_to_others") if args.key?("visible_to_others")
      raise InvalidParamsError, "At least one supported profile field is required" if fields.empty?
      fields
    end
  end
end
