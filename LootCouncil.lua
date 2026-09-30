--[[
Loot council sessions: build a list of items, broadcast it to the raid with a
fixed set of response options, collect every raider's response, let a
manually-configured council vote per candidate, and award the item - which
then flows into the existing trade queue (Trade.lua) exactly like a roll-off
award does, and is recorded to a persistent history log.

This file currently implements Phase 2 (broadcasting the leader's session
item list - built and owned by Session/SessionItems.lua - to the raid over a
dedicated comm channel, populating CurrentSession on every client) and Phase 3
(collecting each raider's response - see UI/RespondWindow.lua).
Voting and awarding are added in later phases; see the plan this was built
from for the full design.
]]

local FL = ForeverLoot;
local LootCouncil = FL.LootCouncil;
local Util = FL.Util;

-- Dedicated comm layer (see the "Broadcast" section below) - forward-declared
-- so Init() can register them before their bodies are defined further down,
-- same convention as tradeTimePattern/scanTooltip above.
local lcSend, onLCMessage;
local AceComm, LibDeflate, LibSerialize;

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark";
LootCouncil.FALLBACK_ICON = FALLBACK_ICON;

-- Dedicated AceComm prefix for this feature - deliberately NOT the existing
-- "GargulComm2" channel Comm.lua speaks (that one mirrors Gargul's real wire
-- protocol for third-party interop; inventing new action ids on it would
-- broadcast unrelated traffic to real Gargul clients in the raid).
local LC_PREFIX = "ForeverLootLC";
LootCouncil.CommActions = {}; -- action name (string) -> handler(Message)
LootCouncil.debugEnabled = false;

-- In-memory (never persisted to FL.DB) proof that a given raid/party member
-- is actually running ForeverLoot: name -> true, set the moment ANY LC_PREFIX
-- traffic arrives from them (see onLCMessage below) and by the sessionStart
-- ack (applySessionStart) so a non-responder can be proven present too.
LootCouncil.Presence = {};

--- Whether `name` has proven (via LC_PREFIX comm traffic this session) that
--- they're running ForeverLoot. Used by Session/Awards.lua to tell a
--- non-responder who simply hasn't answered yet from one who doesn't have
--- the addon at all.
---@param name string
function LootCouncil.HasAddon(name)
    return LootCouncil.Presence[name] == true;
end

--------------------------------------------------------------------------
-- Late item-info arrival - deferred from Phase 2 (see applySessionStart's
-- comment below). Generalized to loop over Session.items (an array, not a
-- single tracked item like RollTracker.lua's rollOff) since duplicate
-- itemIDs across different session items are allowed by design (Phase 1's
-- "duplicates allowed on purpose" delta).
--------------------------------------------------------------------------

local function refreshSessionItemData(itemID)
    local Session = LootCouncil.CurrentSession;
    if (not Session) then return; end

    local changed = false;
    for _, item in ipairs(Session.items) do
        if (item.itemID == itemID and not item.itemIcon) then
            local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = Util.GetItemInfo(item.itemLink);
            if (itemIcon) then
                item.itemIcon = itemIcon;
                item.itemName = item.itemName or itemName;
                item.itemQuality = item.itemQuality or itemQuality;
                changed = true;
            end
        end
    end

    if (changed and FL.UI.RespondWindow and FL.UI.RespondWindow.IsShown and FL.UI.RespondWindow.IsShown()) then
        FL.UI.RespondWindow.Refresh();
    end
end

local function ensureItemInfoFrame()
    local itemInfoFrame = CreateFrame("Frame");
    itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED");
    itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
        if (not success) then return; end
        refreshSessionItemData(itemID);

        -- Candidate equipped-gear icons (link comes from candidate.equipped,
        -- not a Session.items entry) and the assign/reassign popup's "still in
        -- the raid" repaint both read arbitrary item links refreshSessionItemData
        -- never matches by itemID, so AwardWindow needs its own unconditional
        -- (but throttled, see AwardWindow.Refresh) repaint on every arrival
        -- while it's open, not just ones tied to a session item.
        if (FL.UI.AwardWindow and FL.UI.AwardWindow.IsShown and FL.UI.AwardWindow.IsShown()) then
            FL.UI.AwardWindow.Refresh();
        end
    end);
end

function LootCouncil.Init()
    FL.DB.lootCouncil = FL.DB.lootCouncil or {
        roster = {},
        draft = { items = {} },
        history = {},
        session = nil,
        nextSessionId = 0,
    };
    local db = FL.DB.lootCouncil;
    db.nextSessionId = db.nextSessionId or 0; -- upgrade path: field didn't exist before this fix

    LootCouncil.Roster = db.roster;
    LootCouncil.History = db.history;
    LootCouncil.CurrentSession = db.session;

    AceComm = LibStub("AceComm-3.0");
    LibDeflate = LibStub("LibDeflate");
    LibSerialize = LibStub("LibSerialize");
    AceComm:RegisterComm(LC_PREFIX, onLCMessage);

    ensureItemInfoFrame();
end

--------------------------------------------------------------------------
-- Broadcast - dedicated comm channel, mirrors Comm.lua's own pipeline
-- (serialize -> compress -> encode) and anti-spoof check, but without
-- Gargul's version-handshake fields since there's no third-party protocol
-- to satisfy here.
--------------------------------------------------------------------------

local function lcDebugPrint(msg)
    if (LootCouncil.debugEnabled) then
        print("|cff8865ffForeverLoot|r " .. msg);
    end
end

lcSend = function(action, content, channel, recipient)
    local distribution, target = Util.GroupDistribution(channel or "GROUP", recipient);

    local payload = { a = action, b = content, c = Util.playerFqn() };
    if (distribution ~= "WHISPER" and recipient) then
        payload.r = recipient;
    end

    local encoded = LibDeflate:EncodeForWoWAddonChannel(
        LibDeflate:CompressDeflate(LibSerialize:Serialize(payload), { level = 5 }));

    lcDebugPrint(("SEND %s -> %s%s"):format(tostring(action), distribution, target and (":" .. target) or ""));

    AceComm:SendCommMessage(LC_PREFIX, encoded, distribution, target, "NORMAL");
end

onLCMessage = function(prefix, encoded, distribution, senderName)
    if (prefix ~= LC_PREFIX) then return; end

    local ok, decompressed = pcall(function()
        return LibDeflate:DecompressDeflate(LibDeflate:DecodeForWoWAddonChannel(encoded));
    end);
    if (not ok or not decompressed) then return; end

    local deserializeOk, payload = LibSerialize:Deserialize(decompressed);
    if (not deserializeOk or type(payload) ~= "table" or not payload.a) then return; end

    -- Not meant for us (whisper forcefully routed through raid/party channel)
    local myName = Util.UnitName("player");
    local myFqn = Util.playerFqn();
    if (payload.r and not Util.iEquals(payload.r, myFqn) and not Util.iEquals(payload.r, myName)) then
        return;
    end

    -- Anti-spoofing: claimed sender must start with the real (server-supplied) sender name
    if (payload.c and senderName) then
        local claimed = string.lower(strtrim(payload.c));
        local real = string.lower(strtrim(senderName));
        if (string.sub(claimed, 1, #real) ~= real) then return; end
    end

    local Message = {
        action = payload.a,
        content = payload.b,
        senderFqn = payload.c or senderName,
        senderName = Util.stripRealm(payload.c or senderName),
        channel = distribution,
    };
    Message.isSelf = Util.iEquals(Message.senderFqn, myFqn) or Util.iEquals(Message.senderName, myName);

    -- Any traffic on LC_PREFIX proves the sender is running ForeverLoot -
    -- only a real client can construct a valid payload here. Deliberately
    -- NOT excluding Message.isSelf: GROUP-distribution sends loop back to
    -- the sender through this same function (see applySessionStart's own
    -- isSelf handling), so this is what marks our own presence the moment
    -- we send anything on this channel - nothing else ever does.
    if (Message.senderName) then
        LootCouncil.Presence[Message.senderName] = true;
    end

    lcDebugPrint(("RECV %s <- %s (%s)"):format(tostring(Message.action), Message.senderFqn or "?", distribution));

    local handler = LootCouncil.CommActions[Message.action];
    if (handler) then handler(Message); end
end

--------------------------------------------------------------------------
-- Council membership (Phase 4+)
--------------------------------------------------------------------------

--- Pure roster check. Two separate, wider checks build on top of this -
--- CanAccessReviewWindow (window visibility) and CanVote (voting
--- eligibility) - both also let the session initiator in (whoever actually
--- started the session - not necessarily the group's current leader; see
--- those functions below). This function itself must stay the narrow
--- roster-only check other code relies on.
---@param name string
function LootCouncil.IsCouncilMember(name)
    return LootCouncil.Roster[Util.stripRealm(name)] == true;
end

--- Whether the local player may open UI/AwardWindow.lua. Wider
--- than IsCouncilMember: also lets the current session's initiator in, so a
--- leader who forgot to add themselves to the roster (Phase 7 concern) can
--- still review the session they started - the Award button stays disabled
--- until Phase 6 regardless.
function LootCouncil.CanAccessReviewWindow()
    if (LootCouncil.IsCouncilMember(Util.UnitName("player"))) then return true; end
    local Session = LootCouncil.CurrentSession;
    return Session ~= nil and Session.initiatorIsMe == true;
end

--- Whether `name`/`fqn` may cast a vote in the current session - a council
--- member, or the session's own initiator, even if the initiator forgot to
--- add themselves to the roster (mirrors CanAccessReviewWindow's widening,
--- for the same reason). Takes an explicit fqn (rather than reading the
--- local-only Session.initiatorIsMe flag) so the SAME function verifies
--- both the local player (ToggleVote) and a remote sender (applyVote) by
--- comparing fqn against Session.initiatorFqn, which every client agrees on.
---@param name string
---@param fqn string|nil
function LootCouncil.CanVote(name, fqn)
    if (LootCouncil.IsCouncilMember(name)) then return true; end
    local Session = LootCouncil.CurrentSession;
    return Session ~= nil and fqn ~= nil and Util.iEquals(fqn, Session.initiatorFqn);
end

--------------------------------------------------------------------------
-- Roster management (stopgap ahead of Phase 7's dedicated UI)
--------------------------------------------------------------------------

-- Fired (no arguments) whenever the council roster changes for any reason -
-- a local edit (RosterAdd/RosterRemove/RosterClear) or an incoming sync
-- (councilSettingsSync/session-start snapshot, both of which go through
-- applyRosterNames below). Lets UI outside the settings page (e.g.
-- StartSessionWindow's council-count button) react immediately instead of
-- polling.
local rosterChangedCallbacks = {};

function LootCouncil.RegisterRosterChangedCallback(fn)
    table.insert(rosterChangedCallbacks, fn);
end

local function fireRosterChanged()
    for _, fn in ipairs(rosterChangedCallbacks) do
        pcall(fn);
    end
end

--- Alphabetical array of every current council member's name, for display
--- and for broadcasting (see SyncCouncilSettings/sessionStart below).
function LootCouncil.RosterNames()
    local names = {};
    for name in pairs(LootCouncil.Roster) do
        table.insert(names, name);
    end
    table.sort(names);
    return names;
end

--- Replaces the local roster wholesale with `names` (full-replace snapshot,
--- not a merge) - self-healing the same way response/vote state already is,
--- matching this module's idempotent-absolute-state convention throughout.
--- Shared by the explicit councilSettingsSync push (applyCouncilSettingsSync)
--- and sessionStart's own roster snapshot (applySessionStart) - the only two
--- ways a roster reaches the wire; local edits (RosterAdd/RosterRemove/
--- RosterClear) deliberately do NOT auto-broadcast, so the raid leader
--- decides when to actually push a roster in progress (see
--- LootCouncil.pendingRosterSync below and UI/SettingsWindow/Pages/
--- LootCouncil.lua's "Sync to Raid" button).
---@param names string[]
local function applyRosterNames(names)
    wipe(LootCouncil.Roster);
    for _, name in ipairs(names) do
        if (type(name) == "string" and name ~= "") then
            LootCouncil.Roster[Util.stripRealm(name)] = true;
        end
    end
    fireRosterChanged();
end

-- Set by every LOCAL roster edit (RosterAdd/RosterRemove/RosterClear) and
-- cleared by SyncCouncilSettings - tracks whether the roster has changed
-- since the last explicit "Sync to Raid" push, so the settings page can
-- highlight that button gold again as a reminder those changes still need
-- to go out (see UI/SettingsWindow/Pages/LootCouncil.lua's updateFooterCount).
-- Deliberately NOT set by applyRosterNames: that path only ever runs for
-- roster state arriving FROM the network (a councilSettingsSync push or a
-- session-start snapshot), which is already synced by definition.
LootCouncil.pendingRosterSync = false;

--- Adds `name` to the council roster. Returns false if already present.
--- Does NOT broadcast - local edits only take effect on the wire once the
--- raid leader explicitly hits "Sync to Raid" (SyncCouncilSettings) or
--- starts a session (SendToRaid), both of which send the full roster.
---@param name string
function LootCouncil.RosterAdd(name)
    name = Util.stripRealm(name or "");
    if (name == "") then return false; end
    if (LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = true;
    LootCouncil.pendingRosterSync = true;
    fireRosterChanged();
    return true;
end

--- Removes `name` from the council roster. Returns false if not present.
--- Does NOT broadcast - see RosterAdd's comment above.
---@param name string
function LootCouncil.RosterRemove(name)
    name = Util.stripRealm(name or "");
    if (not LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = nil;
    LootCouncil.pendingRosterSync = true;
    fireRosterChanged();
    return true;
end

--- Removes every current council roster member. Returns the number removed.
--- Does NOT broadcast - see RosterAdd's comment above.
function LootCouncil.RosterClear()
    local n = Util.tcount(LootCouncil.Roster);
    if (n == 0) then return 0; end
    wipe(LootCouncil.Roster);
    LootCouncil.pendingRosterSync = true;
    fireRosterChanged();
    return n;
end

--- Pushes the full council roster to the raid - distinct from SendToRaid
--- below, which starts a new voting SESSION on the leader's draft item list.
--- Only meaningful to call as the raid leader/assistant (see
--- UI/SettingsWindow/Pages/LootCouncil.lua, which disables its "Sync to
--- Raid" button otherwise) - not gated here, matching this module's existing
--- trust model (any client can technically call RosterAdd/RosterRemove or
--- SendToRaid; the wire layer's anti-spoof check only guarantees identity,
--- not intent).
function LootCouncil.SyncCouncilSettings()
    lcSend("councilSettingsSync", {
        names = LootCouncil.RosterNames(),
    }, "GROUP");
    LootCouncil.pendingRosterSync = false;
end

--- Applied by every client (including the sender, via the self-looped
--- broadcast) when a councilSettingsSync arrives. If this local player was
--- just added while a session is already active, automatically pop the
--- Review and Award window open for them - matches the existing "broadcast
--- pops the window" convention MaybeAutoShow already uses for a brand-new
--- session (see applySessionStart) - without this, a newly-added council
--- member would have no way to know they need to open /flc themselves.
local function applyCouncilSettingsSync(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.names) ~= "table") then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local wasMember = LootCouncil.IsCouncilMember(myName);

    applyRosterNames(content.names);

    print(("|cff8865ffForeverLoot|r Council settings synced from %s (%d members)."):format(
        Message.senderFqn or "?", #content.names));

    local becameMember = (not wasMember) and LootCouncil.IsCouncilMember(myName);
    local Session = LootCouncil.CurrentSession;
    if (becameMember and Session and Session.status == "active") then
        if (FL.UI.AwardWindow and FL.UI.AwardWindow.Show) then
            FL.UI.AwardWindow.Show(); -- Show() itself calls Refresh()
        end
    elseif (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.councilSettingsSync = applyCouncilSettingsSync;

--------------------------------------------------------------------------
-- Session lifecycle
--------------------------------------------------------------------------

-- Shared by applySessionStart and applySessionAddItems below, so a session
-- item's shape (and the late-arriving-item-data fallback) can't drift
-- between "start a session" and "add items to one already running".
---@param itemLink string
---@param sessionIndex number this item's Session.items index (the `session` field itemSession-keyed lookups use everywhere else - AwardItem, ToggleVote, SubmitResponse, etc.)
local function buildSessionItemEntry(itemLink, sessionIndex)
    local itemID = Util.itemIDFromLink(itemLink);
    local itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = Util.GetItemInfo(itemLink);

    -- Not cached client-side yet - explicitly request it rather than
    -- relying on GetItemInfo's implicit fetch (mirrors
    -- RollTracker.lua's applyStart). No refresh listener is wired up
    -- here since no Phase 2 UI needs to redraw when it arrives late -
    -- Phase 3's response window adds that.
    if (not itemName and itemID) then
        C_Item.RequestLoadItemDataByID(itemID);
    end

    return {
        session = sessionIndex,
        itemLink = itemLink,
        itemID = itemID,
        itemName = itemName,
        itemQuality = itemQuality,
        itemIcon = itemIcon,
        awardedTo = nil,
        awardedAt = nil,
        candidates = {},
        sendFailed = false,
    };
end

-- Applied locally by every client (initiator included, via the self-looped
-- broadcast) when a sessionStart message is processed - mirrors
-- RollTracker.lua's applyStart. The sessionId always comes from the message,
-- never generated locally, so every client agrees on the same id.
local function applySessionStart(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.items) ~= "table" or not content.sessionId) then
        return;
    end

    -- Roster snapshot carried alongside the session, so everyone converges
    -- on the leader's current roster the moment a session starts, even if
    -- they missed (or the leader never sent) an explicit "Sync to Raid".
    if (type(content.names) == "table") then
        applyRosterNames(content.names);
    end

    -- The leader's response-button list at the moment the session started
    -- (Core/Responses.lua's SessionSnapshot) - every raider's Respond popup
    -- and every Review & Vote pill for this session reads ONLY from this
    -- snapshot from here on, never from this client's own local settings.
    -- Falls back to the defaults for a leader running a version that
    -- doesn't send this field yet, rather than leaving the session with no
    -- response options at all.
    local responses = (type(content.responses) == "table" and #content.responses > 0)
        and content.responses
        or FL.Responses.CloneList(FL.Responses.DEFAULT_LIST);

    local items = {};
    for i, itemLink in ipairs(content.items) do
        items[i] = buildSessionItemEntry(itemLink, i);
    end

    FL.DB.lootCouncil.session = {
        id = content.sessionId,
        initiatorFqn = Message.senderFqn,
        initiatorIsMe = Message.isSelf,
        startedAt = GetTime(),
        status = "active",
        items = items,
        responses = responses,
    };
    LootCouncil.CurrentSession = FL.DB.lootCouncil.session;

    lcDebugPrint(("Loot council session %d started by %s (%d items)"):format(content.sessionId, Message.senderFqn or "?", #items));

    -- Prove to the whole raid/party that we're running ForeverLoot even if
    -- we never end up responding/voting - lets ANY council member's Award
    -- window (not just the initiator's) tell "hasn't responded yet" apart
    -- from "doesn't have the addon" (Session/Awards.lua). Broadcast rather
    -- than whispered straight to the initiator: a whisper target needs a
    -- resolvable bare player name, and Message.senderFqn here is the
    -- wire-protocol "Name-Realm" identity string, not a valid whisper
    -- target - GROUP sidesteps that entirely and reaches every client.
    if (not Message.isSelf) then
        lcSend("presenceAck", nil, "GROUP");
    end

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.MaybeAutoShow) then
        FL.UI.RespondWindow.MaybeAutoShow();
    end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.MaybeAutoShow) then
        FL.UI.AwardWindow.MaybeAutoShow();
    end
end
LootCouncil.CommActions.sessionStart = applySessionStart;

-- Applied locally by every client (sender included) when a sessionAddItems
-- message is processed - appends to the already-active Session.items instead
-- of replacing it, mirroring applySessionStart's own per-item construction.
-- Requires content.sessionId to match the locally-tracked Session.id (and
-- Session.status to still be "active") so a stale add can't reattach itself
-- to a session that's since ended or been superseded by a new sessionStart.
local function applySessionAddItems(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.items) ~= "table" or not content.sessionId) then
        return;
    end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId or Session.status ~= "active") then
        return;
    end

    local baseIndex = #Session.items;
    for i, itemLink in ipairs(content.items) do
        Session.items[baseIndex + i] = buildSessionItemEntry(itemLink, baseIndex + i);
    end

    lcDebugPrint(("Loot council session %d: %d item(s) added by %s"):format(content.sessionId, #content.items, Message.senderFqn or "?"));

    if (not Message.isSelf) then
        lcSend("presenceAck", nil, "GROUP");
    end

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.MaybeAutoShow) then
        FL.UI.RespondWindow.MaybeAutoShow();
    end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.MaybeAutoShow) then
        FL.UI.AwardWindow.MaybeAutoShow();
    end
end
LootCouncil.CommActions.sessionAddItems = applySessionAddItems;

-- Presence is already recorded generically for every inbound message
-- (onLCMessage above); this handler only exists to repaint the Award window
-- immediately when an ack lands, instead of waiting for some unrelated
-- refresh to happen to catch it.
local function applyPresenceAck(Message)
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.presenceAck = applyPresenceAck;

--- Broadcasts the leader's current session item list (owned by
--- Session/SessionItems.lua) to the raid as a new session.
---@return boolean success
function LootCouncil.SendToRaid()
    local sessionItems = FL.SessionItems.GetItems();
    if (#sessionItems == 0) then
        print("|cff8865ffForeverLoot|r Add at least one item to the list first.");
        return false;
    end

    -- Persisted (FL.DB.lootCouncil.nextSessionId), NOT a module-local counter
    -- reset to 0 on every reload/relog - LootCouncil.History survives across
    -- logins, and RecordHistory's dedupe id is keyed on Session.id, so a
    -- counter that restarts at 1 every login would collide with old history
    -- entries (almost always on awardSeq 1, the most common value ever
    -- recorded) and silently drop the new award from history. See
    -- RecordHistory's id comment.
    local db = FL.DB.lootCouncil;
    db.nextSessionId = (db.nextSessionId or 0) + 1;
    local sessionId = db.nextSessionId;

    local itemLinks = {};
    for i, draftItem in ipairs(sessionItems) do
        itemLinks[i] = draftItem.itemLink;
    end

    lcSend("sessionStart", {
        sessionId = sessionId,
        items = itemLinks,
        names = LootCouncil.RosterNames(),
        responses = FL.Responses.SessionSnapshot(),
    }, "GROUP");

    return true;
end

--- Broadcasts the leader's current draft list (owned by Session/SessionItems.lua)
--- as an ADDITION to the already-active session, instead of starting a new
--- one - SendToRaid's counterpart for "the session's still running, more
--- loot just dropped". No permission gate here, same convention as
--- SendToRaid: Session/SessionItems.lua's SendToActiveSession() is the only
--- caller and already enforces leader/assistant.
---@param draftItems table array of {itemLink, itemID, source} (SessionItems' draft shape)
---@return boolean success
function LootCouncil.AddItemsToSession(draftItems)
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return false; end
    if (#draftItems == 0) then return false; end

    local itemLinks = {};
    for i, draftItem in ipairs(draftItems) do
        itemLinks[i] = draftItem.itemLink;
    end

    lcSend("sessionAddItems", {
        sessionId = Session.id,
        items = itemLinks,
    }, "GROUP");

    return true;
end

--------------------------------------------------------------------------
-- Equipped-item snapshot, sent alongside a response so the council can see
-- what the raider already has in the item's own slot family. Only ever reads
-- the local player's own equipped gear (GetInventoryItemLink("player", ...))
-- - never another unit's ("inspect").
--------------------------------------------------------------------------

-- equipLoc string -> the slot id(s) to snapshot. Rings/trinkets always
-- return both of their slots, and every weapon-ish equipLoc always returns
-- BOTH hand slots regardless of 1H/2H, so the council can compare against
-- whichever hand is actually relevant. Every other equippable slot only
-- ever has one physical slot, so it just maps to its own INVSLOT_* id.
local EQUIPPED_SLOT_FAMILIES = {
    INVTYPE_HEAD           = { INVSLOT_HEAD },
    INVTYPE_NECK           = { INVSLOT_NECK },
    INVTYPE_SHOULDER       = { INVSLOT_SHOULDER },
    INVTYPE_BODY           = { INVSLOT_BODY }, -- shirt
    INVTYPE_CHEST          = { INVSLOT_CHEST },
    INVTYPE_ROBE           = { INVSLOT_CHEST }, -- caster robes share the chest slot
    INVTYPE_WAIST          = { INVSLOT_WAIST },
    INVTYPE_LEGS           = { INVSLOT_LEGS },
    INVTYPE_FEET           = { INVSLOT_FEET },
    INVTYPE_WRIST          = { INVSLOT_WRIST },
    INVTYPE_HAND           = { INVSLOT_HAND },
    INVTYPE_FINGER         = { INVSLOT_FINGER1, INVSLOT_FINGER2 },
    INVTYPE_TRINKET        = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 },
    INVTYPE_CLOAK          = { INVSLOT_BACK },
    INVTYPE_WEAPON         = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_2HWEAPON       = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_WEAPONMAINHAND = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_WEAPONOFFHAND  = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_SHIELD         = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    INVTYPE_HOLDABLE       = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
    -- Bows/guns/wands/thrown/relics equip into the dedicated ranged slot,
    -- not either hand.
    INVTYPE_RANGED         = { INVSLOT_RANGED },
    INVTYPE_RANGEDRIGHT    = { INVSLOT_RANGED },
    INVTYPE_THROWN         = { INVSLOT_RANGED },
    INVTYPE_RELIC          = { INVSLOT_RANGED },
    INVTYPE_AMMO           = { INVSLOT_AMMO },
    INVTYPE_TABARD         = { INVSLOT_TABARD },
};

--- Snapshot of the local player's own currently-equipped item link(s) in
--- whichever slot family `itemLink` belongs to. Anything outside those
--- families (armor, consumables, etc.) yields an empty table. Empty slots
--- are simply omitted from the result, keeping the payload tiny.
---@param itemLink string
---@return table<number, string> slot id -> item link
local function getEquippedSlotsForItem(itemLink)
    local equipped = {};
    local _, _, _, _, _, _, _, _, equipLoc = Util.GetItemInfo(itemLink);
    local family = equipLoc and EQUIPPED_SLOT_FAMILIES[equipLoc];
    if (not family) then return equipped; end

    for _, slot in ipairs(family) do
        local link = GetInventoryItemLink("player", slot);
        if (link) then equipped[slot] = link; end
    end
    return equipped;
end

--------------------------------------------------------------------------
-- Responses (Phase 3)
--------------------------------------------------------------------------

-- Monotonic per-session counter for candidate.arrivalIndex - local-only tie
-- breaking for AwardWindow's response-order sort (Lua's table.sort isn't
-- stable), never sent over comm since it only needs to be consistent within
-- this client's own view.
local nextArrivalIndex = 0;

--- Sends this client's response for one item in the current session.
--- Applies the response to CurrentSession locally FIRST (optimistic update -
--- same shape applyResponse below builds, respondedAt/approvals preserved
--- the same way), so the response window can reorder the item immediately
--- instead of waiting on the round trip through the server and back (the
--- self-looped broadcast that used to be the only thing that mutated local
--- state here). applyResponse still reconciles this entry - and clears
--- sendFailed - when that echo actually arrives.
--- If the send itself errors, the optimistic entry is rolled back to
--- whatever candidate entry existed before (nil for a first-time response)
--- and item.sendFailed is set so UI/RespondWindow.lua can show
--- "Failed to send" and sort the item to the bottom of the pending list
--- instead of leaving it looking answered.
---@param itemSession number
---@param responseId number one of the current SESSION's response snapshot ids (Session.responses)
---@param note string|nil
function LootCouncil.SubmitResponse(itemSession, responseId, note)
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return; end
    local item = Session.items[itemSession];
    if (not item) then return; end
    if (not Session.responses or not FL.Responses.GetById(Session.responses, responseId)) then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local _, classFile = UnitClass("player");

    local previous = item.candidates[myName];
    -- A council vote cast for myName before this, my first response, lands
    -- in item.preVotes (see getOrCreateCandidate below) instead of
    -- item.candidates - fold it in here so it isn't lost the moment a real
    -- candidate entry gets created.
    local preVote = item.preVotes and item.preVotes[myName];
    -- Equipped gear can change between an initial response and a later note
    -- edit, so this is recomputed fresh every submit (unlike
    -- respondedAt/approvals/arrivalIndex, which are deliberately preserved).
    local equipped = getEquippedSlotsForItem(item.itemLink);
    local arrivalIndex = previous and previous.arrivalIndex;
    if (not arrivalIndex) then
        nextArrivalIndex = nextArrivalIndex + 1;
        arrivalIndex = nextArrivalIndex;
    end
    item.candidates[myName] = {
        class = classFile,
        response = responseId,
        note = note or "",
        equipped = equipped,
        respondedAt = (previous and previous.respondedAt) or GetServerTime(),
        arrivalIndex = arrivalIndex,
        approvals = (previous and previous.approvals) or (preVote and preVote.approvals) or {},
        voteOrder = (previous and previous.voteOrder) or (preVote and preVote.voteOrder) or {},
    };
    if (item.preVotes) then item.preVotes[myName] = nil; end
    item.sendFailed = false;

    local ok = pcall(lcSend, "response", {
        sessionId = Session.id,
        itemSession = itemSession,
        response = responseId,
        note = note or "",
        class = classFile,
        equipped = equipped,
    }, "GROUP");

    if (not ok) then
        item.candidates[myName] = previous;
        if (preVote) then item.preVotes[myName] = preVote; end -- restore, still pre-response
        item.sendFailed = true;
    end

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end

-- Applied locally by every client (sender included, via the self-looped
-- broadcast) when a response message is processed. respondedAt and approvals
-- are preserved from any existing entry on an update, not reset - this is
-- what keeps a raider's position in the "Responded" section fixed once
-- crossed (see UI/RespondWindow.lua), and keeps any council
-- votes already cast (Phase 5) from being wiped out by a later response edit.
local function applyResponse(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.sessionId or not content.itemSession
        or not content.response) then
        return;
    end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId) then return; end -- stale/foreign session
    if (Session.status ~= "active") then return; end -- late response for an ended session

    local item = Session.items[content.itemSession];
    if (not item) then return; end

    local existing = item.candidates[Message.senderName];
    -- Fold in any pre-response council vote, same as SubmitResponse above.
    local preVote = item.preVotes and item.preVotes[Message.senderName];
    local arrivalIndex = existing and existing.arrivalIndex;
    if (not arrivalIndex) then
        nextArrivalIndex = nextArrivalIndex + 1;
        arrivalIndex = nextArrivalIndex;
    end
    item.candidates[Message.senderName] = {
        class = content.class,
        response = content.response,
        note = content.note or "",
        equipped = (type(content.equipped) == "table") and content.equipped or {},
        respondedAt = (existing and existing.respondedAt) or GetServerTime(),
        arrivalIndex = arrivalIndex,
        approvals = (existing and existing.approvals) or (preVote and preVote.approvals) or {},
        voteOrder = (existing and existing.voteOrder) or (preVote and preVote.voteOrder) or {},
    };
    if (item.preVotes) then item.preVotes[Message.senderName] = nil; end

    -- Authoritative confirmation that SubmitResponse's optimistic send above
    -- actually made it out and back - clears any stale failure marker even
    -- if a later retry's own pcall result got missed for some reason.
    if (Message.isSelf) then
        item.sendFailed = false;
    end

    lcDebugPrint(("%s responded %s to item %d"):format(Message.senderName, tostring(content.response), content.itemSession));

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.response = applyResponse;

--------------------------------------------------------------------------
-- Voting (Phase 5)
--------------------------------------------------------------------------

--- Idempotent voteOrder mutation shared by ToggleVote's optimistic update
--- and applyVote's echo/remote update: only inserts/removes `name` when
--- `approved` is an actual transition from its current membership, so
--- ToggleVote's own self-looped broadcast (which re-applies the exact same
--- state through applyVote) can never double-insert the same name.
---@param candidate table
---@param name string
---@param approved boolean
local function updateVoteOrder(candidate, name, approved)
    local wasApproved = candidate.approvals[name] == true;
    candidate.voteOrder = candidate.voteOrder or {};
    if (approved and not wasApproved) then
        table.insert(candidate.voteOrder, name);
    elseif (not approved and wasApproved) then
        for i, existingName in ipairs(candidate.voteOrder) do
            if (existingName == name) then table.remove(candidate.voteOrder, i); break; end
        end
    end
end

--- Returns something with .approvals/.voteOrder for `name` on `item` that
--- ToggleVote/applyVote can mutate, even before `name` has responded.
---
--- Deliberately does NOT create an item.candidates[name] entry for a
--- non-responder: item.candidates[name]'s mere existence means "has
--- responded" everywhere else (RespondWindow.lua's pending/sent split and
--- its sent-list sort by respondedAt, AwardWindow.lua's response counter,
--- Awards.BuildCandidateList's seen-tracking) - planting a vote-only entry
--- there previously made a non-responder look responded with a nil
--- respondedAt, which crashed RespondWindow's sent-list sort. Votes cast
--- before a response land in item.preVotes[name] instead - a side table
--- Awards.BuildCandidateList's awaitingCandidate() reads to seed the
--- "Awaiting Response" placeholder row's approvals/voteOrder - and get
--- folded into the real candidate row (preserving them, same as an existing
--- candidate's approvals/voteOrder) the moment SubmitResponse/applyResponse
--- actually create one; see the preVotes merge there.
---@param item table
---@param name string
local function getOrCreateCandidate(item, name)
    local candidate = item.candidates[name];
    if (candidate) then return candidate; end

    item.preVotes = item.preVotes or {};
    item.preVotes[name] = item.preVotes[name] or { approvals = {}, voteOrder = {} };
    return item.preVotes[name];
end

--- Toggles the local council member's approval of `targetPlayer` for one
--- item. Sends the resulting ABSOLUTE approval state, never a delta - see
--- applyVote below and docs/LOOT_COUNCIL_PLAN.md §3: an idempotent "my
--- current state is X" message self-heals if dropped or retransmitted,
--- instead of permanently desyncing a delta-based tally. Mirrors
--- SubmitResponse's optimistic-mutate -> pcall-send -> rollback-on-failure
--- -> refresh shape.
---@param itemSession number
---@param targetPlayer string realm-stripped candidate name being voted on
function LootCouncil.ToggleVote(itemSession, targetPlayer)
    local myName = Util.stripRealm(Util.UnitName("player"));
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return; end
    -- Never even attempt to send if we're not allowed to vote - a defensive
    -- backstop, not the only gate (the review window itself only enables
    -- the vote button for council members/the initiator - see its Refresh()).
    if (not LootCouncil.CanVote(myName, Util.playerFqn())) then return; end

    local item = Session.items[itemSession];
    if (not item) then return; end

    local candidate = getOrCreateCandidate(item, targetPlayer);

    local wasApproved = candidate.approvals[myName] == true;
    local approved = not wasApproved;

    -- Optimistic local mutation first (matches SubmitResponse). Set
    -- membership only - never store `false` (approvals is a set of names
    -- who approve, not a name->bool map, per docs/LOOT_COUNCIL_PLAN.md §1).
    -- voteOrder is updated BEFORE approvals so updateVoteOrder still sees the
    -- pre-toggle membership state.
    updateVoteOrder(candidate, myName, approved);
    candidate.approvals[myName] = approved or nil;

    local ok = pcall(lcSend, "vote", {
        sessionId = Session.id,
        itemSession = itemSession,
        targetPlayer = targetPlayer,
        approved = approved,
    }, "GROUP");

    if (not ok) then
        updateVoteOrder(candidate, myName, wasApproved); -- roll back
        candidate.approvals[myName] = wasApproved or nil;
    end

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end

--- Applied by every client (including the voter's own self-looped
--- broadcast) when a vote message is received. Mirrors applyResponse's
--- validate -> session-id-match -> mutate -> debug-print -> refresh shape,
--- but ALSO independently re-verifies the SENDER may vote (council member
--- or the session initiator, via CanVote) - never trusts anything the
--- sender claims about their own permissions (mirrors RollTracker.lua's
--- stopRollOff initiator check).
local function applyVote(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.sessionId or not content.itemSession
        or type(content.targetPlayer) ~= "string" or type(content.approved) ~= "boolean") then
        return;
    end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId) then return; end -- stale/foreign session
    if (Session.status ~= "active") then return; end -- late vote for an ended session

    -- Independently re-verify the sender may vote - the whole point of this
    -- check is that we do NOT trust the sender's own belief about their
    -- permissions, only our own local session/roster state.
    if (not LootCouncil.CanVote(Message.senderName, Message.senderFqn)) then return; end

    local item = Session.items[content.itemSession];
    if (not item) then return; end

    local candidate = getOrCreateCandidate(item, content.targetPlayer);

    -- voteOrder before approvals, same ordering as ToggleVote - on the
    -- voter's own self-echo this is a no-op transition (ToggleVote already
    -- applied it optimistically), so the name is never inserted twice.
    updateVoteOrder(candidate, Message.senderName, content.approved);
    -- Set membership only - never store `false` (see ToggleVote above).
    candidate.approvals[Message.senderName] = content.approved or nil;

    lcDebugPrint(("%s %s %s for item %d"):format(Message.senderName,
        content.approved and "approved" or "unapproved", content.targetPlayer, content.itemSession));

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.vote = applyVote;

--------------------------------------------------------------------------
-- Award + history (Phase 6)
--------------------------------------------------------------------------

--- Appends an award to the persistent history log (FL.DB.lootCouncil.history),
--- keyed by "initiatorFqn-sessionId-itemSession-awardSeq" so processing the
--- same award broadcast twice can't create a duplicate entry. A re-award
--- (awardSeq > 1) first deletes any existing row(s) sharing this item's
--- "initiatorFqn-sessionId-itemSession-" prefix, so reassigning an item
--- always leaves exactly one history row for it - the current recipient's -
--- rather than accumulating one stale row per past recipient. Called by BOTH
--- AwardItem (the leader's own optimistic path) and applyAward (every other
--- client's only path) - see docs/LOOT_COUNCIL_PLAN.md §1: "every client
--- appends to it... not just the leader," so the log survives the leader
--- disconnecting or swapping characters. Also nudges LootHistoryWindow to
--- repaint if it's currently open, so a new row (or a reassignment's
--- delete+insert) shows up live instead of only after the window is next
--- reopened - covers both paths above, so this fires whether the local
--- player just awarded/reassigned an item or the row just arrived from
--- another client's broadcast.
---
--- Session.id alone isn't enough: it's just each client's own nextSessionId
--- counter (see SendToRaid), so two different council leaders' "session 3"
--- collide on the exact same id despite being unrelated sessions. Prefixing
--- the leader's realm-qualified name turns it into a compound key that's
--- unique across different people's logs too, not just across a single
--- person's logins - load-bearing the moment history from two people is ever
--- merged (e.g. a future import feature), not just today's single-log case.
---@param Session table the CurrentSession this award belongs to
---@param itemSession number
---@param playerName string the award winner
---@param awardedBy string realm-stripped name of the session leader
---@param awardSeq number this item's per-award sequence number (see item.awardCount)
function LootCouncil.RecordHistory(Session, itemSession, playerName, awardedBy, awardSeq)
    local item = Session.items[itemSession];
    if (not item) then return; end

    -- A Forever character's full name ("First Last") has a space in it, which
    -- Util.playerFqn() preserves for display purposes elsewhere - stripped
    -- here so the id string itself stays space-free.
    local initiatorKey = (Session.initiatorFqn or "?"):lower():gsub("%s+", "");
    local id = ("%s-%d-%d-%d"):format(initiatorKey, Session.id, itemSession, awardSeq);
    for _, entry in ipairs(LootCouncil.History) do
        if (entry.id == id) then return; end -- this exact award already recorded
    end

    -- A re-award (awardSeq > 1) replaces this item's history row rather than
    -- appending alongside it - without this, reassigning an item left a
    -- stale row crediting the previous recipient sitting next to the new
    -- one. Matches on the same idPrefix as the dedupe id above (this
    -- session's item, scoped to this session's leader) so a different
    -- leader's unrelated "session 3" can never collide with this one's.
    local idPrefix = ("%s-%d-%d-"):format(initiatorKey, Session.id, itemSession);
    for i = #LootCouncil.History, 1, -1 do
        if (LootCouncil.History[i].id:sub(1, #idPrefix) == idPrefix) then
            table.remove(LootCouncil.History, i);
        end
    end

    -- Ids aren't stable between sessions (Core/Responses.lua), so history
    -- never stores a response id - only an immutable {label,color,kind}
    -- copy resolved from THIS session's own response snapshot, taken at the
    -- moment of the award. A later rename/recolor/delete in settings (or
    -- even a whole new session reusing the same id for something else) can
    -- never change what a past award's history entry shows. The literal
    -- fallback below only fires for a genuinely unresolvable id (e.g. a
    -- session with no response snapshot at all, from before this feature
    -- existed).
    -- Only a handful of candidates get saved per item, not every responder:
    -- whoever chose the top/first response option (Session.responses[1],
    -- e.g. "Major"), plus enough of the remaining real responders - in the
    -- same order the Award page shows them (FL.Awards.BuildCandidateList) -
    -- to reach a floor of 5. Synthetic "hasn't responded yet" placeholder
    -- rows that BuildCandidateList fabricates for unanswered group members
    -- are excluded automatically, since they were never inserted into
    -- item.candidates to begin with. The winner is always included even if
    -- their own response wasn't the top option and the 5-floor didn't reach
    -- them, since this entry exists specifically to record their award.
    local topResponseId = Session.responses and Session.responses[1] and Session.responses[1].id;
    local ordered = FL.Awards.BuildCandidateList(item);
    local topChosen, rest = {}, {};
    for _, entry in ipairs(ordered) do
        if (item.candidates[entry.name]) then
            if (topResponseId and entry.candidate.response == topResponseId) then
                table.insert(topChosen, entry.name);
            else
                table.insert(rest, entry.name);
            end
        end
    end

    local selected, selectedSet = {}, {};
    for _, name in ipairs(topChosen) do
        table.insert(selected, name);
        selectedSet[name] = true;
    end
    for _, name in ipairs(rest) do
        if (#selected >= 5) then break; end
        table.insert(selected, name);
        selectedSet[name] = true;
    end
    if (not selectedSet[playerName] and item.candidates[playerName]) then
        table.insert(selected, playerName);
    end

    local responses = {};
    for _, name in ipairs(selected) do
        local candidate = item.candidates[name];
        local responseCopy = FL.Responses.HistoryCopy(Session.responses, candidate.response)
            or { label = tostring(candidate.response), color = "8a8176", kind = "text" };
        responses[name] = {
            response = responseCopy,
            note = candidate.note,
            votes = Util.tcount(candidate.approvals),
            class = candidate.class,
        };
    end

    local winnerCandidate = item.candidates[playerName];

    table.insert(LootCouncil.History, {
        id = id,
        itemLink = item.itemLink,
        itemID = item.itemID,
        itemIcon = item.itemIcon,
        awardedTo = playerName,
        awardedToClass = winnerCandidate and winnerCandidate.class,
        awardedBy = awardedBy,
        awardedAt = GetServerTime(),
        sessionId = Session.id,
        itemSession = itemSession,
        responses = responses,
    });

    if (FL.UI.LootHistoryWindow and FL.UI.LootHistoryWindow.Refresh) then
        FL.UI.LootHistoryWindow.Refresh();
    end
end

--- Whether the local player may award items in the current session: gated
--- purely on having been the client that broadcast sessionStart
--- (Session.initiatorIsMe), NOT a live UnitIsGroupLeader check - see
--- AwardItem below. Shared by AwardItem's own guard and every UI-side
--- award/reassign gate, so the exact wording only lives in one place.
function LootCouncil.CanAwardItems()
    local Session = LootCouncil.CurrentSession;
    return Session ~= nil and Session.initiatorIsMe == true;
end

--- Awards `itemSession` to `playerName`: leader-only. Can be called again on
--- an already-awarded item to re-award it to someone else - there is no
--- "already awarded" guard, only the per-item awardCount below, which exists
--- purely to give each award event its own history id (see RecordHistory).
--- Optimistically mutates CurrentSession (matches SubmitResponse/ToggleVote's
--- convention), queues the item in FL.Trade and attempts to hand it over
--- immediately (mirrors RollTracker.AwardItem, RollTracker.lua:314-377,
--- reusing its rollOffId-keyed dedupe via a composite id instead of a
--- parallel Trade function - docs/LOOT_COUNCIL_PLAN.md §6 - which also means
--- a re-award correctly supersedes any still-pending trade queue entry from
--- the previous award of this same item, same composite id), announces the
--- award to raid/party chat (mirrors RollTracker.AwardItem's own chat
--- announcement), records history locally, then broadcasts the award so
--- every other client converges via applyAward below.
---@param itemSession number
---@param playerName string
function LootCouncil.AwardItem(itemSession, playerName)
    local Session = LootCouncil.CurrentSession;
    if (not LootCouncil.CanAwardItems()) then
        print("|cff8865ffForeverLoot|r Only the loot council session leader can award this item.");
        return;
    end
    if (Session.status ~= "active") then return; end
    local item = Session.items[itemSession];
    if (not item) then return; end

    local previousAwardedTo = item.awardedTo;
    local awardSeq = (item.awardCount or 0) + 1;
    item.awardCount = awardSeq;
    item.awardedTo = playerName;
    item.awardedAt = GetServerTime();
    local candidate = item.candidates[playerName];

    local councilAwardId = Session.id * 10000 + itemSession; -- reuses Trade's existing
                                                               -- rollOffId-scoped dedupe unmodified
    FL.Trade.QueueRemoveByRollOff(councilAwardId);
    local queueEntry = {
        itemLink = item.itemLink, itemIcon = item.itemIcon, itemID = item.itemID,
        winner = playerName, rollOffId = councilAwardId, rollAmount = nil,
        classification = candidate and FL.Awards.ResponseLabel(candidate.response),
        winnerClass = candidate and candidate.class,
    };
    FL.Trade.QueueAdd(queueEntry);

    FL.Trade.AttemptTradeForQueueEntry(queueEntry, function(success, reason)
        if (success) then
            return;
        end
        lcDebugPrint(("Auto-trade to %s failed: %s"):format(playerName, tostring(reason)));
        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Show) then
            FL.UI.TradeQueueWindow.Show();
        end
    end);

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel and FL.Settings.GetRaidChatLootCouncilAwardEnabled()) then
        local message = ("%s was awarded to %s!"):format(item.itemLink, playerName);
        if (previousAwardedTo and previousAwardedTo ~= playerName) then
            message = message .. (" (Re-assigned from %s)"):format(previousAwardedTo);
        end
        Util.SendChatMessageSafe(message, awardChannel);
    end

    LootCouncil.RecordHistory(Session, itemSession, playerName, Util.stripRealm(Util.UnitName("player")), awardSeq);

    local ok = pcall(lcSend, "award", { sessionId = Session.id, itemSession = itemSession, winner = playerName, awardSeq = awardSeq }, "GROUP");
    if (not ok) then
        -- Local state/trade/history are already committed at this point (the
        -- item is physically being handed over), so unlike
        -- SubmitResponse/ToggleVote there's nothing safe to roll back - just
        -- warn that other clients may not see this in their history yet.
        print("|cff8865ffForeverLoot|r Couldn't broadcast this award - other clients may not see it in their history until they relog or a resync happens.");
    end

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
end

--- Marks `itemSession` assigned for disenchanting: leader-only, same guard as
--- AwardItem. Deliberately reuses AwardItem's exact awardCount/awardedTo/
--- RecordHistory/lcSend "award" shape with
--- FL.Constants.LOOT_COUNCIL_DISENCHANT_RECIPIENT standing in for a player
--- name, so every other client converges via the existing applyAward below
--- with no changes there - but skips FL.Trade entirely (there's no real
--- recipient to hand the item to) and announces a disenchant line instead of
--- an award line.
---@param itemSession number
function LootCouncil.DisenchantItem(itemSession)
    local Session = LootCouncil.CurrentSession;
    if (not LootCouncil.CanAwardItems()) then
        print("|cff8865ffForeverLoot|r Only the loot council session leader can award this item.");
        return;
    end
    if (Session.status ~= "active") then return; end
    local item = Session.items[itemSession];
    if (not item) then return; end

    local recipient = FL.Constants.LOOT_COUNCIL_DISENCHANT_RECIPIENT;
    local previousAwardedTo = item.awardedTo;
    local awardSeq = (item.awardCount or 0) + 1;
    item.awardCount = awardSeq;
    item.awardedTo = recipient;
    item.awardedAt = GetServerTime();

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel and FL.Settings.GetRaidChatLootCouncilAwardEnabled()) then
        local message = ("%s will be disenchanted!"):format(item.itemLink);
        if (previousAwardedTo and previousAwardedTo ~= recipient) then
            message = message .. (" (Re-assigned from %s)"):format(previousAwardedTo);
        end
        Util.SendChatMessageSafe(message, awardChannel);
    end

    LootCouncil.RecordHistory(Session, itemSession, recipient, Util.stripRealm(Util.UnitName("player")), awardSeq);

    local ok = pcall(lcSend, "award", { sessionId = Session.id, itemSession = itemSession, winner = recipient, awardSeq = awardSeq }, "GROUP");
    if (not ok) then
        print("|cff8865ffForeverLoot|r Couldn't broadcast this award - other clients may not see it in their history until they relog or a resync happens.");
    end

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
end

--- Applied by every client (leader included, via the self-looped broadcast)
--- when an award message is received. On the leader's own client this is a
--- no-op past the idempotency guard (AwardItem already applied this exact
--- awardSeq locally); on every other client this is the ONLY place award
--- state gets applied, and it never touches FL.Trade or chat
--- (docs/LOOT_COUNCIL_PLAN.md §2: only the initiator's own client hands the
--- item out). A GREATER awardSeq than what's already applied still goes
--- through on every client, including the leader's - that's what makes
--- re-awarding work. Independently re-verifies the sender is this session's
--- actual leader - never trusts the sender's own claim, mirroring
--- applyVote's CanVote re-check.
local function applyAward(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.sessionId or not content.itemSession
        or type(content.winner) ~= "string" or not content.awardSeq) then
        return;
    end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId) then return; end -- stale/foreign session

    if (not Util.iEquals(Message.senderFqn, Session.initiatorFqn)) then return; end

    local item = Session.items[content.itemSession];
    if (not item) then return; end
    if (item.awardCount and content.awardSeq <= item.awardCount) then return; end -- already applied (e.g. the leader's own echo)

    item.awardCount = content.awardSeq;
    item.awardedTo = content.winner;
    item.awardedAt = GetServerTime();

    LootCouncil.RecordHistory(Session, content.itemSession, content.winner, Message.senderName, content.awardSeq);

    lcDebugPrint(("%s awarded item %d to %s"):format(Message.senderName, content.itemSession, content.winner));

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
end
LootCouncil.CommActions.award = applyAward;

--------------------------------------------------------------------------
-- Session end
--------------------------------------------------------------------------

--- Ends the current session: leader-only (same gate as AwardItem). Sets
--- Session.status so every already-wired status=="active" check
--- (SubmitResponse/ToggleVote/AwardItem, RespondWindow.Refresh) locks out
--- further activity on every client, not just this one. Optimistic local
--- mutation first, matching AwardItem's convention, then broadcasts so every
--- other client converges via applySessionEnd below.
function LootCouncil.EndSession()
    local Session = LootCouncil.CurrentSession;
    if (not LootCouncil.CanAwardItems()) then return; end
    if (not Session or Session.status ~= "active") then return; end

    Session.status = "ended";
    -- Printed here rather than left to applySessionEnd's self-looped echo -
    -- that handler's "already applied" guard (Session.status ~= "active")
    -- bails out before its own print, since the optimistic mutation above
    -- already moved status off "active" by the time our own echo arrives.
    print("|cff8865ffForeverLoot|r You ended the loot council session.");

    local ok = pcall(lcSend, "sessionEnd", { sessionId = Session.id }, "GROUP");
    if (not ok) then
        print("|cff8865ffForeverLoot|r Couldn't broadcast the session end - other clients may not see it until they relog or a resync happens.");
    end

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Refresh) then
        FL.UI.StartSessionWindow.Refresh();
    end
end

--- Applied by every client (leader included, via the self-looped broadcast)
--- when a sessionEnd message arrives - the only place non-leader clients ever
--- see the session's status change. Independently re-verifies the sender is
--- this session's actual leader, mirroring applyAward.
local function applySessionEnd(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.sessionId) then return; end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId) then return; end -- stale/foreign session
    if (not Util.iEquals(Message.senderFqn, Session.initiatorFqn)) then return; end
    if (Session.status ~= "active") then return; end -- already applied (e.g. the leader's own echo)

    Session.status = "ended";

    lcDebugPrint(("%s ended loot council session %d"):format(Message.senderName, content.sessionId));
    -- Only reached on every OTHER client - the leader's own echo is caught by
    -- the "already applied" guard above (their optimistic mutation in
    -- EndSession already moved status off "active"), which is why EndSession
    -- prints its own leader-side confirmation instead of relying on this.
    print(("|cff8865ffForeverLoot|r %s ended the loot council session."):format(Message.senderName));

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Refresh) then
        FL.UI.StartSessionWindow.Refresh();
    end
end
LootCouncil.CommActions.sessionEnd = applySessionEnd;

--------------------------------------------------------------------------
-- End session early (UI/AwardWindow.lua's title-bar trash button) - distinct
-- from EndSession above: that one is only reachable once every item is
-- already assigned (a formality), this one is leader-initiated at any point
-- and specifically clears out whatever is still unassigned instead of
-- leaving it dangling forever.
--------------------------------------------------------------------------

--- Ends the current session early: leader-only (same gate as EndSession).
--- Every still-unassigned item has its candidates (responses + votes) wiped
--- and gets flagged item.removedEarly - NOT table.remove'd out of
--- Session.items, since item.session doubles as that array's own index
--- everywhere (AwardItem/ToggleVote/SubmitResponse/getSelectedItem all do
--- Session.items[itemSession]) and a physical remove would shift every later
--- item's index out from under its own .session field, corrupting already-
--- awarded items' trade-queue linkage (LootCouncil.AwardItem's
--- councilAwardId is derived from itemSession). Already-awarded items are
--- untouched - they keep their place in Session.items and FL.Trade's queue.
--- Session.status flips to "ended" same as EndSession, which is what
--- actually locks out further activity and closes every client's Review and
--- Award/Respond window (both already hide themselves once status isn't
--- "active" - see AwardWindow.doRefresh/RespondWindow.Refresh) and makes
--- applyResponse/applyVote drop any late message for this session.
function LootCouncil.EndSessionEarly()
    local Session = LootCouncil.CurrentSession;
    if (not LootCouncil.CanAwardItems()) then return; end
    if (not Session or Session.status ~= "active") then return; end

    local removedSessions = {};
    local removedCount = 0;
    for _, item in ipairs(Session.items) do
        if (not item.awardedTo) then
            item.candidates = {};
            item.preVotes = nil;
            item.removedEarly = true;
            removedCount = removedCount + 1;
            table.insert(removedSessions, item.session);
        end
    end

    Session.status = "ended";
    print(("|cff8865ffForeverLoot|r Session ended. %d unassigned item%s %s not awarded."):format(
        removedCount, removedCount == 1 and "" or "s", removedCount == 1 and "was" or "were"));

    local ok = pcall(lcSend, "sessionEndEarly", { sessionId = Session.id, removedSessions = removedSessions }, "GROUP");
    if (not ok) then
        print("|cff8865ffForeverLoot|r Couldn't broadcast the early session end - other clients may not see it until they relog or a resync happens.");
    end

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Refresh) then
        FL.UI.StartSessionWindow.Refresh();
    end
end

--- Applied by every client (leader included, via the self-looped broadcast)
--- when a sessionEndEarly message arrives - mirrors applySessionEnd's
--- sessionId/sender/idempotency guards, plus applies the same per-item
--- removedEarly flagging EndSessionEarly did locally on the leader's client.
local function applySessionEndEarly(Message)
    local content = Message.content;
    if (type(content) ~= "table" or not content.sessionId or type(content.removedSessions) ~= "table") then
        return;
    end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId) then return; end -- stale/foreign session
    if (not Util.iEquals(Message.senderFqn, Session.initiatorFqn)) then return; end
    if (Session.status ~= "active") then return; end -- already applied (e.g. the leader's own echo)

    for _, itemSession in ipairs(content.removedSessions) do
        local item = Session.items[itemSession];
        if (item and not item.awardedTo) then
            item.candidates = {};
            item.preVotes = nil;
            item.removedEarly = true;
        end
    end
    Session.status = "ended";

    lcDebugPrint(("%s ended loot council session %d early (%d unassigned)"):format(
        Message.senderName, content.sessionId, #content.removedSessions));
    print(("|cff8865ffForeverLoot|r The loot session was ended by %s."):format(Message.senderName));

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Refresh) then
        FL.UI.StartSessionWindow.Refresh();
    end
end
LootCouncil.CommActions.sessionEndEarly = applySessionEndEarly;
