# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

class Scene_Registration
  USERNAME_PATTERN = /\A[a-zA-Z0-9._-]{3,32}\z/.freeze
  USERNAME_LETTER_PATTERN = /[a-zA-Z]/.freeze
  VERIFY_WORD_CODES = %w[accounts.verify_word_required accounts.verify_word_invalid].freeze

  def main
# Klangten: registration does not depend on the EltenLink launcher stamp.
    name = ""
    password = ""
    mail = ""
    while name == ""
    name = input_text(p_("Registration", "Enter your username. It must contain between 3 and 32 characters, including at least one letter. You may use letters, numbers, dots, hyphens, and underscores."), flags: 0, text: "", escapable: true, permitted_characters: (("a".."z").to_a+("A".."Z").to_a+("0".."9").to_a+[".","-","_"]), max_length: 32)
    if name!="" && name!=nil
      if !registration_username_valid?(name)
        alert(p_("Registration", "This username is forbidden."))
        name=""
        next
      end
      begin
        availability = EltenLink::Accounts.registration_name_availability(elten_link, name: name)
      rescue EltenLink::Error => e
        Log.warning("Registration name availability failed: #{e.message}")
        alert(p_("Registration", "An error occurred while connecting to the server."))
        name=""
        next
      end
      if availability == :forbidden
        alert(p_("Registration", "This username is forbidden."))
        name=""
      elsif availability == :exists
        alert(p_("Registration", "A user with this name already exists."))
        name=""
      elsif availability != :available
        alert(_("Error"))
        name=""
      end
    end
  end
  if name==nil
    $scene=Scene_Main.new
    return
    end
  pswconfirm = ""
  while password == "" or password != pswconfirm
    password = input_text(p_("Registration", "Enter your password. We recommend using a strong password consisting of letters and numbers. The maximum password length is 256 characters."),flags: EditBox::Flags::Password, text: "", escapable: true)
    break if password==nil
    pswconfirm = input_text(p_("Registration", "Re-enter your password"),flags: EditBox::Flags::Password, text: "", escapable: true)
    break if pswconfirm==nil
    if pswconfirm != password
      alert(p_("Registration", "The entered passwords differ"))
      end
    end
    if password==nil || pswconfirm==nil
    $scene=Scene_Main.new
    return
    end
  while mail.include?("@")==false || mail.include?(".")==false
    mail = input_text(p_("Registration", "Enter your email address. It will be used to reset a forgotten password and to send you important information."), flags: 0, text: "", escapable: true)
    break if mail==nil
  end
  if mail==nil
    $scene=Scene_Main.new
    return
    end
# Klangten: the Klango server may demand the verification word of the Klango team.
# It is asked for always but may stay empty; if the server requires it or rejects
# it, only this field is asked again.
verify_word = input_text(p_("Registration", "Enter the verification word. The Klango team gives it out, for example on the Klango website, to keep automated registrations away. If you do not have one, leave the field empty."), flags: 0, text: "", escapable: true)
if verify_word==nil
  $scene=Scene_Main.new
  return
end
# Klangten: accepting the Klango server terms is mandatory for registration.
if !registration_terms_accepted?
  $scene=Scene_Main.new
  return
end
stamp=nil
result=nil
loop do
begin
result = EltenLink::Accounts.register(elten_link, name: name, password: password, mail: mail, stamp: stamp, verify_word: verify_word.strip, accept_tos: true)
break
rescue EltenLink::Error => e
  if VERIFY_WORD_CODES.include?(e.code.to_s)
    verify_word = ask_verify_word(e.code.to_s)
    if verify_word==nil
      $scene=Scene_Main.new
      return
    end
    next
  elsif klangten_too_many_attempts?(e)
    alert(klangten_too_many_attempts_message(e))
  elsif e.code.to_s == "accounts.registration_disabled"
    alert(p_("Registration", "Registration from the program is currently closed on the Klango server. Please register on the Klango website."))
  elsif e.code.to_s == "accounts.name_forbidden"
    alert(p_("Registration", "This username is forbidden."))
  elsif e.code.to_s == "accounts.name_exists"
    alert(p_("Registration", "An account with the specified username already exists."))
  elsif e.code.to_s == "accounts.disposable_email"
    alert(p_("Registration", "Disposable e-mail addresses cannot be used for registration. Please use a permanent e-mail address."))
  elsif e.code.to_s == "network_error"
    alert(p_("Registration", "An error occurred while connecting to the server."))
  else
    alert(e.message)
  end
  speech_wait
  $scene = Scene_Loading.new
  # Klangten: starting over does not help while the server blocks registrations.
  return if klangten_too_many_attempts?(e) || e.code.to_s == "accounts.registration_disabled"
  return main
end
end
Log.info("Registered #{result.name}, terms accepted: #{result.tos_accepted?}")
if result.respond_to?(:activated?) && result.activated?
  alert(p_("Registration", "Registration was successful. Thank you. You can log in using your username and password."))
else
  alert(p_("Registration", "Registration was successful. Thank you. An activation code has been sent to your email address. You will need to enter it when logging in."))
end
  speech_wait
  $scene = Scene_Loading.new
  end

  private

  def registration_username_valid?(name)
    name.to_s.match?(USERNAME_PATTERN) && name.to_s.match?(USERNAME_LETTER_PATTERN)
  end

  # Asks again for the verification word after accounts.verify_word_required or
  # accounts.verify_word_invalid. Returns nil when cancelled.
  def ask_verify_word(code)
    if code == "accounts.verify_word_required"
      label = p_("Registration", "The Klango server requires a verification word for new accounts. Enter the verification word you received from the Klango team or found on the Klango website.")
    else
      label = p_("Registration", "The verification word is not correct. Please check it and enter it again.")
    end
    word = ""
    while word.strip == ""
      word = input_text(label, flags: 0, text: "", escapable: true)
      return nil if word == nil
    end
    word.strip
  end

  # Shows the Klango server terms with a link and a mandatory checkbox.
  # Returns true when the user ticked the checkbox and pressed Register.
  def registration_terms_accepted?
    url = klangten_server_terms_url
    accepted = false
    form = Form.new([
      txt_terms = EditBox.new(p_("Registration", "Klango server terms"), type: EditBox::Flags::MultiLine|EditBox::Flags::ReadOnly, text: p_("Registration", "To register, you must accept the terms of use of the Klango server. You can read them at %{url}.") % { url: url }),
      btn_open = Button.new(p_("Registration", "Open the terms in the browser")),
      chk_accept = CheckBox.new(p_("Registration", "I accept the Klango server terms")),
      btn_register = Button.new(p_("Registration", "Register")),
      btn_cancel = Button.new(_("Cancel"))
    ])
    form.cancel_button = btn_cancel
    btn_cancel.on(:press) { form.resume }
    btn_open.on(:press) do
      platform_open_url(url)
      form.focus
    end
    btn_register.on(:press) do
      if chk_accept.checked
        accepted = true
        form.resume
      else
        alert(p_("Registration", "You must accept the Klango server terms to register."))
      end
    end
    form.wait
    accepted
  end
  end
