# ForeverLoot — Loot Council module

## Context

ForeverLoot currently has ad-hoc roll-off tracking (`RollTracker.lua`) and a trade queue
(`Trade.lua`/`UI/TradeQueueWindow.lua`), but no way to run a loot-council-style session:
build a list of items, broadcast it to the raid with a fixed set of response options + an
optional note, collect every raider's response, let a manually-configured council vote per
candidate, and have the session leader award the item — which flows into the existing
trade queue exactly like a roll-off award does, and is recorded to a persistent history log.

The user has built two prior references, both read-only, never modified by this feature:
- **RCLootCouncil** (`/Users/Cory/Developer/Code/ForeverLoot_v2/RCLootCouncil/`) — the
  full-featured original this is modeled on. Its data shapes (item entries, per-candidate
  response tables, vote deltas, award/history logging) are the primary design inspiration.
- **BrickedRaidHelper** (`/Users/Cory/Developer/Code/ForeverLoot_v2/BrickedRaidHelper/LootCouncil/`)
  — the user's own earlier, incomplete attempt at the same feature. Useful as a cautionary
  reference: it never implemented voting, award, or history, and it had a real bug
  (responses stored as an unkeyed array instead of keyed by player name, so duplicate
  responses silently accumulated instead of overwriting). This design deliberately avoids
  repeating that bug — see `candidates` in §1.

This must work identically across all 3 UI skins (Default/Blizzard/BlizzardThin).
ForeverLoot's existing Theme system (`UI/Theme/`) already makes this a non-issue: windows
are built once against the skin-agnostic `FL.Theme.*` API, and the active skin is
dispatched automatically — **no per-skin branching is needed anywhere in this feature.**

User-confirmed design decisions (asked directly, not assumed):
- **Item source (Phase 1):** manual item-link entry, plus a bulk "Add All Tradeable"
  command that scans the leader's own bags for BoP items with a tradeable-timer remaining
  (leader-side only, no raider round-trip).
