# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Data kept on this device (src/eapi/local_store.rb): the media play history
# and the local notes, inside a real (offline) Klangten.

require_relative "../test_helper"

class KCommunityLocalTest < KlangtenTest::FlowTest
  def run_in_klangten(&block)
    k = klangten
    k.start(&block)
    k.settle
    k.result
  end

  def test_media_history
    result = run_in_klangten do
      stub = proc { |id, title, type = "radio"| EltenLink::Media.stub_item(id: id, title: title, type: type, url: "http://example.org/#{id}") }
      Klangten::MediaHistory.add(stub.call(1, "Eins"))
      Klangten::MediaHistory.add(stub.call(2, "Zwei", "podcast"))
      Klangten::MediaHistory.add(stub.call(1, "Eins"))
      Klangten::MediaHistory.add(id: 0, url: "http://stream.example.org/live")
      order = Klangten::MediaHistory.entries.map(&:title)
      podcast = Klangten::MediaHistory.entries.find { |e| e.id == 2 }
      (3..105).each { |i| Klangten::MediaHistory.add(stub.call(i, "Nr #{i}")) }
      size = Klangten::MediaHistory.entries.size
      Klangten::MediaHistory.remove(Klangten::MediaHistory.entries.first)
      after_remove = Klangten::MediaHistory.entries.first.id
      Klangten::MediaHistory.clear
      [order, podcast.type, size, after_remove, Klangten::MediaHistory.entries.size,
       File.file?(File.join(Dirs.eltendata, "local", "guest", "media_history.json"))]
    end
    order, type, size, after_remove, cleared, stored = result
    assert_equal ["http://stream.example.org/live", "Eins", "Zwei"], order
    assert_equal "podcast", type
    assert_equal 100, size
    assert_equal 104, after_remove
    assert_equal 0, cleared
    assert stored, "kept per account (guest without login)"
  end

  def test_stub_items
    result = run_in_klangten do
      radio = EltenLink::Media.stub_item(id: 5, title: "Radio", type: "radio", url: "http://example.org/r")
      feed = EltenLink::Media.stub_item(id: 6, title: "Cast", type: "podcast", url: "http://example.org/f.xml")
      page = EltenLink::Media.stub_item(id: 7, title: "Seite", type: "webpage", url: "https://example.org/")
      typed = EltenLink::Media.stub_item(url: "http://x.example.org/s")
      [radio.stream_url, feed.feed_url, feed.stream_url, page.stream_url, typed.stream?, typed.rating_count]
    end
    assert_equal ["http://example.org/r", "http://example.org/f.xml", "", "", true, 0], result
  end

  def test_local_notes
    result = run_in_klangten do
      note = Klangten::LocalNotes.create("Einkauf", "Brot\nMilch")
      second = Klangten::LocalNotes.create("Zweite", "x")
      order = Klangten::LocalNotes.all.map(&:name)
      Klangten::LocalNotes.update(note.id, text: "Brot")
      text = Klangten::LocalNotes.find(note.id).text
      missing = Klangten::LocalNotes.update("nope", text: "x")
      deleted = [Klangten::LocalNotes.delete(second.id), Klangten::LocalNotes.delete(second.id)]
      [order, text, missing, deleted, Klangten::LocalNotes.all.map(&:name)]
    end
    assert_equal [["Zweite", "Einkauf"], "Brot", nil, [true, false], ["Einkauf"]], result
  end

  def test_broken_file_reads_as_empty
    result = run_in_klangten do
      path = Klangten::LocalStore.path(Klangten::LocalNotes::FILE)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{kaputt")
      broken = Klangten::LocalNotes.all.size
      File.write(path, "\r\n[{\"id\":\"a\",\"name\":\"CRLF\",\"text\":\"t\"}]\r\n")
      [broken, Klangten::LocalNotes.all.map(&:name)]
    end
    assert_equal [0, ["CRLF"]], result
  end
end
