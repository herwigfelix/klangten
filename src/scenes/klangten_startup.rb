# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# What happens once after a login, before the main screen takes over: the
# message of the day from the server (EltenLink::StartupInfo) is read out, and
# on a computer with Klango 3 or Klango 4 the import of their data is offered
# once (Scene_KlangoImport). login.rb calls login_completed, Scene_Main runs
# the rest on the scene thread.

module KlangtenStartup
  IMPORT_OFFERED_KEY = "KlangoImportOffered".freeze

  class << self
    def login_completed
      @pending = true
    end

    # True once after each login.
    def consume
      pending = @pending == true
      @pending = false
      pending
    end

    # Returns a scene to switch to (the import), or nil.
    def run
      announce_messages
      offer_import
    rescue StandardError => e
      Log.warning("Startup steps failed: #{e.class}: #{e.message}")
      nil
    end

    private

    def announce_messages
      messages = EltenAPI::Tasks.run(title: p_("Klangten", "Loading the message of the day..."), show_after: 3, timeout: 20) do |_progress, token|
        EltenLink::StartupInfo.messages(EltenLink::Client.new)
      end
      messages.to_a.each do |message|
        if message.type == "textarea"
          input_text(p_("Klangten", "Message of the day"), flags: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, text: message.text)
        else
          alert(message.text)
        end
      end
    rescue EltenAPI::Tasks::Cancelled, EltenAPI::Tasks::TimedOut, EltenLink::Error => e
      Log.info("No message of the day: #{e.class}")
    end

    def offer_import
      return nil if !defined?(Scene_KlangoImport) || !Scene_KlangoImport.available?
      return nil if LocalConfig[IMPORT_OFFERED_KEY, false, type: :bool] == true
      sources = KlangoImport.sources
      return nil if sources.empty?
      findings = KlangoImport.inspect_sources(sources)
      LocalConfig[IMPORT_OFFERED_KEY] = true
      return nil if findings.empty?
      question = p_("Klangten", "Klangten found Klango on this computer. Do you want to take over its local notes and its Mastodon sign-in? Klango itself stays unchanged. You can also do this later under Tools, Import data from Klango.")
      return nil if !confirm(question, default_yes: true)
      Scene_KlangoImport.new
    end
  end
end
