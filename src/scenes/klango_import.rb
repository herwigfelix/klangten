# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Tools > Import data from Klango (desktop only): finds Klango 3 and Klango 4
# on this computer (KlangoImport, src/eapi/klango_import.rb), shows what can
# be taken over and imports what the user ticks: local Klango notes become
# notes on the server, the Mastodon sign-in becomes Klangten's Mastodon
# account. Klango itself is only read. Can be repeated at any time: notes that
# are already there are skipped.

class Scene_KlangoImport
  def self.available?
    !(defined?(EltenBoot) && EltenBoot.respond_to?(:platform?) && EltenBoot.platform?(:ios))
  rescue Exception
    false
  end

  def main
    run
    $scene = Scene_Main.new if $scene == self
  end

  private

  def run
    unless self.class.available?
      alert(p_("Klangten", "Importing data from Klango is only possible on a computer."))
      return
    end
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      return
    end
    findings, existing = collect
    return if findings == nil
    if findings.sources.empty?
      alert(p_("Klangten", "No Klango 3 or Klango 4 was found on this computer."))
      return
    end
    notes = KlangoImport.new_notes(findings.notes, existing)
    current = Klangten::Mastodon::AccountStore.load(Session.name)
    login = findings.mastodon.first
    login = nil if current != nil && current.usable?
    show_form(findings, notes, login, current)
  end

  # Reads the Klango registries and the notes that are already on the server.
  def collect
    EltenAPI::Tasks.run(title: p_("Klangten", "Looking for Klango data...")) do |_progress, token|
      findings = KlangoImport.find
      existing = []
      existing = EltenLink::Notes.list(EltenLink::Client.new) if !findings.notes.empty?
      token.raise_if_cancelled!
      [findings, existing]
    end
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue EltenLink::Error => e
    Log.warning("Klango import: notes could not be listed: #{e.code}: #{e.message}")
    alert(p_("Klangten", "Your notes could not be loaded from the server. Try again later."))
    nil
  end

  def summary(findings, notes, login, current)
    lines = []
    findings.sources.each do |source|
      user = findings.users[source.kind]
      lines << if user.to_s != ""
        p_("Klangten", "Found: %{program} (last signed in as %{user}).") % { program: source.label, user: user }
      else
        p_("Klangten", "Found: %{program}.") % { program: source.label }
      end
    end
    if findings.notes.empty?
      lines << p_("Klangten", "Klango has no local notes.")
    else
      lines << p_("Klangten", "Local notes in Klango: %{count}, not yet in Klangten: %{new}.") % { count: findings.notes.size, new: notes.size }
    end
    if findings.mastodon.empty?
      lines << p_("Klangten", "Klango is not signed in to Mastodon.")
    elsif login == nil
      lines << p_("Klangten", "Klangten is already connected to the Mastodon account %{account}.") % { account: current.label }
    else
      lines << p_("Klangten", "Mastodon account in Klango: %{account}.") % { account: mastodon_label(login) }
    end
    lines << p_("Klangten", "Klango is only read; nothing there is changed. Messages, forums, notes on the server, media favourites and blogs are on the Klango server and are already available in Klangten.")
    lines.join("\n")
  end

  def mastodon_label(login)
    host = login.instance.to_s.sub(%r{\Ahttps?://}, "").chomp("/")
    login.acct.to_s == "" ? host : "@#{login.acct}@#{host}"
  end

  def show_form(findings, notes, login, current)
    info = EditBox.new(p_("Klangten", "Data from Klango"), type: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, text: summary(findings, notes, login, current), quiet: true)
    chk_notes = notes.empty? ? nil : CheckBox.new(np_("Klangten", "Import %{count} local note as a Klangten note", "Import %{count} local notes as Klangten notes", notes.size) % { count: notes.size }, checked: true)
    chk_mastodon = login == nil ? nil : CheckBox.new(p_("Klangten", "Connect the Mastodon account %{account}") % { account: mastodon_label(login) }, checked: true)
    if chk_notes == nil && chk_mastodon == nil
      input_text(p_("Klangten", "Nothing to import"), flags: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, text: info.text)
      return
    end
    btn_import = Button.new(p_("Klangten", "Import"))
    btn_cancel = Button.new(_("Cancel"))
    form = Form.new([info, chk_notes, chk_mastodon, btn_import, btn_cancel].compact)
    form.cancel_button = btn_cancel
    chosen = false
    btn_cancel.on(:press) { form.resume }
    btn_import.on(:press) do
      chosen = true
      form.resume
    end
    form.wait
    return if !chosen
    import(chk_notes != nil && chk_notes.checked ? notes : [], chk_mastodon != nil && chk_mastodon.checked ? login : nil)
  end

  def import(notes, login)
    return alert(p_("Klangten", "Nothing was selected.")) if notes.empty? && login == nil
    state = { notes: 0, mastodon: nil, error: nil }
    begin
      EltenAPI::Tasks.run(title: p_("Klangten", "Importing data from Klango...")) do |progress, token|
        client = EltenLink::Client.new
        notes.each_with_index do |note, index|
          token.raise_if_cancelled!
          progress.update(index, total: notes.size, message: KlangoImport.note_name(note))
          EltenLink::Notes.create(client, KlangoImport.note_name(note), note.body.to_s)
          state[:notes] += 1
        end
        state[:mastodon] = verify_mastodon(login, token) if login != nil
      end
    rescue EltenAPI::Tasks::Cancelled
      state[:error] = :cancelled
    rescue EltenLink::Error => e
      Log.warning("Klango import: note could not be created: #{e.code}: #{e.message}")
      state[:error] = :notes
    end
    mastodon_saved = save_mastodon(login, state[:mastodon])
    report(notes.size, state, login, mastodon_saved)
  end

  # Checks the token against the Mastodon server (on the worker).
  def verify_mastodon(login, token)
    client = Klangten::Mastodon::Client.new(login.instance, token: login.token)
    account = client.verify_credentials
    token.raise_if_cancelled!
    info = begin
      client.instance_info
    rescue Klangten::Mastodon::Error
      { "max_characters" => Klangten::Mastodon::DEFAULT_MAX_CHARACTERS }
    end
    { base_url: client.base_url, account: account, info: info }
  rescue Klangten::Mastodon::Error, ArgumentError, SocketError, SystemCallError, IOError, Timeout::Error => e
    Log.warning("Klango import: Mastodon sign-in could not be verified: #{e.class}: #{e.message}")
    { failed: true }
  end

  def save_mastodon(login, verified)
    return nil if login == nil || !verified.is_a?(Hash)
    return false if verified[:failed]
    account = verified[:account]
    record = Klangten::Mastodon::Account_Record.new(
      user: Session.name.to_s.downcase,
      instance: verified[:base_url],
      client_id: login.client_id,
      client_secret: login.client_secret,
      token: login.token,
      account_id: account.id.to_s,
      acct: account.acct.to_s,
      display_name: account.name.to_s,
      max_characters: verified[:info]["max_characters"].to_i,
      shared_token: true
    )
    Klangten::Mastodon::AccountStore.save(Session.name, record)
    Klangten::Mastodon::Service.refresh
    Session.feeds_update if Session.respond_to?(:feeds_update)
    true
  rescue StandardError => e
    Log.warning("Klango import: Mastodon account could not be saved: #{e.class}: #{e.message}")
    false
  end

  def report(wanted, state, login, mastodon_saved)
    lines = []
    if wanted > 0
      lines << np_("Klangten", "%{count} note was imported.", "%{count} notes were imported.", state[:notes]) % { count: state[:notes] }
      lines << p_("Klangten", "Some notes could not be imported. Start the import again to continue.") if state[:notes] < wanted
    end
    if login != nil
      lines << case mastodon_saved
      when true then p_("Klangten", "The Mastodon account %{account} is now connected to Klangten.") % { account: mastodon_label(login) }
      when false then p_("Klangten", "The Mastodon sign-in from Klango is no longer valid. Connect the account again in the Mastodon settings.")
      else p_("Klangten", "The Mastodon account was not connected.")
      end
    end
    alert(lines.join(" "))
  end
end
