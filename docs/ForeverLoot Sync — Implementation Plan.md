# ForeverLoot Sync — Implementation Plan

Oct 1, 2026 · @Cory

## How to use this plan

Hand Claude Code one phase at a time. Each phase is small enough to build in one sitting, ends in a state you can load into the game, and lists exactly what to try in-game and which debug lines prove it works. All testing happens in the game, with debug output as the test harness. Nothing is tested outside WoW.

### Before phase 0

1. Export the spec doc (ForeverLoot History Sync — Spec) as Markdown and save it in the addon repo as `docs/sync-spec.md`.
2. Save this plan as `docs/sync-plan.md`.
3. Start each Claude Code session with: "Read `docs/sync-spec.md` and `docs/sync-plan.md`, then implement Phase N only."

### Rules for Claude Code in every phase

- **Read first.** Before changing anything, read the existing addon code for loot council sessions, history storage, the existing AceComm broadcast and the slash commands. Integrate with them; don't build parallel copies.
- **The spec is the source of truth** for wire formats, message types, apply rules and constants. If the code forces a deviation, write it down in `docs/sync-deviations.md` with the reason. For build order, this plan replaces the rollout phases in spec section 15.2.
- **One phase only.** Don't start the next phase's work early, even when it looks easy.
- **Keep the addon working after every phase.** Loot council and history UI must behave exactly as before for players who never type a debug command.
- **Lua 5.1 as WoW runs it.**
  - Everything is file-local. Modules share the addon namespace: `local _, ns = ...`.
  - The only new globals are SavedVariables keys.
  - Libraries in use: AceComm-3.0 (with its bundled ChatThrottleLib and CallbackHandler-1.0), LibSerialize and LibDeflate. Add nothing else from Ace3.
  - New files are added to the TOC in the order listed in spec section 12.1.
- **Debug output exactly as this plan specifies.** Same categories, same field names, same order. The user pastes logs back into Claude Code, and consistent lines make that work.
- **End every phase with a short report:** files changed, the in-game checklist for this phase, and anything left undone.

### Phase overview

| Phase | Delivers | Accounts needed |
| --- | --- | --- |
| 0 | Debug system, slash commands, `Constants`, `Scheduler`, `Gate` | 1 |
| 1 | Store v2 (tombstones, pins, `itemString`), migration, `Store:Apply`, officer-only deletes | 1–2 |
| 2 | Wire format (`Codec`, `Transport`), item-link rebuild, new live messages | 2 |
| 3 | Digests, retention cutoff, pruning, key-item pins | 2 |
| 4 | Sync domains + discovery (`HELLO`), as a dry run with no data transfer | 2–3 |
| 5 | Sync sessions with one primary peer | 2 |
| 6 | Secondary peers, prefix rotation, throughput | 3 |
| 7 | Council-session snapshot domain | 2–3 in a raid group |
| 8 | Hardening, defaults, release | guild |

## In-game test setup

You need two or three clients online at once in the same guild, and the debug tools from phase 0, which can fake gaps, gate states and bulk data. Only the debug tools touch data in unusual ways, and they are guarded so test data never reaches guildmates who aren't testing.

### Clients

- **Two clients at once** is the minimum from phase 2 onward. Two characters on the same game account cannot be online together, so use a second game account, or a guildmate running your development build.
- **Three clients** are needed for phase 6, where receiving from several peers in parallel is the thing being tested.
- Label them in your notes as **A** (yours, usually an officer), **B** (a non-officer) and **C**. Every checklist below refers to these letters.
- Install the same development build on every test client. Mixed versions are only tested deliberately, in phase 8.

### Keeping test data away from real guildmates

Test-data mode is the guard:

- `/fl debug testdata on` marks this client as a tester.
- Rows made by `/fl debug gen` get ids that start with `zztest-`.
- **Clients without test-data mode reject any `zztest-` row**, in `Store:Apply`, before it is stored or relayed. Fake rows therefore only move between testers.
- `/fl debug purgetest` removes all `zztest-` rows from this client without creating tombstones, so nothing is broadcast.
- A separate test guild is still the safest option for the volume tests in phase 6.

### Faking the situations sync must handle

| Situation | How to create it in-game |
| --- | --- |
| A member who was offline and missed data | `/fl debug droplocal <n>` on that client removes its newest `n` rows locally, with no tombstones and no broadcast, then rebuilds digests. To everyone else, the client now looks like it missed those rows. |
| Inside an instance | Enter any dungeon, or use `/fl debug gate closed` to force the sync gate shut anywhere. |
| A boss encounter | Pull any dungeon boss. `ENCOUNTER_START` fires for dungeon bosses too. |
| Lots of history (new member backfill) | `/fl debug testdata on`, then `/fl debug gen <n>` on one client to create `n` fake rows spread over the last 4 months. |
| Disconnect mid-transfer | `/reload` or log out on the sending client while a session is running. |

### Getting logs back to Claude Code

`/fl debug log` opens a window with the last 500 debug lines selected and ready to copy. Paste them into Claude Code together with the phase number and which client (A, B or C) they came from. The buffer survives `/reload`, so you can reload first and copy afterwards.

## Debug system

Every module logs through one `Debug` module. Each line has a fixed format, a category and a level. Lines go to chat and to a 500-line buffer you can copy out. Counters run all the time at almost no cost, and status commands print the current state on demand. Phase 0 builds all of this before any sync code exists.

### Line format

```text
FL 14:02:31.482 [SESS] k7Q2 state COMPARING->RECONCILING buckets=4 [20361,20360,20358,20341]
^  ^            ^      ^ event, then key=value pairs
|  |            category
|  local time with milliseconds
fixed tag (shown colored in chat, plain in the log buffer)
```

Conventions every module follows:

- **Field names** are lowercase, written `key=value`, with no spaces around `=`. A value with spaces is quoted: `from="Zerpy Frog"`.
- **Player names** are full names exactly as stored.
- **Units** are always spelled: bytes as `412B` or `4.9KB`, durations as `ms` or `s`.
- **Hashes** are 8 uppercase hex digits: `x=1A2B3C4D`.
- **Outcome words** come from a fixed set: `added`, `dup`, `tombstoned`, `expired`, `invalid`, `rejected`, `queued`, `sent`, `ok`, `fail`, `skip`.
- **Session lines** put the session token right after the category, so one session can be followed with a text search.
- **Ids** are printed in full; they are needed to cross-check clients.

### Levels

| Level | Shows | Typical volume |
| --- | --- | --- |
| 1, summary (default) | Gate changes, `HELLO` sent and heard, session start and end, pruning, migration, warnings | A few lines a minute |
| 2, detail | Every message sent and received, each bucket, each batch, each item-link resolve | Dozens a minute during sync |
| 3, trace | Every entry applied, every hash compared | Hundreds during a backfill; use for short tests only |

`WARN` and `ERR` lines are written to the buffer even when debug output is off, because they are rare and cheap. They are only printed to chat when debug is on.

### Categories

