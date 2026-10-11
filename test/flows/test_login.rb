# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Logging in against the real Klango server: start menu, name, password,
# and the auto-login shortcut used by feature tests.

require_relative "../test_helper"

class LoginTest < KlangtenTest::FlowTest
  def test_login_with_name_and_password
    server.create_user("hans")
    k = klangten(server: server)
    k.boot
    k.expect("Log in", since: 0)
    k.press("enter")
    k.expect("Username")
    k.type("hans")
    k.press("enter")
    k.expect("Password")
    k.type(KlangtenTest::PASSWORD)
    k.press("enter")
    puts k.transcript
    k.expect("hans")
  end
end
