# Debug logs

Every line ForeverLoot writes to the debug log (`/fl debug`, `/fl debug log`). The table at the bottom is generated from the code, so the `Where` column is accurate as of 2026-10-04.

## Line format

```
FL HH:MM:SS.mmm [CAT] <area>: <what happened> · <details>
```

- **Area** says what the line is about: `council`, `history`, `sync with Bolvar (#a3F9)` (a history sync session, with its token), `session #12`, or a debug command name (`roundtrip history`, `probe #Xy3k`). It's left out where the category already says it, as in most GATE lines.
- **What happened** is a short sentence that makes sense on its own. Failures and surprises are written in capitals so they stand out: `FAILED`, `MISMATCH`, `STILL DIFFERENT`, `DENIED`.
- **Details** come after ` · ` as comma-separated words. There are no `key=value` codes.
- **Times** always use `Debug.FormatTime`, so they look like `340ms`, `4.2s` or `2m05s`. Sizes use `Debug.FormatBytes`.
- **Names** are bare, never quoted. Domains are `history` and `council` (`Debug.DomainName`), never `d1`/`d2`.
- **Only Latin-1 characters**, because WoW's chat font renders `·` but not `→`.

| Lvl | Meaning |
|---|---|
| 1 | Normal. One line per meaningful event. |
| 2 | Verbose. Per-message or per-batch detail. |
| 3 | Very verbose. Per-row writes and hashes. |
| W / E | Warning / error. Always saved to the buffer, even with debug off. |

## Categories

| Cat | Covers |
|---|---|
| GATE | When history sync, guild award updates (live award/pin/delete broadcasts) and council sync are allowed to run, and what's being held |
| PEERS | Finding peers: the "what do you have?" check (HELLO) and its replies, with reply times |
| COUNCIL | Loot council sessions (start, answers, votes, awards, end) and their catch-up sync. Replaces `SNAP` and the old `/fl commdebug` council lines. |
| SESS | Guild history sync sessions with one peer |
| LIVE | Live award, pin and delete broadcasts to the guild |
| PERM | Officer permission checks |
| COMM | The wire: sends, receives, queues, drops, and Gargul-channel traffic (level 2) |
| CODEC | Encoding and decoding |
| STORE, DIGEST, DOMAIN, PRUNE, ITEM | Local history data: writes, hashes, retention, item info |
| ROLL | Roll-offs. Was `/fl commdebug`. |
| SOFTRES | Softres import and sharing. Was `/fl commdebug`. |
| SCHED, PERF | Timers, the task queue, slow tasks |
| TEST | Debug commands and self-tests |

`/fl commdebug` is retired. It now prints where those lines went.

## Debug Log window

`/fl debug` (or `/fl debug log`) opens the log, with a toolbar for the common commands:

| Row | Buttons |
|---|---|
| LOGGING | **Debug: On/Off** · **Level** (click to cycle Normal -> Verbose -> Very verbose, colored green/yellow/red) · **Categories** dropdown (click a category to mute or unmute it; "All categories" toggles every one) · **Clear** |
| SYNC | **Sync History** (`forcehello`) · **Sync Loot Council Session** (`forcehello raid`) · **Network Probe...** (popup, prefilled with your group, 20 messages, 2/s, 20 bytes) |
| TEST DATA | **Test Data: Enabled/Disabled** · **Generate...** (popup: count, old or not) · **Drop Test Rows...** (popup: count; test rows only) · **Purge Test Rows** · **Wipe History...** (asks first) |

Each `[CAT]` tag is shown in its category's color (`Debug.CATEGORIES` in Sync/Debug.lua), in chat, the log and the Categories dropdown; WARN is yellow and ERR red. The saved log stays plain text: the window switches to plain text while you're selecting, so Ctrl+C copies no color codes.

Generate and Drop are disabled until test data is on, same as their slash commands. The log repaints itself while the window is open and stays scrolled to the bottom. It waits while you're selecting text.

## Example: a raider who missed a session end logs back in