| Category | Module | Covers |
| --- | --- | --- |
| `GATE` | Gate | Sync and live gate state, the reason for each change, the live queue |
| `SCHED` | Scheduler | Timers firing, work-queue depth |
| `STORE` | Store | Apply outcomes, migration |
| `PERM` | Permissions | Delete and pin checks |
| `CODEC` | Codec | Encode and decode sizes, timing and failures |
| `COMM` | Transport | Messages sent and received, prefix, priority, bytes, completion |
| `ITEM` | ItemLinks | Item-link rebuilds |
| `DIGEST` | Digest | Rebuilds, roots, bucket comparisons |
| `PRUNE` | Retention | Cutoff, pruning, automatic pins |
| `DOMAIN` | Domains | Registration, summaries, compare results |
| `PEERS` | Peers | `HELLO` decisions, reply probability, responder choice |
| `SESS` | Session, Coordinator | Session state changes, buckets, batches, outcomes |
| `LIVE` | Live | Live broadcasts out and in |
| `SNAP` | council-session domain | Snapshot export, import and version compare |
| `PERF` | Scheduler | Frame-budget overruns |
| `TEST` | Debug | Test-data and fault-injection commands |

### Behaviour

- **Zero cost when off.** `Debug:Log` takes the format string and its arguments separately, and returns before calling `string.format` when the category or level is off. No log line may build strings eagerly.
- **Repeat collapsing.** An identical line repeated within 2 s is counted instead of printed, and shown once at the end as `(x12)`.
- **Buffer.** The last 500 lines are kept in `ForeverLootDB.debug.log` (plain text), so they survive `/reload`.
- **Output frame.** Chat output goes to `DEFAULT_CHAT_FRAME` unless `/fl debug frame <n>` picks another chat window.
- **Counters.** `Debug:Count(key, n)` is always on: messages and bytes per message type and direction, apply outcomes, reject reasons, and session outcomes. They are printed by `/fl sync stats`.

The API Claude Code should build:

```lua
ns.Debug:Log("SESS", 1, "%s open mode=%s peer=%q domain=%d", token, mode, peer, domainId)
ns.Debug:Warn("CODEC", "decode fail from=%q step=%s", sender, step)
ns.Debug:Count("comm.recv.ROWS.bytes", #payload)
local on = ns.Debug:IsOn("DIGEST", 3)  -- guard for expensive trace loops
```

### Commands

Each command is added in the phase noted.

| Command | What it does | Phase |
| --- | --- | --- |
| `/fl debug on` · `off` | Turn debug output on or off (saved) | 0 |
| `/fl debug level 1`\|`2`\|`3` | Set verbosity | 0 |
| `/fl debug cat <CAT> on`\|`off` | Mute or unmute one category | 0 |
| `/fl debug frame <n>` | Send output to chat window `n` | 0 |
| `/fl debug log` · `clear` | Open the copy window, or empty the buffer | 0 |
| `/fl debug gate auto`\|`open`\|`closed` | Override the sync gate for testing | 0 |
| `/fl debug testdata on`\|`off` | Mark this client as a tester (accepts `zztest-` rows) | 1 |
| `/fl debug gen <n>` | Create `n` fake test rows over the last 4 months | 1 |
| `/fl debug purgetest` | Remove all test rows locally, no tombstones | 1 |
| `/fl debug droplocal <n>` | Remove the newest `n` rows locally, no tombstones | 1 |
| `/fl sync dump <id>` | Print one stored entry, every field | 1 |
| `/fl debug roundtrip [n]` | Encode then decode the newest `n` rows locally and report any field that differs | 2 |
| `/fl sync digest` · `months` · `days <monthKey>` | Print roots, month aggregates or day aggregates | 3 |
| `/fl debug prunedry` | Show what pruning would remove, without removing it | 3 |
| `/fl sync status` | One-screen summary of every module | 0, extended each phase |
| `/fl sync domains` | Each registered domain with its summary | 4 |
| `/fl sync peers` | Known peers, last heard, their summaries | 4 |
| `/fl debug forcehello` | Send `HELLO` now, ignoring timers and suppression | 4 |
| `/fl sync sessions` | Open sessions with state, buckets and bytes | 5 |
| `/fl sync stats` · `stats reset` | Print or reset the counters | 2 |

## Phase 0: Debug system, Scheduler, Gate

This phase builds the tools every later phase is verified with, plus the two modules that decide when anything may run. No data or network behavior changes yet.

### Build

1. **`Sync/Constants.lua`**: every value from spec section 13, plus `DEBUG_LOG_LINES = 500` and `DEBUG_COLLAPSE_SECONDS = 2`.
2. **`Sync/Debug.lua`**, exactly as described in the Debug system section above:
   - The `Log`, `Warn`, `Err`, `Count` and `IsOn` API.
   - Settings saved in `ForeverLootDB.debug = { enabled, level, cats, frame, log }`.
   - The 500-line ring buffer and repeat collapsing.
   - The copy window: a movable frame with a scrolling multi-line EditBox. It opens with all text highlighted so Ctrl+C copies it.
3. **Slash commands:** extend the addon's existing `/fl` handler if there is one, otherwise register `/fl`. Add `/fl debug …` and `/fl sync status`.
4. **`Sync/Scheduler.lua`** (spec 12.2):
   - `After(sec, jitter, fn, name)`, `Every(sec, jitter, fn, name)` and `Cancel(h)`, built on `C_Timer`.
   - `Enqueue(fn, name)`: a work queue drained in an `OnUpdate` handler within `FRAME_BUDGET_MS`, timed with `debugprofilestop()`.
5. **`Sync/Gate.lua`** (spec section 8):
   - Tracks instance, combat, encounter, loading and guild state from events.
   - `CanSync()`, `CanLive()`, `QueueLive(fn, label)`, `OnChange(cb)`, and the `/fl debug gate` override.
6. **`/fl debug livetest`**: queues a dummy live action through `Gate.QueueLive` that only logs when it runs. It exists to test the encounter queue before real live messages exist.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Debug is turned on, and at login when it is on | `[GATE] state sync=open live=open reason=none` | 1 |
| Any gate change | `[GATE] state sync=closed live=open reason=instance` (reasons: `instance`, `combat`, `encounter`, `loading`, `noguild`, `override`, `none`) | 1 |
| A live action is queued | `[GATE] live queued n=1 label=livetest reason=encounter` | 1 |
| The live queue flushes | `[GATE] live flushed n=1 after=ENCOUNTER_END waited=94s` | 1 |
| A timer fires | `[SCHED] timer fire name=<name> late=12ms` | 2 |
| Work queue grows past 10 tasks | `[SCHED] queue depth=14` | 2 |
| A task exceeds the frame budget | `[PERF] WARN overrun task=<name> used=7.4ms budget=4ms` | always (WARN) |
| Any test command | `[TEST] gate override=closed`, `[TEST] livetest queued` | 1 |

`/fl sync status` prints at this phase:

```text
FL sync status
  proto=1 retention=4 debug=on level=1
  gate: sync=open live=open reason=none override=auto
  scheduler: timers=0 queue=0
```

### In-game checklist (client A)

