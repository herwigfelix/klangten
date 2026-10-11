# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Fixtures of the Klango community flow tests (media catalog, polls, notes,
# persons, group messages): created through the JSON API as the users
# themselves, catalog entries and roles directly in the server database (the
# API has no way to create public catalog entries).

module KCommunityWorld
  F = "/api/v1/forum"

  # A Klango group founded by anna (moderator) with the given members.
  def kc_group(name: "Runde", members: ["hans"])
    gid = server.api("POST", "#{F}/groups", { name: name, description: "Zum Testen", lang: "en", public: 1, open: 1 }, as: "anna")["id"]
    members.each { |member| server.api("POST", "#{F}/group/#{gid}/membership", {}, as: member) }
    gid
  end

  # A public catalog entry; type 3 radio, 11 web page. Returns its id.
  def kc_entry(title, url, type: 3)
    server.sql("INSERT INTO catalog_entities (title, description, keywords, lang, entity_type_id, url, www, bitrate, klangoid, flak, created)" \
               " VALUES (?, 'Test', 'test', 'de', ?, ?, '', '', 'klango', '0', 1)", title, type, url)
    server.sql("SELECT entity_id FROM catalog_entities WHERE title = ?", title)[0][0]
  end

  # Logged in as hans, on the home list of the media catalog.
  def kc_catalog
    k = klangten(server: server)
    k.boot_logged_in("hans")
    k.menu("Media", "Media catalog")
    k.expect("Media catalog")
    k
  end
end
