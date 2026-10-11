# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Start options, server selection, confirmed servers and the licence lock
# (src/eltenlink/klangten_config.rb, src/eltenlink/klangten_startup.rb).
# Pure logic only - no network, no UI:
#
#   ruby test/klangten_startup_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
load File.join(ROOT, "src", "eltenlink", "klangten_config.rb")
load File.join(ROOT, "src", "eltenlink", "klangten_startup.rb")

module KlangtenEnvIsolation
  KEYS = %w[
    KLANGTEN_API_URL KLANGO_SRV_HOST_BASE_URL KLANGTEN_CONFIG_DIR
    KLANGTEN_RECORDINGS_DIR ELTEN_LAUNCHER_EXECUTABLE_PATH
  ].freeze

  def setup
    super
    @saved_env = KEYS.to_h { |key| [key, ENV[key]] }
    KEYS.each { |key| ENV.delete(key) }
    Klangten::ServerLock.clear
  end

  def teardown
    @saved_env.each { |key, value| value == nil ? ENV.delete(key) : ENV[key] = value }
    Klangten::ServerLock.clear
    super
  end
end

class KlangtenStartupParseTest < Minitest::Test
  include KlangtenEnvIsolation

  def test_separate_value
    result = Klangten::Startup.parse(["elten.exe", "--overwrite-config-path", "D:\\Klangten\\data"])
    assert_equal({ "KLANGTEN_CONFIG_DIR" => "D:\\Klangten\\data" }, result)
  end

  def test_equals_form
    result = Klangten::Startup.parse(["--srv-host-base-url=https://example.org"])
    assert_equal({ "KLANGO_SRV_HOST_BASE_URL" => "https://example.org" }, result)
  end

  def test_klango_variable_form_without_dashes
    result = Klangten::Startup.parse(["srv-host-base-url=example.org", "overwrite-recordings-path=rec"])
    assert_equal "example.org", result["KLANGO_SRV_HOST_BASE_URL"]
    assert_equal "rec", result["KLANGTEN_RECORDINGS_DIR"]
  end

  def test_quotes_and_case
    result = Klangten::Startup.parse(["--Overwrite-Config-Path", "\"C:\\Program Files\\x\""])
    assert_equal "C:\\Program Files\\x", result["KLANGTEN_CONFIG_DIR"]
  end

  def test_unknown_and_flags_are_ignored
    result = Klangten::Startup.parse(["/hidden", "--dev", "/datadir", "x", "foo=bar", "--srv-host-base-url"])
    assert_equal({}, result)
  end

  def test_bare_name_without_value_is_no_option
    assert_equal({}, Klangten::Startup.parse(["srv-host-base-url", "https://example.org"]))
  end

  def test_empty_value_is_ignored_and_last_one_wins
    result = Klangten::Startup.parse(["--srv-host-base-url=", "--srv-host-base-url", "a.example", "--srv-host-base-url=b.example"])
    assert_equal "b.example", result["KLANGO_SRV_HOST_BASE_URL"]
  end

  def test_value_is_not_read_as_an_option
    result = Klangten::Startup.parse(["--overwrite-config-path", "--srv-host-base-url=x", "/hidden"])
    assert_equal "--srv-host-base-url=x", result["KLANGTEN_CONFIG_DIR"]
    refute result.key?("KLANGO_SRV_HOST_BASE_URL")
  end
end

class KlangtenStartupApplyTest < Minitest::Test
  include KlangtenEnvIsolation

  def test_relative_paths_are_relative_to_the_program_and_created
    Dir.mktmpdir do |dir|
      env = {}
      Klangten::Startup.apply!(["--overwrite-config-path", "data", "--overwrite-recordings-path=../rec"], env: env, base_dir: dir)
      assert_equal File.join(dir, "data"), env["KLANGTEN_CONFIG_DIR"]
      assert_equal File.expand_path("../rec", dir), env["KLANGTEN_RECORDINGS_DIR"]
      assert File.directory?(File.join(dir, "data"))
    end
  end

  def test_inherited_environment_stays_and_is_made_absolute
    Dir.mktmpdir do |dir|
      env = { "KLANGTEN_CONFIG_DIR" => "inherited", "KLANGO_SRV_HOST_BASE_URL" => "https://a.example" }
      Klangten::Startup.apply!([], env: env, base_dir: dir)
      assert_equal File.join(dir, "inherited"), env["KLANGTEN_CONFIG_DIR"]
      assert_equal "https://a.example", env["KLANGO_SRV_HOST_BASE_URL"]
      Klangten::Startup.apply!(["--srv-host-base-url", "https://b.example"], env: env, base_dir: dir)
      assert_equal "https://b.example", env["KLANGO_SRV_HOST_BASE_URL"]
    end
  end

  def test_base_dir
    assert_equal "/Volumes/Stick", Klangten::Startup.base_dir(env: { "ELTEN_LAUNCHER_EXECUTABLE_PATH" => "/Volumes/Stick/Klangten.app/Contents/MacOS/elten" })
    assert_equal "/opt/klangten", Klangten::Startup.base_dir(env: { "ELTEN_LAUNCHER_EXECUTABLE_PATH" => "/opt/klangten/elten" })
    assert_equal "/src/klangten", Klangten::Startup.base_dir(env: {}, source_root: "/src/klangten")
    assert_equal ROOT, Klangten::Startup.base_dir(env: {})
  end

  def test_restart_arguments
    env = { "KLANGTEN_CONFIG_DIR" => "/x/data", "KLANGO_SRV_HOST_BASE_URL" => "https://example.org" }
    assert_equal ["--overwrite-config-path", "/x/data", "--srv-host-base-url", "https://example.org"], Klangten::Startup.restart_arguments(env: env)
    assert_equal [], Klangten::Startup.restart_arguments(env: {})
  end

  def test_update_commands_carry_the_options
    ENV["KLANGTEN_CONFIG_DIR"] = "/x/data"
    osx = Klangten::Updates.install_command("osx", "/tmp/Klangten.dmg", app_path: "/Applications/Klangten.app")
    assert_equal ["/tmp/Klangten.dmg", "/Applications/Klangten.app", "--overwrite-config-path", "/x/data"], osx[4..]
    assert_includes osx[2], "--args \"$@\""
    linux = Klangten::Updates.install_command("linux", "/tmp/k.run")
    assert_equal ["/tmp/k.run", "1", "--overwrite-config-path", "/x/data"], linux[4..]
    assert_includes linux[2], "elten \"$@\""
    ENV.delete("KLANGTEN_CONFIG_DIR")
    assert_equal ["/tmp/k.run", "0"], Klangten::Updates.install_command("linux", "/tmp/k.run", silent: false)[4..]
  end
