# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Forum fixtures shared by the forum flow tests: data is created through the
# same JSON API the client speaks, as the users themselves.

module ForumWorld
  F = "/api/v1/forum"

  # Group "Testgruppe" by anna with hans as member, one forum, one thread.
  # type: 0 text, 1 voice, 2 mixed.
  def forum_world(type: 0, forum: "Plauderecke")
    server.create_user("hans", "anna")
    gid = server.api("POST", "#{F}/groups", { name: "Testgruppe", description: "Zum Testen", lang: "en", public: 1, open: 1 }, as: "anna")["id"]
    server.api("POST", "#{F}/group/#{gid}/membership", {}, as: "hans")
    fid = server.api("POST", "#{F}/group/#{gid}/forums", { name: forum, type: type }, as: "anna")["forumid"]
    thread = server.api("POST", F, { forum: fid, thread_name: "Hallo Welt", text: "Erster Beitrag" }, as: "anna")["id"]
    { group: gid, forum: fid, thread: thread }
  end

  # Logged in as hans, inside the thread "Hallo Welt".
  def open_thread(forum: "Plauderecke")
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Community", "Forum")
    k.expect("Testgruppe")
    k.press("right")
    k.move_to(forum, key: "down")
    k.press("right")
    k.expect("Hallo Welt")
    k.press("enter")
    k
  end
end