```
[PEERS]   council: asked party what they have · trigger login, carrying council #12 active rev 9, leader Anduin, 58B
[PEERS]   council: no replies within 12s · retrying in 30s (attempt 2/3, urgent)
[PEERS]   council: reply from Anduin arrived late, ignored (14.8s after asking, window was 12s) · council they have newer (...)
[PEERS]   council: reply from Anduin in 3.4s · council they have newer (theirs #12 ended rev 11, leader Anduin; mine #12 active rev 9, leader Anduin)
[PEERS]   council: 1 reply within 12s · Anduin 3.4s
[COUNCIL] sync: Anduin has a newer copy · theirs #12 ended rev 11, leader Anduin; mine #12 active rev 9, leader Anduin
[COUNCIL] sync: requested session from Anduin (attempt 1/2)
[COUNCIL] session #12 replaced by a synced copy · 6 items, ended
[COUNCIL] sync: applied Anduin's session · rev 9 -> 11, now ended, reply took 6.1s
```

On the leader's side:

```
[PEERS]   council: Bolvar asked what we have · council they're behind (theirs #12 active rev 9, ...; mine #12 ended rev 11, ...)
[PEERS]   council: replying to Bolvar in 2.1s · council differs, I'm the session leader (always reply)
[COUNCIL] sync: Bolvar asked for our session
[COUNCIL] sync: sent session to Bolvar · rev 11, 6 items, 1.2KB
```

## All lines

### GATE

| Lvl | Message | Where |
|---|---|---|
| 1 | `(built by describeState)` | Sync/Gate.lua:120 |
| 1 | `holding %s until the %s gate opens · %s, %d waiting` | Sync/Gate.lua:139 |
| 1 | `released %d held message%s · after %s, oldest waited %s%s` | Sync/Gate.lua:174 |
| 1 | `(built by describeState)` | Sync/Gate.lua:236 |

### PEERS

| Lvl | Message | Where |
|---|---|---|
| 2 | `council: didn't ask (%s) · already waiting on replies` | Sync/Coordinator.lua:259 |
| 1 | `%s: skipped periodic check · a matching peer was heard %s ago` | Sync/Coordinator.lua:289 |
| 1 | `history: skipped periodic check · a sync is already running` | Sync/Coordinator.lua:299 |
| 1 | `%s runs ForeverLoot %s · protocol %s%s` | Sync/Peers.lua:105 |
| 1 | `%s has a newer ForeverLoot · theirs %s, mine %s` | Sync/Peers.lua:113 |
| 2 | `now tracking %s · %d known peers` | Sync/Peers.lua:156 |
| 2 | `forgot %s · silent for %s, %d known peers` | Sync/Peers.lua:191 |
| 2 | `%s: didn't ask · not in a group` | Sync/Peers.lua:316 |
| 1 | `%s: didn't ask · gate closed` | Sync/Peers.lua:321 |
| 1 | `%s: asked %s what they have · trigger %s%s, carrying %s, %s` | Sync/Peers.lua:336 |
| 1 | `%s: %s%s · %s` | Sync/Peers.lua:433 |
| 1 | `%s: not replying to %s · already in sync` | Sync/Peers.lua:444 |
| 1 | `%s: not replying to %s · gate closed (%s differs)` | Sync/Peers.lua:456 |
| 1 | `%s: leaving %s to others · lost reply roll (%s)` | Sync/Peers.lua:481 |
| 1 | `%s: replying to %s in %s · %s differs, %s` | Sync/Peers.lua:487 |
| 1 | `%s: %d repl%s within %ds · %s` | Sync/Peers.lua:551 |
| 1 | `%s: no replies within %ds · retrying in %ds (attempt %d/%d, urgent)` | Sync/Peers.lua:581 |
| 1 | `%s: no replies within %ds · gave up after %d tries` | Sync/Peers.lua:584 |
| 1 | `history: status check sent · trigger %s, %s` | Sync/Peers.lua:618 |

### COUNCIL

