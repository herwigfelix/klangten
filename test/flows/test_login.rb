# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Logging in against the real Klango server (src/scenes/login.rb): name and
# password, a wrong password, the auto-login question, and the shortcut
# feature tests use (boot_logged_in).

require_relative "../test_helper"

class LoginTest < KlangtenTest::FlowTest
  def enter_credentials(k, name, password)
    k.boot
    k.expect("Log in", since: 0)
    k.press("enter")
    k.expect("Username")
    k.type(name)
    k.press("enter")
    k.expect("Password")
    k.type(password)
  end

  def test_login_with_name_and_password
    server.create_user("hans")
    k = klangten(server: server)
    enter_credentials(k, "hans", KlangtenTest::PASSWORD)
    # The password is not read out, only its sound.
    assert_includes k.sounds, "editbox_passwordchar"
    k.expect_not(KlangtenTest::PASSWORD[0, 3])
    k.press("enter")
    k.expect("Do you want to enable auto log in for account hans?")
    k.press("enter") # "No"
    k.expect("Logged in as: hans")
    k.expect_sound("login")
    k.expect("Quick actions")
    assert_kind_of Scene_Main, k.scene
    assert server.requests.any? { |method, path, status| method == "POST" && path.start_with?("/api/v1/session") && status == 200 }
    refute File.exist?(File.join(k.data_dir, "login.dat")), "no auto-login key without consent"
  end

  def test_wrong_password_asks_again
    server.create_user("hans")
    k = klangten(server: server)
    enter_credentials(k, "hans", "falsch!!")
    k.press("enter")
    k.expect("Invalid login or password.")
    k.press("enter")
    k.expect("Username")
    k.expect_not("Logged in")
  end

  def test_enabling_auto_login_stores_a_key
    server.create_user("hans")
    k = klangten(server: server)
    enter_credentials(k, "hans", KlangtenTest::PASSWORD)
    k.press("enter")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    k.expect("Automatic login will remain enabled")
    assert File.exist?(File.join(k.data_dir, "login.dat"))
  end

  def test_boot_logged_in_shortcut
    server.create_user("grete")
    k = klangten(server: server)
    k.boot_logged_in("grete")
    k.expect("Logged in as: grete", since: 0)
    assert_kind_of Scene_Main, k.scene
  end
end
