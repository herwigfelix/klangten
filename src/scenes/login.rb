# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

class Scene_Login
  AUTO_LOGIN_INVALID_PASSWORD_CODES = %w[session.invalid_credentials auth.invalid_password unauthorized].freeze
  AUTO_LOGIN_PASSWORD_RETRIES = 1

  @@skipauto=false
  def initialize(skipauto=false)
    @skipauto=skipauto
    if @@skipauto==true
      @@skipauto=false
      @skipauto=true
      end
    end
  def main
                    autologin, name, token, tokenenc = read_logindata
                    if !autologin_key_encryption_supported?
                      if tokenenc.to_i > 0
                        Log.warning("Encrypted auto-login key is not supported on this platform, ignoring saved login data")
                        delete_logindata
                        autologin, name, token, tokenenc = 0, "", "", -1
                      elsif autologin.to_i == 3 && tokenenc.to_i < 0
                        tokenenc = 0
                        write_logindata(autologin, name, token, tokenenc)
                      end
                    end
                password=""
                                                    if autologin.to_i <= 0 or @skipauto==true
                                                      name=""
                                                      password=""
                          while name == ""
    name = input_text(p_("Login", "Username:"),flags: 0,text: "",escapable: true)
      end
  if name == nil
    $scene = Scene_Loading.new(true)
    return
    end
  password=""
    while password == ""
    password = input_text(p_("Login", "Password:"),flags: EditBox::Flags::Password,text: "",escapable: true)
  end
if password==nil
  $scene=Scene_Loading.new
  return
end
# Klangten: silent lookup, no error dialog when the user search is unavailable.
name=klangten_canonical_user_name(name)
else
        if autologin == 3
      tokenenc=-1 if autologin_key_encryption_supported? && tokenenc>0 && token.bytesize<=130
    suc=false
    while suc==false and tokenenc>=1
    pin=""
    pin=input_text(p_("Login", "Enter PIN"),flags: EditBox::Flags::Password,text: "",escapable: true) if tokenenc==2
      if pin==nil
       @skipauto=true
       return
        end
      t=decrypt(token,pin) if tokenenc>0
      if t=="" and pin==nil
        @skipauto=true
        return main
      elsif t!=""
        token=t
        break
      end
      end
  if tokenenc==-1 && autologin_key_encryption_supported?
    otoken=token
    if !confirm(p_("Login", "Do you want to enable auto-login key encryption? Once encrypted, the auto-login key can be read only on this computer. Copying or exporting it will not allow another device to access your account. You can create separate auto-login keys for any other computers you use."))
            tokenenc=0
                else
      tokenenc=1
      pin=makepin
      otoken=crypt(token,pin)
      tokenenc=2 if pin!=nil
          end
    write_logindata(autologin, name, otoken, tokenenc)
    end
  elsif tokenenc==-1
    tokenenc=0
    write_logindata(autologin, name, token, tokenenc)
  end
  end
  version_string = login_version_string
  version_islauncher = login_version_islauncher
  version_isdevelopment = login_version_isdevelopment(version_islauncher)
  password="" if autologin.to_i==2 && @skipauto!=true
  suc=false
login_error=nil
# Klangten: the EltenLink launcher stamp is never requested or sent.
stamp=nil
# Klangten: set once the user has accepted the Klango terms (session.tos_required).
accept_tos=false
  while suc==false
  begin
  if token!="" && @skipauto!=true
    logintemp = EltenLink::Authentication.login(elten_link, name: name, token: token, version_string: version_string, version_isdevelopment: version_isdevelopment, version_islauncher: version_islauncher, appid: $appid, language: Configuration.language, os: platform_os, authmethod: "list", stamp: stamp, accept_tos: accept_tos)
else
  logintemp = EltenLink::Authentication.login(elten_link, name: name, password: password, version_string: version_string, version_isdevelopment: version_isdevelopment, version_islauncher: version_islauncher, appid: $appid, language: Configuration.language, os: platform_os, authmethod: "list", stamp: stamp, accept_tos: accept_tos)