| Lvl | Message | Where |
|---|---|---|
| 2 | `session #%d changed · %s, rev %d -> %d` | Data/CouncilSessionDomain.lua:109 |
| 1 | `session #%d ended · no longer advertised to the group` | Data/CouncilSessionDomain.lua:113 |
| 1 | `sync: not advertising session #%d · it has ended` | Data/CouncilSessionDomain.lua:145 |
| 1 | `%s %s %s on %s` | LootCouncil.lua:1062 |
| 1 | `couldn't start the trade with %s · %s, added to the trade queue` | LootCouncil.lua:1365 |
| 1 | `%s awarded %s to %s` | LootCouncil.lua:1484 |
| 1 | `session #%d ended by %s` | LootCouncil.lua:1550 |
| 1 | `session #%d ended early by %s · %d items left unassigned` | LootCouncil.lua:1656 |
| 1 | `session #%d replaced by a synced copy · %d items, %s` | LootCouncil.lua:1744 |
| 2 | `sent %s · to %s` | LootCouncil.lua:236 |
| 2 | `got %s from %s · via %s` | LootCouncil.lua:285 |
| 1 | `session #%d started by %s · %d items` | LootCouncil.lua:580 |
| 1 | `session #%d: %s added %d item%s · now %d items` | LootCouncil.lua:626 |
| 1 | `%s answered "%s" on %s` | LootCouncil.lua:912 |
| W | `sync: gave up waiting for %s's session · no answer after %d tries over %s` | Sync/Coordinator.lua:144 |
| 1 | `sync: no session from %s within %ds · asking again` | Sync/Coordinator.lua:148 |
| 1 | `sync: requested session from %s (attempt %d/2)` | Sync/Coordinator.lua:154 |
| 1 | `sync: nothing to send %s · no session for this group` | Sync/Coordinator.lua:162 |
| 1 | `sync: sent session to %s%s · rev %d, %d items, %s` | Sync/Coordinator.lua:167 |
| 1 | `sync: %s %s · theirs %s; mine %s` | Sync/Coordinator.lua:185 |
| 1 | `sync: ignored session request from %s · not in our group` | Sync/Coordinator.lua:211 |
| 2 | `sync: %s asked for our session` | Sync/Coordinator.lua:214 |
| 1 | `sync: applied %s's session · rev %d -> %d, now %s%s` | Sync/Coordinator.lua:234 |
| 1 | `sync: kept ours over %s's session · theirs isn't newer (rev %d vs our %d)%s` | Sync/Coordinator.lua:237 |
| 1 | `sync: rejected %s's session · %s%s` | Sync/Coordinator.lua:240 |

### SESS

