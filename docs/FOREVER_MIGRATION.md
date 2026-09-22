# ForeverLoot → WoW Forever: API migration report

## Context

ForeverLoot targets TBC Anniversary (`## Interface: 20506`, client 2.5.6). WoW Forever runs on the
Midnight (12.x) API. You reported that some registered events don't exist there. This document
lists every place the addon has to change, why, and how to verify it.

The sections below are the original findings, written before the code changes. **See "Implementation status"
for what has since been implemented**; the `file:line` references in sections 1-2 point at the pre-change code.

### Implementation status

All eight steps of section 5 are implemented. **The addon now targets WoW Forever only**: TBC Anniversary
compatibility was dropped, and the feature-detection and legacy code paths that briefly supported both
clients were removed again (legacy history events, old container/item fallbacks, `InterfaceOptions_*`,
`SetMinResize`, the `OnTooltipSetItem` hook).

Verified with a mock-WoW harness (real `Util.lua`, `GroupLootRoll.lua`, `Tooltip.lua` under a simulated
Forever client) and `luac -p` on every edited file. Confirmed in the live client by you: login with no
errors, the options panel and its tooltips, the API `/dump` checks, and item tooltips.

| Step | Done | Notes |
|---|---|---|
| 1 `pcall` each `Init()` | yes | `Core/Init.lua`; a failing module prints its error and the rest still load |
| 2 dead events | yes | the two dead events are gone; `CANCEL_ALL_LOOT_ROLLS` and `LOOT_HISTORY_UPDATE_DROP` registered |
| 3 item wrappers, `ChatFrameUtil.InsertLink` | yes | `Util.GetItemInfo/GetItemIcon/GetItemQualityColor` over `C_Item`; 9 call sites |
| 4 tooltip | yes | `TooltipDataProcessor` only |
| 5 secret values | yes | `Util.isSecret`; guards in `ProcessRoll` and `HandleWhisperCommand` |
| 6 `InitiateTrade` | yes | `Util.unitTokenForName`; plain-name fallback for non-group players |
| 7 group loot | yes | rehydrate from `GetActiveLootRollIDs` (SavedVariables copy removed), drop-history rebuild, Transmog button, popup-suppression bookkeeping |
| 8 TOC | yes | `## Interface: 120100` |

Still open (needs a live group): rollID→drop matching (2.3), taint from the `GroupLootContainer_RemoveFrame`
release (2.4), whether a plain name still works for `InitiateTrade` (2.6, untested), the `AllowLoadGameType`
question (3), and the Transmog button atlases. Not done: gamepad-mode roll frame (2.4), reagent-bag scan (2.6).

### How this was verified (and the limits)

Static comparison of Blizzard's own UI source, mirrored at `Gethe/wow-ui-source`:

- branch `forever` (commit "1.60.1 (69913)", 2026-09-18) vs branch `classic_anniversary`
- cross-checked against RCLootCouncil 3.23.3 (Interface 120100) on your disk

Forever's game type is **`camelot`** (a Mainline base with Camelot overrides; 464 Blizzard TOCs
load as `mainline`, 147 as `camelot`).

**Limits:** C-implemented functions (`RollOnLoot`, `IsInRaid`, `GetLootRollItemLink`, ...) are not
visible in Lua source. I confirmed those only where Blizzard's own Forever code calls them, and
flag the rest **[verify in game]**. Nothing here has been run in a live client.

---

## 1. Blockers — the addon errors or silently does nothing

### 1.1 Two events don't exist → login init chain aborts
`GroupLootRoll.lua:284-285` registers `LOOT_HISTORY_ROLL_CHANGED` and `LOOT_HISTORY_ROLL_COMPLETE`.
Neither exists in Forever's API docs (both exist on Anniversary). `RegisterEvent` on an unknown
event throws.

**Cascade:** `Core/Init.lua:37-45` runs every module `Init()` in sequence with no `pcall`.
`GroupLootRoll.Init` throws, so **`SoftRes.Init`, `Tooltip.Init` and `Trade.Init` never run**.
The whole addon looks broken from one bad line.

