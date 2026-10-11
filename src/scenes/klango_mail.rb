# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Account settings: the Klango e-mail addresses of the account (the same
# settings Klango shows as "My e-mail settings"). Lists the addresses, creates
# and deletes additional ones, chooses the sender address and name, sets the
# mailbox password, switches the sign-in of mail programs and of the webmail
# and shows the access data for a mail program. Data: EltenLink::MailAccounts.

class Scene_Account_KlangoMail
  def main
    unless Session.logged?
      alert(_("This section is unavailable for guests"))
      return finish
    end
    focus = 0
    settings = load_settings
    while settings != nil
      outcome, focus, changed = show_form(settings, focus)
      break if outcome != :refresh
      settings = changed || load_settings
    end
    finish
  end

  private

  def finish
    $scene = Scene_Main.new if $scene == self
  end

  def load_settings
    run_request(p_("Klangten", "Loading the e-mail settings...")) { |client| EltenLink::MailAccounts.settings(client) }
  end

  # Runs a server request on a worker (busy indicator after half a second,
  # Escape cancels). Returns the block's result or nil after an announced error.
  def run_request(title)
    EltenAPI::Tasks.run(title: title) { |_progress, token| yield(EltenLink::Client.new, token) }
  rescue EltenAPI::Tasks::Cancelled
    nil
  rescue EltenLink::Error => e
    Log.warning("Klango mail request failed: #{e.code}: #{e.message}")
    alert(error_text(e))
    nil
  end

  def error_text(error)
    case EltenLink::MailAccounts.error_key(error)
    when "taken" then p_("Klangten", "This address is already taken.")
    when "reserved" then p_("Klangten", "This name is reserved and cannot be used.")
    when "invalid" then p_("Klangten", "This name cannot be used in an address. Use lower-case letters, digits, dots, hyphens and underscores; it must begin and end with a letter or a digit.")
    when "empty" then p_("Klangten", "Enter a name for the address.")
    when "toolong" then p_("Klangten", "The name can have at most 32 characters.")
    when "toomany" then p_("Klangten", "You already have the maximum number of addresses.")
    when "baddomain" then p_("Klangten", "This domain is not available on this server.")
    when "unknown" then p_("Klangten", "This address does not belong to your account.")
    when "ismain" then p_("Klangten", "The main address carries your mailbox and cannot be deleted.")
    when "tooshort" then p_("Klangten", "The mailbox password needs at least 8 characters.")
    when "nopassword" then p_("Klangten", "Set a mailbox password first.")
    when "unavailable" then p_("Klangten", "The mailbox password cannot be set right now. Please try again later.")
    else
      case error.code.to_s
      when "network_error", "timeout" then p_("Klangten", "The server could not be reached.")
      else error.message.to_s == "" ? _("Error") : error.message.to_s
      end
    end
  end

  def address_label(address)
    parts = [address.address]
    parts << p_("Klangten", "main address") if address.main?
    parts << p_("Klangten", "sender") if address.default?
    parts.join(", ")
  end

  def access_text(settings)
    lines = []
    lines << p_("Klangten", "User name: %{login}") % { login: settings.login }
    lines << p_("Klangten", "Incoming mail (IMAP): %{server}, port %{port}, SSL/TLS") % { server: settings.imap_server, port: settings.imap_port }
    lines << p_("Klangten", "Outgoing mail (SMTP): %{server}, port %{port}, STARTTLS") % { server: settings.smtp_server, port: settings.smtp_port }
    lines << p_("Klangten", "Webmail: %{url}") % { url: settings.webmail_url } if settings.webmail_url != ""
    lines << p_("Klangten", "Password: the mailbox password set here.")
    unless settings.password?
      lines << p_("Klangten", "No mailbox password is set yet, so mail programs and the webmail cannot sign in.")
    end
    lines << p_("Klangten", "Mail to your addresses also arrives in your Klango messages.")
    lines.join("\n")
  end

  def show_form(settings, focus)
    outcome = nil
    changed = nil
    addresses = settings.addresses
    lst_addresses = ListBox.new(addresses.map { |a| address_label(a) }, header: p_("Klangten", "Your Klango e-mail addresses"))
    btn_new = Button.new(p_("Klangten", "New address"))
    btn_display = Button.new(p_("Klangten", "Sender name: %{name}") % { name: settings.display })
    btn_password = Button.new(settings.password? ? p_("Klangten", "Change or remove the mailbox password") : p_("Klangten", "Set a mailbox password"))
    chk_imap = CheckBox.new(p_("Klangten", "Allow mail programs to sign in"), checked: settings.imap)
    chk_webmail = CheckBox.new(p_("Klangten", "Allow sign-in to the webmail"), checked: settings.webmail)
    edt_access = EditBox.new(p_("Klangten", "Access data for mail programs"), type: EditBox::Flags::MultiLine | EditBox::Flags::ReadOnly, text: access_text(settings), quiet: true)
    btn_close = Button.new(_("Close"))
    fields = [lst_addresses, btn_new, btn_display, btn_password, chk_imap, chk_webmail, edt_access, btn_close]
    form = Form.new(fields, index: [[focus.to_i, 0].max, fields.size - 1].min)
    form.cancel_button = btn_close
    done = lambda do |result|
      changed = result
      outcome = :refresh
      form.resume
    end
    btn_close.on(:press) { form.resume }

    lst_addresses.bind_context { |menu|
      address = addresses[lst_addresses.index]
      if address != nil
        if !address.default?
          menu.option(p_("Klangten", "Use as sender address"), nil, "s") {
            result = set_sender(address)
            done.call(result) if result != nil
          }
        end
        menu.option(p_("Klangten", "Copy address"), nil, "c") {
          Clipboard.text = address.address
          alert(p_("Klangten", "Copied to clipboard."))
        }
        if !address.main?
          menu.option(_("Delete"), nil, :del) {
            result = delete_address(address)
            done.call(result) if result != nil
          }
        end
      end
      menu.option(p_("Klangten", "New address"), nil, "n") {
        result = new_address(settings)
        done.call(result) if result != nil
      }
    }
    lst_addresses.on(:select) {
      address = addresses[lst_addresses.index]
      if address != nil && !address.default?
        result = set_sender(address)
        done.call(result) if result != nil
      end
    }
    btn_new.on(:press) {
      result = new_address(settings)
      done.call(result) if result != nil
    }
    btn_display.on(:press) {
      name = input_text(p_("Klangten", "Name shown as the sender of your e-mails"), text: settings.display, escapable: true, max_length: 64)
      if name != nil && name.strip != "" && name.strip != settings.display
        result = run_request(p_("Klangten", "Saving...")) { |client| EltenLink::MailAccounts.update(client, display: name.strip) }
        if result != nil
          alert(p_("Klangten", "The sender name has been changed."))
          done.call(result)
        end
      end
    }
    btn_password.on(:press) {
      result = change_password(settings)
      done.call(result) if result != nil
    }
    chk_imap.on(:change) {
      result = set_switch(settings, imap: chk_imap.checked)
      result == nil ? chk_imap.checked = settings.imap : done.call(result)
    }
    chk_webmail.on(:change) {
      result = set_switch(settings, webmail: chk_webmail.checked)
      result == nil ? chk_webmail.checked = settings.webmail : done.call(result)
    }
    form.wait
    [outcome, fields.index(form.fields[form.index]) || 0, changed]
  end

  def set_sender(address)
    result = run_request(p_("Klangten", "Saving...")) { |client| EltenLink::MailAccounts.set_default(client, address.address) }
    alert(p_("Klangten", "%{address} is now your sender address.") % { address: address.address }) if result != nil
    result
  end

  def delete_address(address)
    return nil if !confirm(p_("Klangten", "Do you really want to delete the address %{address}? Mail sent to it will no longer reach you.") % { address: address.address })
    result = run_request(p_("Klangten", "Deleting...")) { |client| EltenLink::MailAccounts.delete(client, address.address) }
    alert(p_("Klangten", "The address has been deleted.")) if result != nil
    result
  end

  def new_address(settings)
    if !settings.can_add?
      alert(p_("Klangten", "You already have the maximum number of addresses (%{count}). Delete one first.") % { count: settings.max_addresses })
      return nil
    end
    domains = settings.domains
    domain = domains.first.to_s
    if domains.size > 1
      index = selector(domains.map { |d| "@" + d }, header: p_("Klangten", "Domain of the new address"), cancel_index: domains.size)
      return nil if index == nil || index < 0 || index >= domains.size
      domain = domains[index]
    end
    local = input_text(p_("Klangten", "Name before @%{domain}") % { domain: domain }, escapable: true, max_length: 64)
    return nil if local == nil || local.strip == ""
    created = nil
    result = run_request(p_("Klangten", "Creating the address...")) do |client|
      created, changed = EltenLink::MailAccounts.add(client, local.strip, domain)
      changed
    end
    alert(p_("Klangten", "The address %{address} has been created.") % { address: created }) if result != nil
    result
  end

  def change_password(settings)
    if settings.password?
      options = [p_("Klangten", "Set a new mailbox password"), p_("Klangten", "Remove the mailbox password"), _("Cancel")]
      choice = selector(options, header: p_("Klangten", "Mailbox password"), cancel_index: 2)
      return nil if choice == nil || choice == 2
      if choice == 1
        return nil if !confirm(p_("Klangten", "Remove the mailbox password? Mail programs and the webmail can then no longer sign in."))
        result = run_request(p_("Klangten", "Saving...")) { |client| EltenLink::MailAccounts.set_password(client, "") }
        alert(p_("Klangten", "The mailbox password has been removed.")) if result != nil
        return result
      end
    end
    password = input_text(p_("Klangten", "New mailbox password (at least %{count} characters)") % { count: EltenLink::MailAccounts::MIN_PASSWORD_LENGTH }, flags: EditBox::Flags::Password, escapable: true)
    return nil if password == nil || password == ""
    if password.size < EltenLink::MailAccounts::MIN_PASSWORD_LENGTH
      alert(p_("Klangten", "The mailbox password needs at least 8 characters."))
      return nil
    end
    repeat = input_text(p_("Klangten", "Repeat the mailbox password"), flags: EditBox::Flags::Password, escapable: true)
    return nil if repeat == nil
    if repeat != password
      alert(p_("Klangten", "The passwords do not match."))
      return nil
    end
    result = run_request(p_("Klangten", "Saving...")) { |client| EltenLink::MailAccounts.set_password(client, password) }
    if result != nil
      text = p_("Klangten", "The mailbox password has been set.")
      text += " " + p_("Klangten", "Now tick whether mail programs or the webmail may sign in with it.") if !result.imap && !result.webmail
      alert(text)
    end
    result
  end

  def set_switch(settings, imap: nil, webmail: nil)
    if (imap == true || webmail == true) && !settings.password?
      alert(p_("Klangten", "Set a mailbox password first."))
      return nil
    end
    run_request(p_("Klangten", "Saving...")) { |client| EltenLink::MailAccounts.update(client, imap: imap, webmail: webmail) }
  end
end
