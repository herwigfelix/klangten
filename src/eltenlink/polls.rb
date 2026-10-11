# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: drafts, editing, publishing, group polls, polls by author and language, answer drafts.

module EltenLink
  class Poll
    attr_accessor :id, :name, :author, :description, :created, :voted, :language, :votes
    # Klangten: "draft", "public", "group" or "hidden", and the group id.
    attr_accessor :status, :group

    def initialize(id = 0)
      @id = id.to_i
      @name = ""
      @author = ""
      @description = ""
      @created = 0
      @voted = false
      @language = ""
      @votes = 0
      @status = "public"
      @group = 0
    end

    def draft?
      @status == "draft"
    end
  end

  class PollDetails < Poll
    attr_accessor :questions
    # Klangten: own poll that may be edited; questions locked once published or voted.
    attr_accessor :can_edit, :locked, :anonymous

    def initialize(id = 0)
      super(id)
      @questions = []
    end
  end

  class PollResults
    attr_accessor :votes, :answers

    def initialize(votes = 0, answers = [])
      @votes = votes.to_i
      @answers = answers
    end
  end

  class PollAnswer
    attr_accessor :author, :question, :answer, :type

    def initialize(author:, question:, answer:, type: 0)
      @author = author
      @question = question.to_i
      @answer = answer
      @type = type.to_i
    end
  end

  module Polls
    class << self
      def list(client, details: 2, params: {})
        request_params = params.merge("details" => details)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls", request_params)["polls"])
      end

      def voted?(client, poll)
        data = client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}/voted")
        data["voted"] == true || data["voted"].to_s == "1"
      end

      def delete(client, poll)
        client.api_data("DELETE", "/api/v1/polls/#{poll_id(poll)}")
        true
      end

      def create(client, name:, language:, questions:, description:, hidden: false, expirydate: nil, hideresults: false, draft: false, groupid: nil)
        params = {
          "name" => name,
          "language" => language,
          "questions" => JSON.generate(questions),
          "description" => description,
          "hidden" => hidden ? 1 : 0
        }
        params["expirydate"] = expirydate if expirydate != nil
        params["hideresults"] = hideresults ? 1 : 0 if expirydate != nil
        params["draft"] = 1 if draft
        params["groupid"] = groupid.to_i if groupid.to_i > 0
        client.api_data("POST", "/api/v1/polls", params)["id"].to_i
      end

      # Klangten: changes an own poll. Questions are only replaced while the
      # poll is an unpublished draft without votes; returns true when the
      # server kept the old questions (locked).
      def edit(client, poll, name: nil, description: nil, language: nil, questions: nil)
        params = {}
        params["name"] = name if name != nil
        params["description"] = description if description != nil
        params["language"] = language if language != nil
        params["questions"] = JSON.generate(questions) if questions != nil
        client.api_data("PATCH", "/api/v1/polls/#{poll_id(poll)}", params)["locked"] == true
      end

      # Publishes an own poll for everyone, only by link (hidden) or in a group.
      def publish(client, poll, groupid: nil, hidden: false)
        params = {}
        params["groupid"] = groupid.to_i if groupid.to_i > 0
        params["hidden"] = 1 if hidden
        client.api_data("POST", "/api/v1/polls/#{poll_id(poll)}/publish", params)["status"].to_s
      end

      def unpublish(client, poll)
        client.api_data("POST", "/api/v1/polls/#{poll_id(poll)}/unpublish")
        true
      end

      # [[author, number of polls]]
      def authors(client)
        Array(client.api_data("GET", "/api/v1/polls/authors")["authors"]).map { |row| [row["user"].to_s, row["polls"].to_i] }
      end

      def by_author(client, user)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls/authors/#{user.to_s.urlenc}")["polls"])
      end

      # [[code, name, number of polls]]
      def languages(client)
        Array(client.api_data("GET", "/api/v1/polls/languages")["languages"]).map { |row| [row["language"].to_s, row["name"].to_s, row["polls"].to_i] }
      end

      def by_language(client, code)
        code = code.to_s == "" ? "-" : code.to_s
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls/languages/#{code.urlenc}")["polls"])
      end

      def group_polls(client, group_id)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls/groups/#{group_id.to_i}")["polls"])
      end

      # Saved answers that were not sent yet: answer lines as for answer(), or nil.
      def answer_draft(client, poll)
        data = client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}/draft")
        data["draft"] == true ? data["answers"].to_s : nil
      end

      def save_answer_draft(client, poll, answers)
        client.api_data("PUT", "/api/v1/polls/#{poll_id(poll)}/draft", { "answers" => answers })
        true
      end

      def delete_answer_draft(client, poll)
        client.api_data("DELETE", "/api/v1/polls/#{poll_id(poll)}/draft")
        true
      end

      def get(client, poll)
        parse_details(client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}"), poll_id(poll))
      end

      def answer(client, poll, answers)
        client.api_data("POST", "/api/v1/polls/#{poll_id(poll)}/answers", { "answers" => answers })
        true
      end

      def results(client, poll, details: 1)
        parse_results(client.api_data("GET", "/api/v1/polls/#{poll_id(poll)}/results", { "details" => details }))
      end

      def by_me(client)
        parse_poll_summaries(client.api_data("GET", "/api/v1/polls", { "by_me" => "1" })["polls"])
      end

      private

      def parse_poll_summaries(rows)
        rows.to_a.map do |row|
          poll = Poll.new(row["id"])
          poll.name = row["name"].to_s
          poll.author = row["author"].to_s
          poll.created = row["created"].to_i
          poll.language = row["language"].to_s
          poll.voted = row["voted"] == true || row["voted"].to_s == "1"
          poll.votes = row["votes"].to_i
          poll.description = row["description"].to_s
          poll.status = row["status"].to_s == "" ? "public" : row["status"].to_s
          poll.group = row["group"].to_i
          poll
        end
      end

      def parse_details(data, id)
        poll = PollDetails.new(id)
        poll.name = data["name"].to_s
        poll.author = data["author"].to_s
        poll.created = Time.at(data["created"].to_i)
        poll.questions = data["questions"].is_a?(Array) ? data["questions"] : []
        poll.description = data["description"].to_s
        poll.language = data["language"].to_s
        poll.votes = data["votes"].to_i
        poll.voted = data["voted"] == true
        poll.status = data["status"].to_s == "" ? "public" : data["status"].to_s
        poll.group = data["group"].to_i
        poll.can_edit = data["can_edit"] == true
        poll.locked = data["locked"] == true
        poll.anonymous = data["anonymous"] == true
        poll
      end

      def parse_results(data)
        answers = []
        data["answers"].to_a.each do |row|
          answers.push(PollAnswer.new(
            author: row["author"].to_i,
            question: row["question"].to_i,
            answer: row["answer"].to_s
          ))
        end
        PollResults.new(data["votes"].to_i, answers)
      end

      def poll_id(poll)
        poll.respond_to?(:id) ? poll.id : poll
      end
    end
  end
end