- Remove both registrations (see 2.3 for the replacement design).
- Hardening worth doing regardless: wrap each `Init()` in `pcall` and print the error.

### 1.2 `C_LootHistory.GetItem` / `GetPlayerInfo` are gone
Used at `GroupLootRoll.lua:234-235`. Forever's `C_LootHistory` is the encounter-based API only:

| Function | Notes |
|---|---|
| `GetAllEncounterInfos()` | list of `{encounterName, encounterID, startTime, duration}` |
| `GetInfoForEncounter(encounterID)` | |
| `GetSortedDropsForEncounter(encounterID)` | list of drop infos |
| `GetSortedInfoForDrop(encounterID, lootListKey)` | one drop, including per-player rolls |
| `GetLootHistoryTime()` | |

Events: `LOOT_HISTORY_UPDATE_DROP(encounterID, lootListKey)`, `LOOT_HISTORY_UPDATE_ENCOUNTER(encounterID)`,
`LOOT_HISTORY_ONE_HUNDRED_ROLL(encounterID, lootListKey)`, `LOOT_HISTORY_CLEAR_HISTORY`,
`LOOT_HISTORY_GO_TO_ENCOUNTER`. This is a redesign, not a rename: see 2.3.

### 1.3 Global item aliases were removed
Anniversary defines these in the `Blizzard_DeprecatedItemScript` shim addon. **Forever doesn't ship
that shim** (11 deprecated shim addons present on Anniversary are absent on Forever), and Blizzard's
own Forever code only calls the `C_Item.*` forms. Bare calls will hit `nil`.

| Call site | Replace with |
|---|---|
| `RollTracker.lua:133`, `:430`, `SoftRes.lua:486`, `UI/SoftResImport.lua:188`, `UI/RollWindow.lua:511` — `GetItemInfo` | `C_Item.GetItemInfo` |
| `UI/SoftResImport.lua:295`, `:350`, `UI/TradeQueueWindow.lua:218` — `GetItemIcon` | `C_Item.GetItemIconByID` |
| `UI/GroupLootRollBars.lua:407` — `GetItemQualityColor` | `C_Item.GetItemQualityColor` (still returns r, g, b, qualityString) |

`C_Item.GetItemInfo`, `GetItemIconByID`, `GetItemQualityColor` and `RequestLoadItemDataByID` all exist
on **both** clients, so one shim in `Core/Util.lua` (`Util.GetItemInfo = C_Item.GetItemInfo`, etc.)
fixes every site with no branching. `C_Item.RequestLoadItemDataByID` (already used) is fine.

### 1.4 `OnTooltipSetItem` never fires
`Tooltip.lua:105,108` hook `OnTooltipSetItem`. Forever's Blizzard UI has **0** references to it
(Anniversary has 12). The hook is inert, so the SoftRes and "Pending Trade" tooltip lines vanish
with no error.

Use `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data) ... end)`
(`data.id` is the itemID, `data.hyperlink` the link). `TooltipDataProcessor.AddTooltipPostCall` also
exists on Anniversary, so one code path may serve both. **[verify in game]** that Anniversary doesn't
then double-add lines alongside the legacy hook.

### 1.5 Chat text is a *secret value* during chat lockdown
`CHAT_MSG_SYSTEM` and `CHAT_MSG_WHISPER` are flagged `SecretInChatMessagingLockdown = true` in the
Forever docs: `text` and `playerName` are secret while locked down (encounters, M+, etc.).
Manipulating a secret string errors.

| Site | Operation on the secret |
|---|---|
| `RollTracker.lua:44-46` → `:81` | `string.gmatch(message, rollPattern)` |
| `SoftRes.lua:540-541` → `:502-505` | `strtrim`, `string.sub`, `string.lower` on `message`; `Util.stripRealm(sender)` |

Fix: `if issecretvalue(message) or issecretvalue(sender) then return end` at the top of each handler
(`issecretvalue` exists in Forever). Rolls usually happen after a kill, so this mostly bites in
edge cases, but it's a hard Lua error when it does.

---

## 2. Behaviour changes — runs, but wrong or incomplete

