# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

class Scene_Documentation
  def initialize(docid)
    @docid=docid
  end
  def main
    label=""
    text=""
    case @docid
    when "license"
      label=p_("Documentation", "Licence agreement")
      text= licensetext
      when "rules", "privacypolicy"
        # Klangten: EltenLink's documents are replaced by a notice about the Klango server's terms.
        label=p_("Klangten", "Terms of the Klango server")
        text=klangten_server_terms_text
          when "readme"
            label=p_("Documentation", "Read me")
            # Klangten: the manual is upstream Elten's; say which parts do not apply.
            # The note names Elten literally, so it is not branded.
            text="**#{Klangten::Config::PRODUCT_NAME}:** "+unbranded { p_("Klangten","This manual comes from Elten and has not been fully adapted to Klangten. Premium packages, sponsors, the calendar, tasks and the built-in updater do not exist in Klangten. Two-factor authentication sends its codes via Telegram or by text message; resetting the password does not disable it. Conferences and calls use the TeamConference rooms of the Klango server: positional sound, whispering, dice, cards, recording and sound card streaming are not available. The Feed shows the home timeline of your Mastodon account.") }+"\n\n"+_doc('readme')
            when "migration24"
              label=p_("Documentation", "Information about migration to Elten version 2.4")
            text=_doc('migration24')
    end
    @form=Form.new([
    edt_text = EditBox.new(label, type: EditBox::Flags::ReadOnly|EditBox::Flags::MultiLine|EditBox::Flags::MarkDown, text: text, quiet: true),
    btn_close = Button.new(p_("Documentation", "Close"))
    ], index: 0, silent: false, quiet: true)
    btn_close.on(:press) {@form.resume}
    @form.cancel_button=@form.accept_button=btn_close
    @form.wait
    $scene=Scene_Main.new
  end
end