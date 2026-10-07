# Changelog

## 0.2.2-beta1

### Loot history

- If your account has history for another guild, the History window shows a guild picker at the left of its title bar. It lists your current guild by name first, then the others. Picking another guild shows its history read-only: no Add Entry, deleting or pinning, and it's never synced. Reopening the window goes back to your own guild.

### Loot responses

- Response sets are now saved as named profiles shared by every character on your account. "Default" always exists and can't be deleted. Profiles are managed on the Loot Responses settings page, and the separate Profiles page is gone.

### Sounds

- The default soft-reserve alert is now Blizzard's Battle.net toast. The bundled Sonic Ring sound was removed, and anyone who had it selected moves to the new default.

## 0.2.1 (pre-release)

### Loot history sync

- **Each guild now has its own loot history.** Before, every character on an account shared one history, so a raider whose alt was in another guild using ForeverLoot brought that guild's history back into yours and sync spread it to everyone. Now each guild's history is kept separately, and only your current guild's history is shown and synced.
- Your existing history belongs to the first guild you log into after updating (one chat line says so). Log your main first.
- Awards from a loot council run by another guild's raid leader are kept in that guild's history on your client, not in your guild's, and never synced.
- History sync and live award updates are only accepted from members of your own guild.
- Sync protocol bumped: 0.2.0 clients and 0.2.1 clients no longer sync with each other. Everyone in the guild needs to update.
- Rows from other guilds that already reached your history are not removed. Officers can delete them from the History window.

## 0.2.0 (pre-release)

### Trade Queue

- With EllesmereUI Bags or Baganator enabled, items waiting in the Trade Queue now glow in your bags, in the item's quality color. Toggle it in Settings > General > Trade Queue (on by default; greyed out without either bag addon). In Baganator the glow is listed as a corner widget ("ForeverLoot: Trade Queue glow") in its Corners settings; keep it at the top of its corner.

### Loot history sync

- Loot history now syncs across the whole guild. Awards, deletes and pins are sent live to everyone online, and anyone who was offline catches up automatically the next time they log in (outside instances, out of combat). The first login after updating may take a few minutes to catch up.
- **Only officers can delete history rows.** Deletes spread to every guild member's history.
- Rows older than 4 months are pruned automatically at the start of each month. Pinned rows ("keep forever") are never pruned.
- Raid members who join late, reload or disconnect during a loot council session catch up to the leader's current session state within seconds.
- A loot council session you missed the end of (you were offline when the leader ended it) no longer stops you from starting a new one. A session counts as finished once its leader isn't in your group, and the leader's own unended session expires after 12 hours.
- If you miss the end of a loot council session and log back in while still in the leader's raid, your copy is now corrected to ended within seconds. Before, the leader only answered your catch-up request some of the time, so the session could stay stuck as active for a long while.
- Loot council catch-up on login, /reload and joining a group now works in a 5-man party, not just in a raid.
- Loot council catch-up no longer needs you to be in a guild, so pugs catch up too. Guild history sync still does.
- Debug log lines are rewritten in plain words (`area: what happened · details`), with reply times on sync requests and a visible line when a reply arrives too late to count. Council, roll and softres debug lines moved from `/fl commdebug` into `/fl debug` (new categories COUNCIL, ROLL, SOFTRES; `SNAP` is now COUNCIL). See `docs/debug-logs.md`.
- The Debug Log window (`/fl debug log`) has a toolbar: debug on/off, level, category mute list, clear, sync history / council session now, network probe, and the test-data tools (generate, drop, purge, wipe). It updates live while open.
- If a guildmate runs a newer ForeverLoot, you'll see one chat line telling you an update is available.
- New slash commands for troubleshooting: `/fl sync status`, `/fl sync digest`, `/fl debug log`. Debug output is off by default.
- New **Sync** settings page. Turn automatic sync off, or pause it until your next login (a /reload keeps it paused), and press Sync Now to compare right away. The page shows live status, active transfers with progress bars, speed and time left, the guild members you sync with and their versions, your local history, and a log of recent syncs. With sync off or paused, your client sends no sync traffic at all, but new awards are still shared live. While the page is open, it checks with your peers every 30 seconds, so the peer list stays current.
