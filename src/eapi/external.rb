# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: translation through the Klango server instead of Google.

module EltenAPI
  module External
    private
# Functions using external APIs
   
   # Translates a string to another language.
    #
    # Klangten: the translation runs on the Klango server (POST /api/v1/translate,
    # see EltenLink::Translation) instead of an unofficial Google address. It
    # needs a signed-in session; a failure is announced and returns nil.
    #
    # @param from [String] source language code (if 0, the language autodetection is used)
    # @param to [String] destination language code
    # @param text [String] a text to translate
    # @param api [Int] deprecated, ignored
    # @return [String, nil] the translation result, nil on failure
def translatetext(from,to,text,_api=0)
  return "" if text==nil || text.to_s.strip==""
  if !Session.logged?
    alert(p_("Klangten", "Sign in to translate texts."))
    return nil
  end
  result = EltenAPI::Tasks.run(title: p_("Klangten", "Translating...")) do |_progress, token|
    EltenLink::Translation.translate(EltenLink::Client.new, text.to_s, to: to, from: from, cancellation_token: token)
  end
  result.text
rescue EltenAPI::Tasks::Cancelled
  nil
rescue EltenLink::Error => e
  Log.warning("Translation failed: #{e.code}: #{e.message}")
  alert(klangten_translation_error(e))
  nil
end

# Klangten: a spoken reason for a failed translation.
def klangten_translation_error(error)
  case error.code.to_s
  when "translate.unavailable" then p_("Klangten", "Translation is not available on this server.")
  when "translate.rate_limited" then p_("Klangten", "You have translated a lot in the last hour. Please try again later.")
  when "translate.too_long" then p_("Klangten", "This text is too long to translate.")
  when "translate.invalid_language" then p_("Klangten", "This language cannot be translated.")
  when "translate.failed" then p_("Klangten", "The translation service is not responding. Please try again later.")
  when "unauthorized" then p_("Klangten", "Sign in to translate texts.")
  when "network_error", "timeout" then p_("Klangten", "The translation failed because the server could not be reached.")
  else p_("Klangten", "The text could not be translated.")
  end
end

# Opens a translator dialog
#
# @param text [String] a text to translate
     def translator(text)
  langs={}
  for lk in Lists.langs.keys
    lname=Lists.langs[lk]['nativeName']+" ("+Lists.langs[lk]['name']+")"
    langs[lk]=lname
    end
       dialog_open
  from=ListBox.new([p_("EAPI_External", "recognize automatically")]+langs.values,header: p_("EAPI_External", "source language"))
 ind=0
 for i in 0..langs.keys.size-1
   ind=i if Configuration.language[0..1].downcase==langs.keys[i].downcase
   end
 to=ListBox.new(langs.values,header: p_("EAPI_External", "destination language"),index: ind)
 submit=Button.new(p_("EAPI_External", "Translate"))
 cancel=Button.new(_("Cancel"))
 form=Form.new([from,to,submit,cancel])
 form.accept_button=submit
 form.cancel_button=cancel
 result=nil
 submit.on(:press) { result=:ok; form.resume }
 cancel.on(:press) { result=:cancel; form.resume }
 form.wait
 if result!=:ok
   dialog_close
   loop_update
   return -1
 end
  lfrom=0
  if from.index==0
      lfrom=0
    else
        lfrom=langs.keys[from.index-1]
      end
      lto=langs.keys[to.index]
      ef = translatetext(lfrom,lto,text)
      lfrom = "AUTO" if lfrom==0
      input_text("#{lfrom} - #{lto}",flags: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly,text: ef) if ef != nil
      loop_update
    dialog_close
  end
end
include External
end
