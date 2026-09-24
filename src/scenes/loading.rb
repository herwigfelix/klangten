  # A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

class Scene_Loading
  def initialize(skiplogin=false)
    @skiplogin=skiplogin
  end

  def embedded_resource_text(name)
    EltenAPI::Resources.read(name)
  end

  def load_json_resource(name, default)
    text = embedded_resource_text(name)
    return default if text == nil
    require "json" unless defined?(JSON)
    JSON.parse(text.to_s.force_encoding(Encoding::UTF_8))
  rescue Exception
    Log.warning("Cannot load #{name}: #{$!.class}: #{$!.message}") if defined?(Log)
    default
  end

  @@firstinit=true
  def main
    $mainmenuextra={}
    $usermenuextra={}
            $restart=false
                                Configuration.volume=50
            $preinitialized = false
          Log.info("Native keyboard runtime initialized")
          $scenes = []
    Configuration.volume = 50
    $instance = 0
    $path=current_executable_path
  Log.info("Exec path: #{$path}")
    $wnd = EltenWindow.ensure_window if $wnd==nil || $wnd==0
    start_hidden = $elten_start_hidden == true && tray_supported?
    EltenWindow.show if start_hidden != true
    Log.debug("HWND: #{$wnd.to_s}")
              tray_result=(tray_supported? && defined?(EltenTray)) ? EltenTray.show($wnd) : nil
          if tray_result!=nil
          if tray_result==0
            Log.error("Tray icon creation failed")
          else
            Log.info("Tray icon created")
          end
          end
      $computer=platform_computer_name
      Log.info("Computer: #{$computer}")
            $sprite = Sprite.new
    $sprite.bitmap = Bitmap.new("elten.jpg") if FileTest.exists?("elten.jpg")
        Session.name = nil
    Session.token = nil
    Session.feeds_clear
      Dirs.appsdata = EltenPath.join(Dirs.eltendata, "apps")
      Dirs.apps = EltenPath.join(Dirs.appsdata, "src")
Dirs.extras = EltenPath.join(Dirs.eltendata, "extras")
Dirs.soundthemes = EltenPath.join(Dirs.eltendata, "soundthemes")
Dirs.temp=EltenPath.join(Dirs.tmp, Klangten::Config::TEMP_DIR_NAME)
FileUtils.mkdir_p(Dirs.eltendata)
FileUtils.mkdir_p(Dirs.appsdata)
FileUtils.mkdir_p(Dirs.apps)
FileUtils.mkdir_p(EltenPath.join(Dirs.appsdata, "data"))
FileUtils.mkdir_p(EltenPath.join(Dirs.appsdata, "cache"))
Programs.migrate_legacy_apps_layout
EltenAPI::Alarms.migrate_legacy_file if defined?(EltenAPI::Alarms) && EltenAPI::Alarms.respond_to?(:migrate_legacy_file)
FileUtils.mkdir_p(Dirs.extras)
FileUtils.mkdir_p(Dirs.soundthemes)
FileUtils.mkdir_p(Dirs.temp)
#upd
FileUtils.rm_rf(EltenPath.join(Dirs.eltendata, "apps", "inis")) if FileTest.exists?(EltenPath.join(Dirs.eltendata, "apps", "inis"))
FileUtils.rm_rf(EltenPath.join(Dirs.eltendata, "bin")) if FileTest.exists?(EltenPath.join(Dirs.eltendata, "bin"))
if FileTest.exists?(EltenPath.join(Dirs.eltendata, "config"))
v={
'Advanced'=>[['KeyUpdateTime'], ['RefreshTime'], ['SyncTime'], ['AgentRefreshTime'], ['AgentSessionTime']],
'Interface' => [['ListType'], ['SoundThemeActivation'], ['TypingEcho'], ['HideWindow'], ['MainVolume'], ['SayTimePeriod','Clock'], ['SayTimeType','Clock'], ['LineWrapping'], ['SoundCard', 'SoundCard'], ['Microphone', 'SoundCard']],
'Language' => [['Language','Interface']],
'Login' => [['AutoLogin'], ['Name'], ['Token'], ['TokenEncrypted']],
'Sapi' => [['Voice','Voice'], ['Rate','Voice'], ['Volume','Voice']],
'SoundTheme' => [['Path','Interface','SoundTheme']]
}
begin
for k in v.keys
  for o in v[k]
    o[1]=k if o[1]==nil
    o[2]=o[0] if o[2]==nil
        val=readini(EltenPath.join(Dirs.eltendata, "config", (k+"")+".ini"), k+"", o[0], "")
    writeconfig(o[1]+"", o[2]+"", val) if val!=""
    end
  end
