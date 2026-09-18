# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. 
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. 
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>. 
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten.

module GlobalMenu
  def self.developer_mode?
    $developer_mode == true
  end

  class <<self
    @@activecontrols=[]
  def show(defaults=true, force_context: false)
        return if opened?
        return if construct(defaults, force_context: force_context)==false
        loop_update(false)
        return if @menu.size==0
        @currentmenu = @menu
                @menu.open
        @currentmenu = nil
        loop_update(false)
          end
  def construct(defaults=true, force_context: false)
    @header=""
    @header = p_("MainMenu", "Menu") if defaults
    style=:menu
    style=:menubar if defaults
    @menu = Menu.new("",style)
    if $activecontrols!=nil
      active_controls = $activecontrols || []
      for c in active_controls
      if !c.menu_enabled?
        return
        end
      end
      if defaults != :defaults && (Configuration.contextmenubar==true || defaults==false || force_context)
        if defaults
          context_controls = active_controls.select { |control| control.hascontext }
          if context_controls.size > 0
            @menu.submenu(_("Context menu")) do |context_menu|
              context_controls.each { |control| control.context(context_menu, false) }
            end
          end
        else
          active_controls.each { |control| control.context(@menu, false) }
        end
      end
  end
  if defaults==true && !$scene.is_a?(Scene_Main) && (Session.logged? || $preinitialized==true)
    @menu.submenu(p_("MainMenu", "Quick &actions")) {|m|
    QuickActions.get.each {|a|m.quickaction(a.label, a) if a.show}
    }
  end
    if defaults or defaults==:defaults
            @menu.header=@header if $activecontrols==nil || $activecontrols.size==0
            if Session.logged? || $preinitialized==true
      @menu.submenu(p_("MainMenu", "&Community")) {|m|
      if Session.logged?
    m.scene(p_("MainMenu", "&Messages"), Scene_Messages)
    end
    m.scene(p_("MainMenu", "&Blogs"), Scene_Blog)
    m.scene(p_("MainMenu", "&Forum"), Scene_Forum)
        m.scene(p_("MainMenu", "&Conferences"), Scene_Conference)
            if Session.logged?
            m.scene(p_("MainMenu", "Notification hi&story"), Scene_Notifications)
        m.scene(p_("MainMenu", "No&tes"), Scene_Notes)
    m.scene(p_("MainMenu", "Po&lls"), Scene_Polls)
    # Klangten: timelines of the connected Mastodon account (the Feed tab shows the home timeline).
    m.scene(p_("Mastodon", "Mastodon t&imelines"), Scene_MastodonTimeline) if Session.logged?
    end
    @menu.submenu(p_("MainMenu", "&Users")) {|m|
    if Session.logged?
    m.scene(p_("MainMenu", "My &contacts"), Scene_Contacts)
    m.scene(p_("MainMenu", "Users who a&dded me to their contact list"), Scene_Users_AddedMeToContacts)
    end
    m.scene(p_("MainMenu", "Who is &online?"), Scene_Online)
    m.scene(p_("MainMenu", "&badges"), Scene_Honors)
    m.scene(p_("MainMenu", "&Users list"), Scene_Users)
    m.scene(p_("MainMenu", "Ad&mins and authors"), Scene_Admins)
    m.scene(p_("MainMenu", "User searc&h"), Scene_UserSearch)
    m.scene(p_("MainMenu", "Recently &active users"), Scene_Users_RecentlyActived)
    m.scene(p_("MainMenu", "Recently &registered users"), Scene_Users_RecentlyRegistered)
    }
    if Session.logged?
            @menu.scene(p_("MainMenu", "Call &history"), Scene_CallHistory)
            @menu.scene(p_("MainMenu", "Manage my &account"), Scene_Account)
      end
    }
    end
    # Klangten: Media and Files (as in old Elten) with the Klango media catalog and
    # the built-in former Elten programs (src/eapi/program_builtins.rb). They sit on
    # the top level right after Community: Community, Media, Files, Programs, Tools.
    klangten_group(p_("Klangten", "&Media"), [
      [p_("Klangten", "Media &catalog"), Scene_MediaCatalog],
      klangten_builtin_item(:youtube, p_("Klangten", "&YouTube"))
    ])
    klangten_group(p_("Klangten", "&Files"), [
      klangten_builtin_item(:filemanager, p_("Klangten", "File &manager")),
      klangten_builtin_item(:ffmpeg, p_("Klangten", "FFmpeg &encoders"))
    ])
    # The program system is omitted on iOS (App Store policy forbids downloading
    # and running third-party code), so its menu is hidden there entirely.
    unless defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) && EltenBoot.platform?(:ios)
    @menu.submenu(p_("MainMenu", "&Programs")) {|m|
    list=Programs.list.reject{|program|program.hidden?}.sort_by {|program| EltenSystemHelpers.locale_sort_key((program.menu_label||program.name||program.to_s).to_s.delete("&"))}
    for prg in list
      m.scene(prg.menu_label||prg.name||prg.to_s, prg)
      end
    m.scene(p_("MainMenu", "Programs management"), Scene_Programs)
    }
    end
    @menu.submenu(p_("MainMenu", "&Tools")) {|m|
    m.scene(p_("MainMenu", "Program &settings"), Scene_Settings)
    m.scene(p_("MainMenu", "Sound &themes"), Scene_SoundThemes)
    m.scene(p_("MainMenu", "Speed &test"), Scene_SpeedTest)
    m.scene(p_("MainMenu", "&Install Elten"), Scene_Install) if Klangten::Config.updates_enabled?
    m.scene(p_("MainMenu", "&Log viewer"), Scene_Log)
    m.scene(p_("MainMenu", "&Console"), Scene_Console) if developer_mode?
    if developer_mode?
      m.option(p_("MainMenu", "Load custom translation &file")) {
      f=get_file(p_("MainMenu", "Select a translation file"), path: "", save: false, extensions: [".mo"])
      if f!=nil
      loadlocale f
      alert(p_("MainMenu", "Translation loaded"))
      end
      }
    end
    m.scene(p_("MainMenu", "De&bugging"), Scene_Debug) if developer_mode?
    }
    @menu.submenu(p_("MainMenu", "&Help")) {|m|
    m.scene(p_("MainMenu", "Frequently asked &questions"), Scene_FAQ)
    m.scene(p_("MainMenu", "&Changelog"), Scene_Changes)
    m.scene(p_("MainMenu", "Program &version"), Scene_Version)
    m.scene(p_("MainMenu", "Sounds &guide"), Scene_Sounds)
      m.scene(p_("MainMenu", "&Read me"), Scene_Documentation, "readme")
   m.scene(p_("MainMenu", "&Licence agreement"), Scene_Documentation, "license")
   # Klangten: EltenLink's terms, privacy policy and the Elten 2.4 migration notice do not apply.
   m.scene(p_("Klangten", "&Terms of the Klango server"), Scene_Documentation, "rules")
   m.scene(p_("MainMenu", "List of &Invisible Interface keyboard shortcuts"), Scene_IIKeys)
   m.submenu(p_("MainMenu", "Welcome &wizards")) {|m|
       m.scene(p_("MainMenu", "&First run wizard"), Scene_WelcomeWizard, true, true)
       m.scene(p_("MainMenu", "&Update to Elten 3.0 wizard"), Scene_WelcomeWizard, false, true)
}
    }
    @menu.submenu(p_("MainMenu", "&Quit")) {|m|
    if tray_supported?
    m.option(p_("MainMenu", "Hide in &tray")) {
    tray
    }
    end
    if Session.logged?
    m.option(p_("MainMenu", "&Logout")) {
    Session.feeds_clear
    register_activity(wait: true, final: true)
    login_data_path = EltenPath.join(Dirs.eltendata, "login.dat")
    begin
      if FileTest.exists?(login_data_path)
        EltenLink::System.logout_autologin(EltenLink.client(self), $computer)
      else
        EltenLink::System.logout_session(EltenLink.client(self))
      end
      Log.info("Session token invalidated on logout") if defined?(Log)
    rescue Exception
      Log.warning("Session token invalidation failed on logout: #{$!.class}: #{$!.message}") if defined?(Log)
    end
    File.delete(login_data_path) if FileTest.exists?(login_data_path)
                          play_sound("logout")
            $restart=true
            $scene=Scene_Loading.new
    }
    end
    m.option(p_("MainMenu", "E&xit")) {
    $exit=true
    $scene=nil
    }
    m.option(p_("MainMenu", "&Restart")) {
                                  play_sound("logout")
              $restart=true
              $scene=Scene_Loading.new
    }
    if !developer_mode?
    m.option(p_("MainMenu", "Restart in de&veloper mode")) {
              if !restart_to_developer_mode
                alert(p_("MainMenu", "Cannot restart in developer mode."))
              end
    }
    end
    if developer_mode?
    m.option(p_("MainMenu", "Restart in de&bug mode")) {
                    play_sound("logout")
              $DEBUG=true
              $restart=true
              $scene=Scene_Loading.new
    }
    m.option(p_("MainMenu", "Restart in &normal mode")) {
              if !restart_to_normal_mode
                alert(p_("MainMenu", "Cannot restart in normal mode."))
              end
    }
    end
    }
    if ($subthreads||[]).size>0 || $mainthread!=$currentthread
      @menu.submenu(p_("MainMenu", "&Windows")) {|m|
      for i in -1...$subthreads.size
        if i>=0
        sc=$subthreads[i]
      else
        sc=$mainthread
        end
        m.option(p_("MainMenu", "Window %{number}")%{:number=>i+1}, sc) {|sc|
                $switchthread=sc
        $focus = true
Log.info("Switching to thread #{i+1}")
        }
        end
      }
      end
    if defaults==true && defined?(Programs::Extensions)
      Programs::Extensions.menu_items.each do |item|
        @menu.option(item.label) { item.call }
      end
    end
  end
  return true
  end
    def opened?
      @currentmenu!=nil&&@currentmenu.opened?
    end
    # Klangten: [label, scene] for a built-in program, or nil when it does not run
    # here. A program excluded by its own manifest (YouTube and the FFmpeg encoders
    # on iOS) gets no entry at all - an entry that only announces its own absence is
    # worse than none. A genuine load failure is logged by Programs.load_builtin.
    def klangten_builtin_item(key, label)
      program = defined?(Programs::BuiltIns) ? Programs::BuiltIns.program_class(key) : nil
      program == nil ? nil : [label, program]
    end

    # Klangten: a submenu holding a single entry is noise - on iOS "Media" would be
    # nothing but the catalogue and "Files" nothing but the file manager, because
    # the other programs do not run there. So the entries are collected first: a
    # lone survivor moves up to the top level under its own name, several get their
    # submenu, and none at all disappears. Anything added later (Spotify under
    # Files) therefore lands in the right shape on every platform by itself.
    def klangten_group(label, entries)
      entries = entries.compact
      return if entries.empty?
      return @menu.scene(entries[0][0], entries[0][1]) if entries.size == 1
      @menu.submenu(label) { |m| entries.each { |entry| m.scene(entry[0], entry[1]) } }
    end
    def scenes
      construct(:defaults)
      @menu.scenes
    end
    def ctitems
      construct(false)
      @menu.items
    end
      end
      end
