# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: codes via Telegram or text message, method change, backup codes after enabling.

class Scene_Authentication
  CODE_TRIES = 3

  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      $scene=Scene_Main.new
      return
    end
    begin
      status=EltenLink::Authentication.status(elten_link)
    rescue EltenLink::Error => e
      Log.warning("Authentication state failed: #{e.message}")
      speak(_("Error"))
      speech_wait
      return $scene=Scene_Main.new
    end
    if !status.enabled?
      action=selector([_("Enable"),_("Exit")],header: p_("Authentication", "Two-factor authentication protects your account even if your password becomes known. When it is enabled, every login from a new device has to be confirmed with a code. The code is sent to you via Telegram or by text message, whichever you choose now. In addition you receive backup codes for the case that you cannot receive a code."),start_index: 0,cancel_index: 1,flags: 1)
      if action==0
        password=ask_password
        return main if password==nil
        enable(password)
        return main
      end
    else
      action=selector([_("Disable"),p_("Authentication", "Generate backup codes"),p_("Authentication", "Change method"),_("Exit")],header: enabled_header(status),start_index: 0,cancel_index: 3,flags: 1)
      case action
      when 0
        disable
        return main
      when 1
        generate_backup_codes
        return main
      when 2
        change_method
        return main
      end
    end
    $scene=Scene_Main.new
  end

  private

  def enabled_header(status)
    text=p_("Authentication", "Two-factor authentication is enabled on this account.")
    if status.telegram?
      text+=" "+p_("Authentication", "Codes are sent to you via Telegram.")
    elsif status.phone!=""
      text+=" "+p_("Authentication", "Codes are sent by text message to %{phone}.")%{:phone=>status.phone.gsub(/\u2022+/, "...")}
    else
      text+=" "+p_("Authentication", "Codes are sent to you by text message.")
    end
    if status.backup_left!=nil
      text+=" "+p_("Authentication", "Unused backup codes: %{count}.")%{:count=>status.backup_left}
    end
    text
  end

  def ask_password
    password=""
    password=input_text(p_("Authentication", "Type your password"),flags: EditBox::Flags::Password,text: "",escapable: true) while password==""
    password
  end

  def error_alert(error)
    alert(klangten_two_factor_error_message(error) || _("Error"))
    speech_wait
  end

  # Asks for the delivery method and sets two-factor authentication up.
  # Returns true when it is enabled afterwards.
  def enable(password)
    method=selector([p_("Authentication", "Codes via Telegram"),p_("Authentication", "Codes by text message (SMS)"),_("Cancel")],header: p_("Authentication", "How do you want to receive your codes? Telegram needs the Telegram app on your phone or computer; you connect it once with the Klango bot. A text message needs a mobile phone number."),start_index: 0,cancel_index: 2,flags: 1)
    case method
    when 0 then enable_telegram(password)
    when 1 then enable_sms(password)
    else false
    end
  end

  def enable_sms(password)
    phone=""
    while phone!=nil and (phone=="" or (phone[0..0]!="+" and phone[0..1]!="00") or phone.size<11 or (/[a-zA-Z,.\/;'\"\[\]!@\#\$%\^\&\*\(\)\_]/=~phone)!=nil)
      phone=input_text(p_("Authentication", "Type your phone number that will be used during verification. Remember to enter  the country code, for example, +48 for Poland"),flags: 0,text: "",escapable: true)
    end
    return false if phone==nil
    return false if input_text(p_("Authentication", "Is this phone number correct? Press enter to continue or escape to cancel."),flags: EditBox::Flags::ReadOnly,text: phone, escapable: true)==nil
    alert(p_("Authentication", "Please wait, connecting to the server ..."))
    begin
      EltenLink::Authentication.enable(elten_link, password: password, method: "sms", phone: phone, language: Configuration.language)
    rescue EltenLink::Error => e
      Log.warning("Authentication enable (sms) failed: #{e.code}: #{e.message}")
      speech_wait
      error_alert(e)
      return false
    end
    speech_wait
    verify_code(p_("Authentication", "A text message containing the code to activate two-factor authentication will be sent to the phone number you provided. Enter the code."))==:ok
  end

  def enable_telegram(password)
    alert(p_("Authentication", "Please wait, connecting to the server ..."))
    begin
      data=EltenLink::Authentication.enable(elten_link, password: password, method: "telegram", language: Configuration.language)
    rescue EltenLink::Error => e
      Log.warning("Authentication enable (telegram) failed: #{e.code}: #{e.message}")
      speech_wait
      error_alert(e)
      return false
    end
    speech_wait
    link=data["link"].to_s
    start=data["start"].to_s
    bot=EltenAPI::Common::TWO_FACTOR_TELEGRAM_BOT
    header=p_("Authentication", "Now connect Telegram with your account. Either open the link, which opens a chat with the Klango bot %{bot} in Telegram, and press Start there. Or send the bot this message yourself: %{start}. The link and the message are valid for 15 minutes. The bot then replies with a six-digit code, which you enter here.")%{:bot=>bot, :start=>start}
    options=[]
    actions=[]
    if link!=""
      options.push(p_("Authentication", "Open the link in Telegram"))
      actions.push(:open)
    end
    if start!=""
      options.push(p_("Authentication", "Read the start message"))
      actions.push(:read)
      options.push(p_("Authentication", "Copy the start message"))
      actions.push(:copy)
    end
    options.push(p_("Authentication", "Enter the code"))
    actions.push(:code)
    options.push(_("Cancel"))
    actions.push(:cancel)
    index=0
    loop do
      index=selector(options,header: header,start_index: index,cancel_index: actions.size-1,flags: 1)
      case actions[index]
      when :open
        platform_open_url(link)
      when :read
        input_text(p_("Authentication", "Send this message to %{bot} in Telegram")%{:bot=>bot},flags: EditBox::Flags::ReadOnly,text: start,escapable: true)
      when :copy
        begin
          Clipboard.text=start
          alert(p_("Authentication", "The start message has been copied to the clipboard."))
        rescue Exception => e
          Log.warning("Copying the Telegram start message failed: #{e.message}")
          alert(_("Error"))
        end
      when :code
        result=verify_code(p_("Authentication", "Enter the six-digit code the Klango bot sent you in Telegram."))
        return true if result==:ok
        return false if result==:failed
      else
        return false
      end
    end
  end

  # Asks for the activation code and activates. Returns :ok, :failed (give up)
  # or :not_linked (Telegram: the bot has not seen /start yet, try again later).
  def verify_code(label)
    tries=0
    while tries<CODE_TRIES
      code=input_text(label,flags: 0,text: "",escapable: true)
      return :failed if code==nil
      code=code.delete("\r\n\t ")
      next if code==""
      begin
        codes=EltenLink::Authentication.verify(elten_link, code: code, appid: $appid)
      rescue EltenLink::Error => e
        Log.warning("Authentication verification failed: #{e.code}: #{e.message}")
        case e.code.to_s
        when "authentication.telegram_not_linked"
          error_alert(e)
          return :not_linked
        when "authentication.invalid_code"
          tries+=1
          if tries<CODE_TRIES
            label=p_("Authentication", "The entered code is not correct. Try again.")
          else
            alert(p_("Authentication", "The entered code is not correct."))
            speech_wait
          end
        else
          error_alert(e)
          return :failed
        end
      else
        alert(p_("Authentication", "Two-factor authentication has been activated on this account."))
        speech_wait
        show_backup_codes(codes)
        return :ok
      end
    end
    :failed
  end

  def show_backup_codes(codes)
    return if codes==nil || codes.empty?
    display_text(codes.join("\r\n\r\n"), header: p_("Authentication", "Your backup codes. Each code can be used once to log in when you cannot receive a code. Write them down or copy them to a safe place now. Press Escape when you are done."))
  end

  def disable
    password=ask_password
    return if password==nil
    return if !confirm(p_("Authentication", "Are you sure you want to disable two-factor authentication?"))
    begin
      EltenLink::Authentication.disable(elten_link, password: password)
    rescue EltenLink::Error => e
      Log.warning("Authentication disable failed: #{e.code}: #{e.message}")
      error_alert(e)
      return
    end
    alert(p_("Authentication", "Two-factor authentication has been disabled."))
    speech_wait
  end

  def generate_backup_codes
    return if !confirm(p_("Authentication", "Do you want to generate backup codes? These can be used to sign in when you have no access to your phone. All previously generated codes will be deleted."))
    password=ask_password
    return if password==nil
    begin
      codes=EltenLink::Authentication.backup_codes(elten_link, password: password)
    rescue EltenLink::Error => e
      Log.warning("Authentication backup codes failed: #{e.code}: #{e.message}")
      error_alert(e)
    else
      input_text(p_("Authentication", "Generated backup codes"), flags: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly, text: codes.join("\r\n\r\n"), escapable: true)
    end
  end

  # Switching between Telegram and text message: the server only enables an
  # account without two-factor authentication, so it is disabled first.
  def change_method
    return if !confirm(p_("Authentication", "To change the method, two-factor authentication is disabled and then set up again with the new method. Until the new setup is finished, your account is protected by the password only. Continue?"))
    password=ask_password
    return if password==nil
    begin
      EltenLink::Authentication.disable(elten_link, password: password)
    rescue EltenLink::Error => e
      Log.warning("Authentication disable for method change failed: #{e.code}: #{e.message}")
      error_alert(e)
      return
    end
    return if enable(password)
    alert(p_("Authentication", "Two-factor authentication is now disabled on this account. You can set it up again at any time."))
    speech_wait
  end
end