end
suc=true
rescue EltenLink::Error => e
if e.code.to_s=="auth.two_factor_required"
  # Klangten: the choice follows details.methods of the error ("sms",
  # "telegram", "backup"); a code is requested with authmethod phone/telegram.
  kinds=klangten_two_factor_methods(e)
  labels=kinds.map { |k| klangten_two_factor_method_label(k) }
  meth=selector(labels+[_("Cancel")], header: p_("Login", "Two-factor authentication is enabled on this account. Select an authentication method."), start_index: 0, cancel_index: kinds.size, flags: 1)
  kind=kinds[meth]
  if kind==nil
    @@skipauto=true
    return $scene=Scene_Login.new
  end
if kind!="backup"
  send_error=nil
  authmethod=(kind=="telegram" ? "telegram" : "phone")
  begin
  if token!="" && @skipauto!=true
    logintemp = EltenLink::Authentication.login(elten_link, name: name, token: token, version_string: version_string, version_isdevelopment: version_isdevelopment, version_islauncher: version_islauncher, appid: $appid, language: Configuration.language, os: platform_os, authmethod: authmethod, stamp: stamp, accept_tos: accept_tos)
else
  logintemp = EltenLink::Authentication.login(elten_link, name: name, password: password, version_string: version_string, version_isdevelopment: version_isdevelopment, version_islauncher: version_islauncher, appid: $appid, language: Configuration.language, os: platform_os, authmethod: authmethod, stamp: stamp, accept_tos: accept_tos)
end
  rescue EltenLink::Error => send_error
  end
  if send_error!=nil && send_error.code.to_s.start_with?("authentication.") && (msg=klangten_two_factor_error_message(send_error))!=nil
    # Klangten: e.g. no Telegram right now; back to the choice, where a backup code is offered.
    alert(msg)
    speech_wait
    suc=false
    next
  elsif send_error!=nil && send_error.code.to_s!="auth.two_factor_required"
    login_error=send_error
    break
  end
  end
  suc=false
tries=0
label=klangten_two_factor_code_label(kind)
restart=false
while tries<3
  code=input_text(label,flags: 0,text: "",escapable: true)
  if code==nil
    delete_logindata
    return $scene=Scene_Loading.new
    break
  end
  code=code.delete("\r\n\t ")
  next if code==""
  begin
    EltenLink::Authentication.authenticate(elten_link, appid: $appid, name: name, code: code)
  rescue EltenLink::Error => code_error
    if code_error.code.to_s=="authentication.code_expired" || code_error.code.to_s=="authentication.too_many_attempts"
      # Klangten: a new code is needed; back to the choice of the method.
      alert(klangten_two_factor_error_message(code_error))
      speech_wait
      restart=true
      break
    elsif code_error.code.to_s!="authentication.invalid_code" && (msg=klangten_two_factor_error_message(code_error))!=nil
      alert(msg)
      speech_wait
      restart=true
      break
    end
    tries+=1
    if tries>=3
      alert(p_("Login", "Verification failed."))
      delete_logindata
    return $scene=Scene_Loading.new
    break
    else
      label=p_("Login", "The code you entered is incorrect. Please try again.")
    end
  else
        break
    end
  end
next if restart
elsif e.code.to_s=="session.tos_required" && !accept_tos
  # Klangten: the Klango server wants the terms accepted first. This also happens
  # with an auto-login key; the user is asked and the same login is repeated.
  if klangten_ask_server_terms(e.detail("url"))
    accept_tos=true
    suc=false
  else
    login_error=e
    break
  end
elsif e.code.to_s=="session.account_not_activated"
  if handle_account_activation(name)
    suc=false
  else
    delete_logindata
    @@skipauto=true
    return $scene=Scene_Login.new
  end
else
  login_error=e
  break
end
  end
