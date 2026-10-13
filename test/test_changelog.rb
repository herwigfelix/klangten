# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Help, Changelog (src/scenes/changes.rb) lists only the versions in its own
# table; a changelog file without a row there is never shown (0.4.1 was
# released that way). Every Klangten changelog needs its row, and the version
# being released needs a changelog.

require "minitest/autorun"

class TestChangelog < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def listed_versions
    File.read(File.join(ROOT, "src/scenes/changes.rb")).scan(/^\["(0\.\d+)", "[\d-]+", Klangten::Config::PRODUCT_NAME\]/).flatten
                                                       .map { |v| v.delete(".").chars.join("_") }
  end

  def test_every_changelog_is_listed
    %w[en-GB de-DE].each do |lang|
      files = Dir[File.join(ROOT, "locale", lang, "changelog", "0_*.md")].map { |f| File.basename(f, ".md") }
      assert_empty files - listed_versions, "#{lang}: changelog files missing in src/scenes/changes.rb"
    end
  end

  def test_the_current_version_has_a_listed_changelog
    version = File.read(File.join(ROOT, "src/eltenlink/klangten_config.rb"))[/VERSION = "([\d.]+)"/, 1]
    name = version.sub(/\.0\z/, "").tr(".", "_")
    assert_includes listed_versions, name
    assert File.file?(File.join(ROOT, "locale/en-GB/changelog/#{name}.md"))
    assert File.file?(File.join(ROOT, "locale/de-DE/changelog/#{name}.md"))
  end
end