rescue Exception
  Log.error("UPD: #{$!.to_s} #{$@.to_s}")
end

FileUtils.cp(EltenPath.join(Dirs.eltendata, "config", "appid.dat"), EltenPath.join(Dirs.eltendata, "appid.dat")) if !FileTest.exists?(EltenPath.join(Dirs.eltendata, "appid.dat"))
FileUtils.rm_rf(EltenPath.join(Dirs.eltendata, "config"))
end
begin
FileUtils.rm_rf(EltenPath.join(Dirs.eltendata, "lng"))
if FileTest.exists?(EltenPath.join(Dirs.soundthemes, "inis"))
d=Dir.entries(EltenPath.join(Dirs.soundthemes, "inis"))
for f in d
  next if !f.include?(".ini")
  name=readini(EltenPath.join(Dirs.soundthemes, "inis", f), "SoundTheme", "Name", "")
  path=readini(EltenPath.join(Dirs.soundthemes, "inis", f), "SoundTheme", "Path", "")
  File.binwrite(EltenPath.join(Dirs.soundthemes, path, "__name.txt"), name)
end
end
rescue Exception
end
begin
EltenSystemHelpers.obsolete_extra_entries.each do |entry|
  path = EltenPath.join(Dirs.extras, entry)
  FileUtils.rm_rf(path) if FileTest.exists?(path)
end
rescue Exception
end
if !FileTest.exists?(EltenPath.join(Dirs.eltendata, "login.dat"))
    autologin = readconfig("Login","AutoLogin",-2)
        if autologin.to_i!=-2
          name = readconfig("Login","Name","")
    token = readconfig("Login","Token","")
        tokenenc = readconfig("Login","TokenEncrypted",-2)
        if tokenenc.to_i > 0 && !autologin_key_encryption_supported?
          Log.warning("Skipping encrypted legacy auto-login data because key encryption is not supported on this platform")
        else
          token=Base64.strict_decode64(token) if tokenenc>0
      Scene_Login.new.write_logindata(autologin, name, token, tokenenc)
        end
            writeconfig("Login", "Name", nil)
      writeconfig("Login", "Token", nil)
      writeconfig("Login", "TokenEncrypted", nil)
    end
    writeconfig("Login", "AutoLogin", nil)
    end
#endupd
if FileTest.exists?(EltenPath.join(Dirs.eltendata, "appid.dat"))
$appid=File.binread(EltenPath.join(Dirs.eltendata, "appid.dat"))
else
  Log.info("Generating new AppID")
  $appid = ""
  chars = ("A".."Z").to_a+("a".."z").to_a+("0".."9").to_a
  64.times do
    $appid << chars[rand(chars.length-1)]
  end
    File.binwrite(EltenPath.join(Dirs.eltendata, "appid.dat"),$appid)
  end
  use_soundtheme("data/audio.elsnd", true)
  Log.info("Loading locales")
  loadlocaledata
  load_configuration
    Log.info("Initializing Bass")
Bass.init($wnd)
                          if Configuration.usefx==:auto
                                Log.debug("Testing for Bass FX")
                            Configuration.usefx=Bass.test
                            writeconfig("Advanced", "UseFX", Configuration.usefx)
                            end
if defined?(NVDA)
  Log.info("Initializing NVDA Support")
  NVDA.init
  loop_update while !NVDA.waiting?
end
EltenAPI::InvisibleInterface.reset_for_loading if defined?(EltenAPI::InvisibleInterface) && EltenAPI::InvisibleInterface.respond_to?(:reset_for_loading)
Log.info("Connecting to #{Klangten::Config::SERVER_NAME} server at #{Klangten::Config.api_base_url}")
if !EltenLink::System.connected?(elten_link)
  Log.warning("Failed to connect")
  $neterror=true
