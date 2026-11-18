# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The text browser (src/scenes/webbrowser.rb) against pages on a local web
# server: reading, Tab between links, following a link, Backspace back and
# Shift+Backspace forward, a link to a file, links to other programs. The full browser needs Chrome
# for Testing and is not part of the automatic tests (tools/web-probe.rb).

require_relative "../test_helper"

class WebBrowserTest < KlangtenTest::FlowTest
  def site
    web = fake_web
    web.text("/index.html", <<~HTML, mime: "text/html")
      <html><head><title>Startseite</title></head><body>
      <h1>Willkommen bei Klangten</h1>
      <p>Hier steht ein Absatz.</p>
      <p><a href="/zwei.html">Zur zweiten Seite</a> und <a href="/datei.zip">eine Datei</a></p>
      </body></html>
    HTML
    web.text("/zwei.html", <<~HTML, mime: "text/html")
      <html><head><title>Zweite Seite</title></head><body>
      <h1>Die zweite Seite</h1><p>Noch ein Absatz.</p>
      </body></html>
    HTML
    web.file("/datei.zip", "PK\x03\x04".b + "x".b * 100, mime: "application/zip")
    web
  end

  def open_text_browser(k, url)
    k.call(settle: false) do
      KlangtenWeb.prefer_text_browser = true
      KlangtenWeb.downloads_dir = File.join(work_dir, "downloads")
      Dir.mkdir(KlangtenWeb.downloads_dir) unless Dir.exist?(KlangtenWeb.downloads_dir)
      Scene_WebBrowser.open_url(url)
    end
    k.settle
  end

  def test_read_follow_links_and_go_back
    web = site
    k = klangten
    k.boot
    k.expect("Log in", since: 0)
    open_text_browser(k, web.url("/index.html"))
    k.expect("Startseite")
    k.expect("Willkommen bei Klangten")
    # Reading the page aloud took the cursor to its end; start at the top.
    k.press("ctrl+home")
    k.press("tab")
    k.expect("Zur zweiten Seite")
    k.press("enter")
    k.expect("Zweite Seite")
    k.expect("Die zweite Seite")
    k.press("backspace")
    k.expect("Startseite")
    k.press("shift+backspace")
    k.expect("Zweite Seite")
    assert_equal ["/index.html", "/zwei.html"], web.requests.map(&:path).uniq.first(2)
    k.press("esc")
    k.settle
  end

  # A page must not open files or start programs on the computer unasked:
  # the system would open such links with whatever program it has for them.
  def test_links_to_other_programs_are_not_opened_unasked
    web = fake_web
    web.text("/links.html", <<~HTML, mime: "text/html")
      <html><head><title>Links</title></head><body>
      <h1>Fremde Links</h1>
      <p><a href="file:///etc/passwd">Lokale Datei</a> <a href="ms-settings:privacy">Fremdes Programm</a> <a href="mailto:jemand@example.org">Post</a></p>
      </body></html>
    HTML
    opened = []
    original = nil
    k = klangten
    k.boot
    k.expect("Log in", since: 0)
    original = ::EltenSystemHelpers.method(:open_url)
    ::EltenSystemHelpers.define_singleton_method(:open_url) { |url| opened << url.to_s; true }
    open_text_browser(k, web.url("/links.html"))
    k.press("ctrl+home")
    k.press("tab")
    k.expect("Lokale Datei")
    k.press("enter")
    k.expect("This link cannot be opened from a web page: file:///etc/passwd")
    assert_empty opened
    k.press("tab")
    k.expect("Fremdes Programm")
    k.press("enter")
    k.expect("This link opens another program on your computer: ms-settings:privacy. Do you want to open it?")
    k.press("enter") # No is the default
    assert_empty opened
    k.press("enter")
    k.expect("Do you want to open it?")
    k.press("down")
    k.expect("Yes")
    k.press("enter")
    k.settle
    assert_equal ["ms-settings:privacy"], opened
    k.press("tab")
    k.expect("Post")
    k.press("enter")
    k.settle
    assert_equal ["ms-settings:privacy", "mailto:jemand@example.org"], opened
  ensure
    ::EltenSystemHelpers.define_singleton_method(:open_url, original) if original != nil
  end

  def test_link_to_a_file_is_downloaded
    web = site
    k = klangten
    k.boot
    k.expect("Log in", since: 0)
    open_text_browser(k, web.url("/index.html"))
    k.press("ctrl+home")
    k.press("tab")
    k.press("tab")
    k.expect("eine Datei")
    k.press("enter")
    k.expect("datei.zip is not a web page")
    k.press("enter") # Yes is the default
    k.expect("Saved as datei.zip")
    assert File.file?(File.join(work_dir, "downloads", "datei.zip"))
  end
end