1. `/fl debug on`. Expect a `[GATE] state … reason=none` line.
2. Enter a dungeon. Expect `sync=closed … reason=instance` and `live=open`. Leave it and expect `sync=open`.
3. Fight a mob outdoors. Expect `reason=combat`. About 5 s after combat ends, expect `sync=open`.
4. In a dungeon, pull a boss. Expect `live=queued reason=encounter`. Run `/fl debug livetest` during the fight: expect `live queued`. When the boss dies or the group wipes, expect `live flushed n=1 after=ENCOUNTER_END`.
5. `/fl debug gate closed`, then `/fl debug gate auto`. Expect `reason=override`, then a return to the real state.
6. `/reload`, then `/fl debug log`. Lines from before the reload are in the window, and Ctrl+C copies them.
7. `/fl debug cat GATE off`, then repeat step 2. No `GATE` lines appear.
8. `/fl debug off`, then play normally for a while with Lua errors visible (`/console scriptErrors 1` or BugSack). Nothing prints, no errors appear, and the loot council works as before.

### Done when

Every step above behaves as described, and the addon behaves exactly as before with debug off.

## Phase 1: Store v2, migration, permissions

This phase routes every history write through `Store:Apply`, adds tombstones and pins to saved data, and makes deletes officer-only. Live messages keep their **old** wire format in this phase; only what happens on each client changes.

### Build

1. **`Data/Store.lua`**, using the schema from spec 12.5 and `Apply` from spec 12.6.
   - **Migration from schema 1 to 2:** create the `tombstones` and `pins` tables, and add `itemString` to every row from its `itemLink` (spec 4.5). Rows whose link can't be parsed keep `itemString = nil` and log a warning.
   - **Stubs until later phases:** `Digest:Add` and `Digest:Remove` (phase 3) and `Retention:IsExpired`, which returns `false` until phase 3. Call them through stubs now so phase 3 only fills them in.
   - **Test-data guard:** reject any id starting with `zztest-` unless test-data mode is on.
   - **Callbacks:** fire `EntryApplied` through CallbackHandler, and refresh the history UI from that callback.
2. **`Sync/Permissions.lua`** (spec 11, policy `officers`).
   - Cache each guild member's rank index from `GetGuildRosterInfo`. Refresh it on `GUILD_ROSTER_UPDATE`, requesting a refresh with `C_GuildInfo.GuildRoster()` at login.
   - `CanDelete(name)` and `CanPin(name)` return true when `rankIndex <= OFFICER_RANK_MAX`. Rank 0 is the guild master.
3. **`Sync/Live.lua`, first version.**
   - `Live.Award(row)`, `Live.Delete(id)` and `Live.Pin(id)` call `Store:Apply` first, then the addon's **existing** broadcast.
   - The existing award and delete UI calls these functions instead of writing history directly.
   - The delete button is hidden for players who fail `CanDelete`.
   - Receivers of the existing delete broadcast build a tombstone and pass it to `Store:Apply`.
4. **Debug commands:**
   - `testdata on|off`.
   - `gen <n>`: fake rows with ids `zztest-<n>-<random>`. `awardedAt` is spread randomly over the last 4 months; each row has 5 responses from current guild members, notes picked from a small list of realistic phrases, and item strings copied from real rows. Generated rows stay on this client; nothing is broadcast.
   - `purgetest`.
   - `droplocal <n>`: removes test rows only, unless the command ends with `real`. Before phase 5, a dropped real row only comes back from other clients once sync exists.
   - `/fl sync dump <id>`.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Migration runs (once) | `[STORE] migrate schema=1->2 rows=812 itemString=809 missingLink=3 t=41ms` | 1 |
| A row's link can't be parsed | `[STORE] WARN migrate noItemString id=<id> link=<raw link>` | always |
| Any entry applied | `[STORE] apply kind=R id=<id> src=local\|live\|sync\|test result=added\|dup\|tombstoned\|expired\|invalid\|rejected reason=<why>` | 3 |
| A tombstone is stored | `[STORE] tombstone id=<id> by="<name>" rowTime=<t> removedRow=yes removedPin=no` | 1 |
| A delete is checked | `[PERM] delete allowed name="<name>" rank=0 max=1` or `[PERM] delete denied name="<name>" rank=5 max=1` | 1 |
| A test row is rejected on a non-tester | `[STORE] apply … result=rejected reason=testdata` | 1 |
| Test commands | `[TEST] gen n=500 from=2026-06-01 to=2026-10-01 t=120ms`, `[TEST] purgetest removed=500`, `[TEST] droplocal n=20 newest=<id> oldest=<id> real=no` | 1 |

`/fl sync status` adds:

```text
  store: schema=2 rows=812 tombstones=3 pins=0 test=0 missingItemString=3
  perm: policy=officers me="Zerpy Grape" rank=0 canDelete=yes
```

### In-game checklist

1. **Before installing,** note the number of history rows the UI shows on client A.
2. Install the build and log in with debug on. Expect exactly one `migrate` line, a `rows=` count matching step 1, and ideally `missingLink=0`.
3. Open the history UI. Everything looks and sorts exactly as before.
4. `/fl sync dump <id>` on any real row. `itemString` is present, and its first number matches the row's `itemID`.
5. **A (officer):** delete a row. Expect `[PERM] delete allowed` and `[STORE] tombstone … removedRow=yes`.
6. **B (non-officer):** the delete button is not shown. B received A's delete: expect `[STORE] tombstone` on B, and the row is gone from B's UI.
7. **Award an item** through a council session. Expect `result=added src=local` on A and `result=added src=live` on B (level 3).
8. **A:** `/fl debug testdata on`, then `/fl debug gen 50`. Expect a `[TEST] gen` line, and `/fl sync status` shows `test=50`. Then `/fl debug purgetest`; status shows `test=0`.
9. `/reload` A. Status still shows `schema=2` and the same counts, and no second `migrate` line appears.

### Done when

Migration is clean, the UI is unchanged, deletes are officer-only and leave tombstones on every online client, and every write logs an apply outcome.

## Phase 2: Wire format, transport, live messages

This phase builds the compact wire format and the AceComm transport, then switches live award, delete and pin broadcasts to `LIVE_ROW`, `LIVE_DEL` and `LIVE_PIN`. The in-game `roundtrip` command proves that encoding loses nothing before any sync depends on it.

### Build

1. **`Net/Codec.lua`** (spec section 4):
   - The message pipeline: LibSerialize, then LibDeflate `CompressDeflate` at level 9, then `EncodeForWoWAddonChannel`; the reverse on receive.
   - Positional rows with batch-local player and response-type dictionaries.
   - The class-id map, built from `GetNumClasses` and `GetClassInfo`.
   - The id codec: `compact(name) = name:lower():gsub(" ", "")`. The session leader is looked up in the batch dictionary first, then the guild roster, and the round-trip guard falls back to the raw id string.
   - Marks (tombstones and pins) codec, and row validation from spec 4.9.
2. **`Net/Transport.lua`:**
   - Register prefixes `FLoot` and `FLootS1`–`S3` through AceComm.
   - `Send(type, body, dist, target, {prio, lane, onSent})`. `onSent` is driven by AceComm's progress callback: it fires when sent equals total.
   - `Register(type, handler)`. Messages from yourself are ignored, and an unknown `PROTO_VERSION` drops the message.
   - Byte and message counters per type and direction.