| Lvl | Message | Where |
|---|---|---|
| 1 | `history sync: moved %d buckets from %s to %s · %s` | Sync/Session.lua:1083 |
| 1 | `history sync: %s finished early, gave %d more buckets to %s` | Sync/Session.lua:1087 |
| 1 | `%s: asking to pull %d buckets · helper for the main sync` | Sync/Session.lua:1115 |
| 2 | `%s: keep-alive · waiting on %d helpers` | Sync/Session.lua:1152 |
| 1 | `history sync plan: main peer %s, helpers %s · buckets %s` | Sync/Session.lua:1193 |
| 1 | `%s: done, %s · sent %d, got %d rows, %d pins/deletes, %d buckets, %s` | Sync/Session.lua:1257 |
| W | `%s: %s never confirmed we're done · sent it %d times` | Sync/Session.lua:1261 |
| 1 | `history sync finished · %d peer%s, %d rows in %s, %d rows/min` | Sync/Session.lua:1276 |
| 1 | `%s: no reply to done · sending it again (try %d)` | Sync/Session.lua:1306 |
| 1 | `%s: %d bucket%s differ · %s` | Sync/Session.lua:1369 |
| W | `%s: gave up comparing %s history · no answer after %d tries` | Sync/Session.lua:1427 |
| 1 | `%s: no answer comparing %s history · asking again (retry %d/%d)` | Sync/Session.lua:1431 |
| 2 | `%s: compared %s months · mine %d, theirs %d, differ %s` | Sync/Session.lua:1532 |
| 1 | `%s: ignored request · sync is off or paused here` | Sync/Session.lua:1614 |
| 1 | `%s: refused · gate closed here` | Sync/Session.lua:1629 |
| 1 | `%s: refused · already serving %d, told them to retry in %ds` | Sync/Session.lua:1636 |
| 1 | `%s: refused · we both opened at once, keeping ours (#%s)` | Sync/Session.lua:1666 |
| 1 | `%s: accepted, serving them · %s sync%s, now serving %d/%d` | Sync/Session.lua:1686 |
| 1 | `%s: they refused · we both opened at once, theirs wins` | Sync/Session.lua:1702 |
| 1 | `%s: they refused · %s%s` | Sync/Session.lua:1712 |
| 1 | `history sync: %s is the new main peer · %s %s` | Sync/Session.lua:1740 |
| 2 | `%s: ignored an old archive-months reply · round %s, now on %d` | Sync/Session.lua:1789 |
| 2 | `%s: ignored an old days reply · round %s, now on %d` | Sync/Session.lua:1817 |
| 2 | `%s: got batch %d · %d rows: %d new, %d already had, %d rejected` | Sync/Session.lua:1880 |
| 2 | `%s: got batch %d · %d pins/deletes: %d deletes applied, %d pins added` | Sync/Session.lua:1885 |
| 1 | `%s: not done yet · %d buckets incomplete, asked them to resend` | Sync/Session.lua:1959 |
| 1 | `%s: done, %s · sent %d, got %d rows, %d pins/deletes, %d buckets, %s` | Sync/Session.lua:1972 |
| 1 | `%s: they replied to done · %d buckets still pending, resent %d` | Sync/Session.lua:2011 |
| 2 | `history sync: not starting one with %s · one is already running` | Sync/Session.lua:2071 |
| 2 | `history sync: not starting one with %s · gate closed` | Sync/Session.lua:2075 |
| 1 | `history sync: not starting one with %s · already serving them` | Sync/Session.lua:2081 |
| 1 | `%s: asking to start · full sync` | Sync/Session.lua:2103 |
| 1 | `%s: stopped early · %s, while %s, %s buckets done` | Sync/Session.lua:426 |
| 1 | `%s: %s -> %s` | Sync/Session.lua:470 |
| 2 | `%s: sending batch %d · %d %s, %s, prefix %s` | Sync/Session.lua:583 |
| 2 | `%s: sent batch %d · took %s` | Sync/Session.lua:588 |
| W | `%s: batch %d is slow to send · waiting up to %ds more (prefix %s)` | Sync/Session.lua:596 |
| W | `%s: batch %d FAILED to send (prefix %s)` | Sync/Session.lua:601 |
| 2 | `%s: slow batch %d finally %s · after %s` | Sync/Session.lua:605 |
| W | `%s: hash collision in %s %s · comparing full id lists instead` | Sync/Session.lua:657 |
| W | `%s: gave up on bucket %s · no hashes after %d tries` | Sync/Session.lua:698 |
| 1 | `%s: no hashes for bucket %s yet · asking again (retry %d/%d)` | Sync/Session.lua:701 |
| 2 | `%s: bucket %s compared · mine %d, theirs %d, need %d, giving %d` | Sync/Session.lua:751 |
| W | `%s: gave up on bucket %s · rows never came after %d tries` | Sync/Session.lua:822 |
| 1 | `%s: rows for bucket %s haven't come · asking again (retry %d/%d)` | Sync/Session.lua:825 |
| 2 | `%s: skipped bucket %s · nothing here to give, another peer covers it` | Sync/Session.lua:943 |

### LIVE

