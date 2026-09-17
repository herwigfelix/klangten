# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: rebranded; updater settings removed.

module EltenMCP
  module DomainSettings
    SAFE_SETTINGS = {
      "main_volume" => [:integer, "Interface", "MainVolume", :volume, 5, 100],
      "background_sounds" => [:boolean, "Interface", "BGSounds", :bgsounds],
      "sound_theme_activation" => [:boolean, "Interface", "SoundThemeActivation", :soundthemeactivation],
      "list_type" => [:enum, "Interface", "ListType", :listtype, %w[linear circular]],
      "keyboard_scheme" => [:enum, "Interface", "KeyboardScheme", :keyboardscheme, %w[default windows macos]],
      "controls_presentation" => [:enum, "Interface", "ControlsPresentation", :controlspresentation, %w[voice_and_sound sound_only voice_only]],
      "typing_echo" => [:enum, "Interface", "TypingEcho", :typingecho, %w[characters words characters_and_words none]],
      "use_pan" => [:boolean, "Interface", "UsePan", :usepan],
      "enable_braille" => [:boolean, "Interface", "EnableBraille", :enablebraille],
      "autoplay" => [:enum, "Interface", "AutoPlay", :autoplay, %w[always without_transcription never]],
      "line_wrapping" => [:boolean, "Interface", "LineWrapping", :linewrapping],
      "hide_window" => [:boolean, "Interface", "HideWindow", :hidewindow],
      "context_menu_bar" => [:boolean, "Interface", "ContextMenuBar", :contextmenubar],
      "language" => [:string, "Interface", "Language", :language],
      "voice" => [:string, "Voice", "Voice", :voice],
      "voice_rate" => [:integer, "Voice", "Rate", :voicerate, 0, 100],
      "voice_volume" => [:integer, "Voice", "Volume", :voicevolume, 5, 100],
      "voice_pitch" => [:integer, "Voice", "Pitch", :voicepitch, 0, 100],
      "sync_time" => [:boolean, "Advanced", "SyncTime", :synctime],
      "clock_period" => [:enum, "Clock", "SayTimePeriod", :saytimeperiod, %w[hourly half_hourly quarter_hourly]],
      "clock_type" => [:enum, "Clock", "SayTimeType", :saytimetype, %w[none voice_and_sound voice_only sound_only]],
      "usage_reports" => [:tristate, "Privacy", "RegisterActivity", :registeractivity, %w[unset enabled disabled]]
    }.freeze

    SETTING_INFO = {
      "main_volume" => ["Main volume", "Volume of Klangten interface sounds, from 0 to 100."],
      "background_sounds" => ["Background sounds", "Play ambient menu and dialog background sounds."],
      "sound_theme_activation" => ["Sound theme sounds", "Play event sounds from the selected sound theme."],
      "list_type" => ["List navigation", "linear stops at list ends; circular wraps to the opposite end."],
      "keyboard_scheme" => ["Keyboard scheme", "Keyboard convention used by Klangten controls."],
      "controls_presentation" => ["Control announcements", "How controls are announced: speech, sounds or both."],
      "typing_echo" => ["Typing echo", "Whether typed characters, words, both or neither are spoken."],
      "use_pan" => ["Stereo positioning", "Use left/right positioning for interface sounds."],
      "enable_braille" => ["Braille output", "Enable supported braille output."],
      "autoplay" => ["Audio autoplay", "When audio content starts automatically."],
      "line_wrapping" => ["Wrap long lines", "Wrap long lines in text fields."],
      "hide_window" => ["Minimize to tray", "Automatically minimize the Klangten window to the system tray."],
      "context_menu_bar" => ["Context menu in menu bar", "Expose the current context menu in the application menu bar."],
      "language" => ["Interface language", "Language code of the Klangten interface. Use one of the returned choices."],
      "voice" => ["Speech voice", "Speech voice identifier. Use one of the returned choices."],
      "voice_rate" => ["Speech rate", "Speech rate from 0 to 100."],
      "voice_volume" => ["Speech volume", "Speech volume from 5 to 100."],
      "voice_pitch" => ["Speech pitch", "Speech pitch from 0 to 100."],
      "sync_time" => ["Synchronize time", "Synchronize the time used by Klangten with the server clock."],
      "clock_period" => ["Clock announcement interval", "How often Klangten announces the time when clock announcements are enabled."],
      "clock_type" => ["Clock announcement style", "Whether time is announced by speech, sound, both or not at all."],
      "usage_reports" => ["Usage reports", "Allow Klangten to send usage reports."]
    }.freeze

    RESTART_SETTINGS = %w[language voice].freeze

    def register_settings_tools
      register_domain_tool(
        "settings_read", "Read changeable settings",
        "Read the fixed allowlist as self-describing setting objects: current value, label, explanation, type, choices/range and restart advice. No MCP, login, token, email, password, network-account or auto-login field is present.",
        :settings, :write, action_schema(%w[list], :settings)
      ) do |_args|
        settings = SAFE_SETTINGS.map { |name, spec| setting_description(name, spec) }
        response("list", "Returned #{settings.size} changeable settings. Call settings_read before settings_write and use only returned values/choices.",
          "settings" => settings, "count" => settings.size,
          "excluded" => "MCP configuration and permissions; authentication/account settings; auto-login; low-level network transport settings")
      end

      value_properties = SAFE_SETTINGS.each_with_object({}) do |(name, spec), properties|
        properties[name] = setting_input_schema(name, spec)
      end
      schema = {
        "type" => "object",
        "properties" => {
          "values" => {
            "type" => "object", "properties" => value_properties,
            "minProperties" => 1, "maxProperties" => SAFE_SETTINGS.size,
            "additionalProperties" => false,
            "description" => "Setting names and semantic values returned by settings_read."
          }
        },
        "required" => ["values"], "additionalProperties" => false
      }
      register_domain_tool(
        "settings_write", "Change Klangten settings",
        "Change several settings returned by settings_read in one call. Read metadata first and use its exact name, type, range and choices. Unknown/protected names and unavailable language/voice identifiers are rejected. MCP permissions, enablement, key and port cannot be changed.",
        :settings, :write, schema, mutating_annotations
      ) { |args| update_safe_settings(args["values"]) }
    end

    private

    def update_safe_settings(values)
      raise InvalidParamsError, "values must be a non-empty object" if !values.is_a?(Hash) || values.empty?
      raise InvalidParamsError, "At most 50 settings can be changed together" if values.size > 50
      unknown = values.keys.map(&:to_s) - SAFE_SETTINGS.keys
      raise InvalidParamsError, "Unknown or protected settings: #{unknown.join(", ")}" if !unknown.empty?
      changes = []
      values.each do |name, raw_value|
        spec = SAFE_SETTINGS[name.to_s]
        value = coerce_safe_setting(name.to_s, raw_value, spec)
        previous = current_setting(spec)
        stored = case spec[0]
        when :enum then value.to_s
        when :tristate then { nil => "unset", true => "true", false => "false" }.fetch(value)
        else value
        end
        @bridge.set_config(spec[1], spec[2], stored)
        setter = "#{spec[3]}="
        Configuration.public_send(setter, value) if Configuration.respond_to?(setter)
        public_value = spec[0] == :tristate ? { nil => "unset", true => "enabled", false => "disabled" }.fetch(value) : value
        changes << result(
          "name" => name.to_s, "previous_value" => previous, "new_value" => public_value,
          "restart_recommended" => RESTART_SETTINGS.include?(name.to_s)
        )
      end
      restart = values.keys.map(&:to_s) & RESTART_SETTINGS
      completed("change_settings", "Changed #{changes.size} setting#{changes.size == 1 ? "" : "s"}.#{restart.empty? ? "" : " Restart Klangten to apply: #{restart.join(", ")}."}",
        "changes" => changes, "changed_count" => changes.size,
        "restart_recommended_for" => restart)
    end

    def coerce_safe_setting(name, value, spec)
      case spec[0]
      when :boolean
        raise InvalidParamsError, "#{name} must be boolean" if value != true && value != false
        value
      when :integer
        raise InvalidParamsError, "#{name} must be an integer" if !value.is_a?(Integer)
        integer = value
        raise InvalidParamsError, "#{name} is outside #{spec[4]}..#{spec[5]}" if integer < spec[4] || integer > spec[5]
        integer
      when :enum
        raise InvalidParamsError, "#{name} must be one of #{spec[4].join(", ")}" if !spec[4].include?(value.to_s)
        value.to_s.to_sym
      when :tristate
        semantic = value.to_s
        raise InvalidParamsError, "#{name} must be one of #{spec[4].join(", ")}" if !spec[4].include?(semantic)
        { "unset" => nil, "enabled" => true, "disabled" => false }.fetch(semantic)
      when :string
        raise InvalidParamsError, "#{name} must be a string of at most 1024 bytes" if !value.is_a?(String) || value.bytesize > 1024
        choices = setting_choice_values(name)
        if %w[language voice].include?(name) && choices.empty?
          raise InvalidParamsError, "No safe #{name} choices are currently available; do not guess an identifier"
        end
        if !choices.empty? && !choices.include?(value)
          raise InvalidParamsError, "#{name} must be one of the values returned by settings_read"
        end
        value
      else
        raise InvalidParamsError, "Unsupported protected setting type"
      end
    end

    def setting_description(name, spec)
      info = SETTING_INFO.fetch(name)
      values = {
        "name" => name, "label" => info[0], "description" => info[1],
        "type" => spec[0].to_s, "current_value" => current_setting(spec),
        "restart_recommended" => RESTART_SETTINGS.include?(name)
      }
      if spec[0] == :integer
        values["range"] = result("minimum" => spec[4], "maximum" => spec[5])
      elsif spec[0] == :enum || spec[0] == :tristate
        values["choices"] = spec[4].map { |choice| result("value" => choice, "label" => choice_label(choice)) }
      elsif spec[0] == :string && %w[language voice].include?(name)
        values["choices"] = setting_choices(name)
      end
      result(values)
    end

    def setting_input_schema(name, spec)
      info = SETTING_INFO.fetch(name)
      schema = { "description" => info[1] }
      case spec[0]
      when :boolean
        schema["type"] = "boolean"
      when :integer
        schema.merge!("type" => "integer", "minimum" => spec[4], "maximum" => spec[5])
      when :enum
        schema.merge!("type" => "string", "enum" => spec[4])
      when :tristate
        schema.merge!("type" => "string", "enum" => spec[4])
      when :string
        schema["type"] = "string"
        choices = setting_choice_values(name)
        schema["enum"] = choices if %w[language voice].include?(name)
      else
        raise ToolError, "Unsupported protected setting type"
      end
      schema
    end

    def current_setting(spec)
      getter = spec[3]
      value = Configuration.respond_to?(getter) ? Configuration.public_send(getter) : @bridge.config(spec[1], spec[2], "")
      case spec[0]
      when :boolean
        raise ToolError, "Unexpected boolean setting contract" if value != true && value != false
        value
      when :integer
        raise ToolError, "Unexpected integer setting contract" if !value.is_a?(Integer)
        value
      when :enum
        text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
        raise ToolError, "Unexpected enum setting contract" if text == nil || !spec[4].include?(text)
        text
      when :tristate
        raise ToolError, "Unexpected tristate setting contract" if value != nil && value != true && value != false
        { nil => "unset", true => "enabled", false => "disabled" }.fetch(value)
      when :string
        raise ToolError, "Unexpected text setting contract" if !value.is_a?(String)
        value
      else
        raise ToolError, "Unsupported protected setting type"
      end
    rescue Exception
      raise ToolError, "Cannot read the current value of a changeable setting"
    end

    def setting_choice_values(name)
      setting_choices(name).map { |choice| choice["value"] }
    end

    def setting_choices(name)
      case name
      when "language"
        current = current_setting(SAFE_SETTINGS.fetch(name)).to_s
        codes = ["en-GB"]
        if @bridge.respond_to?(:loadedlanguages, true)
          codes.concat(Array(@bridge.send(:loadedlanguages)).map { |language| language.respond_to?(:realcode) ? language.realcode.to_s : "" })
        end
        codes << current if current != ""
        codes.reject(&:empty?).uniq.map { |code| result("value" => code, "label" => language_label(code)) }
      when "voice"
        current = current_setting(SAFE_SETTINGS.fetch(name)).to_s
        voices = defined?(SpeechOutput) && SpeechOutput.respond_to?(:voices) ? Array(SpeechOutput.voices) : []
        choices = voices.filter_map do |voice|
          next if !voice.respond_to?(:voiceid)
          id = voice.voiceid.to_s
          next if id == ""
          result("value" => id, "label" => (voice.respond_to?(:name) ? voice.name.to_s : id))
        end
        if current == ""
          choices.unshift(result("value" => "", "label" => "System default voice"))
        elsif !choices.any? { |choice| choice["value"] == current }
          choices << result("value" => current, "label" => "Currently selected voice")
        end
        choices
      else
        []
      end
    rescue Exception
      []
    end

    def language_label(code)
      language = defined?(Lists) && Lists.respond_to?(:langs) ? Lists.langs[code.to_s[0, 2].downcase] : nil
      return code.to_s if !language.is_a?(Hash)
      name = language["name"].to_s
      native = language["nativeName"].to_s
      return code.to_s if name == "" && native == ""
      return "#{name} (#{native})" if name != "" && native != "" && name != native
      name == "" ? native : name
    rescue Exception
      code.to_s
    end

    def choice_label(value)
      value.to_s.split("_").map { |part| part == "rc" ? "RC" : part.capitalize }.join(" ")
    end
  end
end