3. **`Data/ItemLinks.lua`:** rebuild `itemLink` from `itemString` (spec 4.5). Wait for `GET_ITEM_INFO_RECEIVED` or `Item:ContinueOnItemLoad`, and resolve at most 20 per frame through `Scheduler`.
4. **`Live`:** awards, deletes and pins are now sent as `LIVE_ROW`, `LIVE_DEL` and `LIVE_PIN` on GUILD at ALERT priority, through `Gate.QueueLive`.
   - Remove the old history broadcast. Council-session messages that are not history stay exactly as they are; phase 7 deals with those.
   - Receivers run `Permissions.CheckLive` on `LIVE_DEL` and `LIVE_PIN`: the sender must equal `deletedBy` or `pinnedBy`, and must currently be an officer.
5. **Debug commands:**
   - `/fl debug roundtrip [n]`: encode the newest `n` rows (default 50) as one `ROWS` batch, decode it locally, and compare every field. `itemLink` is compared by its item string.
   - `/fl debug forcedelete <id>`: sends a `LIVE_DEL` for the id without the local permission check and without applying it locally. It exists only to test that receivers reject non-officers.
   - `/fl sync stats`.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Encode | `[CODEC] encode type=LIVE_ROW rows=1 players=7 resp=5 ser=286B cmp=231B enc=236B t=0.9ms` | 2 |
| Decode | `[CODEC] decode type=LIVE_ROW from="<name>" enc=236B ok=1 rejected=0 t=0.6ms` | 2 |
| Decode failure | `[CODEC] WARN decode fail from="<name>" step=decode\|decompress\|deserialize\|version proto=<n>` | always |
| Row rejected | `[CODEC] reject id=<id> reason=badIndex\|tooManyResponses\|noteTooLong\|future\|expired\|badItemString\|badType field=<n>` | 2 |
| Id sent raw | `[CODEC] id raw id=<id> reason=noPattern\|leaderUnknown\|roundtrip` | 2 |
| Send queued | `[COMM] send type=LIVE_ROW dist=GUILD prefix=FLoot prio=ALERT bytes=236 chunks=1` | 2 |
| Send finished | `[COMM] sent type=LIVE_ROW bytes=236 dur=0.1s` | 2 |
| Received | `[COMM] recv type=LIVE_ROW from="<name>" dist=GUILD bytes=236` | 2 |
| Live out | `[LIVE] out LIVE_ROW id=<id> queued=no` | 1 |
| Live in | `[LIVE] in LIVE_ROW id=<id> from="<name>" result=added` | 1 |
| Live permission reject | `[PERM] live reject type=LIVE_DEL from="<name>" by="<name>" reason=senderMismatch\|notOfficer rank=5` | 1 |
| Item link | `[ITEM] pending id=<id> itemID=251533`, then `[ITEM] resolved id=<id> wait=0.4s` | 2 |
| Item link stuck | `[ITEM] WARN unresolved id=<id> itemID=<n> after=30s` | always |
| Round trip | `[TEST] roundtrip n=50 ok=50 diff=0 rawIds=0 avgRow=172B batch=8.6KB` | 1 |
| Round-trip difference | `[TEST] roundtrip diff id=<id> field=responses[3].note local="…" decoded="…"` | 1 |

`/fl sync stats` at this phase:

```text
FL sync stats (since login 42m)
  sent:  LIVE_ROW 3 msgs 708B | LIVE_DEL 1 msg 61B
  recv:  LIVE_ROW 5 msgs 1.2KB | LIVE_DEL 0
  apply: added=5 dup=0 tombstoned=0 expired=0 invalid=0 rejected=0
  codec: decodeFail=0 rowRejects=0 rawIds=0
```

### In-game checklist (A and B online)

1. **A:** `/fl debug roundtrip 200`. Expect `diff=0` and `rawIds=0`. Paste the line into Claude Code with the `avgRow` and `batch` sizes; this is the first real measurement of the spec's size estimates. Any `rawIds` above 0 means some ids don't match the leader pattern: copy the `[CODEC] id raw` lines.
2. **A awards an item.** A shows `[LIVE] out`, and B shows `[LIVE] in … result=added`. Run `/fl sync dump <id>` on both clients: every field matches.
3. **Award an item B has never seen.** B shows `[ITEM] pending`, then `resolved` within a few seconds, and B's UI shows the full colored link.
4. **A deletes a row.** B shows `[LIVE] in LIVE_DEL` and a `[STORE] tombstone` line.
5. **B (non-officer):** `/fl debug forcedelete <id>` on a test row. A shows `[PERM] live reject … reason=notOfficer`, and the row still exists on A.
6. **During a dungeon boss fight,** A awards or runs `/fl debug livetest`. A shows `[GATE] live queued`. After the fight, the message is flushed and B receives it.
7. `/fl sync stats` on both clients: no `decodeFail`, and `rejected` counts only the step 5 test.

### Done when

Round trip shows zero differences on real data, every live award, delete and pin arrives on the other client in the new format, and decode failures stay at 0.

## Phase 3: Digests, retention, pins

This phase adds the hash trees that tell two clients whether they agree, and the retention rules. There is still no sync traffic. The checks compare digests printed on two clients, side by side. Pruning stays a dry run for real rows until phase 8, so no real history is lost while the system is unfinished.

### Build

1. **`Data/Digest.lua`** (spec section 5):
   - FNV-1a exactly as in spec 5.1, with the bucket aggregate `{count, x, s}`.
   - Window and archive trees, with day, month and root levels, plus `hash → entry` maps.
   - `Rebuild()` at login, and `Add`/`Remove` called from `Store` (replacing the phase 1 stubs).
   - **Self-test at load:** `fnv1a("a") == 0xE40C292C` and `fnv1a("foobar") == 0xBF9CF968`. A mismatch logs `ERR` and disables sync.
2. **`Data/Retention.lua`** (spec section 10):
   - `Cutoff()`, computed from `GetServerTime()` with UTC month arithmetic (`date("!*t")`), and `IsExpired()` (replacing the stub).
   - Check for a moved cutoff at login and then every hour. When it moves, prune and rebuild the digests.
   - `Prune()`, in slices of 200 rows per frame.
   - **Safety switch:** `PRUNE_REAL = false` in `Constants`. Expired real rows are kept on disk, but are left out of digests and never sent, exactly as if they were pruned. Test rows are pruned for real. Phase 8 sets `PRUNE_REAL = true`.
3. **Pins:**
   - Add `KEY_ITEMS` (a set of item ids) and `KEY_ITEMS_VERSION` to `Constants`.
   - `Retention.AutoPin(row)` runs at award. A matching row creates a pin that is applied and sent as `LIVE_PIN` right after `LIVE_ROW`.
   - When `KEY_ITEMS_VERSION` is higher than the stored value, pin matching rows still in the window once at login, without broadcasting, then store the new version.
   - Officers get a manual "Pin" action in the history UI, which calls `Live.Pin`.
