# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

# iOS spell checking. Backed by UITextChecker in the native host when available;
# otherwise reports as unavailable (same contract as the macOS backend).

class SpellCheck
  class Result
    attr_accessor :index, :length
    attr_reader :suggestions

    def initialize
      @suggestions = []
    end
  end

  class << self
    def available?
      defined?(IOSHostBridge) && IOSHostBridge.respond_to?(:spellcheck) && IOSHostBridge.spellcheck_available?
    rescue Exception
      false
    end

    def languages
      return [] unless available?
      Array(IOSHostBridge.spellcheck_languages)
    rescue Exception
      []
    end

    def check(language, text)
      return [] unless available?
      raw = IOSHostBridge.spellcheck(language.to_s, text.to_s)
      Array(raw).map do |entry|
        result = Result.new
        result.index = entry[:index].to_i
        result.length = entry[:length].to_i
        Array(entry[:suggestions]).each { |suggestion| result.suggestions << suggestion.to_s }
        result
      end
    rescue Exception
      []
    end
  end
end