### 2.1 Roll UI must handle Transmog (and Disenchant)
`GetLootRollItemInfo` returns 13 values in Forever:
`texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, reasonGreed, reasonDisenchant, deSkillRequired, canTransmog`.
`GroupLootRoll.lua:164` reads the first 7, which are still positioned correctly. New `rollType`s:
`3` = Disenchant, `4` = Transmog. Blizzard's frame **replaces Greed with Transmog** when
`canTransmog` is true (`GroupLootFrame.lua:342-355`). `UI/GroupLootRollBars.lua` only has
Need/Greed/Pass, so on a transmog roll the Greed button is dead. Add a Transmog button →
`RollOnLoot(rollID, 4)`.

Also new on `START_LOOT_ROLL`: a third arg, `lootHandle` (nilable). `LOOT_ROLLS_COMPLETE` now carries
`lootHandle` too. The existing handlers ignore extra args, so nothing breaks; the handle is potentially
useful for 2.3.

### 2.2 `CANCEL_ALL_LOOT_ROLLS` now exists → register it
The comment at `GroupLootRoll.lua:279-281` says it's Retail-only and deliberately skipped. It exists
in Forever (not Anniversary) and Blizzard's own frames listen to it. Register it and clear all
`ActiveRolls` (via `GroupLootRoll.ClearActiveRoll` for each). Without it, bars can linger after a
zone change or full cancel.
Gate on the event existing (`pcall(eventFrame.RegisterEvent, ...)`) if you keep Anniversary support.

### 2.3 Rebuild "who chose Need/Greed/Pass" on the new history API (the big one)
Old model (`GroupLootRoll.lua:233-239`, `stashVote`, `cachedRolls`): per-player events
`LOOT_HISTORY_ROLL_CHANGED(itemIdx, playerIdx)` → `GetPlayerInfo` → append to `votes[0|1|2]`.

New model: `LOOT_HISTORY_UPDATE_DROP(encounterID, lootListKey)` →
`C_LootHistory.GetSortedInfoForDrop(encounterID, lootListKey)` returns a **snapshot** with:

- `itemHyperlink`, `startTime`, `duration`, `allPassed`, `isTied`
- `winner` / `currentLeader` (each an `EncounterLootDropRollInfo`)
- `rollInfos[]`, each `{playerName, playerGUID, playerClass, isSelf, state, isWinner, roll?}`

`state` (`EncounterLootDropRollState`) differs from your 0/1/2 keys:

| Forever state | Meaning | Your old key |
|---|---|---|
| 0 NeedMainSpec | Need (main spec) | 1 |
| 1 NeedOffSpec | Need (off spec) | 1 |
| 2 Transmog | Transmog | — new |
| 3 Greed | Greed | 2 |
| 4 NoRoll | hasn't rolled yet | — |
| 5 Pass | Pass | 0 |

Design consequences:
- Replace incremental stashing with **replace-the-whole-vote-set on each `UPDATE_DROP`**. The
  `cachedRolls` race-guard (`GroupLootRoll.lua:39`, `drainCache`) largely goes away.
- Need rolls now expose the **roll number** (`roll`). You can show it in the tooltip.
- `playerClass` is a class token string; check it matches the `classFile` your `classColoredName` expects.
- **Unresolved link:** nothing I found ties a `rollID` to an `(encounterID, lootListKey)` pair.
  Blizzard's UI never uses `lootHandle` or `lootListKey` outside the history frame, and neither do
  RCLootCouncil or your `ForeverLoot`. The safe approach is to correlate by `itemHyperlink` (itemID),
  tie-broken by `startTime` vs `ActiveRolls[rollID].startedAt`. **[verify in game]** whether
  `lootHandle == lootListKey` (see checklist), since that would be an exact key.
- `GetSortedInfoForDrop`/`GetSortedDropsForEncounter` are `SecretArguments = "AllowedWhenUntainted"`.
  Args from the event payload should be fine, but don't feed them values derived from secret data.