else
    Log.info("Connection established")
      $neterror=false
            end
      Bass::BASS_SetConfigPtr.call(0x10403,EltenPath.join(Dirs.extras, "soundfont.sf2")) if FileTest.exists?(EltenPath.join(Dirs.extras, "soundfont.sf2"))
                                    startmessage = Elten.version.to_s
                                    # The iOS build announces itself as "Klangten on touch" followed by the
                                    # bare version. The product name is stripped first, otherwise the start
                                    # message says it twice ("Klangten on touch. Klangten 0.1.0").
                                    startmessage = "#{Klangten::Config::PRODUCT_NAME} on touch. " + startmessage.sub(/\A#{Regexp.escape(Klangten::Config::PRODUCT_NAME)}\s*/i, "") if defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) && EltenBoot.platform?(:ios)
$start = Time.now.to_i
$thr1=Thread.new{thr1} if $thr1==nil
$thr2=Thread.new{thr2} if $thr2==nil
                    Lists.langs=load_json_resource("langs.json", {})
                    Lists.locations=load_json_resource("locations.json", [])
if Configuration.language==""
                                          # Fall back to English only when the system locale matches nothing.
                                          system_locale=EltenSystemHelpers.current_locale_name
                                          Configuration.language=resolve_locale_code(system_locale)
                                          Log.info("First run language: system locale #{system_locale.to_s.empty? ? "unknown" : system_locale} -> #{Configuration.language.to_s.empty? ? "default (English)" : Configuration.language}") if defined?(Log)
                                                                                  writeconfig("Interface", "Language", Configuration.language) if Configuration.language.to_s!=""
                                                                                end
                                                                                setlocale(Configuration.language)
                                                                                 nvda_running = defined?(NVDA) && NVDA.controller_running?
                                                                                           if (Configuration.voice == "?" or Configuration.voice == "") && nvda_running
           Configuration.voice="NVDA"
                     end
                                                                                 SpeechOutput.apply_current_settings if defined?(SpeechOutput)
                                  if $silentstart==nil
  $silentstart=true if $commandline.include?("/silentstart")
end
oldfiles=EltenSystemHelpers.legacy_installation_files
btn=0
if oldfiles.size > 0
loop {
suc=true
dr=Dir.entries("bin")
for d in dr
  suc=false if oldfiles.include?(d.downcase)
end
break if suc
btn=0
begin
  caption, text = EltenSystemHelpers.legacy_installation_warning
  btn=EltenWindow.message_box(text, caption, 2|0x10, $wnd)
  rescue Exception
  end
  if btn==3
    $immediateexit=true
    $exit=true
    exit
  elsif btn==5
        break
  end
  }
end
  if @@firstinit==true
      @@firstinit=false
  else
      delay(1)
      end
v=44
if nvda_running && defined?(NVDA) && (!NVDA.check || NVDA.getversion!=v)
  if !NVDA.check
  str=p_("Loading", "Elten has detected that you are using NVDA. To support some features of this screen reader, the Elten add-on for NVDA must be installed. Do you want to install it now?")
elsif NVDA.getversion!=v
  str=p_("Loading", "A new version of the Elten add-on for NVDA is available. The version you are using is no longer supported by this Elten release and may cause errors. Do you want to update it now?")
    end
  addon_path=EltenPath.join(File.dirname($path), "data", Klangten::Config::NVDA_ADDON_FILE)
  if FileTest.exists?(addon_path)
    suc=false
confirm(str) {
suc=true
  NVDA.install_addon(addon_path)
     NVDA.destroy
   t=Time.now.to_f
 waiting {
 loop_update while Time.now.to_f-t<30 and NVDA.controller_running?
 delay(1)
 loop_update while Time.now.to_f-t<30 and !NVDA.controller_running?
  loop_update while Time.now.to_f-t<30 and FileTest.exists?(EltenPath.join(Dirs.temp, "nvda.pipe"))
  NVDA.init
  delay(1)
  }
 }
  else
    alert(p_("Loading", "The Elten add-on for NVDA is not available in this build. Install or update it manually to enable full NVDA integration."))
  end
end
Log.info("NVDA Version: "+NVDA.getnvdaversion.to_s) if defined?(NVDA) && NVDA.check
# Klangten: no EltenLink server key verification. The API is plain JSON over
# TLS, and the server certificate is verified by EltenAPI::TLS on every connection.
alert(startmessage) if $silentstart != true
            $speech_wait = true if $silentstart != true
            # Klangten: Android has no launcher; it updates itself from the GitHub releases.
            android_update_check if platform_os == "android" && Configuration.checkupdates == true && $denyupdate != true
            if Klangten::Config.updates_enabled? && Configuration.checkupdates==true && launched_by_launcher?
            # Klangten: the rolling channel reads the public GitHub releases of the
            # fork, every other channel asks the Klango server.
            if updates_rolling?
              release=github_latest_release
              bid=github_release_build_id(release)
              update_available=(bid!=nil)
              $update_version_string=release.version_string if release!=nil && release.version_string.to_s!=""
            else
            build_info=EltenLink::System.build_info(elten_link, branch: get_updatesbranch, os: platform_os, arch: Klangten::Updates.arch, current_build_id: Elten.build_id)
            bid=build_info.build_id
            update_available=build_info.present?
            $update_version_string=build_info.version_string if build_info.version_string.to_s!=""
            end
                    if Elten.build_id.to_s!="" and Elten.build_id.to_s!=bid.to_s and update_available and $denyupdate != true
                      Log.info("New update available (BuildID: #{bid.to_s}, Version: #{$update_version_string.to_s})")
if $portable != 1
              $scene = Scene_Update_Confirmation.new
      return
    else
      alert(p_("Loading", "A new version of the program is available."))
      end
            end
    end
            if $neterror == true
      if EltenLink::System.connected?(elten_link)
        $neterror = false
      else
        alert(_("Error"))
        $offline=true
        delay(3)
        speech_wait
                      end
                    end
      if !FileTest.exists?(EltenPath.join(Dirs.eltendata, "license_agreed.dat"))
                $exit = true
license
                $exit = nil
                # Klangten: a fresh data directory has nothing to migrate from Elten 2.3, so the
                # agreement is stored in its final form and the 2.4 migration notice is skipped.
                File.binwrite(EltenPath.join(Dirs.eltendata, "license_agreed.dat"),"\002")
              elsif File.open(EltenPath.join(Dirs.eltendata, "license_agreed.dat"), "rb") { |io| io.read(1) }=="\001"
                $exit = true
license
                $exit = nil
                insert_scene(Scene_Documentation.new("migration24"))
                File.binwrite(EltenPath.join(Dirs.eltendata, "license_agreed.dat"),"\002")
              end
              File.delete(EltenPath.join(Dirs.eltendata, "update.last")) if FileTest.exists?(EltenPath.join(Dirs.eltendata, "update.last"))
      Programs.load_all
      QuickActions.load_actions
  if FileTest.exists?(EltenPath.join(Dirs.eltendata, "login.dat")) and $offline!=true and @skiplogin==false
          Log.info("Processing with autologin")
            $scene = Scene_Login.new
      return
    end
        # Klangten: "Reinstall" downloads an installer and is offered only when the updater is enabled.
        @actions = [:login, :register, :password_reset, :guest, :settings]
        @actions << :reinstall if Klangten::Config.updates_enabled?
        @actions << :exit
        labels = {
          :login => p_("Loading", "Log in"),
          :register => p_("Loading", "Register"),
          :password_reset => p_("Loading", "Password reset"),
          :guest => p_("Loading", "Use guest account"),
          :settings => p_("Loading", "Settings"),
          :reinstall => p_("Loading", "Reinstall"),
          :exit => _("Exit")
        }
        @cw = ListBox.new(@actions.map { |action| labels[action] }, header: "", index: 0, flags: 0, quiet: false)
        loop do
loop_update
      @cw.update
      update
      if $scene != self
        break
      end
      end
    end
    def update
      if key_pressed?(:key_enter)
        case @actions[@cw.index]
        when :login
          $scene = Scene_Login.new
          when :register
            $scene = Scene_Registration.new
            when :password_reset
              $scene=Scene_ForgotPassword.new
              when :guest
                Session.name=nil
                Session.token=nil
                Session.moderator=0
                $preinitialized=true
                $scene=Scene_Main.new
                when :settings
              $scene = Scene_Settings.new
                when :reinstall
                  $scene = Scene_Update.new
              when :exit
                $scene = nil
        end
        end
      end
    end
