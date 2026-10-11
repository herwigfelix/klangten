# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# EltenLink::MailAccounts: request shape (offline) and a full round trip
# against a Klangten dev server (online, see test/k04_support.rb).

require "minitest/autorun"
require_relative "k04_support"
K04Support.load_source "src/eltenlink/mail_accounts.rb"

class TestMailAccounts < Minitest::Test
  SETTINGS = {
    "addresses" => [{ "address" => "alice@klango.online", "main" => true, "default" => false },
                    { "address" => "a.b@sixdots.it", "main" => false, "default" => true }],
    "domains" => ["klango.online", "sixdots.it"], "display" => "Alice", "has_password" => false,
    "imap" => false, "webmail" => false, "max_addresses" => 3, "can_add" => true,
    "login" => "alice@klango.online", "imap_server" => "mail.klango.online", "imap_port" => 993,
    "smtp_server" => "mail.klango.online", "smtp_port" => 587, "webmail_url" => "https://webmail.klango.online"
  }.freeze

  def test_settings_are_parsed
    client = K04Support::FakeClient.new { SETTINGS }
    settings = EltenLink::MailAccounts.settings(client)
    assert_equal [["GET", "/api/v1/mail/settings", nil]], client.calls
    assert_equal 2, settings.addresses.size
    assert settings.addresses[0].main?
    assert_equal "a.b@sixdots.it", settings.sender.address
    assert settings.can_add?
    refute settings.password?
    assert_equal 993, settings.imap_port
  end

  def test_requests
    client = K04Support::FakeClient.new { |_m, path, _p| path.end_with?("/addresses") ? { "address" => "x@klango.online", "settings" => SETTINGS } : { "settings" => SETTINGS }.merge(SETTINGS) }
    address, settings = EltenLink::MailAccounts.add(client, "X", "klango.online")
    assert_equal "x@klango.online", address
    assert_equal 2, settings.addresses.size
    EltenLink::MailAccounts.set_default(client, "A.B@Sixdots.it")
    EltenLink::MailAccounts.delete(client, "a.b@sixdots.it")
    EltenLink::MailAccounts.update(client, display: "Al", imap: true)
    EltenLink::MailAccounts.set_password(client, "")
    assert_equal ["POST", "/api/v1/mail/addresses", { "local" => "X", "domain" => "klango.online" }], client.calls[0]
    assert_equal ["POST", "/api/v1/mail/addresses/a.b%40sixdots.it/default", nil], client.calls[1]
    assert_equal ["DELETE", "/api/v1/mail/addresses/a.b%40sixdots.it", nil], client.calls[2]
    assert_equal ["PATCH", "/api/v1/mail/settings", { "display" => "Al", "imap" => 1 }], client.calls[3]
    assert_equal ["PUT", "/api/v1/mail/password", { "password" => "" }], client.calls[4]
  end

  def test_error_keys
    assert_equal "taken", EltenLink::MailAccounts.error_key(EltenLink::Error.new("x", code: "mail.taken"))
    assert_nil EltenLink::MailAccounts.error_key(EltenLink::Error.new("x", code: "mail.whatever"))
    assert_nil EltenLink::MailAccounts.error_key(EltenLink::Error.new("x", code: "network_error"))
  end

  def test_round_trip_on_dev_server
    skip "KLANGTEN_TEST_API not set" unless K04Support::DevClient.available?
    client = K04Support::DevClient.login(ENV.fetch("KLANGTEN_TEST_USER"), ENV.fetch("KLANGTEN_TEST_PASSWORD"))
    settings = EltenLink::MailAccounts.settings(client)
    main = settings.addresses.find(&:main?)
    refute_nil main
    # Leftovers of an earlier run.
    settings.addresses.reject(&:main?).each { |a| EltenLink::MailAccounts.delete(client, a.address) }
    local = "k04test#{Process.pid}"
    check = EltenLink::MailAccounts.check(client, local)
    assert check.available, check.reason
    address, settings = EltenLink::MailAccounts.add(client, local)
    assert_equal "#{local}@#{settings.domains.first}", address
    error = assert_raises(EltenLink::Error) { EltenLink::MailAccounts.add(client, local) }
    assert_equal "taken", EltenLink::MailAccounts.error_key(error)
    error = assert_raises(EltenLink::Error) { EltenLink::MailAccounts.add(client, "postmaster") }
    assert_equal "reserved", EltenLink::MailAccounts.error_key(error)
    settings = EltenLink::MailAccounts.set_default(client, address)
    assert_equal address, settings.sender.address
    error = assert_raises(EltenLink::Error) { EltenLink::MailAccounts.delete(client, main.address) }
    assert_equal "ismain", EltenLink::MailAccounts.error_key(error)
    settings = EltenLink::MailAccounts.delete(client, address)
    assert_equal main.address, settings.sender.address
    settings = EltenLink::MailAccounts.update(client, display: "K04 Test")
    assert_equal "K04 Test", settings.display
    error = assert_raises(EltenLink::Error) { EltenLink::MailAccounts.update(client, imap: true) } unless settings.password?
    assert_equal "nopassword", EltenLink::MailAccounts.error_key(error) if error
    error = assert_raises(EltenLink::Error) { EltenLink::MailAccounts.set_password(client, "kurz") }
    assert_equal "tooshort", EltenLink::MailAccounts.error_key(error)
    settings = EltenLink::MailAccounts.set_password(client, "langesgeheimnis")
    assert settings.password?
    settings = EltenLink::MailAccounts.update(client, imap: true, webmail: true)
    assert settings.imap && settings.webmail
    settings = EltenLink::MailAccounts.set_password(client, "")
    refute settings.password? || settings.imap || settings.webmail
  end
end