- **Response options:** a fixed starter list (not configurable in v1).
- **Voting model:** per-candidate approve/unapprove toggle, live tally, visible to all
  council members (matches RCLootCouncil's model, not a single-choice radio).
- **Council roster:** a manually configured list stored in `FL.DB`, independent of raid
  rank/assist status.
- **Comm channel:** a brand-new, dedicated AceComm prefix for this feature (`"ForeverLootLC"`)
  — **not** the existing `"GargulComm2"` channel `Comm.lua` speaks. That channel mirrors
  Gargul's exact addon-comm wire protocol for real interop with real Gargul clients in the
  raid; inventing custom action ids on it would be a first for a ForeverLoot-original
  feature and would broadcast unrelated traffic to any real Gargul user in the raid. A
  dedicated prefix keeps this fully isolated, mirroring `Comm.lua`'s own
  serialize/compress/encode pipeline (same libs already loaded: AceComm-3.0, LibSerialize,
  LibDeflate).

---

## Implementation status

| Phase | Done | Notes |
|---|---|---|
| 1 Add items to the list | yes | commit `e50ae2b`; confirmed working in-game by the user |
| 2 Broadcast to raid | yes | dedicated `"ForeverLootLC"` prefix, `Util.GroupDistribution` extracted, `SendToRaid`/`applySessionStart` implemented as designed, no deltas from plan |
| 3 Raider response | no | |
| 4 Council review (read-only) | no | |
| 5 Voting | no | |
| 6 Award + trade queue + history | no | |
| 7 Roster config UI | no | |
| 8 History browser (stretch) | no | |
| 9 Harden session sharing for late/reconnecting raiders | no | |
| 10 Harden initiator `/reload` mid-session | no | |

See §7 below for what each phase delivers and how to verify it. Update this table (and add
a "deltas from the original design" note under the relevant phase in §7, same convention
`FOREVER_MIGRATION.md` uses) each time a phase lands.

---

## 1. DB schema — `FL.DB.lootCouncil`

Set up once in `LootCouncil.Init()`, following the exact convention every other module uses
(`Trade.Init`, `Settings.Init`): guard with `or {}`, then point module-local tables directly
at the DB slice so every mutation auto-persists.

```lua
FL.DB.lootCouncil = FL.DB.lootCouncil or {
    roster  = {},              -- set: [strippedPlayerName] = true
    draft   = { items = {} },  -- leader's in-progress, unbroadcast list (Phase 1)
    history = {},              -- array, oldest-first, append-only
    session = nil,             -- live broadcast session (Phase 2+), nil until one has run
};
LootCouncil.Roster  = FL.DB.lootCouncil.roster;
LootCouncil.Draft   = FL.DB.lootCouncil.draft;
LootCouncil.History = FL.DB.lootCouncil.history;
LootCouncil.CurrentSession = FL.DB.lootCouncil.session;
```

`CurrentSession` is **persisted**, unlike `RollTracker.CurrentRollOff` — deliberately
diverging from that precedent. A roll-off is over in seconds, so losing it to a `/reload`
is harmless; a loot-council session can run for most of a raid night and accumulate many
raiders' responses and council votes, so losing it to a `/reload` would be genuinely
costly. See §7 Phase 10 for the additional catch-up handshake needed on top of persistence,
to cover the gap between "session was still live when this client went offline/reloaded"
and "some responses/votes arrived while it was down."

**`roster`** — a set keyed by `Util.stripRealm(name)` (same membership convention
`Util.groupMembers()` already uses):
```lua
roster = { ["Thrall"] = true, ["Jaina"] = true }
```
`LootCouncil.IsCouncilMember(name) = LootCouncil.Roster[Util.stripRealm(name)] == true`.

**`draft.items`** (Phase 1, local only, never touches comm):
```lua
draft.items[i] = {
    itemLink = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r",
    itemID   = 19019,
    source   = "manual" | "bagscan",  -- informational only, shown in the Add Items window
}
```

**`CurrentSession`** (persisted at `FL.DB.lootCouncil.session`, the live broadcast session,
built by Phase 2's `applySessionStart` on every client including the initiator, via the
self-looped broadcast):
```lua
LootCouncil.CurrentSession = {
    active = true,
    id = sessionId,             -- comes from the sessionStart payload, NOT a local counter -
                                 -- every client must agree on the same id since later phases
                                 -- correlate response/vote/award messages by it
    initiatorFqn = Message.senderFqn,
    initiatorIsMe = Message.isSelf,
    startedAt = GetTime(),
    status = "active",          -- "active" | "closed"
    items = {
        [1] = {
            session = 1,          -- stable per-item index within this session
            itemLink = "...",
            itemID = 19019,
            itemName = "...",
            itemQuality = 4,
            itemIcon = nil,        -- may be nil until GET_ITEM_INFO_RECEIVED - Phase 2 does a
                                    -- one-shot resolve + prefetch only; the refresh-on-arrival
                                    -- listener (mirroring RollTracker.lua) is added in Phase 3,
                                    -- the first phase with a window that needs to redraw on it
            awardedTo = nil,
            awardedAt = nil,
            candidates = {},       -- KEYED BY PLAYER NAME (not an array) — the deliberate fix
                                    -- for BrickedRaidHelper's array-based de-dup bug
        },
    },
};
```

**`candidates`** — keyed by player name (Phase 3+):
```lua
item.candidates["Jaina"] = {
    class = "MAGE",              -- SENT OVER COMM as part of the response payload (not resolved
                                  -- locally via Util.groupMembers()) so a candidate's class is
                                  -- still known even if they log off or leave the group before
                                  -- the council reviews the item
    response = "MAJOR",          -- one of Constants.LOOT_COUNCIL_RESPONSES ids
    note = "BiS for my spec",    -- optional free text
    respondedAt = GetServerTime(),
    approvals = {},              -- set, keyed by council-member name who currently approves
                                  -- this candidate for this item
}
```
Live vote tally = `Util.tcount(candidate.approvals)` (new tiny helper to add to
`Core/Util.lua` when Phase 5 needs it — counts keys in a set; nothing equivalent exists
yet). Approve/unapprove is a toggle on set membership, sent as the voter's **resulting
absolute state**, not a `+1/-1` delta like RCLootCouncil — deliberately: a delta
permanently desyncs if a single vote message is ever dropped, while an idempotent "this
voter's current state is X" message self-heals on retransmit or relog.

**`history`** — persistent record (Phase 6+):
```lua
history[i] = {
    id = "3-1",                  -- "%d-%d":format(sessionId, itemSession), dedupes if an award
                                  -- broadcast is processed twice
    itemLink = "...", itemID = 19019, itemIcon = "...",
    awardedTo = "Jaina", awardedToClass = "MAGE",   -- NOT "winner"/"winnerClass" — matches the
                                                     -- item entry's own `awardedTo` field name
    awardedBy = "Thrall",         -- session leader's name
    awardedAt = GetServerTime(),
    sessionId = 3, itemSession = 1,
    responses = {                 -- snapshot copied at award time, so later edits can't
                                   -- retroactively rewrite history
        ["Jaina"]  = { response = "MAJOR", note = "BiS for my spec", votes = 3 },
        ["Thrall"] = { response = "OFFSPEC", note = "", votes = 0 },
    },
}
```
Plain array (matches `FL.DB.tradeQueue`'s convention — no AceDB anywhere in this project).
**Every client** appends to it on receiving the award broadcast, not just the leader — so
the log survives the leader disconnecting or swapping characters.

Note: `Trade.QueueAdd`'s entry table still uses `winner` (§6) — that's `Trade.lua`'s own
established field name, unrelated to this rename and not to be changed, since `Trade.lua`
isn't being modified.

---

## 2. Comm protocol — dedicated prefix

`ForeverLoot/LootCouncil.lua` registers its own AceComm prefix (`LC_PREFIX =
"ForeverLootLC"`, implemented in Phase 2), mirroring `Comm.lua`'s serialize → compress →
encode pipeline (same libs, already loaded: AceComm-3.0, LibSerialize, LibDeflate) but
**without** Gargul's version-handshake fields, since there's no third-party protocol to
satisfy here. `Util.GroupDistribution(channel, recipient)` — extracted from `Comm.lua`'s
former `resolveChannel` in Phase 2 — is shared by both comm layers.

Action names (plain strings, no Gargul-numeric-id constraint):

| Action | Direction | Channel | Payload | Phase |
|---|---|---|---|---|
| `sessionStart` | leader → raid | GROUP | `{ sessionId, items = { itemLink, ... } }` | 2 (done) |
| `response` | raider → raid | GROUP | `{ sessionId, itemSession, response, note, class }` | 3 |
| `vote` | council member → raid | GROUP | `{ sessionId, itemSession, targetPlayer, approved }` | 5 |
| `award` | leader → raid | GROUP | `{ sessionId, itemSession, winner }` | 6 |
| `stopSession` | leader → raid | GROUP | `{ sessionId }` (optional/stretch — cancel) | — |
| `sessionRequest` | raider → raid | GROUP | `{}` | 9 |
| `catchUpRequest` / `catchUpResponse` | initiator ↔ raid | GROUP / WHISPER | | 10 |

Design notes:
- **Item list sent as full item links, always**, not RCLootCouncil's trimmed
  compact-string-plus-cache-rebuild — matches this project's own existing precedent
  (`RollTracker.StartRollOff` already sends a full item link as `content.item`), and
  `LibDeflate` compression already absorbs the bandwidth cost RC was optimizing away. Full
  `itemLink` (never a bare `itemID` reconstructed into a synthetic link) is required
  everywhere an item is sent or stored — `sessionStart.items`, `CurrentSession.items[i].itemLink`,
  and `history[i].itemLink` — since the link string is what actually carries bonus IDs, gem
  sockets, and other on-the-fly modifiers. `itemID`/`itemName`/`itemQuality`/`itemIcon` are
  still resolved locally from the link for display purposes, but the canonical
  stored/transmitted value is always the full link.
- **`class` is sent explicitly in the `response` payload**, not resolved locally via
  `Util.groupMembers()` — a candidate's class needs to still be known to the council even
  if that player later logs off, leaves the group, or otherwise drops out of the local
  roster lookup before the review/award step.
- **`response` and `vote` are broadcast to the whole group**, not whispered to the leader —
  so every client's local `CurrentSession` (council and non-council members alike)
  converges with no fan-out/roster-sync logic needed, mirroring how roll results are
  already public group information in `RollTracker`.
- The **`vote` handler must independently verify** `LootCouncil.IsCouncilMember(Message.senderName)`
  before applying — never trust the sender's own claim.
- On `award`, **only the sender's own client** (`Session.initiatorIsMe`) additionally calls
  `FL.Trade.QueueAdd`/`FL.Trade.AttemptTrade` — same gating pattern `RollTracker.AwardItem`
  uses (`RollTracker.lua:323`); every other client just marks `awardedTo` and appends to
  local history.
- **Session id ownership:** the leader generates `sessionId` locally (a simple incrementing
  counter, `nextSessionId` in `LootCouncil.lua`) and includes it in the `sessionStart`
  payload; every receiver — including the sender itself, via WoW's self-looped
  addon-message delivery to a channel you're in — reads `Message.content.sessionId` rather
  than generating its own. This is unlike `RollTracker`'s `rollOffId`, which is a purely
  local per-client counter never sent over the wire (fine there, since it's only used for
  that client's own trade-queue dedupe).

---

## 3. New files and `ForeverLoot.toc` placement

**Logic** (flat root, after `Trade.lua`, before `Tooltip.lua`):
- `ForeverLoot/LootCouncil.lua` — DB init, dedicated comm registration/dispatch, `Draft.*`
  (Phase 1), bag scan (Phase 1), session broadcast (Phase 2), `SubmitResponse`,
  `ToggleVote`, `AwardItem`, roster helpers, history recording (later phases).

**UI** (`UI/`, after `UI\TradeQueueWindow.lua`, one file per phase so each phase stays
independently loadable):
- `UI/LootCouncilAddItemsWindow.lua` (Phase 1, done)
- `UI/LootCouncilResponseWindow.lua` (Phase 3)
- `UI/LootCouncilReviewWindow.lua` (Phases 4–6; owns a
  `StaticPopupDialogs["FOREVERLOOT_LC_AWARD_CONFIRM"]` entry, same minimal-popup pattern
  `UI/RollWindow.lua:72` uses)
- `UI/LootCouncilRosterWindow.lua` (Phase 7)
- `UI/LootCouncilHistoryWindow.lua` (Phase 8, stretch)

**`Core/Init.lua`**: `FL.LootCouncil` and its `modules`-list registration already exist from
Phase 1 — nothing further needed there for Phase 2. Each `FL.UI.LootCouncil*Window`
namespace gets added incrementally, per phase, as its window file is introduced.

**`Debug.lua`**: add each new window's `ResetPosition()` call to `resetAllWindowPositions()`
as it's introduced. `/flc` is the Loot Council entry-point slash command (Phase 1: toggles
the leader-facing Add Items window; Phase 9 extends it to show the "no active session"
panel when the player has no local session). `/fl commdebug` toggles both `Comm.lua`'s and
`LootCouncil.lua`'s debug printing together (wired in Phase 2).

**`Core/Util.lua`**: `Util.GroupDistribution(channel, recipient)` added in Phase 2
(extracted out of `Comm.lua`'s former `resolveChannel`, shared by both comm layers).
`Util.tcount(t)` (count keys in a set) still to be added when Phase 5 needs it.

---

## 4. Window mockups

All windows built once via `FL.Theme.CreateWindow`, `CreateScrollFrame`, `SkinScrollBar`,
`SkinCloseButton`, `SkinIconBorder`, `SkinButton`/`SkinAccentButton`, `SkinEditBox`,
`MakeBottomResizable`, and `FL.Settings.GetWindowPosition`/`SetWindowPosition` — following
`UI/TradeQueueWindow.lua`'s established structure (pooled icon rows, row-wide highlight,
`OnUpdate`-polled tooltip). No skin-specific code anywhere.

**(a) Leader — "Add Items to List"** (Phase 1, done)
```
+----------------------------------------------------+
| ForeverLoot - Loot Council: Build List          [X] |
+----------------------------------------------------+
| [ item link.................. ] [Add]               |
| [       Add All Tradeable From Bags        ]         |
+----------------------------------------------------+
| [icn] Sulfuron Hammer                      [Remove] |
| [icn] Ashkandi                             [Remove] |
| [icn] Thunderfury                          [Remove] |
+----------------------------------------------------+
| 3 items in list              [   Send to Raid   ]   |
+----------------------------------------------------+
```
`[Add]` accepts a pasted item link only (validated via `Util.isValidItemLink`) — name-search
is out of scope for v1. "Add All Tradeable From Bags" runs a bag scan (see §5) and appends
de-duped results. As shipped, there is no manual reordering (see the Phase 1 deltas in §7).

**(b) Raider — "Respond to Items"** (Phase 3)
```
+----------------------------------------------------+
| ForeverLoot - Loot Council: Respond             [X] |
+----------------------------------------------------+
| [icn] Ashkandi                                      |
|   (Major)(Minor)(Offspec)(Mog)(Pass)                |
|   Note: [_______________________________]          |
+----------------------------------------------------+
| --------------------- Responded --------------------|
| [icn] Sulfuron Hammer                      Sent |✓| |
|   (Major)(Minor)(Offspec)(Mog)(Pass)                |
|   Note: [_______________________________]          |
+----------------------------------------------------+
```
Auto-opens on receiving `sessionStart` if any item lacks a local response (same
"broadcast pops the window" pattern `applyStart` uses for `RollWindow.Show()`). Clicking a
response fires `SubmitResponse` immediately, and that item moves to a "Responded" section
below a separator, under still-pending items. Typing a note *before* picking a response
does **not** trigger a send or a re-sort. Once an item has moved into the "Responded"
section, changing the selected response afterward re-sends the updated response but does
**not** move or re-sort the row again — its position is fixed once it first crosses into
"Responded."

**(c) Council — "Review & Vote"** (Phases 4–6)
```
+------------------------------------------------------------------+
| ForeverLoot - Loot Council: Review & Vote                    [X] |
+------------------------------------------------------------------+
| Items          | Sulfuron Hammer                                 |
| >[icn] Sulfuron |----------------------------------------------- |
|  [icn] Ashkandi | Player    Response   Note        Votes  [+/-]  |
|  [icn] Thnderfy | Jaina     Major      "bis spec"    [3]  [✓]    |
|                 | Thrall    Offspec    ""             [1]  [ ]   |
|                 | Malfurion (no response yet)          -   -    |
|                 |          [ Award to Jaina (3 votes) ]          |
+------------------------------------------------------------------+
```
Left pane: pooled item-icon rows. Right pane: per-candidate table for the selected item.
**This entire window is gated to council members only** —
`LootCouncil.IsCouncilMember(UnitName("player"))` is checked before the window is ever
shown; a non-council member has no way to open it at all. `[✓]/[ ]` toggle calls
`ToggleVote`. `[Award to X]` enabled only when `CurrentSession.initiatorIsMe` is true and a
candidate row is selected.

*Nuance to be aware of:* since the window is council-gated and the award button is
initiator-gated, a session leader who forgets to add themselves to the roster (§Phase 7)
won't be able to open this window to award anything. Decide at implementation time whether
`AwardItem`'s initiator check should implicitly also grant window access, or whether
leaders are simply expected to always be on the roster.

**(d) Award confirmation** — a `StaticPopupDialogs` entry, no custom frame (same minimal
approach as `RollWindow.lua`'s existing award popup):
```
+---------------------------------------+
|  Award [Sulfuron Hammer] to Jaina?    |
|       [ Award ]      [ Cancel ]        |
+---------------------------------------+
```

**(e) History browser** (Phase 8, stretch) — same pooled-row list as `TradeQueueWindow`,
read-only, newest-first, click-to-tooltip.
```
+----------------------------------------------------+
| ForeverLoot - Loot Council: History             [X] |
+----------------------------------------------------+
| [icn] Sulfuron Hammer  -> Jaina        2026-09-20   |
| [icn] Ashkandi         -> Thrall       2026-09-20   |
+----------------------------------------------------+
```

---

## 5. Bag scan for "Add All Tradeable" (Phase 1, done)

Scans the standard Blizzard BoP-trade tooltip line via a hidden scanning tooltip, since
`C_Container.GetContainerItemInfo`'s `isBound` flag alone can't distinguish "still
tradeable" from "timer expired." Implemented as `LootCouncil.ScanBagsForTradeable()` /
`LootCouncil.DraftAddAllTradeable()`, see `LootCouncil.lua`.

`BIND_TRADE_TIME_REMAINING`'s exact current wording was verified in-client (`/dump
BIND_TRADE_TIME_REMAINING`) — confirmed working by the user.

---

## 6. Trade queue integration (`FL.Trade` — no modification needed)

`LootCouncil.AwardItem(itemSession, playerName)` (Phase 6) mirrors `RollTracker.AwardItem`
(`RollTracker.lua:314-377`) closely, reusing the existing `rollOffId`-keyed dedupe
(`Trade.QueueRemoveByRollOff`, `Trade.lua:105-111`) with a composite id instead of adding a
parallel `Trade.QueueRemoveByCouncilSession` function:

```lua
function LootCouncil.AwardItem(itemSession, playerName)
    local Session = LootCouncil.CurrentSession;
    if (not Session or not Session.initiatorIsMe) then
        print("|cff8865ffForeverLoot|r Only the loot council session leader can award this item.");
        return;
    end
    local item = Session.items[itemSession];
    if (not item or item.awardedTo) then return; end

    item.awardedTo = playerName;
    item.awardedAt = GetServerTime();
    local candidate = item.candidates[playerName];

    local councilAwardId = Session.id * 10000 + itemSession; -- reuses Trade's existing
                                                               -- rollOffId-scoped dedupe unmodified
    FL.Trade.QueueRemoveByRollOff(councilAwardId);
    FL.Trade.QueueAdd({
        itemLink = item.itemLink, itemIcon = item.itemIcon, itemID = item.itemID,
        winner = playerName, rollOffId = councilAwardId, rollAmount = nil,
        classification = candidate and responseLabel(candidate.response),
        winnerClass = candidate and candidate.class,
    });
    FL.Trade.AttemptTrade(playerName, item.itemLink, function(success, reason) ... end);

    LootCouncil.RecordHistory(Session, itemSession, playerName);
    lcSend("award", { sessionId = Session.id, itemSession = itemSession, winner = playerName }, "GROUP");
end
```
`Trade.lua`, `UI/TradeQueueWindow.lua`, and `Tooltip.lua` need **no code changes**.

---

## 7. Phased build order (each phase independently shippable/testable)

**Phase 1 — Add Items to the List** ✅ DONE (commit `e50ae2b`, on `main`)
`LootCouncil.lua` (DB init, `Draft.AddItem/RemoveItem`, `ScanBagsForTradeable`),
`UI/LootCouncilAddItemsWindow.lua`, `Core/Init.lua` + toc entries, `Debug.lua` slash
command.
*Verify:* `/flc` opens the window; paste item link + Add; loot a BoP item, click "Add All
Tradeable", confirm it appears; remove; `/reload` and confirm draft survives
(`/dump ForeverLootDB.lootCouncil.draft`); toggle all 3 skins + `/reload` each. **Confirmed
working by the user in-game.**

Deltas from the original design, made during implementation based on user feedback:
- **No manual reordering.** The up/down arrow buttons in the mockup were cut; rows are just
  icon + name + delete. `LootCouncil.DraftMoveItem` was never kept.
- **Duplicates are allowed, on purpose.** The itemID de-dupe check in `DraftAddItem` was
  removed — the same item can drop more than once in a raid, so adding it twice creates two
  independent rows rather than being rejected or merged.
- **Delete button matches `TradeQueueWindow` exactly**, not a plain "X" — extracted into a
  new shared `FL.Theme.CreateDeleteButton(parent, size)` (`UI/Theme/Helpers.lua` +
  `Theme.lua`), and `TradeQueueWindow.lua` was refactored to use it too.
- **`/flc add [item link] [item link] ...`** was added as a second entry point alongside the
  box, plus multi-link support in the box itself (`LootCouncil.ExtractItemLinks`/
  `DraftAddItemsFromText`).
- **Item-link extraction is wrapper-agnostic** — matches the mandatory `|Hitem:...|h[Name]|h`
  core and opportunistically extends over whatever prefix/suffix is actually present.
- **Shift-click-to-insert-into-the-box** required hooking `HandleModifiedItemClick`, not
  `ChatEdit_InsertLink`.
- **"Add All Tradeable From Bags" anchor bug fixed**: re-anchored to `frame`'s own
  TOPLEFT/TOPRIGHT instead of `itemLinkBox`'s off-center anchor.

**Phase 2 — Broadcast to raid** ✅ DONE
`Util.GroupDistribution` extraction (`Core/Util.lua`), dedicated comm prefix registration
(`"ForeverLootLC"`), `LootCouncil.SendToRaid()`, `sessionStart` handler
(`applySessionStart`). `Debug.lua`'s `/fl commdebug` extended to also toggle
`LootCouncil.debugEnabled`.
*Verify:* two clients grouped — leader clicks "Send to Raid" in the existing Add Items
window; second client's `/run print(ForeverLoot.LootCouncil.CurrentSession.id)` matches the
leader's; `/dump ForeverLootDB.lootCouncil.session` shows the same items on both; `/fl
commdebug` shows `lc*` SEND/RECV lines for the `sessionStart` action.

No deltas from the original design — implemented as planned. Item icon/name/quality are
resolved once per item at session-start time (with a `C_Item.RequestLoadItemDataByID`
prefetch if not yet cached); the `GET_ITEM_INFO_RECEIVED` refresh-and-redraw listener
(mirroring `RollTracker.lua`'s `ensureItemInfoFrame`) is deliberately deferred to Phase 3,
since no Phase 2 UI needs to react to a late-arriving icon.

**Phase 3 — Raider response**
`UI/LootCouncilResponseWindow.lua`, `SubmitResponse` (includes `class`), `response`
handler, pending/responded sort-and-separator behavior (§4b), and the
`GET_ITEM_INFO_RECEIVED` refresh listener deferred from Phase 2.
*Verify:* response window auto-opens on receipt; typing a note first does not move the row;
click response, confirm it moves below the "Responded" separator and stays put even if the
response selection is later changed; confirm other clients'
`CurrentSession.items[1].candidates["Name"].response`/`.class` updates.

**Phase 4 — Council review (read-only)**
`UI/LootCouncilReviewWindow.lua` (list + candidate table, vote/award controls disabled),
gated entirely behind `LootCouncil.IsCouncilMember`.
*Verify:* council member (stopgap: `/run FL.DB.lootCouncil.roster["Name"]=true` before
Phase 7's UI exists) sees every response+note populate live; confirm a non-council client
has no way to open the window at all.

**Phase 5 — Voting**
`ToggleVote`, `vote` handler (with sender-is-council-member check), wire toggle + live
tally into the review window. Add `Util.tcount(t)` to `Core/Util.lua`.
*Verify:* two council clients toggle different candidates for the same item, tallies match
on both screens live; confirm a non-council client's toggle is rejected.

**Phase 6 — Award + trade queue + history**
`AwardItem`, `FOREVERLOOT_LC_AWARD_CONFIRM` popup, `award` handler, `RecordHistory`.
*Verify:* Award → confirm popup → item appears in `TradeQueueWindow`; complete/fail trade,
confirm existing `Trade.lua` behavior is unchanged; `/dump ForeverLootDB.lootCouncil.history`
shows the new entry **on every client**, not just the leader's.

**Phase 7 — Roster config UI**
`UI/LootCouncilRosterWindow.lua`, replacing the `/run` stopgap.
*Verify:* add/remove names; review-window vote access follows live, no reload needed.

**Phase 8 — History browser (stretch)**
`UI/LootCouncilHistoryWindow.lua`.
*Verify:* lists all past awards newest-first, click-to-tooltip, all 3 skins.

**Phase 9 — Harden session sharing for late/reconnecting raiders**
A raider who wasn't present for the `sessionStart` broadcast (offline, zoned, addon just
loaded) has no local `CurrentSession` at all. Add to `/flc`: if `LootCouncil.CurrentSession`
is nil (or its `status` isn't `"active"`), show a small window — "No active loot council
session" + a `[Request Session]` button. Clicking it sends `lcSend("sessionRequest", {}, "GROUP")`.
Register a `sessionRequest` handler: only the actual session initiator
(`CurrentSession.initiatorIsMe`) acts on it, and replies by re-sending the full current
session state — items + all candidates' responses/votes — via
`lcSend("sessionStart", fullState, "WHISPER", Message.senderName)` targeted at just the
requester.
*Verify:* have a raider log in or reconnect mid-session with no local session state; run
`/flc`, confirm the "no session" window + request button appear; click it, confirm the
initiator's client whispers back the full state and the raider's `CurrentSession` populates
to match everyone else's.

**Phase 10 — Harden initiator `/reload` mid-session**
Even with `CurrentSession` persisted (§1), a `/reload` has a window where messages sent by
others can arrive while the addon is unloaded and be missed entirely. On
`LootCouncil.Init()`, if a persisted `CurrentSession` exists with `status == "active"`,
broadcast `lcSend("catchUpRequest", { sessionId = CurrentSession.id }, "GROUP")`. Every
other client that has local state for that `sessionId` replies via
`lcSend("catchUpResponse", { sessionId, itemSession, response, note, class, votes = {...} }, "WHISPER", Message.senderName)`.
The reloaded initiator merges each reply into its (already mostly-correct, persisted)
`CurrentSession` — a reconciliation merge, not a wholesale overwrite.
*Verify:* start a session, collect a few responses and votes, have the initiator `/reload`
while a raider is mid-response, have that raider submit their response *during* the
initiator's reload window, confirm the initiator's `CurrentSession` still ends up complete
after the catch-up round-trip (`/dump ForeverLootDB.lootCouncil.session`).

---

## 8. Cross-cutting verification

- **Multi-client**: two WoW clients (or duoed alts) grouped, one council leader, at least
  one plain raider and one second council member — required starting Phase 2.
- **Skin coverage**: after any UI file change, cycle Options → Theme through
  Default/Blizzard/BlizzardThin with `/reload` each time. Since no phase introduces
  skin-specific branching, a bug appearing in only one skin means a `FL.Theme.*` call was
  skipped somewhere.
- **State inspection**: `/dump ForeverLootDB.lootCouncil` shows `roster`/`draft`/`history`/
  `session`; `/run print(ForeverLoot.LootCouncil.CurrentSession and ForeverLoot.LootCouncil.CurrentSession.id)`
  for a quick check without a full dump.
- **Comm debug**: `/fl commdebug` toggles both `FL.Comm.debugEnabled` and
  `FL.LootCouncil.debugEnabled` together, printing SEND/RECV lines for both prefixes.
- **Regression check**: after Phase 6, confirm roll-off awards and loot-council awards
  coexist correctly in the trade queue (both use `rollOffId`-keyed dedupe) and are each
  removed independently on successful trade.
- **`luac -p`** every edited file before in-game testing (mirrors how the Forever API
  migration was verified, per `docs/FOREVER_MIGRATION.md`).

---

## Critical files

- `ForeverLoot/LootCouncil.lua` — module core: DB, draft, bag scan, dedicated comm layer,
  `SubmitResponse`/`ToggleVote`/`AwardItem` (later phases)
- `ForeverLoot/UI/LootCouncilReviewWindow.lua` (not yet created) — the most complex window:
  review, vote, award
- `ForeverLoot/UI/LootCouncilAddItemsWindow.lua` — Phase 1 deliverable
- `ForeverLoot/Core/Util.lua` — `Util.GroupDistribution` (added, Phase 2), `Util.tcount`
  (still to add, Phase 5)
- `ForeverLoot/Core/Init.lua` — namespace + modules-list registration
- `ForeverLoot/RollTracker.lua` — reference implementation to mirror for session lifecycle,
  comm dispatch, `AwardItem`
- `ForeverLoot/UI/TradeQueueWindow.lua` — reference implementation to mirror for window
  structure/visual conventions
- `ForeverLoot/Trade.lua` — consumed as-is via `QueueAdd`/`QueueRemoveByRollOff`/
  `AttemptTrade`, no changes needed
- `ForeverLoot/ForeverLoot.toc` — load-order insertions, one line per phase