### 2.4 Default popup suppression: mechanism changed
- `START_LOOT_ROLL` is no longer handled by the frames. It goes
  `EventRouting` → `GameEvent.HandleStartLootRoll` → `GroupLootContainer_AddRoll(rollID, rollTime)`
  (`Blizzard_Game/Mainline/EventImplementation.lua:385-391`; skipped if gamepad UI is on).
  So `frame:UnregisterEvent("START_LOOT_ROLL")` (`GroupLootRoll.lua:95`) **is a no-op**.
- The default frames register `CANCEL_LOOT_ROLL`/`CANCEL_ALL_LOOT_ROLLS`/`MAIN_SPEC_NEED_ROLL`
  **on every OnShow** (`FrameUtil.RegisterFrameForEvents`), so the `UnregisterEvent("CANCEL_LOOT_ROLL")`
  at `:96` is undone the next time the frame shows.
- `NUM_GROUP_LOOT_FRAMES` is now a `local` in Blizzard's file. Your `or 4` fallback at `:119`
  already covers this. `GroupLootFrame1..4` are still real globals (`GroupLootFrame.xml:641-644`).
- What still works: the `OnShow → Hide` hook (`:101`) does hide them, and
  `hooksecurefunc("GroupLootContainer_Update", ...)` is still valid.
- What's leaky: hiding the frame doesn't call `GroupLootContainer_RemoveFrame`, so `rollFrames` keeps
  stale slots and `maxIndex` grows each roll, and every `GroupLootContainer_Update` re-`Show()`s the
  container before your hook hides it again. **Suggested:** post-hook `GroupLootContainer_AddFrame` and
  call `GroupLootContainer_RemoveFrame(GroupLootContainer, frame)` for bookkeeping (defer with
  `C_Timer.After(0, ...)` to stay out of the secure call). **[verify in game]** for taint
  (`ADDON_ACTION_BLOCKED`); fall back to the current approach if it taints.
- Gamepad mode uses a separate `GamepadGroupLootRollFrame` that isn't suppressed. Optional.

### 2.5 `/reload` roll persistence can be deleted
`GroupLootRoll.lua:139-148, 211-231` persists rollIDs in SavedVariables because "there's no 'list
current rolls' API". That's wrong: `GetActiveLootRollIDs()` exists and Blizzard uses it in **both**
the Forever client (`GroupLootFrame.lua:150,1461`) and the TBC client
(`Blizzard_UIParent/TBC/UIParent.lua:591`). Rehydrate exactly as Blizzard does:

```lua
for _, rollID in ipairs(GetActiveLootRollIDs()) do
    onStartLootRoll(rollID, C_Loot.GetLootRollDuration(rollID))  -- Forever
end
```

`C_Loot.GetLootRollDuration` is Forever-only; on Anniversary keep `GetLootRollTimeLeft(rollID)`.
Then drop `FL.DB.activeLootRolls` and `persistedRolls()`. Keep the `PLAYER_ENTERING_WORLD` trigger
(Blizzard's gamepad path does the same).

### 2.6 `InitiateTrade` now takes a UnitToken
`Trade.lua:217` calls `InitiateTrade(playerName)`, relying on Anniversary accepting a plain name.
Forever's signature is `InitiateTrade(guid: UnitToken)` (Blizzard's own call is
`InitiateTrade("target")`). Resolve the winner to a unit token (`raidN`/`partyN`, matching by
`UnitName`) or a GUID before calling. `Util.groupMembers()` (`Core/Util.lua:51`) only maps
names → class, so add a `name → unit token` helper alongside it. **[verify in game]** whether a bare
name still works; don't rely on it.

Smaller trade items:
- `UnitName("NPC")` (`Trade.lua:148,199,281`) is still valid; Blizzard's TradeFrame uses
  `GetUnitName("NPC")`. Optional: `GetUnitName("NPC", true)` to include the realm.
- `ITEM_UNLOCKED(bagOrSlotIndex, slotIndex?)` and `UI_INFO_MESSAGE(errorType, message)` payloads
  match your handlers. `ERR_TRADE_COMPLETE` unchanged.
