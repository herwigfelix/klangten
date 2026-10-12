# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# A message to the members of a Klango group (src/scenes/groupmessage.rb) and
# sharing forum threads and blog posts on Mastodon (feeds.rb helpers).

require_relative "../test_helper"
require_relative "kcommunity_world"

class KCommunityGroupMessageTest < KlangtenTest::FlowTest
  include KCommunityWorld

  def test_message_to_the_members_of_a_group
    server.create_user("hans", "anna", "grete")
    kc_group(members: ["hans", "grete"])
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Messages")
    # the list is announced once it has loaded; a key pressed before that is lost
    k.wait_for("Empty list")
    k.menu("Context menu", "Message to the members of a group")
    k.expect("Send a message to the members of which group?")
    k.expect("Runde")
    k.press("enter")
    k.expect("Message to the members of Runde")
    k.type("Treffen am Freitag")
    k.move_to("Send")
    k.press("enter")
    k.expect("The message has been sent to 2 people.")
    rows = server.sql("SELECT m.sender, r.recipient, m.subject, m.body FROM msg m JOIN msg_rcpt r ON r.msg_id = m.id ORDER BY r.recipient")
    assert_equal [["hans", "anna", "[Runde]", "Treffen am Freitag"], ["hans", "grete", "[Runde]", "Treffen am Freitag"]], rows
  end

  # The Mastodon compose dialog itself is covered elsewhere; here it is
  # replaced to see what the share actions hand to it.
  def stub_compose(k)
    k.call do
      $kcommunity_shared = []
      EltenAPI::EltenSRV.send(:define_method, :mastodon_compose) do |reply_to: nil, text: nil|
        $kcommunity_shared << text
        :posted
      end
    end
  end

  def test_share_a_forum_thread_on_mastodon
    server.create_user("hans", "anna")
    gid = kc_group
    fid = server.api("POST", "#{F}/group/#{gid}/forums", { name: "Plauderecke", type: 0 }, as: "anna")["forumid"]
    thread = server.api("POST", F, { forum: fid, thread_name: "Hallo Welt", text: "Erster Beitrag" }, as: "anna")["id"]
    k = klangten(server: server)
    k.boot_logged_in("hans")
    stub_compose(k)
    shared = k.call do
      mastodon_share_forum_thread(thread)
    end
    if !shared
      # a group forum: Klangten asks first, because outsiders cannot read it
      k.expect("Only members of its group can read this thread.")
      k.press("down")
      k.expect("Yes")
      k.press("enter")
    end
    texts = k.call { $kcommunity_shared }
    assert_equal 1, texts.size
    assert_match %r{\AHallo Welt https?://\S+/topic/#{thread}\z}, texts[0]
  end

  def test_share_link_helper
    server.create_user("hans")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    stub_compose(k)
    assert_equal true, k.call { mastodon_share_link("Mein Beitrag", "https://hans.example.org/?p=1") }
    assert_equal false, k.call { mastodon_share_link("Ohne Adresse", "") }
    assert_equal ["Mein Beitrag https://hans.example.org/?p=1"], k.call { $kcommunity_shared }
  end
end