| Lvl | Message | Where |
|---|---|---|
| 1 | `sent award %s to the guild%s%s` | Sync/Live.lua:115 |
| 1 | `sent %s of row %s to the guild%s` | Sync/Live.lua:132 |
| 1 | `rejected award from %s · row %s: %s` | Sync/Live.lua:256 |
| 1 | `got award %s from %s · %s%s` | Sync/Live.lua:282 |
| 1 | `got %s of row %s from %s · %s` | Sync/Live.lua:312 |
| 1 | `rejected %s from %s · %s` | Sync/Live.lua:326 |
| 1 | `resending %s to %s by whisper · first send failed (%s)` | Sync/Live.lua:89 |

### PERM

| Lvl | Message | Where |
|---|---|---|
| 1 | `%s %s for %s · rank %s%s` | Sync/Live.lua:171 |
| 1 | `rejected %s from %s · it claims to be from %s` | Sync/Live.lua:293 |
| 1 | `rejected %s from %s · not an officer (rank %s)` | Sync/Live.lua:304 |

### COMM

| Lvl | Message | Where |
|---|---|---|
| 2 | `got %s on the Gargul channel from %s · via %s` | Comm.lua:109 |
| 2 | `sent %s on the Gargul channel · to %s` | Comm.lua:55 |
| 2 | `sending %s %s · %s in %d piece%s, %s priority, prefix %s` | Net/Transport.lua:251 |
| W | `FAILED to send %s %s · %s, queued %s, sending took %s, prefix %s` | Net/Transport.lua:279 |
| 2 | `sent %s %s · %s, queued %s, sending took %s` | Net/Transport.lua:283 |
| W | `dropped incomplete message from %s · only %d of %d pieces arrived (prefix %s)` | Net/Transport.lua:310 |
| W | `%s is flooding us · dropped %d %s messages` | Net/Transport.lua:395 |
| W | `gave up sending %s %s · stuck in the send queue for %ds (prefix %s)` | Net/Transport.lua:495 |
| 2 | `sending %s on the real guild channel · guilddirect test mode` | Net/Transport.lua:608 |
| 1 | `sending %s to the guild as %d whispers · %s` | Net/Transport.lua:623 |
| 2 | `finished %s guild whispers · %d of %d sent, last one after %s` | Net/Transport.lua:636 |
| 1 | `rawsend: got test message from %s · via %s, prefix %s, text %s` | Net/Transport.lua:680 |
| W | `dropped oversized message from %s · %s, limit %s (prefix %s)` | Net/Transport.lua:691 |
| 2 | `ignored message from %s · protocol %s, ours is %d` | Net/Transport.lua:708 |
| 2 | `got %s from %s · via %s, %s` | Net/Transport.lua:724 |
| 2 | `send queue · %d bulk, %d normal, %d alert waiting, %d prefixes busy` | Sync/Session.lua:2191 |

### CODEC

| Lvl | Message | Where |
|---|---|---|
| 2 | `rejected row %s · %s%s` | Data/HistoryDomain.lua:210 |
| 2 | `sending row id %s in full · not in the usual id pattern` | Net/Codec.lua:191 |
| 2 | `sending row id %s in full · not in the usual id pattern` | Net/Codec.lua:198 |
| 2 | `sending row id %s in full · id doesn't start with its awarder's name` | Net/Codec.lua:218 |
| 2 | `sending row id %s in full · short form didn't decode back the same` | Net/Codec.lua:230 |
| 2 | `sending row id %s in full · awarder unknown` | Net/Codec.lua:386 |
| 2 | `encoded ROWS · %d rows, %d players, %d responses, %s raw, %s compressed, %s on the wire, %.1fms` | Net/Codec.lua:540 |
| 2 | `rejected row %s · %s%s` | Net/Codec.lua:553 |
| W | `couldn't decode message from %s · bad framing (our protocol %d)` | Net/Transport.lua:695 |
| W | `couldn't decode message from %s · failed at %s step (our protocol %d)` | Net/Transport.lua:714 |
| 2 | `couldn't decode LIVE_ROW from %s · row %s: %s%s, %.1fms` | Sync/Live.lua:249 |
| 2 | `decoded LIVE_ROW from %s · %.1fms` | Sync/Live.lua:259 |
| 2 | `couldn't decode %s from %s · %s, %.1fms` | Sync/Live.lua:325 |
| 2 | `decoded %s from %s · %.1fms` | Sync/Live.lua:329 |
| 2 | `encoded %s · %s%s raw, %s compressed, %s on the wire, %.1fms` | Sync/Live.lua:72 |