4. **Debug commands:**
   - `/fl sync digest`, `/fl sync digest months` and `/fl sync digest days <monthKey>`.
   - `/fl debug prunedry`.
   - `/fl debug gen <n> old`: test rows 5–6 months old, for testing pruning.
   - `/fl debug keyitem add <itemID>`: an in-memory addition to `KEY_ITEMS`, until `/reload`.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Load | `[DIGEST] selftest ok`, or `[DIGEST] ERR selftest fail got=<hex> want=E40C292C` | 1 |
| Rebuild | `[DIGEST] rebuild entries=3512 W=n:3410,x:1A2B3C4D,s:9F8E7D6C A=n:102,x:0BADF00D,s:12345678 months=5 days=118 excludedExpired=640 t=6ms` | 1 |
| Entry added or removed | `[DIGEST] add kind=R id=<id> day=20361 tree=W` | 3 |
| Cutoff | `[PRUNE] cutoff=2026-06-01 monthKey=24317 retention=4 pruneReal=no` | 1 |
| Cutoff moved | `[PRUNE] cutoff moved 2026-06-01->2026-07-01 rebuilding` | 1 |
| Prune | `[PRUNE] prune removedTest=40 expiredRealKept=212 keptPinned=9 t=14ms` | 1 |
| Automatic pin | `[PRUNE] autopin id=<id> itemID=<n>` | 1 |
| Key-item version pass | `[PRUNE] keyitems version 1->2 pinned=4` | 1 |
| Dry run | `[TEST] prunedry wouldRemove=212 oldest=2025-11-03 newest=2026-05-31 pinnedKept=9 test=40` | 1 |

`/fl sync digest` output, which every later phase relies on to compare clients:

```text
FL digest  cutoff=2026-06-01
  W  n=3410  x=1A2B3C4D  s=9F8E7D6C
  A  n=102   x=0BADF00D  s=12345678
```

`/fl sync digest months` prints one line per month (`2026-09 n=870 x=… s=…`). `days <monthKey>` prints one line per day, including the UTC date.

### In-game checklist (A and B)

1. **Log in on both.** Each shows `selftest ok`, a `rebuild` line and a `cutoff` line with the same cutoff date.
2. **Run `/fl sync digest` on both.** The roots may legitimately differ, because each client's past history is whatever it happened to receive. That difference is exactly what phase 5 fixes. Note both outputs.
3. **Award 2–3 items live from A.** Then run `/fl sync digest days <this month>` on both. **Today's line is identical on A and B** (n, x and s), because both received the same live data today.
4. **A deletes one of today's rows.** Today's line changes, and is still identical on both clients.
5. **A pins a row** with the manual action. B shows the pin applied, and today's line is still identical on both.
6. **Automatic pin:** `/fl debug keyitem add <itemID>` on A, then award that item. Expect `[PRUNE] autopin` on A and the pin arriving on B.
7. **Pruning:** on A, `/fl debug testdata on`, `/fl debug gen 40 old`, then `/fl debug prunedry`. Expect `test=40`. `/reload`, then expect `prune removedTest=40`, and `prunedry` now shows `test=0`. The `expiredRealKept` count matches the real rows older than the cutoff.

### Done when

The self-test passes, today's day bucket matches across clients after any live action, test rows prune correctly, and no real row has been removed.

## Phase 4: Sync domains and discovery (dry run)

This phase builds the generic domain registry and the full `HELLO` / `HELLO_ACK` handshake, with loot history as the only registered domain. The coordinator decides whom it **would** sync with and logs the plan, but opens no sessions. Discovery can be checked on its own before any data moves.

### Build

1. **`Sync/Domains.lua`:** the registry and the interface from spec 7.7: `Register`, `Get`, `InScope` and `NotifyChanged`.
2. **`Data/HistoryDomain.lua`:** domain 1, strategy `set`, scope GUILD, gate `sync`.
   - `Summary()` returns the window and archive roots, the cutoff month key and the retention value.
   - `Compare` returns `same` or `diverged`. A different retention or cutoff returns `incompatible`, which is never synced.
   - The set methods stay stubs until phase 5.
3. **`Sync/Peers.lua`** (spec 7.2, 7.5, 7.7):
   - Build and send `HELLO` for each scope.
   - Handle incoming `HELLO`: compare each domain and decide whether to reply, using `p = min(1, TARGET_RESPONDERS / max(1, knownPeers))`, a random delay and the gate check.
   - `HELLO_ACK` in and out.
   - The known-peers table, expiring entries after `PEER_MEMORY`.
   - Suppression of the periodic `HELLO`.
   - `CollectResponders` over `HELLO_COLLECT_WINDOW`, and up to 3 retries with the `urgent` flag.
4. **`Sync/Coordinator.lua`:**
   - Triggers: login (after `LOGIN_DELAY` and an open gate), periodic, and leaving an instance.
   - After responders are collected, choose a primary and secondaries for each mismatched domain and **log the plan only**.
5. **Debug commands:** `/fl sync domains`, `/fl sync peers` and `/fl debug forcehello`.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Domain registered | `[DOMAIN] register id=1 name=history strategy=set scope=GUILD gate=sync` | 1 |
| Summary built | `[DOMAIN] summary id=1 W=n:3410,x:1A2B3C4D,s:9F8E7D6C A=n:102,… cutoff=24317 ret=4` | 2 |
| `HELLO` sent | `[PEERS] hello out scope=GUILD trigger=login\|periodic\|instanceExit\|force\|notify urgent=no domains=1 bytes=84` | 1 |
| `HELLO` skipped | `[PEERS] hello skip scope=GUILD reason=suppressed\|gateClosed\|sessionActive lastMatch=4m12s` | 1 |
| `HELLO` received | `[PEERS] hello in from="<name>" scope=GUILD d1=same\|diverged\|incompatible d9=unknown` | 1 |
| Reply decision | `[PEERS] ack decide from="<name>" diff=d1 known=7 p=0.43 roll=0.21 -> reply delay=2.4s`, or `-> silent reason=roll\|allSame\|gateClosed` | 1 |
| `HELLO_ACK` received | `[PEERS] ack in from="<name>" d1=diverged W=n:3398` | 1 |
| Responder window closes | `[PEERS] responders window=6s got=3 ["B" n=3410, "C" n=3398, "D" n=3410]` | 1 |
| Nobody replied | `[PEERS] no responders attempt=1/3 retry=30s urgent=yes` | 1 |
| Known peers change | `[PEERS] known add="<name>" total=7`, `[PEERS] known expire="<name>" total=6` | 2 |
| Plan (dry run) | `[SESS] dryrun d1 primary="B" secondaries=["D"] sessions=disabled` | 1 |

`/fl sync peers`:

```text
FL peers (known=2, memory 30m)
  "Zerpy Frog"   heard 1m ago   d1=diverged W n=3398  ver=0.9.0
  "Zerpy Pear"   heard 9m ago   d1=same
```

### In-game checklist (A, B, and C if available)

