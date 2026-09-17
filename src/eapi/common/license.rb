# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

module EltenAPI
  module Common
    private
# Shows user agreement
#
# @param omit [Boolean] determines whether to allow user to close the window without accepting
    def license(omit=false)
    # Klangten: fork notice, licence and the Klango server terms notice replace
    # EltenLink's terms and conditions and privacy policy. The form keeps five
    # fields, so the index handling below is unchanged.
    @notice = klangten_fork_notice
    @license = licensetext
    @serverterms = klangten_server_terms_text
form = Form.new([
EditBox.new(p_("Klangten", "About Klangten"),type: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly|EditBox::Flags::MarkDown,text: @notice,quiet: true),
EditBox.new(p_("EAPI_Common", "Licence agreement"),type: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly|EditBox::Flags::MarkDown,text: @license,quiet: true),
EditBox.new(p_("Klangten", "Terms of the Klango server"),type: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly|EditBox::Flags::MarkDown,text: @serverterms,quiet: true),
Button.new(p_("Klangten", "I accept the licence agreement and the terms of the Klango server")),Button.new(p_("EAPI_Common", "Decline and exit"))])
loop do
  loop_update
  form.update
  if (key_pressed?(:key_enter) or key_pressed?(:key_space)) and form.index == 4
    exit
  end
  if (key_pressed?(:key_space) or key_pressed?(:key_enter)) and form.index == 3
    break
  end
  if key_pressed?(:key_escape)
    if omit == true
      break
    else
      if form.index==0 or form.index==1
        form.index+=1
        form.focus
        else
    q = confirm(p_("Klangten", "Do you accept the licence agreement and the terms of the Klango server?"))
    if q == 0
      exit
    else
      break
      end
    end
    end
    end
  end
end
  end
end