end
    if logintemp != nil
  name=logintemp.name
  Session.name=name
      Session.token=logintemp.token
      Session.moderator=logintemp.moderator.to_i
      Session.fullname=logintemp.fullname
      Session.gender=logintemp.gender.to_i
      Session.languages = logintemp.languages
      Session.greeting = logintemp.greeting
  end
if logintemp != nil
if Configuration.autologin==true && autologin.to_i!=3
  dialog_open  
  if autologin.to_i == 0
  @sel = ListBox.new([_("No"),_("Yes"),p_("Login", "Do not ask again")],header: p_("Login", "Do you want to enable auto log in for account %{user}?")%{:user=>name},index: 0,flags: ListBox::Flags::AnyDir, quiet: false)
else
  @sel=ListBox.new([_("No"),_("Yes")],header: p_("Login", "The saved login data uses the old account authentication method in which  susceptibility to hacker attacks has been detected. New, safer automatic login  algorithms have been introduced in Elten 2.2. It is recommended that you convert  the saved information into a new system in order to improve the security of your  account. Do you want to update the saved information now?"),index: 0,flags: ListBox::Flags::AnyDir, quiet: false)
    end
  loop do
loop_update
    @sel.update
    if key_pressed?(:key_enter)
            case @sel.index
      when 0
        when 1
          token=request_auto_login_token(name, password)
          if token!=nil
              tokenenc=0
              if autologin_key_encryption_supported?
                confirm(p_("Login", "Do you want to enable auto-login key encryption? Once encrypted, the auto-login key can be read only on this computer. Copying or exporting it will not allow another device to access your account. You can create separate auto-login keys for any other computers you use.")) {
                pin=makepin
                token=crypt(token,pin)
                tokenenc=1
                tokenenc=2 if pin!=nil
                              }
              end
                            oautologin=autologin
                            autologin=3
                      write_logindata(autologin, name, token, tokenenc)
                                          if oautologin.to_i==1 or oautologin.to_i==2
              alert(p_("Login", "Automatic login will remain enabled until you log out. You can manage automatic login keys on the My Account tab in the Community menu."))
            else
              alert(p_("Login", "Login data has been updated. Automatic login will remain enabled until you log out. You can manage automatic login keys on the My Account tab in the Community menu."))
              end
         speech_wait
          end
       when 2
         writeconfig("Login", "EnableAutoLogin", false)
         load_configuration
         delete_logindata
         alert(p_("Login", "To re-enable auto-login, go to General settings."))
         end
       break
        end
      end
      dialog_close
 end
  EltenAPI::InvisibleInterface.session_changed if defined?(EltenAPI::InvisibleInterface)
if $speech_wait == true
  $speech_wait = false
  speech_wait
end
play_sound("login")
if Session.greeting == "" or Session.greeting == "\r\n" or Session.greeting == nil or Session.greeting == " "
speak(p_("Login", "Logged in as: %{user}")%{:user=>name}) if $silentstart != true
else
  speak(Session.greeting) if $silentstart != true
  end
EltenAPI::NotificationService.synchronize_runtime_state
else
  case login_error&.code.to_s
  when "network_error", "timeout", "cancelled"
    alert(p_("Login", "Connection failure."))
    Session.token = nil
    speech_wait
  when "session.invalid_credentials", "auth.invalid_password", "unauthorized"
    alert(p_("Login", "Invalid login or password.")) if autologin.to_i==0
    Session.token = nil
    speech_wait
    @skipauto=true
    return main
  when "session.tos_required", "session.too_many_attempts", "session.account_banned"
    # Klangten: asking for the password again would not help; back to the start menu.
    if login_error.code.to_s=="session.tos_required"
      alert(p_("Login", "You cannot log in without accepting the terms of use of the Klango server."))
    elsif login_error.code.to_s=="session.too_many_attempts"
      alert(klangten_too_many_attempts_message(login_error))
    else
      alert(klangten_account_banned_message(login_error))
    end
    Session.token = nil
    speech_wait
    $scene = Scene_Loading.new(true)
    return
  when "session.account_not_activated"
    alert(p_("Login", "This account has not been activated yet."))
    Session.token = nil
    speech_wait
    @skipauto=true
    return main
  when "authentication.sms_cooldown", "authentication.sms_daily_limit", "authentication.sms_limiter_unavailable", "authentication.telegram_unavailable", "authentication.telegram_not_linked", "authentication.invalid_code", "authentication.code_expired", "authentication.too_many_attempts"
    # Klangten: the code could not be sent; the texts are shared with the setup screen.
    alert(klangten_two_factor_error_message(login_error))
    Session.token = nil
    speech_wait
    @skipauto=true
    return main
  else
    alert(p_("Login", "Login failure."))
    Session.token = nil
    speech_wait
    @skipauto=true
    return main
  end