1. **Log in on A with B online.** A shows `[DOMAIN] register`, then about 20 s later `hello out trigger=login`. B shows `hello in … d1=diverged` and an `ack decide … -> reply` line. A then shows `ack in`, `responders … got=1` and `dryrun d1 primary="B"`.
2. **B inside a dungeon:** run `/fl debug forcehello` on A. B logs `-> silent reason=gateClosed`. With A inside a dungeon instead, A's periodic and forced `HELLO`s log `hello skip reason=gateClosed`.
3. **Leave an instance on A.** About 20 s later, expect `hello out trigger=instanceExit`.
4. **Only A online** (log B out): `forcehello`, then expect `no responders attempt=1/3`, and two more attempts 30 s apart with `urgent=yes`.
5. **Wait 15 minutes on A** with B online. Expect a `hello out trigger=periodic`. The suppression path (`reason=suppressed`) can only be checked once clients actually match, so it is verified in phase 5.
6. `/fl sync peers` on A lists B, with B's summary and addon version.

### Done when

Every trigger sends `HELLO` only while the gate is open, peers reply with the logged probability, and the coordinator logs a sensible primary for every mismatch.

## Phase 5: Sync sessions with one primary

This phase turns the dry-run plan into real sessions with the primary peer only. It is the heart of the system: after it, a client that missed data catches up, deletes reach clients that were offline, and the success test is simple: **`/fl sync digest` prints identical roots on both clients.**

### Build

1. **`Sync/Session.lua`**, the state machine from spec 12.3, for `set` domains in `full` mode:
   - Messages `OPEN`, `OPEN_REPLY`, `MONTHS`, `DAYS`, `HASHES`, `WANT`, `ROWS`, `MARKS`, `DONE` and `ABORT`, each carrying a random 4-character token.
   - Mismatched buckets are processed newest first, with at most `BUCKETS_IN_FLIGHT` at a time.
   - The archive tree is compared too.
   - A session is dropped after `SESSION_IDLE_TIMEOUT` with no messages.
   - **Hash-collision fallback:** after 2 failed attempts on the same bucket, switch that bucket to full-id lists (spec 5.6).
2. **`HistoryDomain` set methods:**
   - `Tree()` returns the `Digest` object.
   - `EncodeEntries` builds `ROWS` and `MARKS` batches of about `BATCH_TARGET_BYTES` on `FLootS1` only, at BULK priority. The other sync prefixes are added in phase 6.
   - `ApplyEntries` decodes and applies through `Scheduler.Enqueue`, within the frame budget.
3. **Backpressure:** queue the next batch only after the previous batch's `onSent` fires.
4. **`Coordinator`:**
   - Open a full session with the primary only; secondaries are ignored until phase 6.
   - Serve at most `MAX_SERVE` sessions, and refuse others with `retryAfter`.
   - Abort every session with `reason=gate` when the gate closes.
5. **Debug commands:**
   - `/fl sync sessions`.
   - `/fl debug maxserve <n>`: an in-memory override for testing refusals.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Opened (opener) | `[SESS] k7Q2 open d1 mode=full role=opener peer="B"` | 1 |
| Accepted or refused (server) | `[SESS] k7Q2 accept d1 role=server peer="A" serving=1/2`, or `[SESS] k7Q2 refuse peer="A" reason=busy retryAfter=60s` | 1 |
| State change | `[SESS] k7Q2 state COMPARING->RECONCILING` | 1 |
| Months compared | `[SESS] k7Q2 months W local=5 remote=5 mismatched=[2026-09,2026-08] A=same` | 2 |
| Bucket list | `[SESS] k7Q2 buckets n=6 [20361,20360,20358,20341,20339,20330]` | 1 |
| Each bucket | `[SESS] k7Q2 bucket 20361 local=12 remote=14 want=2 give=0` | 2 |
| Batch sent | `[SESS] k7Q2 batch out #3 rows=38 marks=0 enc=4.9KB prefix=FLootS1`, then `[SESS] k7Q2 batch sent #3 dur=8.1s` | 2 |
| Batch received | `[SESS] k7Q2 batch in #3 rows=38 added=36 dup=2 rejected=0` | 2 |
| Finished | `[SESS] k7Q2 done d1 sent=0 recv=212 marks=3 buckets=6 dur=3m41s rootsMatch=yes` | 1 |
| Aborted | `[SESS] k7Q2 abort reason=gate\|timeout\|remote\|version\|busy state=RECONCILING progress=4/6` | 1 |
| Collision fallback | `[SESS] k7Q2 WARN hash collision day=20361 fallback=fullIds` | always |

`rootsMatch` in the `done` line compares this client's roots with the peer's roots from its last message. `no` is not an error when live data arrived during the session, but it must turn into a match by the next periodic check.

`/fl sync sessions`:

```text
FL sessions (out=1 in=0, serving max 2)
  k7Q2 d1 opener peer="Zerpy Frog" RECONCILING buckets 4/6 sent=0 recv=148 (31KB) 2m10s
```

### In-game checklist (A and B)

1. **Catch up a gap.** On B: `/fl debug droplocal 20 real`. A still has those rows, so this is safe now. `/fl sync digest` on B no longer matches A. On B, `/fl debug forcehello`. Expect a session `open`, `buckets`, `batch in` lines and `done … recv=20 rootsMatch=yes`. **Paste `/fl sync digest` from both clients:** they must be identical.
2. **Both directions in one session.** Turn on test data on both. A runs `gen 30`, B runs `gen 15`. Run `forcehello` on B. Expect `done … sent=15 recv=30`, and digests identical on both.
3. **A delete reaches an offline client.** Log B out. A deletes a real row. Log B in. B's login `HELLO` starts a session, its `done` line shows `marks=1`, the row is gone on B and the digests match.
4. **Gate abort and recovery.** A runs `gen 500`, and B does `purgetest` then `forcehello`. While the session runs, B enters a dungeon. Expect `abort reason=gate` on both clients. After B leaves, a new session finishes the remaining buckets and the digests match.
5. **Disconnect.** Start another backfill, then `/reload` A mid-session. B logs `abort reason=timeout` after about 45 s. The next `HELLO` finishes the job.
6. **Refusal.** On A, `/fl debug maxserve 0`, then `forcehello` on B. B logs `refuse … reason=busy`, then tries again after `retryAfter`.
7. **Suppression.** Once A and B match, leave both online for 30 minutes. Each periodic window should show one client's `hello out` and the other's `hello skip reason=suppressed`.
8. **Throughput baseline.** From step 4's `done` line, write down rows per minute from a single peer. Phase 6 should beat it by roughly 3×.

### Done when

Every scenario ends with identical `/fl sync digest` output on both clients, aborted sessions always recover on a later `HELLO`, and no `ERR` lines appear.

## Phase 6: Secondary peers and throughput

This phase adds parallel pulls from up to two secondaries, and rotates bulk data across all three sync prefixes. The goal is speed without hurting gameplay: a large backfill should run roughly 2–3× faster than the phase 5 baseline, while live awards still arrive within seconds.

### Build

