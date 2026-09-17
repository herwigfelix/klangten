# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: notes only (Klango has no calendars or task projects).

module EltenMCP
  # Klangten: calendars and task projects do not exist on the Klango server, so
  # this domain now covers notes only (plus the poll tools registered below).
  module DomainOrganizer
    def register_organizer_tools
      register_notes
      register_polls
    end

    private

    def register_notes
      register_domain_tool(
        "notes_scope", "Discover note permission scopes",
        "Always-available permission discovery for notes. This tool returns only note IDs and titles, never note text. Note creation is a separate selective scope.",
        :basic, :read,
        {
          "type" => "object",
          "properties" => { "action" => { "type" => "string", "enum" => %w[notes] } },
          "required" => ["action"], "additionalProperties" => false
        }
      ) do |args|
        client = network_client
        case args["action"]
        when "notes"
          raw = EltenLink::Notes.list(client)
          @authorization.remember_notes_scope(raw)
          scopes = raw.map { |note| result("note_id" => note.id, "name" => note.name.to_s) }
          response("notes", "Returned #{scopes.size} note permission scopes without note content.",
            "notes" => scopes, "count" => scopes.size, "creation_scope" => result("aspect" => "notes", "resource_type" => "note_creation", "level" => "write"))
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "notes_read", "Read notes",
        "Read notes through named titles, text, authors, timestamps and shares. No server object or server JSON is forwarded.",
        :notes, :read,
        action_schema(%w[notes note note_shares], :notes)
      ) do |args|
        client = network_client
        case args["action"]
        when "notes"
          raw = EltenLink::Notes.list(client)
          @authorization.remember_notes_scope(raw)
          notes = known_list(raw, :note)
          response("notes", "Returned #{notes.size} notes.", "notes" => notes, "count" => notes.size)
        when "note"
          id = positive_id(args, "note_id")
          raw = EltenLink::Notes.list(client)
          @authorization.remember_notes_scope(raw)
          note = raw.find { |item| item.id == id }
          raise ToolError, "Note #{id} was not found or is not accessible" if note == nil
          response("note", "Returned note #{id}.", "note" => known(note, :note))
        when "note_shares"
          id = positive_id(args, "note_id")
          users = string_values(EltenLink::Notes.shares(client, id))
          response("note_shares", "Returned #{users.size} users sharing note #{id}.", "note_id" => id, "users" => users, "count" => users.size)
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "notes_write", "Write notes",
        "Create and manage notes through semantic fields. The program translates them to strict Klango server calls.",
        :notes, :write,
        action_schema(%w[note_create note_update note_rename note_delete note_share_add note_share_delete], :notes),
        destructive_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "note_create"
          name = required_string(args, "name")
          EltenLink::Notes.create(client, name, required_string(args, "text", true))
          completed("note_create", "Created note '#{name}'.", "name" => name)
        when "note_update"
          id = positive_id(args, "note_id")
          EltenLink::Notes.update(client, id, required_string(args, "text", true))
          completed("note_update", "Updated text of note #{id}.", "note_id" => id)
        when "note_rename"
          id = positive_id(args, "note_id")
          name = required_string(args, "name")
          EltenLink::Notes.rename(client, id, name)
          completed("note_rename", "Renamed note #{id} to '#{name}'.", "note_id" => id, "name" => name)
        when "note_delete"
          id = positive_id(args, "note_id")
          EltenLink::Notes.delete(client, id)
          completed("note_delete", "Deleted note #{id}.", "note_id" => id)
        when "note_share_add", "note_share_delete"
          id = positive_id(args, "note_id")
          user = required_string(args, "user")
          if args["action"] == "note_share_add"
            EltenLink::Notes.add_share(client, id, user)
          else
            EltenLink::Notes.delete_share(client, id, user)
          end
          completed(args["action"], args["action"] == "note_share_add" ? "Shared note #{id} with #{user}." : "Removed #{user}'s access to note #{id}.",
            "note_id" => id, "user" => user)
        else invalid_action(args["action"])
        end
      end
    end

    def register_polls
      register_domain_tool(
        "polls_read", "Read polls",
        "Read polls without positional arrays or numeric question types. Questions have named kinds and indexed options; results resolve encoded option answers to text, counts and percentages.",
        :polls, :read, action_schema(%w[list get results voted by_me], :polls)
      ) do |args|
        client = network_client
        case args["action"]
        when "list"
          polls = EltenLink::Polls.list(client, :details => 2, :params => poll_filters(args))
          polls = polls.first(bounded(args["limit"], 1, 500, 100))
          mapped = known_list(polls, :poll)
          response("list", "Returned #{mapped.size} polls.", "polls" => mapped, "count" => mapped.size, "filters" => poll_filter_response(args))
        when "get"
          id = positive_id(args, "poll_id")
          response("get", "Returned poll #{id} with indexed, named questions.", "poll" => known(EltenLink::Polls.get(client, id), :poll_details))
        when "results"
          poll_results_response(client, positive_id(args, "poll_id"))
        when "voted"
          id = positive_id(args, "poll_id")
          voted = server_boolean(EltenLink::Polls.voted?(client, id), "poll answered state")
          response("voted", voted ? "The signed-in user has answered poll #{id}." : "The signed-in user has not answered poll #{id}.",
            "poll_id" => id, "answered_by_me" => voted)
        when "by_me"
          polls = known_list(EltenLink::Polls.by_me(client), :poll)
          response("by_me", "Returned #{polls.size} polls created by the signed-in user.", "polls" => polls, "count" => polls.size)
        else invalid_action(args["action"])
        end
      end

      register_domain_tool(
        "polls_write", "Answer or manage polls",
        "Answer, create or delete polls through structured objects. The program reads the poll, validates question/option indexes and constructs Klangten's private wire format itself.",
        :polls, :write, action_schema(%w[answer create delete], :polls), destructive_annotations
      ) do |args|
        client = network_client
        case args["action"]
        when "answer"
          id = positive_id(args, "poll_id")
          poll = known(EltenLink::Polls.get(client, id), :poll_details)
          encoded = poll_answers_input(args, poll["questions"])
          EltenLink::Polls.answer(client, id, encoded)
          completed("answer", "Saved structured answers to poll #{id}.", "poll_id" => id,
            "answered_question_indexes" => args["answers"].map { |answer| answer["question_index"] }.uniq.sort)
        when "create"
          name = required_string(args, "name")
          expiry = args.key?("expires_at") ? required_time(args, "expires_at").to_i : nil
          hide_results = args["hide_results_until_expiry"] == true
          raise InvalidParamsError, "hide_results_until_expiry requires expires_at" if hide_results && expiry == nil
          questions = poll_questions_input(args)
          EltenLink::Polls.create(client, :name => name, :language => required_string(args, "language"),
            :questions => questions, :description => (args.key?("description") ? required_string(args, "description", true) : ""),
            :hidden => args["hidden"] == true, :expirydate => expiry, :hideresults => hide_results)
          completed("create", "Created poll '#{name}' with #{questions.size} structured questions.",
            "name" => name, "question_count" => questions.size, "hidden" => args["hidden"] == true,
            "expires_at" => (expiry == nil ? nil : Time.at(expiry)), "results_hidden_until_expiry" => hide_results)
        when "delete"
          id = positive_id(args, "poll_id")
          EltenLink::Polls.delete(client, id)
          completed("delete", "Deleted poll #{id}.", "poll_id" => id)
        else invalid_action(args["action"])
        end
      end
    end

    def poll_filters(args)
      filters = {}
      { "author" => "author", "language" => "language", "query" => "query" }.each do |argument, key|
        filters[key] = required_string(args, argument) if args.key?(argument)
      end
      filters
    end

    def poll_filter_response(args)
      values = {}
      %w[author language query].each { |key| values[key] = args[key] if args.key?(key) }
      result(values)
    end

    def poll_questions_input(args)
      questions = required_array(args, "questions", 100)
      questions.map do |question|
        raise InvalidParamsError, "Each poll question must be an object" if !question.is_a?(Hash)
        text = required_string(question, "text")
        kind = required_string(question, "kind")
        options = if question.key?("options")
          string_array(question, "options", 200)
        else
          []
        end
        type = case kind
        when "single_choice"
          raise InvalidParamsError, "A single-choice question needs at least two options" if options.size < 2
          raise InvalidParamsError, "maximum_choices is not valid for single_choice" if question.key?("maximum_choices")
          0
        when "multiple_choice"
          raise InvalidParamsError, "A multiple-choice question needs at least two options" if options.size < 2
          if question.key?("maximum_choices")
            maximum = positive_value(question["maximum_choices"], "maximum_choices")
            raise InvalidParamsError, "maximum_choices must be at least 2 and no greater than option count" if maximum < 2 || maximum > options.size
            -maximum
          else
            1
          end
        when "text"
          raise InvalidParamsError, "A text question cannot define options or maximum_choices" if !options.empty? || question.key?("maximum_choices")
          2
        else
          raise InvalidParamsError, "kind must be single_choice, multiple_choice or text"
        end
        [text, type] + options
      end
    end

    def poll_answers_input(args, questions)
      answers = required_array(args, "answers", 100)
      raise ToolError, "Unexpected poll question contract" if !questions.is_a?(Array)
      used = {}
      lines = []
      answers.each do |answer|
        raise InvalidParamsError, "Each poll answer must be an object" if !answer.is_a?(Hash)
        question_index = answer["question_index"]
        raise InvalidParamsError, "question_index is outside the poll" if question_index < 0 || question_index >= questions.size
        raise InvalidParamsError, "Each question can appear only once in answers" if used[question_index]
        used[question_index] = true
        question = questions[question_index]
        raise ToolError, "Unexpected translated poll question contract" if !question.is_a?(KnownData::ObjectValue)
        kind = question["kind"]
        maximum = question["maximum_choices"]
        if kind == "text"
          raise InvalidParamsError, "Text question #{question_index} requires text and no selected_option_indexes" if !answer["text"].is_a?(String) || answer.key?("selected_option_indexes")
          text = answer["text"].gsub(/[;:\r\n]/, " ").strip
          raise InvalidParamsError, "Text answer for question #{question_index} is empty" if text == ""
          lines << "#{question_index}:#{text}"
        else
          raise InvalidParamsError, "Choice question #{question_index} requires selected_option_indexes and no text" if !answer["selected_option_indexes"].is_a?(Array) || answer.key?("text")
          selected = positive_or_zero_indexes(answer["selected_option_indexes"], question["options"].size)
          raise InvalidParamsError, "Single-choice question #{question_index} requires exactly one option" if kind == "single_choice" && selected.size != 1
          raise InvalidParamsError, "Question #{question_index} allows at most #{maximum} choices" if maximum != nil && selected.size > maximum
          selected.each { |option_index| lines << "#{question_index}:#{option_index}" }
        end
      end
      lines.join("\r\n")
    end

    def positive_or_zero_indexes(values, option_count)
      raise InvalidParamsError, "selected_option_indexes must be a non-empty array" if !values.is_a?(Array) || values.empty?
      indexes = values.map do |value|
        index = value
        raise InvalidParamsError, "selected option index is outside the question" if index < 0 || index >= option_count
        index
      end.uniq
      indexes
    end

    def poll_results_response(client, poll_id)
      poll = known(EltenLink::Polls.get(client, poll_id), :poll_details)
      results = known(EltenLink::Polls.results(client, poll_id, :details => 1), :poll_results)
      grouped = results["answers"].group_by { |answer| answer["question_index"] }
      questions = poll["questions"].map do |question|
        index = question["question_index"]
        kind = question["kind"]
        maximum = question["maximum_choices"]
        answers = grouped[index] || []
        base = result(
          "question_index" => index, "text" => question["text"], "kind" => kind,
          "maximum_choices" => maximum, "answer_record_count" => answers.size
        )
        if kind == "text"
          base["text_answers"] = answers.map do |answer|
            result("anonymous_respondent_id" => answer["anonymous_respondent_id"], "text" => answer["answer_value"])
          end
        else
          options = question["options"]
          counts = Hash.new(0)
          respondents = Hash.new { |hash, key| hash[key] = [] }
          answers.each do |answer|
            option_index = server_integer_text(answer["answer_value"], "poll result option index")
            raise ToolError, "Poll result references an unknown option" if option_index < 0 || option_index >= options.size
            counts[option_index] += 1
            respondents[option_index] << answer["anonymous_respondent_id"]
          end
          base["options"] = options.map do |option|
            option_index = option["option_index"]
            percentage = results["vote_count"] <= 0 ? 0.0 : (counts[option_index].to_f * 100.0 / results["vote_count"]).round(2)
            result("option_index" => option_index, "text" => option["text"], "selection_count" => counts[option_index],
              "percentage_of_voters" => percentage, "anonymous_respondent_ids" => respondents[option_index].uniq)
          end
        end
        base
      end
      response("results", "Returned readable results for poll #{poll_id} with #{results["vote_count"]} voters.",
        "poll" => result("poll_id" => poll_id, "name" => poll["name"], "author" => poll["author"]),
        "voter_count" => results["vote_count"], "questions" => questions)
    end
  end
end