end

class KlangtenServerSelectionTest < Minitest::Test
  include KlangtenEnvIsolation

  C = Klangten::Config

  def test_default_is_the_official_server
    assert_equal "https://klango.online", C.server_url
    assert_equal "https://ten.klango.online", C.api_url
    assert C.official_server?
    refute C.server_confirmation_required?
    assert_equal "https://ten.klango.online", C.software_api_base_url
  end

  def test_normalize_server_url
    assert_equal "https://example.org", C.normalize_server_url("example.org")
    assert_equal "https://example.org", C.normalize_server_url(" https://Example.ORG/klango/ ")
    assert_equal "http://127.0.0.1:5100", C.normalize_server_url("http://127.0.0.1:5100/")
    assert_equal "https://example.org:8443", C.normalize_server_url("\"https://example.org:8443\"")
    assert_nil C.normalize_server_url("")
    assert_nil C.normalize_server_url("ftp://example.org")
    assert_nil C.normalize_server_url("https://")
  end

  def test_api_host_derivation
    assert_equal "https://ten.example.org", C.api_url_for_server("https://example.org")
    assert_equal "https://ten.example.org", C.api_url_for_server("ten.example.org")
    assert_equal "https://ten.example.org", C.api_url_for_server("https://www.example.org")
    assert_equal "https://ten.example.org", C.api_url_for_server("web.example.org")
    assert_equal "https://ten.example.org", C.api_url_for_server("chat.example.org")
    assert_equal "https://ten.example.org:8443", C.api_url_for_server("https://example.org:8443")
    assert_equal "https://ten.www.org", C.api_url_for_server("www.org")
  end

  def test_hosts_without_subdomain_are_kept
    assert_equal "http://127.0.0.1:5100", C.api_url_for_server("http://127.0.0.1:5100")
    assert_equal "http://localhost:5100", C.api_url_for_server("http://localhost:5100")
    assert_equal "http://klango.localhost", C.api_url_for_server("http://klango.localhost")
    assert_equal "http://[::1]:5100", C.api_url_for_server("http://[::1]:5100")
    assert_equal "http://devbox:5100", C.api_url_for_server("http://devbox:5100")
  end

  def test_foreign_server
    ENV["KLANGO_SRV_HOST_BASE_URL"] = "example.org"
    assert_equal "https://example.org", C.server_url
    assert_equal "https://ten.example.org", C.api_base_url
    assert_equal "ten.example.org:443", C.api_authority
    refute C.official_server?
    assert C.server_confirmation_required?
    assert_equal "https://ten.klango.online", C.software_api_base_url
    assert_equal "https://example.org", C.server_terms_url
    assert_equal "https://example.org", C.server_web_url
  end

  def test_official_server_given_explicitly
    %w[klango.online https://klango.online/ ten.klango.online https://www.klango.online].each do |value|
      ENV["KLANGO_SRV_HOST_BASE_URL"] = value
      assert C.official_server?, value
      refute C.server_confirmation_required?, value
    end
  end

  def test_unusable_server_falls_back_to_the_official_one
    ENV["KLANGO_SRV_HOST_BASE_URL"] = "ftp://nope"
    assert C.official_server?
  end

  def test_developer_switch_wins_and_is_not_confirmed
    ENV["KLANGO_SRV_HOST_BASE_URL"] = "example.org"
    ENV["KLANGTEN_API_URL"] = "http://127.0.0.1:5100/"
    assert_equal "http://127.0.0.1:5100", C.api_url
    refute C.server_confirmation_required?
    assert_equal "http://127.0.0.1:5100", C.software_api_base_url
  end

  def test_updater_trusts_only_the_official_server
    ENV["KLANGO_SRV_HOST_BASE_URL"] = "example.org"
    assert Klangten::Updates.trusted_url?("https://ten.klango.online/api/v1/system/installer/download?os=osx")
    refute Klangten::Updates.trusted_url?("https://ten.example.org/api/v1/system/installer/download?os=osx")
  end

  def test_directory_overrides
    assert_nil C.config_dir_override
    ENV["KLANGTEN_CONFIG_DIR"] = "/x/data"
    ENV["KLANGTEN_RECORDINGS_DIR"] = "/x/rec"
    assert_equal "/x/data", C.config_dir_override
    assert_equal "/x/rec", C.recordings_dir_override
  end
end

class KlangtenServerTrustTest < Minitest::Test
  include KlangtenEnvIsolation

  def test_remember_and_check
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sub", "trusted_servers.txt")
      refute Klangten::ServerTrust.trusted?("https://example.org", path)
      assert Klangten::ServerTrust.remember("https://Example.ORG/", path)
      assert Klangten::ServerTrust.trusted?("example.org", path)
      refute Klangten::ServerTrust.trusted?("https://other.example", path)
      refute Klangten::ServerTrust.trusted?("http://example.org", path)
      assert Klangten::ServerTrust.remember("example.org", path)
      assert Klangten::ServerTrust.remember("http://127.0.0.1:5100", path)
      assert_equal ["https://example.org", "http://127.0.0.1:5100"], Klangten::ServerTrust.list(path)
      refute File.exist?(path + ".tmp")
    end
  end

  def test_list_ignores_comments_and_garbage
    Dir.mktmpdir do |dir|
      path = File.join(dir, "trusted_servers.txt")
      File.write(path, "# comment\r\n\r\nexample.org\r\nftp://x\r\n")
      assert_equal ["https://example.org"], Klangten::ServerTrust.list(path)
    end
  end

  def test_default_path_is_the_standard_data_directory
    ENV["KLANGTEN_CONFIG_DIR"] = "/elsewhere"
    assert_equal File.join("/home/u/.local/share", "sixdotsIT", "klangten", "trusted_servers.txt"),
                 Klangten::ServerTrust.default_path("/home/u/.local/share")
  end
end

class KlangtenServerLockTest < Minitest::Test
  include KlangtenEnvIsolation

  L = Klangten::ServerLock
  # What klango/license.py (wrap_wsgi) answers without a valid licence.
  BODY = "Dieser Klango-Server hat keine g\u00fcltige Lizenz. Bitte wende dich an den Betreiber dieses Servers.\n" \
         "This Klango server has no valid license. Please contact the operator of this server.\n(nokey)\n"
  TEXT = { "Content-Type" => "text/plain; charset=utf-8" }.freeze

  def test_recognises_the_lock
    assert_equal BODY.strip, L.message_from_response(503, TEXT, BODY)
    assert_equal BODY.strip, L.message_from_response("503", { ":status" => "503", "content-type" => "text/plain; charset=utf-8" }, BODY.b)
    assert_equal BODY.strip, L.message_from_response(503, {}, BODY)
  end

  def test_other_answers_are_no_lock
    assert_nil L.message_from_response(200, TEXT, BODY)
    assert_nil L.message_from_response(500, TEXT, BODY)
    assert_nil L.message_from_response(503, { "Content-Type" => "application/json" }, "{\"success\":false}")
    assert_nil L.message_from_response(503, TEXT, "{\"success\":false}")
    assert_nil L.message_from_response(503, { "Content-Type" => "text/html" }, "<html><body>503 Service Temporarily Unavailable</body></html>")
    assert_nil L.message_from_response(503, TEXT, "")
    assert_nil L.message_from_response(503, TEXT, "x" * 5000)
  end

  def test_localized
    assert_equal "Dieser Klango-Server hat keine g\u00fcltige Lizenz. Bitte wende dich an den Betreiber dieses Servers.", L.localized(BODY, "de-DE")
    assert_equal "This Klango server has no valid license. Please contact the operator of this server.", L.localized(BODY, "en-GB")
    assert_equal "This Klango server has no valid license. Please contact the operator of this server.", L.localized(BODY, "pl-PL")
    assert_equal "One line only", L.localized("One line only\n(stale)", "de-DE")
    assert_equal "A B C", L.localized("A\nB\nC", "en")
  end

  def test_announced_once_per_lock
    refute L.locked?
    assert_nil L.take_announcement
    L.report("locked")
    assert L.locked?
    assert_equal "locked", L.take_announcement
    assert_nil L.take_announcement
    L.report("locked")
    assert_nil L.take_announcement
    L.clear
    refute L.locked?
    L.report("locked again")
    L.mark_announced
    assert_nil L.take_announcement
    assert_equal "locked again", L.message
  end
end