1. **`Coordinator` bucket assignment** (spec 7.4):
   - Mismatched buckets are assigned round-robin, newest first, across the primary and up to `MAX_SECONDARIES`.
   - Each secondary gets `OPEN(pull, dayKeys)`.
   - The primary still handles the push direction for every bucket, but skips pulling buckets assigned to a secondary.
   - When a secondary aborts or times out, its unfinished buckets go back to the primary.
2. **`Session`:** pull mode on both sides. The opener sends `HASHES`, and the server answers with `ROWS` and `MARKS` without ever sending `WANT`.
3. **Prefix rotation:** outgoing batches rotate across `FLootS1`–`S3`, with at most one batch in flight per prefix.
4. **Instrumentation:**
   - A rows-per-minute rate for each session, and a summary line when every session for a domain has finished.
   - While any session is active, sample ChatThrottleLib's queue every 10 s.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Assignment | `[SESS] plan d1 primary="B" secondaries=["C","D"] assign B=4 C=3 D=3` | 1 |
| Pull session opened | `[SESS] m2X9 open d1 mode=pull role=opener peer="C" buckets=3` | 1 |
| Reassignment | `[SESS] reassign d1 from="C" buckets=2 to="B" reason=abort` | 1 |
| Rate per session | `[PERF] rate k7Q2 peer="B" rows=1210 dur=2m58s rowsPerMin=408 kbps=0.60` | 1 |
| Whole sync finished | `[SESS] sync complete d1 peers=3 rows=3500 dur=5m40s rowsPerMin=617` | 1 |
| Queue sample | `[COMM] ctl queue bulk=12 normal=0 alert=0 prefixesBusy=3` | 2 |
| Prefix throttled | `[COMM] WARN throttled prefix=FLootS2 type=ROWS retrying` | always |

### In-game checklist (A, B and C)

1. **Prepare.** Turn on test data on all three. A runs `gen 1000`. Let C catch up from A with a session, and check that A's and C's digests match.
2. **Parallel backfill.** On B: `purgetest`, then `forcehello`. Expect a `plan` line with secondaries, pull sessions opening, and `sync complete`. **Compare `rowsPerMin` with the phase 5 baseline** and paste both. Digests on A, B and C are identical.
3. **Secondary drops out.** Repeat step 2, and `/reload` C mid-way. Expect `reassign … from="C" reason=abort` on B, and the sync still completes with matching digests.
4. **Live award during a backfill.** While step 2 runs, A awards an item. Compare the time on A's `[LIVE] out` line with B's `[LIVE] in` line: they should be no more than a few seconds apart.
5. **Gameplay check.** During a backfill, play normally on B. There is no noticeable stutter, `[PERF] overrun` warnings are rare (a few per minute at most), no `throttled` warnings appear, and nobody disconnects.

### Done when

A 3-peer backfill is clearly faster than one peer, digests converge on all three clients, live messages are never delayed by bulk sync, and nothing disconnects.

## Phase 7: Council-session snapshot domain

This phase registers the running loot-council session as domain 2. Raid members who join late, reload or disconnect pick up the current session state through the same discovery handshake. It also proves the domain pattern works for a second kind of data.

### Build

1. **`Data/CouncilSessionDomain.lua`:** domain 2, strategy `snapshot`, scope RAID, gate `live` (spec 7.7).
   - **Single version point.** Find every place the existing code changes a session: start, add item, response, vote, award, end. Route them all through one `CouncilSessionDomain:Bump()`, which increments `rev`. If any change bypasses it, late joiners will see stale state.
   - `Summary()` returns `{sessionId, startedAt, rev, ended}`, or `nil` once an ended session is older than `SESSION_END_TTL`.
   - `Compare` follows spec 7.7: for the same session the higher `rev` wins; for a different session the later `startedAt` wins.
   - `Export` and `Import` use the `Codec` player and response-type dictionaries. `Import` validates the payload and applies it only when it is newer, then refreshes the council UI.
2. **`Peers`:** support RAID-scope `HELLO`.
   - Triggers: joining a raid group (`GROUP_ROSTER_UPDATE` when `IsInRaid()` turns true), `/reload` inside a raid (`PLAYER_ENTERING_WORLD` with `isReload`), and `Domains.NotifyChanged(2)` when a leader starts a session.
   - The `live` gate allows this inside instances and queues it during encounters.
3. **`Coordinator`** handles snapshot repairs:
   - `remoteNewer`: send `SNAP_GET` to the responder with the highest version.
   - `localNewer`: push a `SNAP`.
4. The existing live council messages stay exactly as they are. The snapshot path only exists to catch up a raid member.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Registered | `[DOMAIN] register id=2 name=councilSession strategy=snapshot scope=RAID gate=live` | 1 |
| Version bumped | `[SNAP] bump d2 session=6 rev=14->15 cause=vote` | 2 |
| RAID `HELLO` | `[PEERS] hello out scope=RAID trigger=joinRaid\|reloadInRaid\|notify domains=2` | 1 |
| Compare | `[SNAP] compare d2 from="<name>" local=6/14 remote=6/17 -> remoteNewer` | 1 |
| Request and reply | `[SNAP] get d2 to="<name>"`, then on the sender `[SNAP] export d2 rev=17 items=12 enc=3.2KB` | 1 |
| Import | `[SNAP] import d2 from="<name>" rev=14->17 result=applied\|stale\|invalid t=4ms` | 1 |
| Push | `[SNAP] push d2 to="<name>" rev=17` | 1 |
| Session ended | `[SNAP] ended d2 session=6 advertiseUntil=21:52`, later `[SNAP] summary d2 none reason=endedTtl` | 1 |

`/fl sync domains` now lists both domains:

```text
FL domains
  1 history        set       GUILD  gate=sync  W n=3410 x=1A2B3C4D  A n=102
  2 councilSession snapshot  RAID   gate=live  session=6 rev=17 ended=no
```

### In-game checklist (A leads; B and C in a raid group)

1. **Form a raid group** of A and B (a party converted to a raid works outdoors). A starts a council session and adds items. B follows along through the existing live messages, and `bump` lines appear on A.
2. **Late joiner.** C joins the raid mid-session. C shows `hello out scope=RAID trigger=joinRaid`, `compare … -> remoteNewer`, `get` and `import … result=applied`. C's council window shows the session exactly as A and B see it.
3. **Reload.** B runs `/reload` mid-session. Expect `trigger=reloadInRaid` and an import whose `rev` equals A's.
4. **Missed changes.** B logs out, A makes 3 changes, and B logs back in and rejoins the raid. B's import ends at A's current `rev`.
5. **Ended session.** A ends the session. A player who joins within 10 minutes imports it with `ended=yes`. After the TTL, `summary d2 none reason=endedTtl` appears and the RAID `HELLO` no longer carries domain 2.
6. **Inside a raid instance.** Repeat step 3 inside the instance: it works. During a boss pull, a reload's snapshot request is queued (`[GATE] live queued`) and completes after `ENCOUNTER_END`.
7. **History is unaffected.** Inside the instance, GUILD-scope `HELLO`s log `hello skip reason=gateClosed` while RAID-scope ones still go out.

### Done when

Every late joiner or reloaded raid member shows the leader's current session state within seconds, and history sync behaves exactly as in phase 6.