- `C_Container.UseContainerItem(bag, slot, unitToken?, ...)` — your 2-arg call is fine.
- `Trade.lua:58` scans bags `0..4` only. Optional: extend to the reagent bag (`Enum.BagIndex` also
  has `Bag_1`..; check for the reagent-bag index and `NUM_BAG_SLOTS`), matching your `ForeverLoot` notes.

### 2.7 `ChatEdit_InsertLink` is a deprecated shim
`Core/Util.lua:141` still works: `Blizzard_DeprecatedChatInfo` defines
`ChatEdit_InsertLink = ChatFrameUtil.InsertLink` in both clients. But Blizzard's 114 call sites all use
`ChatFrameUtil.InsertLink`, and shims are what get deleted next (11 already were). Use
`(ChatFrameUtil and ChatFrameUtil.InsertLink or ChatEdit_InsertLink)(itemLink)`.

### 2.7b `GameTooltip:SetText` signature changed (found in game)
Found by a live error, not by the static scan: the function exists on both clients but its arguments
changed. `SetText(text, r, g, b, wrap)` is now `SetText(text [, color, alpha, wrap])`, so
`GameTooltip:SetText(msg, 1, 1, 1, true)` throws "bad argument #5". Fixed in `UI/OptionsPanel.lua` (both
checkbox tooltips) by using `GameTooltip:AddLine(msg, 1, 1, 1, true)`, whose signature is unchanged.
**Lesson for the rest of the port:** an API-existence check can't see argument changes, so any other
widget-method call with positional colour/flag arguments deserves a look if a new error shows up.

### 2.8 Loot method (works; one note)
`SoftRes.lua:440-455`: your fallback to `C_PartyInfo.GetLootMethod()` is right and your
numeric→name table matches Forever's `Enum.LootMethod` exactly (0 freeforall … 5 personal). The bare
`GetLootMethod` global isn't defined in Lua on Forever, so the `if (GetLootMethod)` guard is doing
real work: keep it. Prefer testing `C_PartyInfo` first on any client that has it.

---

## 3. TOC

- `## Interface: 20506` → `## Interface: 120100` (Forever only).
  Forever's build number (69913) is one build after live 12.1.0 (69875) so 120100 matches, the same
  value your `ForeverLoot` and RCLootCouncil use.
- `## AllowLoadGameType standard` (used by RCLootCouncil; 12 Blizzard TOCs use it too) is a valid
  value. Add it only if Forever's addon list shows the addon as incompatible. **[unverified]**

---

## 4. Verified OK — no change needed

**Events** (exist in Forever; payloads compatible): `ADDON_LOADED`, `PLAYER_LOGIN`,
`PLAYER_ENTERING_WORLD`, `UI_SCALE_CHANGED`, `DISPLAY_SIZE_CHANGED`, `ITEM_UNLOCKED`, `TRADE_SHOW`,
`UI_INFO_MESSAGE`, `GET_ITEM_INFO_RECEIVED (itemID, success)`, `START_LOOT_ROLL`, `CANCEL_LOOT_ROLL`,
`LOOT_ROLLS_COMPLETE`, `CHAT_MSG_SYSTEM`/`CHAT_MSG_WHISPER` (subject to 1.5).

**APIs/templates:** `C_Container.*` (already preferred in `Trade.lua:41-43`), `HandleModifiedItemClick`
(60 Blizzard call sites), `GetMouseButtonClicked` (documented), `DressUpItemLink`, `IsModifiedClick`,
`StaticPopupDialogs`/`StaticPopup_Show` (`OnAccept(_, data)` shape fine), `GameTooltip:SetLootRollItem`
and `:SetHyperlink`, `GetServerTime`, `IsInRaid`/`IsInGroup`/`GetRaidRosterInfo`/`GetNumGroupMembers`,
`UnitIsGroupLeader`/`Assistant`, `PixelUtil`, `hooksecurefunc`, `C_Timer`, `SetResizeBounds`,
`BackdropTemplate`/`BackdropTemplateMixin`, `UIDropDownMenu*` + `UIDropDownMenuTemplate`,
`InterfaceOptionsCheckButtonTemplate`, `UIPanelButtonTemplate`/`UIPanelCloseButton`/`InputBoxTemplate`.