end
                $speech_wait = true
        $scene = Scene_Loading.new
        $preinitialized = false
                $scene = Scene_Main.new if Session.logged?
      end
      # Klangten: methods offered by auth.two_factor_required (details.methods),
      # in a fixed order; "phone" is accepted as another name for "sms".
      def klangten_two_factor_methods(error)
        raw=error.detail("methods")
        raw=raw.split(",") if raw.is_a?(String)
        raw=["sms", "telegram", "backup"] if !raw.is_a?(Array) || raw.empty?
        names=raw.map { |m| m.to_s.strip.downcase }.map { |m| m=="phone" ? "sms" : m }
        kinds=%w[telegram sms backup].select { |k| names.include?(k) }
        kinds.push("backup") if !kinds.include?("backup")
        kinds
      end
      def klangten_two_factor_method_label(kind)
        case kind
        when "telegram" then p_("Login", "Get a code via Telegram")
        when "sms" then p_("Login", "Get a code by text message (SMS)")
        else p_("Login", "Enter a backup code")
        end
      end
      def klangten_two_factor_code_label(kind)
        hint=p_("Login", "If you cannot receive a code, use one of your backup codes instead. Resetting the password does not disable two-factor authentication. If you have no backup codes left, contact the administrator at %{contact}.")%{:contact=>EltenAPI::Common::TWO_FACTOR_ADMIN_CONTACT}
        case kind
        when "telegram" then p_("Login", "Enter the code the Klango bot sent you in Telegram to allow this device to log in.")+" "+hint
        when "sms" then p_("Login", "Enter the code sent to you by text message to allow this device to log in.")+" "+hint
        else p_("Login", "Enter backup code")
        end
      end
      def handle_account_activation(name)
        header = p_("Login", "This account has not been activated. Enter the activation code from the e-mail message or request the message again.")
        label = p_("Login", "Activation code:")
        tries = 0
        loop do
          action = selector([p_("Login", "Enter activation code"), p_("Login", "Resend activation e-mail"), _("Cancel")], header: header, start_index: 0, cancel_index: 2, flags: 1)
          return false if action==nil || action==2
          if action==1
            begin
              EltenLink::Accounts.resend_activation(elten_link, name: name)
              alert(p_("Login", "The activation e-mail has been sent again."))
            rescue EltenLink::Error => e
              if e.code.to_s=="accounts.activation_resend_too_soon"
                alert(p_("Login", "The activation e-mail has already been sent. Please wait at least 10 minutes before requesting another one."))
              elsif e.code.to_s=="accounts.activation_not_found"
                alert(p_("Login", "Activation could not be started for this account. It may already be active."))
              else
                alert(e.message)
              end
            end
            next
          end
          while tries<3
            code=input_text(label, flags: 0, text: "", escapable: true)
            return false if code==nil
            code=code.delete("\r\n ")
            begin
              EltenLink::Accounts.activate(elten_link, code: code)
              alert(p_("Login", "Account activated. You can now log in."))
              return true
            rescue EltenLink::Error => e
              if e.code.to_s=="accounts.invalid_activation_code"
                tries+=1
                if tries>=3
                  alert(p_("Login", "Activation failed."))
                  return false
                else
                  label=p_("Login", "The activation code you entered is incorrect. Please try again.")
                end
              else
                alert(e.message)
                return false
              end
            end
          end
        end
      end
      def makepin
        return nil if !autologin_key_encryption_supported?
        pin=""
        while pin==""
          if !confirm(p_("Login", "Do you want to encrypt this key with a custom PIN? You will be prompted for this PIN every time you start Elten to unlock your account. It will not be saved on the server and will apply only to the auto-login key stored on this device."))
            return nil
          else
            p1=input_text(p_("Login", "Enter PIN"),flags: EditBox::Flags::Password,text: "",escapable: true)
            next if p1==nil
            p2=input_text(p_("Login", "Enter PIN again"),flags: EditBox::Flags::Password,text: "",escapable: true)
            next if p2==nil
            if p1==p2
              return p1
            else
              alert(p_("Login", "The PINs you entered do not match. Please try again."))
              end
            end
          end
        end
        def request_auto_login_token(name, password)
          password_verified_by_login = password != nil && password != ""
          retries = 0
          loop do
            if password == nil || password == ""
              password=input_text(p_("Login", "Password:"),flags: EditBox::Flags::Password, text: "", escapable: true)
              return nil if password==nil
              next if password==""
            end
            begin
              return EltenLink::Authentication.auto_login_token(elten_link, name: name, password: password, computer: $computer, appid: $appid)
            rescue EltenLink::Error => e
              Log.warning("Auto-login token creation failed for #{name}: #{e.code}: #{e.message}")
              if klangten_too_many_attempts?(e)
                alert(klangten_too_many_attempts_message(e) + " " + p_("Login", "Automatic login could not be enabled. You are still logged in."))
                return nil
              end
              invalid_password = AUTO_LOGIN_INVALID_PASSWORD_CODES.include?(e.code.to_s)
              if invalid_password && !password_verified_by_login && retries < AUTO_LOGIN_PASSWORD_RETRIES
                retries += 1
                alert(p_("Login", "An error occurred while verifying your identity. You may have entered an incorrect password."))
                password = nil
                next
              end
              if invalid_password
                alert(p_("Login", "Automatic login could not be enabled because the password was not accepted. You are still logged in."))
              else
                alert(p_("Login", "Automatic login could not be enabled due to a connection or server error. You are still logged in."))
              end
              return nil
            end
          end
        end
        def login_version_string
          Elten.version.to_s.upcase
        rescue Exception
          defined?(Elten) ? Elten.version.to_s.upcase : ""
        end
        def login_version_islauncher
          defined?(launched_by_launcher?) ? launched_by_launcher? : false
        rescue Exception
          false
        end
        def login_version_isdevelopment(launched=nil)
          launched = login_version_islauncher if launched==nil
          !launched || (defined?(developer_mode?) && developer_mode?)
        rescue Exception
          true
        end
        Magic="EltenLoginCredentialsPRVDataFile"
        def write_logindata(autologin, name, token, tokenenc)
          str=[Magic,autologin,name.bytesize,name,token.bytesize,token,tokenenc].pack("a*CIa*Ia*c")
          File.binwrite(EltenPath.join(Dirs.eltendata, "login.dat"), str)
        end
        def read_logindata
          return [0,"","",-1] if !FileTest.exists?(EltenPath.join(Dirs.eltendata, "login.dat"))
          str=File.binread(EltenPath.join(Dirs.eltendata, "login.dat"))
          io=StringIO.new(str)
                    return [0,"","",-1] if io.read(Magic.bytesize)!=Magic
                    autologin=io.read(1).unpack("C").first
                    name=io.read(io.read(4).unpack("I").first)
                    token=io.read(io.read(4).unpack("I").first)
                    tokenenc=io.read(1).unpack("c").first
                    return [autologin, name, token, tokenenc]
                  rescue Exception
                    return [0,"","",-1]
                  end
                  def delete_logindata
                    File.delete(EltenPath.join(Dirs.eltendata, "login.dat")) if FileTest.exists?(EltenPath.join(Dirs.eltendata, "login.dat"))
                    rescue Exception
                    end
end