## Phase 8: Hardening and release

This phase makes the system safe for the whole guild: version handling, abuse limits, real pruning turned on, test tools locked away and quiet defaults. It ends with a week-long soak in the real guild.

### Build

1. **Versions:**
   - Send the addon version in every `HELLO` and `HELLO_ACK`.
   - Ignore peers with a different `PROTO_VERSION`, and treat a different retention value as `incompatible`.
   - When a peer runs a newer addon version, show one normal chat line per session: "A newer ForeverLoot is available."
2. **Old-release safety.** Check what the previous release does with unknown messages on its own prefix. If old clients would raise errors on the new messages, register the new prefixes under names the old release never listened to.
3. **Abuse limits:**
   - Process at most 5 `HELLO`s per sender per minute, and at most 3 `OPEN`s per sender per minute.
   - Drop any reassembled message larger than 64 KB before decoding it.
4. **Turn on real pruning:** `PRUNE_REAL = true`. The first real prune logs its counts, which should match the phase 3 dry run.
5. **Lock the test tools.** `gen`, `droplocal`, `forcedelete`, `maxserve` and `keyitem` only work while test-data mode is on.
6. **Defaults for new installs:** debug off and level 1. `WARN` and `ERR` lines still go to the buffer.
7. **Status:** `/fl sync status` adds the addon's memory use, from `UpdateAddOnMemoryUsage()` and `GetAddOnMemoryUsage()`.
8. **`/fl debug spamhello <n>`** (test mode only): sends `n` `HELLO`s in quick succession, to test the rate limit.

### Debug output to add

| When | Line | Level |
| --- | --- | --- |
| Peer version seen | `[PEERS] version peer="<name>" addon=0.9.0 proto=1 newer=yes` | 1 |
| Rate limit | `[COMM] WARN ratelimit from="<name>" type=HELLO dropped=5` | always |
| Oversize message | `[COMM] WARN oversize from="<name>" type=ROWS bytes=81234 limit=65536` | always |
| First real prune | `[PRUNE] prune removedReal=212 removedTest=0 keptPinned=9 first=yes` | 1 |
| Locked test command | `[TEST] refused cmd=gen reason=testdataOff` | 1 |

Final `/fl sync status`:

```text
FL sync status  addon=1.0.0 proto=1 memory=1.9MB
  gate: sync=open live=open reason=none
  store: rows=3410 tombstones=12 pins=9 test=0
  digest: W n=3410 x=1A2B3C4D  A n=102 x=0BADF00D  cutoff=2026-06-01
  domains: 1 history same-as-last-peer | 2 councilSession none
  peers: known=7  last hello out 6m ago  last match heard 2m ago
  sessions: out=0 in=0
  debug: off (warnings buffered: 0)
```

### In-game checklist

1. **Mixed versions.** B runs the previous public release, and A runs the new build. B shows no Lua errors. A logs `version peer="B" …`, and the update hint appears for whichever client is older.
2. **Fresh install.** Debug is off, nothing prints, and `/fl debug log` shows only warnings, if any.
3. **Real prune.** Log in with the new build. The `removedReal` count matches the phase 3 dry run, and pinned rows survive.
4. **Locked tools.** With test data off, `/fl debug gen 5` logs `refused`.
5. **Rate limit.** In test mode on B, `/fl debug spamhello 20`. A logs `WARN ratelimit` and doesn't lag.
6. **Guild soak.** Release to 3–5 guild members for a week, and ask them to keep `/fl debug on` at level 1. At the end of the week, compare `/fl sync digest` across them; they should match. Collect any `WARN` or `ERR` lines with `/fl debug log`.

### Release checklist

- [ ] `PROTO_VERSION` incremented if the wire format changed during development.
- [ ] `docs/sync-deviations.md` reviewed, and the spec updated to match the code.
- [ ] Changelog entry, including that officers are the only ones who can delete.
- [ ] The guild has been told everyone should update, and that the first login may take a few minutes to catch up.

## Reading the logs: symptom to cause

When something looks wrong, find the symptom below, check the listed lines, and paste the evidence into Claude Code. Most problems show up as a specific pattern of debug lines on one of the two clients.

### What to paste into Claude Code

1. The phase number, and which client (A, B or C) each piece came from.
2. `/fl sync status` and `/fl sync digest` from **both** clients involved.
3. `/fl debug log` from both, covering the time of the problem. Use level 2, or level 3 for problems in a single bucket.
4. For a single row, `/fl sync dump <id>` from both clients.

### Symptoms

| Symptom | Look for | Likely cause |
| --- | --- | --- |
| Digests never match, even after sessions end | The same `[SESS] bucket <day>` line in every session with `want=0 give=0` | Both sides hold the same ids, but hash them differently: the id string or `rowTime` differs between clients. Compare `/fl sync dump <id>` on both, field by field. |
| A session ends with `rootsMatch=no` every time | `[SESS] months … mismatched=` lists a month whose buckets never appear | Month and day keys are computed differently (local time used instead of UTC), or the archive tree is skipped. |
| Nobody answers `HELLO` | `[PEERS] ack decide … -> silent` on the peers, with `reason=` | `gateClosed` is expected inside instances. `roll` every time in a small group means `knownPeers` is miscounted. `d1=incompatible` means a retention or cutoff mismatch. |
| A session always times out | `[SESS] batch out` with no matching `batch sent`, then `abort reason=timeout` | AceComm's progress callback isn't firing, or the bundled ChatThrottleLib is too old for the per-prefix throttle (spec 9.1). |
| `[CODEC] WARN decode fail step=decompress` | The sender's addon version in `/fl sync peers` | Mismatched builds, or another addon using the same prefix. Check the `version` lines. |
| Rows rejected with `reason=expired` on the receiver | `[PRUNE] cutoff` on both clients | The cutoffs differ. This heals by itself if it happens at a month boundary; otherwise it is a time-source bug (must be `GetServerTime()` in UTC). |
| `rawIds` above 0 | `[CODEC] id raw … reason=leaderUnknown` | The session leader left the guild, so the raw-id fallback is working as designed. Any other reason points to a pattern bug. |
| `[ITEM] WARN unresolved` | The `itemID` in the line | The item's data never loads on this client. It's cosmetic, since the row still holds its item string. |
| A deleted row comes back | `[STORE] tombstone` for that id on the client where it reappeared | The tombstone was never stored, or a test row was involved. Check the `result=` on the row's later `apply` line: it must be `tombstoned`. |
| Stutter during sync | `[PERF] WARN overrun task=decode` or `task=apply` | Batches are too big for the frame budget. Lower `BATCH_TARGET_BYTES` or split the apply work into smaller slices. |
| Disconnects during sync | `[COMM] ctl queue` showing all prefixes busy just before the disconnect | The total send rate is too high. Use fewer sync prefixes, or lower ChatThrottleLib's rate. |
| A late joiner sees a stale council session | `[SNAP] import result=stale`, while the leader's `bump` lines show a higher `rev` | A session change doesn't go through `CouncilSessionDomain:Bump()`. Search the code for the change that has no `bump` line. |
