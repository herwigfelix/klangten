# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Private messages (src/scenes/messages.rb): writing a text message ends up
# in the server database with sender, recipient, subject and text.

require_relative "../test_helper"

class MessagesTest < KlangtenTest::FlowTest
  def test_send_a_text_message
    server.create_user("hans", "grete")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Messages")
    k.expect("Messages: Empty list")
    k.press("ctrl+n")
    k.expect("Recipient")
    k.type("grete")
    k.press("tab")
    k.expect("Subject")
    k.type("Gruss")
    k.press("tab")
    k.expect("Message")
    k.type("Hallo Grete!")
    k.move_to("Send")
    k.press("enter")
    k.expect("The message has been sent")
    rows = server.sql("SELECT m.sender, r.recipient, m.subject, m.body FROM msg m JOIN msg_rcpt r ON r.msg_id = m.id")
    assert_equal [["hans", "grete", "Gruss", "Hallo Grete!"]], rows
    # grete finds it in her inbox, unread.
    assert_equal [[0]], server.sql("SELECT is_read FROM msg_state WHERE owner = 'grete' AND folder = 'inbox'")
    assert server.requests.any? { |method, path, status| method == "POST" && path.start_with?("/api/v1/messages") && status == 200 }
  end
end