### STORE

| Lvl | Message | Where |
|---|---|---|
| 1 | `deleted row %s · by %s%s%s` | Data/Store.lua:130 |
| W | `upgrade: couldn't read the item in row %s · link %s` | Data/Store.lua:507 |
| 1 | `upgraded saved history to schema 2 · %d rows, %d with items, %d missing links, %dms` | Data/Store.lua:513 |
| 3 | `%s %s from %s · %s%s` | Data/Store.lua:52 |
| W | `upgrade: couldn't read the item in row %s · link %s` | Data/Store.lua:87 |

### DIGEST

| Lvl | Message | Where |
|---|---|---|
| 3 | `hashed %s %s · day %d, %s` | Data/Digest.lua:215 |
| 3 | `unhashed %s %s · %s tree` | Data/Digest.lua:227 |
| 1 | `rebuilt history hashes · %d entries: %d recent (hash %08X/%08X), %d archived (hash %08X/%08X), %d months, %d days, %d expired skipped, %dms` | Data/Digest.lua:339 |
| 1 | `hash self-test passed` | Data/Digest.lua:350 |
| E | `hash self-test FAILED, history sync disabled · got %08X, expected E40C292C` | Data/Digest.lua:353 |

### DOMAIN

| Lvl | Message | Where |
|---|---|---|
| 2 | `history summary · %d recent (hash %08X/%08X), %d archived (hash %08X/%08X), cutoff month %d, keep %d months` | Data/HistoryDomain.lua:40 |
| 1 | `registered %s · %s strategy, %s scope, %s gate` | Sync/Domains.lua:27 |

### PRUNE

| Lvl | Message | Where |
|---|---|---|
| 1 | `keeping history from %s · %d months (month %d)%s` | Data/Retention.lua:103 |
| 1 | `pruned old history%s · %d rows, %d test rows, kept %d pinned, %dms` | Data/Retention.lua:144 |
| 1 | `pruned test rows only · %d removed, kept %d expired real rows and %d pinned, %dms` | Data/Retention.lua:147 |
| 1 | `history cutoff moved · %s -> %s, pruning and rebuilding` | Data/Retention.lua:219 |
| 1 | `auto-pinned key item in row %s · item %d` | Data/Retention.lua:68 |
| 1 | `key item list updated · version %d -> %d, pinned %d rows` | Data/Retention.lua:96 |

### ITEM

| Lvl | Message | Where |
|---|---|---|
| 2 | `item info arrived for row %s · after %s` | Data/ItemLinks.lua:50 |
| W | `item info never arrived for row %s · item %d, waited %ds` | Data/ItemLinks.lua:58 |
| 2 | `waiting on item info for row %s · item %d` | Data/ItemLinks.lua:71 |

### ROLL

| Lvl | Message | Where |
|---|---|---|
| 1 | `%s rolled %d · range %d-%d, counted as %s` | RollTracker.lua:132 |
| 1 | `roll-off for %s started by %s · %ds` | RollTracker.lua:281 |
| 1 | `couldn't announce the roll stop · no raid warning permission?` | RollTracker.lua:328 |
| 2 | `sent %s · to %s` | RollTracker.lua:429 |
| 2 | `got %s from %s · via %s` | RollTracker.lua:461 |
| 1 | `couldn't start the trade with %s · %s, added to the trade queue` | RollTracker.lua:548 |

### SOFTRES

| Lvl | Message | Where |
|---|---|---|
| 1 | `imported softres · %d player entries, %d hard reserves` | SoftRes.lua:290 |
| 1 | `cleared softres data` | SoftRes.lua:319 |
| 1 | `shared softres data with the group` | SoftRes.lua:335 |
| 1 | `couldn't import softres shared by %s · %s` | SoftRes.lua:359 |
| 1 | `couldn't load saved softres data · %s` | SoftRes.lua:579 |

