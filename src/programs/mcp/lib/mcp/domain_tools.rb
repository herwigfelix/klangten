# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; tasks and feed domains removed.

require "time"

module EltenMCP
  class DomainTools
    include DomainAccount
    include DomainForum
    include DomainCommunication
    include DomainSocial
    include DomainOrganizer
    include DomainSettings

    SENSITIVE_ARGUMENT_PARTS = %w[email mail password passwd token session auth authorization cookie secret clientkey client_key loginkey login_key].freeze

    SERVER_FAILURES = {
      "network_error" => ["network_unavailable", "Klangten could not reach the server.", true],
      "timeout" => ["request_timed_out", "The Klangten server request timed out.", true],
      "cancelled" => ["request_cancelled", "The Klangten server request was cancelled.", true],
      "invalid_json" => ["invalid_server_response", "Klangten received a server response that did not match its expected contract. No response data was exposed.", true],
      "api_error" => ["request_rejected", "Klangten rejected the requested operation. No server response data was exposed.", false]
    }.freeze

    STRING = { "type" => "string" }.freeze
    INTEGER = { "type" => "integer" }.freeze
    ID = { "type" => "integer", "minimum" => 1 }.freeze
    BOOLEAN = { "type" => "boolean" }.freeze
    STRING_LIST = { "type" => "array", "items" => STRING }.freeze
    INTEGER_LIST = { "type" => "array", "items" => INTEGER }.freeze
    ID_LIST = { "type" => "array", "items" => ID }.freeze
    DOMAIN_PROPERTIES = {
      :account => {
        "user" => STRING.merge("description" => "Exact Klango username; omitted read targets default to the signed-in user."),
        "query" => STRING.merge("description" => "Text to search for in usernames."),
        "only_unacknowledged" => BOOLEAN.merge("description" => "When true, return only notices not yet acknowledged."),
        "text" => STRING.merge("description" => "Complete replacement text; an empty string clears the field where documented."),
        "full_name" => STRING.merge("description" => "Public full name."),
        "gender" => { "type" => "string", "enum" => %w[female male], "description" => "Named profile gender; numeric API values are not accepted." },
        "birthdate" => {
          "type" => "object", "description" => "Complete calendar birth date.",
          "properties" => {
            "year" => INTEGER.merge("minimum" => 1900, "maximum" => 2200),
            "month" => INTEGER.merge("minimum" => 1, "maximum" => 12),
            "day" => INTEGER.merge("minimum" => 1, "maximum" => 31)
          },
          "required" => %w[year month day], "additionalProperties" => false
        },
        "location" => STRING.merge("description" => "Public location text."),
        "visible_to_others" => BOOLEAN.merge("description" => "Whether other users may view the profile."),
        "honor_id" => ID, "permanent" => BOOLEAN, "limit" => INTEGER.merge("minimum" => 1, "maximum" => 200)
      },
      :forum => {
        "query" => STRING.merge("description" => "Search phrase."),
        "search_in" => { "type" => "string", "enum" => %w[post_content post_author thread_title], "description" => "Where to search; defaults to post_content." },
        "include_audio_transcriptions" => BOOLEAN.merge("description" => "For post_content search, include available audio transcriptions."),
        "user" => STRING, "before" => ID.merge("description" => "Pagination cursor returned as next_before."), "limit" => INTEGER.merge("minimum" => 1, "maximum" => 200),
        "include_seen" => BOOLEAN.merge("description" => "Include previously acknowledged mentions."),
        "forum_id" => ID, "thread_id" => ID, "post_id" => ID,
        "thread_ids" => ID_LIST.merge("minItems" => 1, "maxItems" => 500, "uniqueItems" => true),
        "group_id" => ID, "bookmark_id" => ID, "mention_id" => ID,
        "name" => STRING, "text" => STRING, "description" => STRING,
        "language" => STRING,
        "visibility" => { "type" => "string", "enum" => %w[private public], "description" => "Whether the group is discoverable publicly." },
        "join_policy" => { "type" => "string", "enum" => %w[invitation_only membership_request open], "description" => "How users can become members; not every policy is valid for both visibility values." },
        "comment" => STRING, "message" => STRING, "follow" => BOOLEAN,
        "suggestion" => {
          "type" => "object", "description" => "Optional moderator suggestion translated by MCP to Klangten's private action/flags/range fields.",
          "properties" => {
            "action" => { "type" => "string", "enum" => %w[thread_delete thread_move thread_rename thread_close thread_open thread_move_and_close thread_move_and_open thread_offer post_delete post_move post_edit] },
            "target_forum_id" => ID, "target_thread_id" => ID, "target_group_id" => ID,
            "new_thread_title" => STRING, "new_post_text" => STRING,
            "post_ids" => ID_LIST.merge("maxItems" => 500, "uniqueItems" => true)
          },
          "required" => ["action"], "additionalProperties" => false
        },
        "poll_ids" => ID_LIST.merge("description" => "Existing poll IDs to attach."),
        "content_format" => { "type" => "string", "enum" => %w[plain_text markdown], "description" => "Text formatting; defaults to plain_text." },
        "bookmarked" => BOOLEAN.merge("description" => "Desired personal marked-thread state."),
        "users" => STRING_LIST
      },
      :messages => {
        "limit" => INTEGER.merge("minimum" => 1, "maximum" => 500), "user" => STRING, "subject" => STRING, "query" => STRING,
        "group_id" => STRING, "to" => STRING, "text" => STRING,
        "poll_ids" => ID_LIST,
        "message_id" => ID, "flagged" => BOOLEAN, "deletion_protected" => BOOLEAN,
        "users" => STRING_LIST, "add_users" => STRING_LIST, "name" => STRING,
        "duration_seconds" => INTEGER.merge("minimum" => 0, "maximum" => 31_536_000)
      },
      :blogs => {
        "blog" => STRING.merge("description" => "Exact blog identifier; omitted values default to the signed-in user's blog."),
        "owner" => STRING, "sort_by" => { "type" => "string", "enum" => DomainContracts::BLOG_SORTS.keys },
        "category_id" => ID, "page" => INTEGER.merge("minimum" => 1), "query" => STRING,
        "post_id" => ID, "include_seen" => BOOLEAN,
        "comment_status" => { "type" => "string", "enum" => DomainContracts::BLOG_COMMENT_STATUSES.keys },
        "name" => STRING, "shared" => BOOLEAN, "description" => STRING,
        "title" => STRING, "content" => STRING, "excerpt" => STRING,
        "category_ids" => ID_LIST, "tag_ids" => ID_LIST,
        "visibility" => { "type" => "string", "enum" => %w[public private] },
        "comments_enabled" => BOOLEAN,
        "publish_at" => { "description" => "ISO 8601 or epoch publication time.", "oneOf" => [INTEGER, STRING] },
        "comment_id" => ID, "tag_id" => ID, "user" => STRING,
        "users" => STRING_LIST, "message" => STRING, "mention_id" => ID
      },
      :notifications => {
        "include_history" => BOOLEAN,
        "notification_ids" => ID_LIST.merge("description" => "Notification IDs to mark read together in one request.")
      },
      :notes => {
        "note_id" => ID, "name" => STRING, "text" => STRING, "user" => STRING
      },
      :polls => {
        "poll_id" => ID, "author" => STRING,
        "language" => STRING, "query" => STRING, "limit" => INTEGER.merge("minimum" => 1, "maximum" => 500),
        "answers" => {
          "type" => "array", "minItems" => 1, "maxItems" => 100,
          "description" => "One structured answer per answered question. Use selected_option_indexes for choice questions and text for text questions.",
          "items" => {
            "type" => "object", "properties" => {
              "question_index" => INTEGER.merge("minimum" => 0),
              "selected_option_indexes" => { "type" => "array", "items" => INTEGER.merge("minimum" => 0) },
              "text" => STRING
            }, "required" => ["question_index"], "additionalProperties" => false
          }
        },
        "name" => STRING,
        "questions" => {
          "type" => "array", "minItems" => 1, "maxItems" => 100,
          "description" => "Structured poll questions; option indexes are their zero-based positions.",
          "items" => {
            "type" => "object", "properties" => {
              "text" => STRING,
              "kind" => { "type" => "string", "enum" => %w[single_choice multiple_choice text] },
              "options" => STRING_LIST,
              "maximum_choices" => INTEGER.merge("minimum" => 2)
            }, "required" => %w[text kind], "additionalProperties" => false
          }
        },
        "description" => STRING, "hidden" => BOOLEAN,
        "expires_at" => { "description" => "ISO 8601 or epoch expiry time.", "oneOf" => [INTEGER, STRING] },
        "hide_results_until_expiry" => BOOLEAN
      }
    }.freeze

    def initialize(registry, bridge, authorization)
      @registry = registry
      @bridge = bridge
      @authorization = authorization
    end

    def register_all
      register_account_tools
      register_forum_tools
      register_communication_tools
      register_social_tools
      register_organizer_tools
      register_settings_tools
    end

    private

    def register_domain_tool(name, title, description, aspect, level, schema, annotations = nil, &handler)
      operations = schema.is_a?(Hash) && schema["oneOf"].is_a?(Array) ? schema["oneOf"].map { |branch| branch.dig("properties", "action", "enum", 0) }.compact : []
      guide = DomainContracts.describe(aspect, operations)
      complete_description = guide == "" ? description.to_s : "#{description}\n\nOperations and usage:\n#{guide}"
      output_schema = if operations.empty?
        {
          "type" => "object", "properties" => {
            "operation" => { "type" => "string" }, "summary" => { "type" => "string" },
            "status" => { "type" => "string", "enum" => %w[completed proposed] }
          }, "required" => %w[operation summary]
        }
      else
        {
          "type" => "object", "oneOf" => operations.map do |operation|
            {
              "title" => "#{operation} result", "type" => "object",
              "properties" => {
                "operation" => { "type" => "string", "enum" => [operation] },
                "summary" => { "type" => "string" },
                "status" => { "type" => "string", "enum" => %w[completed proposed] }
              },
              "required" => %w[operation summary]
            }
          end
        }
      end
      @registry.register(
        name,
        :title => title,
        :description => complete_description,
        :permission => Authorization.requirement(aspect, level),
        :input_schema => schema,
        :output_schema => output_schema,
        :annotations => annotations || read_only_annotations,
        :execution => (aspect == :settings ? :main : :worker)
      ) do |args|
        reject_sensitive_arguments!(args)
        begin
          output = KnownData.encode(handler.call(args))
          raise ToolError, "Internal MCP domain response was not explicitly constructed" if !output.is_a?(KnownData::ObjectValue)
          output
        rescue EltenLink::Error => e
          raise translated_server_error(e)
        rescue EltenMCP::Error
          raise
        rescue Exception => e
          Log.error("MCP domain response contract failed: #{e.class}") if defined?(Log)
          raise ToolError, "Klangten domain response did not match the expected safe contract"
        end
      end
    end

    def result(values = {})
      KnownData.object(values)
    end

    def translated_server_error(error)
      code = error.respond_to?(:code) ? error.code : nil
      key = (code.is_a?(String) || code.is_a?(Symbol)) ? code.to_s : ""
      kind, message, retryable = SERVER_FAILURES.fetch(key,
        ["request_rejected", "Klangten rejected the requested operation. No server response data was exposed.", false])
      Log.error("MCP Klango server request failed: #{kind}") if defined?(Log)
      ToolError.new(message, :data => result("kind" => kind, "retryable" => retryable))
    end

    def response(operation, summary, values = {})
      raise ToolError, "Internal MCP response fields must be an object" if !values.is_a?(Hash)
      result({ "operation" => operation.to_s, "summary" => summary.to_s }.merge(values))
    end

    def completed(operation, summary, values = {})
      response(operation, summary, { "status" => "completed" }.merge(values))
    end

    def known(value, model)
      KnownData.model(value, model)
    end

    def known_list(values, model)
      KnownData.models(values, model)
    end

    def action_schema(actions, domain = nil)
      fields = DOMAIN_PROPERTIES[domain] || {}
      branches = actions.map do |action|
        spec = DomainContracts.action(domain, action)
        raise ArgumentError, "Missing MCP action contract for #{domain}/#{action}" if spec == nil
        names = (spec.required + spec.optional).uniq
        properties = { "action" => { "type" => "string", "enum" => [action], "description" => spec.description } }
        names.each do |name|
          property = if name == "acknowledge_read_state"
            { "type" => "boolean", "enum" => [true], "description" => "Confirm the documented read-state change after telling the user when preserving unread state matters." }
          else
            fields[name]
          end
          raise ArgumentError, "Missing MCP argument schema for #{domain}/#{action}.#{name}" if property == nil
          properties[name] = property
        end
        {
          "title" => spec.title, "description" => spec.description,
          "type" => "object", "properties" => properties,
          "required" => ["action"] + spec.required,
          "additionalProperties" => false
        }
      end
      { "type" => "object", "oneOf" => branches }
    end

    def network_client
      raise ToolError, "Klango account is not signed in" if !Session.logged?
      @bridge.background_network_client
    end

    def session_name
      Session.name.to_s
    end

    def optional_user(args)
      value = args["user"].to_s.strip
      value == "" ? session_name : value
    end

    def confirmation_required(operation, warning)
      response(operation, "No data was read because this operation can change unread state. Inform the user when preserving unread state matters, then retry with acknowledgement.",
        "requires_confirmation" => true,
        "warning" => warning,
        "retry_with" => result("acknowledge_read_state" => true)
      )
    end

    def reject_sensitive_arguments!(value, depth = 0)
      raise InvalidParamsError, "Arguments are nested too deeply" if depth > 12
      case value
      when Hash
        value.each do |key, item|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]+/, "_")
          parts = normalized.split("_")
          if SENSITIVE_ARGUMENT_PARTS.include?(normalized) || (parts & SENSITIVE_ARGUMENT_PARTS).any?
            raise InvalidParamsError, "Authentication, password and email fields are not accepted by this tool"
          end
          reject_sensitive_arguments!(item, depth + 1)
        end
      when Array
        value.each { |item| reject_sensitive_arguments!(item, depth + 1) }
      end
    end

    def invalid_action(action)
      raise InvalidParamsError, "Unknown action: #{action}"
    end

    def required_string(args, key, allow_empty = false)
      value = args[key]
      raise InvalidParamsError, "#{key} must be a string" if !value.is_a?(String)
      raise InvalidParamsError, "#{key} is required" if !allow_empty && value.strip == ""
      raise InvalidParamsError, "#{key} is too large" if value.bytesize > 2_000_000
      value
    end

    def limited_string(args, key, maximum, allow_empty = false)
      value = required_string(args, key, allow_empty)
      raise InvalidParamsError, "#{key} is longer than #{maximum} characters" if value.each_char.count > maximum
      value
    end

    def required_array(args, key, maximum)
      value = args[key]
      raise InvalidParamsError, "#{key} must be a non-empty array" if !value.is_a?(Array) || value.empty?
      raise InvalidParamsError, "#{key} has too many items" if value.size > maximum
      value
    end

    def string_array(args, key, maximum)
      required_array(args, key, maximum).map do |value|
        raise InvalidParamsError, "#{key} must contain non-empty strings" if !value.is_a?(String) || value.strip == ""
        value
      end.uniq
    end

    def string_values(values)
      raise ToolError, "Expected a list of strings" if !values.is_a?(Array) || !values.all? { |value| value.is_a?(String) }
      values
    end

    def integer_array(values)
      raise ToolError, "Expected a list of integers" if !values.is_a?(Array) || !values.all? { |value| value.is_a?(Integer) }
      values
    end

    def server_string(value, label = "server value")
      raise ToolError, "Unexpected #{label} contract" if !value.is_a?(String)
      value
    end

    def server_integer(value, label = "server value", positive = false)
      raise ToolError, "Unexpected #{label} contract" if !value.is_a?(Integer)
      raise ToolError, "Unexpected #{label} contract" if positive && value <= 0
      value
    end

    def server_integer_text(value, label = "server value")
      raise ToolError, "Unexpected #{label} contract" if !value.is_a?(String) || !value.match?(/\A-?[0-9]+\z/)
      value.to_i
    end

    def server_boolean(value, label = "server value")
      raise ToolError, "Unexpected #{label} contract" if value != true && value != false
      value
    end

    def boolean_arg(args, key)
      value = args[key]
      raise InvalidParamsError, "#{key} must be boolean" if value != true && value != false
      value
    end

    def bounded(value, minimum, maximum, default)
      number = value == nil ? default : Integer(value)
      raise InvalidParamsError, "Number is outside #{minimum}..#{maximum}" if number < minimum || number > maximum
      number
    rescue ArgumentError, TypeError
      raise InvalidParamsError, "Expected an integer"
    end

    def positive_id(args, key)
      positive_value(args[key], key)
    end

    def positive_value(value, key)
      id = Integer(value) rescue 0
      raise InvalidParamsError, "#{key} must be a positive integer" if id <= 0
      id
    end

    def optional_id(value)
      return nil if value == nil || value.to_s == ""
      positive_value(value, "id")
    end

    def positive_ids(values)
      Array(values).map { |value| positive_value(value, "ids") }.uniq
    end

    def require_ids(ids)
      raise InvalidParamsError, "ids must contain at least one positive integer" if ids.empty?
      ids
    end

    def time_argument(value)
      return nil if value == nil || value.to_s == ""
      return Time.at(value.to_i) if value.is_a?(Numeric) || value.to_s.match?(/^[0-9]+$/)
      Time.parse(value.to_s)
    rescue ArgumentError
      raise InvalidParamsError, "Time must be an epoch value or ISO 8601 string"
    end

    def epoch_argument(value)
      time = time_argument(value)
      time == nil ? nil : time.to_i
    end

    def forum_content_format(value)
      case (value || "plain_text").to_s
      when "plain_text" then 0
      when "markdown" then 1
      else raise InvalidParamsError, "content_format must be plain_text or markdown"
      end
    end

    def required_time(args, key)
      value = time_argument(args[key])
      raise InvalidParamsError, "#{key} is required" if value == nil
      value
    end

    def read_only_annotations
      { "readOnlyHint" => true, "destructiveHint" => false, "idempotentHint" => true, "openWorldHint" => true }
    end

    def mutating_annotations
      { "readOnlyHint" => false, "destructiveHint" => false, "idempotentHint" => false, "openWorldHint" => true }
    end

    def destructive_annotations
      { "readOnlyHint" => false, "destructiveHint" => true, "idempotentHint" => false, "openWorldHint" => true }
    end
  end
end