**Options panel:** `InterfaceOptions_AddCategory` / `InterfaceOptionsFrame_OpenToCategory` don't exist on
*either* client, but `UI/OptionsPanel.lua:111-131` already prefers `Settings.*`, and
`Settings.OpenToCategory(category:GetID())` is valid. Nothing to do (modern hooks are `panel.OnRefresh`/
`OnCommit`/`OnDefault`; your `OnShow` refresh works too).

**Theme.lua scroll bar / button skinning:** `UIPanelScrollFrameTemplate`/`UIPanelScrollBarTemplate`
have the same `ScrollBar`/`ScrollUpButton`/`ThumbTexture` structure on both clients, and the code is
already `pcall`-wrapped.

**Bundled libs:** AceComm-3.0 r14 and ChatThrottleLib v32 already use `C_ChatInfo`; the addon-message
APIs (`RegisterAddonMessagePrefix`, `SendAddonMessage`) exist in Forever's `C_ChatInfo`. CallbackHandler,
LibSharedMedia, LibDeflate, LibSerialize, LibStub use no removed APIs.

---

## 5. Suggested order of work

1. `Init.lua`: `pcall` each `Init()` (contain failures).
2. `GroupLootRoll.lua`: remove the two dead events (unblocks everything else at login).
3. `Util.lua`: item-API shims + `ChatFrameUtil.InsertLink`; update the 9 call sites (1.3).
4. `Tooltip.lua`: `TooltipDataProcessor` (1.4).
5. `RollTracker.lua`/`SoftRes.lua`: `issecretvalue` guards (1.5).
6. `Trade.lua`: unit-token resolution for `InitiateTrade` (2.6).
7. `GroupLootRoll.lua`: `CANCEL_ALL_LOOT_ROLLS` (2.2), `GetActiveLootRollIDs` rehydrate (2.5), then the
   history rebuild (2.3), then Transmog (2.1) and suppression cleanup (2.4).
8. TOC bump (3).

## 6. In-game verification checklist (Forever)

Run these once; each resolves a `[verify in game]` above:

```
/dump GetItemInfo                          -- expect nil (confirms 1.3)
/dump C_Item.GetItemInfo(19019)            -- expect a name
/dump TooltipDataProcessor                 -- expect a table
/dump issecretvalue                        -- expect a function
/dump GetActiveLootRollIDs()               -- table of pending rollIDs
/dump GetLootRollItemLink                  -- expect a function (C-native; RCLootCouncil relies on it)
/dump C_LootHistory.GetAllEncounterInfos() -- inspect after a group roll
/dump C_PartyInfo.GetLootMethod()          -- 0..5
/dump InitiateTrade                        -- then test with a unit token AND a plain name
```

Correlation probe for 2.3 (paste once, then take a real group-loot roll with others):

```lua
local f = CreateFrame("Frame")
f:RegisterEvent("START_LOOT_ROLL"); f:RegisterEvent("LOOT_HISTORY_UPDATE_DROP"); f:RegisterEvent("LOOT_ROLLS_COMPLETE")
f:SetScript("OnEvent", function(_, e, a, b, c)
  print(e, a, b, c)
  if e == "LOOT_HISTORY_UPDATE_DROP" then DevTools_Dump(C_LootHistory.GetSortedInfoForDrop(a, b)) end
end)
```

Compare `START_LOOT_ROLL`'s third arg (`lootHandle`) with `LOOT_HISTORY_UPDATE_DROP`'s `lootListKey`.
If they match, use it as an exact rollID→drop key; otherwise correlate by item link + start time.
Also confirm the Anniversary side still receives the legacy events after your changes.

## Files the code work will touch

`ForeverLoot.toc`, `Core/Init.lua`, `Core/Util.lua`, `GroupLootRoll.lua`, `UI/GroupLootRollBars.lua`,
`Tooltip.lua`, `RollTracker.lua`, `SoftRes.lua`, `Trade.lua`, `UI/SoftResImport.lua`,
`UI/TradeQueueWindow.lua`, `UI/RollWindow.lua`.