### SCHED

| Lvl | Message | Where |
|---|---|---|
| W | `task %s threw an error · %s` | Sync/Scheduler.lua:112 |
| 2 | `timer %s fired · %dms late` | Sync/Scheduler.lua:40 |
| 2 | `timer %s fired · repeating` | Sync/Scheduler.lua:57 |
| 2 | `task queue growing · %d waiting` | Sync/Scheduler.lua:84 |

### PERF

| Lvl | Message | Where |
|---|---|---|
| W | `task %s ran long · %.1fms, frame budget %dms` | Sync/Scheduler.lua:109 |
| 1 | `%s speed · %d rows in %s, %d rows/min, %.2f KB/s` | Sync/Session.lua:1241 |

### TEST

| Lvl | Message | Where |
|---|---|---|
| 1 | `roundtrip council: skipped · no session to export` | Data/CouncilSessionDomain.lua:537 |
| 1 | `roundtrip council: FAILED to decode · %s` | Data/CouncilSessionDomain.lua:545 |
| 1 | `roundtrip council: %s · rev %d, items %d/%d, candidates %d/%d, votes %d/%d, %s` | Data/CouncilSessionDomain.lua:563 |
| 1 | `prunedry: would remove %d rows · %s to %s, keeping %d pinned, %d test rows` | Data/Retention.lua:207 |
| 1 | `gen: added %d test rows · %s to %s, %dms` | Data/Store.lua:361 |
| 1 | `purgetest: removed %d test rows` | Data/Store.lua:403 |
| 1 | `wipehistory: removed %d entries (rows, deletes and pins)` | Data/Store.lua:439 |
| 1 | `droplocal: dropped %d %s rows · newest %s, oldest %s` | Data/Store.lua:474 |
| 1 | `roundtrip history: row %s MISSING after decode` | Net/Codec.lua:563 |
| 1 | `roundtrip history: row %s MISMATCH in %s · local %q, decoded %q` | Net/Codec.lua:568 |
| 1 | `roundtrip history: %s · %d rows, %d ok, %d mismatched, %d full ids, %d skipped, %s per row, %s total` | Net/Codec.lua:577 |
| 1 | `%s: refused · needs /fl debug testdata on` | Sync/Debug.lua:222 |
| 1 | `livetest: queued on the award-updates gate` | Sync/Debug.lua:227 |
| 1 | `livetest: ran` | Sync/Debug.lua:229 |
| 1 | `gate: override set to %s` | Sync/Debug.lua:261 |
| 1 | `testdata: turned %s` | Sync/Debug.lua:270 |
| 1 | `keyitem: added item %d as a key item` | Sync/Debug.lua:286 |
| 1 | `guilddirect: turned %s` | Sync/Debug.lua:380 |
| 1 | `forcehello: asking %s now` | Sync/Debug.lua:387 |
| 1 | `forcedelete: sent delete of row %s · officer check skipped` | Sync/Live.lua:233 |
| 1 | `spamhello: need a count · /fl debug spamhello <n> [name]` | Sync/Peers.lua:646 |
| 1 | `spamhello: skipped · gate closed` | Sync/Peers.lua:651 |
| 1 | `spamhello: sent %d HELLOs to %s · %s each` | Sync/Peers.lua:662 |
| 1 | `probe #%s: sending %d to %s · %s, %dB each, prefix %s, %s priority` | Sync/Probe.lua:117 |
| 1 | `probe: no runs yet` | Sync/Probe.lua:154 |
| 1 | `probe #%s to %s: %d of %d echoed back (%.0f%% lost) · round trip %s, %d send failures, %s %s, %dB each, prefix %s, %s priority` | Sync/Probe.lua:71 |
| 1 | `probe #%s from %s: got %d of %d (%.0f%% lost) · %d out of order, arrived over %s, via %s` | Sync/Probe.lua:81 |
| 1 | `maxserve: serve limit set to %s` | Sync/Session.lua:2127 |
