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

-- In-memory (never persisted to FL.DB) proof that a given raid/party member
-- is actually running ForeverLoot: name -> true, set the moment ANY LC_PREFIX
-- traffic arrives from them (see onLCMessage below) and by the sessionStart
-- ack (applySessionStart) so a non-responder can be proven present too.
LootCouncil.Presence = {};

-- In-memory indexes over the persisted LootCouncil.History array (rebuilt
-- from it at Init, never themselves persisted) - let RecordHistory do its
-- dedupe/replace checks in O(1) instead of scanning the whole (unboundedly
-- growing) history on every single award. Every writer of LootCouncil.History
-- must go through AddHistoryEntry/RemoveHistoryEntry below so these can never
-- drift out of sync with the array.
LootCouncil.HistoryIndex = {};     -- id -> array index into LootCouncil.History
LootCouncil.HistoryItemIndex = {}; -- itemKey -> id of that item's current history entry

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
    LootCouncil.RebuildHistoryIndex();

    AceComm = LibStub("AceComm-3.0");
    LibDeflate = LibStub("LibDeflate");
    LibSerialize = LibStub("LibSerialize");
    AceComm:RegisterComm(LC_PREFIX, onLCMessage);

    ensureItemInfoFrame();
    LootCouncil.InitReloadWindows();
    LootCouncil.InitGroupWatcher();
end

--- Whether the local player still owes a response to an item that can
--- still be awarded. Awarded or removed items don't count: nothing the
--- player answers there can change anything.
local function hasOpenUnansweredItem(Session)
    local myName = Util.stripRealm(Util.UnitName("player"));
    for _, item in ipairs(Session.items) do
        if (not item.candidates[myName] and not item.awardedTo and not item.removedEarly) then
            return true;
        end
    end
    return false;
end

--- Brings the council windows back after a /reload or a relog after a
--- disconnect. The session itself survives in SavedVariables; only the
--- windows were lost.
---   - Respond window: when the player still has items to answer.
---   - Review and Award window: when the player is on the council (or is
---     the session's leader - CanAccessReviewWindow).
--- Checked a few seconds after the first PLAYER_ENTERING_WORLD, and once
--- more later in case the group roster hadn't loaded yet on a fresh login.
--- The council session domain's Summary() is the guard: it's nil unless the
--- session is active and its leader is in our group, so a leftover session
--- from an earlier raid never pops a window. If the session changed while we
--- were away, the snapshot catch-up that follows repaints (or hides) them.
local RELOAD_CHECK_DELAYS = { 3, 10 };

function LootCouncil.InitReloadWindows()
    local frame = CreateFrame("Frame");
    frame:RegisterEvent("PLAYER_ENTERING_WORLD");
    frame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD"); -- later ones are zone changes
        local respondShown, awardShown = false, false;
        for _, delay in ipairs(RELOAD_CHECK_DELAYS) do
            C_Timer.After(delay, function()
                local Session = LootCouncil.CurrentSession;
                if (not LootCouncil.IsSessionLive()) then return; end
                if (not FL.Sync.CouncilSessionDomain:Summary()) then return; end

                if (not respondShown and hasOpenUnansweredItem(Session)
                    and FL.UI.RespondWindow and FL.UI.RespondWindow.Show) then
                    respondShown = true;
                    FL.UI.RespondWindow.Show();
                end
                if (not awardShown and LootCouncil.CanAccessReviewWindow()
                    and FL.UI.AwardWindow and FL.UI.AwardWindow.Show) then
                    awardShown = true;
                    FL.UI.AwardWindow.Show();
                end
            end);
        end
    end);
end

--------------------------------------------------------------------------
-- Broadcast - dedicated comm channel, mirrors Comm.lua's own pipeline
-- (serialize -> compress -> encode) and anti-spoof check, but without
-- Gargul's version-handshake fields since there's no third-party protocol
-- to satisfy here.
--------------------------------------------------------------------------

--- Debug log line in the COUNCIL category (Sync/Debug.lua, /fl debug).
local function lcLog(level, fmt, ...)
    FL.Sync.Debug.Log("COUNCIL", level, fmt, ...);
end

--- "item 3 (|cff...|h[Thunderfury]|h|r)" - a session item for log lines.
local function itemLabel(Session, itemSession)
    local item = Session and Session.items and Session.items[itemSession];
    local link = item and (item.itemLink or item.itemName);
    return link and ("item %d (%s)"):format(itemSession, link) or ("item " .. tostring(itemSession));
end

--- A response id's label from the session's own response list.
local function responseLabel(Session, responseId)
    for _, r in ipairs((Session and Session.responses) or {}) do
        if (r.id == responseId) then return r.label or tostring(responseId); end
    end
    return tostring(responseId);
end

-- Every change to CurrentSession is counted here, once per client, so a
-- raid member who joins late or reloads can tell they're behind (plan Phase
-- 7, Data/CouncilSessionDomain.lua's "single version point"). Called where a
-- change is actually applied: the network apply handlers below, plus the
-- leader's own optimistic paths whose echo is ignored. A raider's own
-- optimistic SubmitResponse/ToggleVote is counted at its echo instead.
local function bump(cause)
    FL.Sync.CouncilSessionDomain:Bump(cause);
end

lcSend = function(action, content, channel, recipient)
    local distribution, target = Util.GroupDistribution(channel or "GROUP", recipient);

    local payload = { a = action, b = content, c = Util.playerFqn() };
    if (distribution ~= "WHISPER" and recipient) then
        payload.r = recipient;
    end

    local encoded = LibDeflate:EncodeForWoWAddonChannel(
        LibDeflate:CompressDeflate(LibSerialize:Serialize(payload), { level = 5 }));

    lcLog(2, "sent %s · to %s", tostring(action), target or tostring(distribution):lower());

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
    if (type(payload.c) == "string" and senderName) then
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

    lcLog(2, "got %s from %s · via %s", tostring(Message.action), Message.senderName or Message.senderFqn or "?",
        tostring(distribution):lower());

    local handler = LootCouncil.CommActions[Message.action];
    if (handler) then handler(Message); end
end

--------------------------------------------------------------------------
-- Council membership (Phase 4+)
--
-- Two separate lists:
--   - The saved roster (LootCouncil.Roster, FL.DB.lootCouncil.roster): this
--     client's own local list of who to pre-select on the Loot Council
--     settings page. Never sent or overwritten over the network.
--   - The session council (Session.council): who actually sits on the
--     council for the running session. Set by the leader at session start
--     from the saved roster members who are in the group (plus the leader),
--     and only changed by the leader's "Update Session Council".
-- Every vote/access check reads the session council.
--------------------------------------------------------------------------

--- Pure session-council check - false with no session. Two separate, wider
--- checks build on top of this - CanAccessReviewWindow (window visibility)
--- and CanVote (voting eligibility) - both also let the session initiator
--- in, as a safety net for an older session saved without a council. This
--- function itself must stay the narrow council-only check other code
--- relies on.
---@param name string
function LootCouncil.IsCouncilMember(name)
    local Session = LootCouncil.CurrentSession;
    local council = Session and Session.council;
    return council ~= nil and council[Util.stripRealm(name)] == true;
end

--- Whether `name` is on this client's saved roster (the settings page's
--- pre-selection), regardless of any session.
---@param name string
function LootCouncil.IsOnSavedRoster(name)
    return LootCouncil.Roster[Util.stripRealm(name)] == true;
end

--- Whether the local player may open UI/AwardWindow.lua. Wider
--- than IsCouncilMember: also lets the current session's initiator in.
function LootCouncil.CanAccessReviewWindow()
    if (LootCouncil.IsCouncilMember(Util.UnitName("player"))) then return true; end
    local Session = LootCouncil.CurrentSession;
    return Session ~= nil and Session.initiatorIsMe == true;
end

--- Whether `name`/`fqn` may cast a vote in the current session - a session
--- council member, or the session's own initiator (mirrors
--- CanAccessReviewWindow's widening). Takes an explicit fqn (rather than
--- reading the local-only Session.initiatorIsMe flag) so the SAME function
--- verifies both the local player (ToggleVote) and a remote sender
--- (applyVote) by comparing fqn against Session.initiatorFqn, which every
--- client agrees on.
---@param name string
---@param fqn string|nil
function LootCouncil.CanVote(name, fqn)
    if (LootCouncil.IsCouncilMember(name)) then return true; end
    local Session = LootCouncil.CurrentSession;
    return Session ~= nil and fqn ~= nil and Util.iEquals(fqn, Session.initiatorFqn);
end

--------------------------------------------------------------------------
-- Saved roster + session council management
--------------------------------------------------------------------------

-- Fired (no arguments) whenever the saved roster OR the session council
-- changes - a local roster edit (RosterAdd/RosterRemove/RosterClear), a new
-- session, or an incoming council update. Lets UI outside the settings page
-- (e.g. StartSessionWindow's council-count button) react immediately
-- instead of polling.
local councilChangedCallbacks = {};

function LootCouncil.RegisterRosterChangedCallback(fn)
    table.insert(councilChangedCallbacks, fn);
end

local function fireCouncilChanged()
    for _, fn in ipairs(councilChangedCallbacks) do
        pcall(fn);
    end
end

local function sortedKeys(set)
    local names = {};
    for name in pairs(set or {}) do
        table.insert(names, name);
    end
    table.sort(names);
    return names;
end

--- Alphabetical array of every saved roster name (in the group or not).
function LootCouncil.RosterNames()
    return sortedKeys(LootCouncil.Roster);
end

--- Alphabetical array of the running session's council, or {} with no
--- session.
function LootCouncil.SessionCouncilNames()
    local Session = LootCouncil.CurrentSession;
    return sortedKeys(Session and Session.council);
end

--- The council a session started (or updated) right now would get: every
--- saved roster member currently in the raid/party, plus the local player
--- (the leader always sits on their own session's council). Alphabetical,
--- realm-stripped.
function LootCouncil.SelectedCouncilNames()
    local selected = {};
    selected[Util.stripRealm(Util.UnitName("player"))] = true;

    local groupsResult = FL.LootCouncilRoster.BuildGroups();
    for _, group in pairs(groupsResult.groups) do
        for _, member in ipairs(group.members) do
            if (LootCouncil.IsOnSavedRoster(member.name)) then
                selected[Util.stripRealm(member.name)] = true;
            end
        end
    end

    return sortedKeys(selected);
end

--- Builds a { [strippedName] = true } set from a names array off the wire.
---@param names string[]
local function councilSet(names)
    local set = {};
    for _, name in ipairs(names or {}) do
        if (type(name) == "string" and name ~= "") then
            set[Util.stripRealm(name)] = true;
        end
    end
    return set;
end

--- Replaces the running session's council wholesale with `names`
--- (full-replace, not a merge - this module's idempotent-absolute-state
--- convention). Used by the leader's sessionCouncilUpdate
--- (applySessionCouncilUpdate). Never touches the saved roster.
---@param names string[]
local function applySessionCouncil(names)
    local Session = LootCouncil.CurrentSession;
    if (not Session) then return; end
    Session.council = councilSet(names);
    fireCouncilChanged();
end

--- Whether the leader's current in-group selection differs from the running
--- session's council - i.e. "Update Session Council" has something to push.
--- Always false with no live session, or when we didn't start it.
function LootCouncil.HasPendingCouncilUpdate()
    if (not LootCouncil.IsSessionLive() or not LootCouncil.CurrentSession.initiatorIsMe) then return false; end
    local current = LootCouncil.CurrentSession.council or {};
    local selected = LootCouncil.SelectedCouncilNames();
    if (#selected ~= Util.tcount(current)) then return true; end
    for _, name in ipairs(selected) do
        if (not current[name]) then return true; end
    end
    return false;
end

--- Adds `name` to the saved roster. Returns false if already present.
--- Local only - a running session's council changes only through
--- UpdateSessionCouncil.
---@param name string
function LootCouncil.RosterAdd(name)
    name = Util.stripRealm(name or "");
    if (name == "") then return false; end
    if (LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = true;
    fireCouncilChanged();
    return true;
end

--- Removes `name` from the saved roster. Returns false if not present.
---@param name string
function LootCouncil.RosterRemove(name)
    name = Util.stripRealm(name or "");
    if (not LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = nil;
    fireCouncilChanged();
    return true;
end

--- Removes every saved roster member. Returns the number removed.
function LootCouncil.RosterClear()
    local n = Util.tcount(LootCouncil.Roster);
    if (n == 0) then return 0; end
    wipe(LootCouncil.Roster);
    fireCouncilChanged();
    return n;
end

--- Pushes the leader's current in-group selection (SelectedCouncilNames) to
--- the running session as its new council. Only the session's initiator may
--- do this - receivers ignore it from anyone else.
---@return boolean success
function LootCouncil.UpdateSessionCouncil()
    local Session = LootCouncil.CurrentSession;
    if (not LootCouncil.IsSessionLive() or not Session.initiatorIsMe) then return false; end
    lcSend("sessionCouncilUpdate", {
        sessionId = Session.id,
        council = LootCouncil.SelectedCouncilNames(),
    }, "GROUP");
    return true;
end

--- Closes the Review and Award window if it's open but the local player no
--- longer has access (taken off the session council, or a new session they
--- aren't on). Returns true if it closed it.
local function closeAwardWindowIfNoAccess()
    local AwardWindow = FL.UI.AwardWindow;
    if (not (AwardWindow and AwardWindow.IsShown and AwardWindow.IsShown())) then return false; end
    if (LootCouncil.CanAccessReviewWindow()) then return false; end
    AwardWindow.Hide();
    return true;
end

--- Applied by every client (including the sender, via the self-looped
--- broadcast) when a sessionCouncilUpdate arrives. If this local player was
--- just added, automatically pop the Review and Award window open for them -
--- matches the "broadcast pops the window" convention MaybeAutoShow already
--- uses for a brand-new session (see applySessionStart).
local function applySessionCouncilUpdate(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.council) ~= "table" or not content.sessionId) then return; end

    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.id ~= content.sessionId or Session.status ~= "active") then return; end
    if (not Util.iEquals(Message.senderFqn, Session.initiatorFqn)) then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local wasMember = LootCouncil.IsCouncilMember(myName);

    applySessionCouncil(content.council);
    bump("council");

    lcLog(1, "session #%d: council updated by %s · %d members", content.sessionId,
        Util.stripRealm(Message.senderFqn or "?"), #content.council);
    print(("|cff8865ffForeverLoot|r Session council updated by %s (%d members)."):format(
        Util.stripRealm(Message.senderFqn or "?"), #content.council));

    local becameMember = (not wasMember) and LootCouncil.IsCouncilMember(myName);
    if (becameMember) then
        if (FL.UI.AwardWindow and FL.UI.AwardWindow.Show) then
            FL.UI.AwardWindow.Show(); -- Show() itself calls Refresh()
        end
    elseif (closeAwardWindowIfNoAccess()) then
        print("|cff8865ffForeverLoot|r You were removed from the session council.");
    elseif (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.sessionCouncilUpdate = applySessionCouncilUpdate;

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

    -- A repeat of the session we already hold (same leader, id and item
    -- list) is a duplicate, not a new session. Before Phase 7 this only
    -- happened on a duplicated message; now a snapshot import (late join,
    -- reload) can deliver the session before its own sessionStart arrives,
    -- and re-creating it here would wipe every response the import carried.
    local existing = LootCouncil.CurrentSession;
    if (existing and existing.id == content.sessionId and Util.iEquals(existing.initiatorFqn, Message.senderFqn)
        and #existing.items >= #content.items) then
        local same = true;
        for i, itemLink in ipairs(content.items) do
            if (existing.items[i].itemLink ~= itemLink) then same = false; break; end
        end
        if (same) then return; end
    end

    -- This session's council: the leader's in-group selection at the moment
    -- it started (SelectedCouncilNames). The initiator is always on it, even
    -- if the leader's client somehow left them out.
    local council = councilSet(type(content.council) == "table" and content.council or nil);
    council[Util.stripRealm(Message.senderFqn or "")] = true;
    council[""] = nil;

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
        startedAtServer = GetServerTime(), -- comparable across clients (snapshot versions); GetTime() isn't
        status = "active",
        items = items,
        responses = responses,
        council = council,
        rev = 0,
    };
    LootCouncil.CurrentSession = FL.DB.lootCouncil.session;
    bump("start");
    fireCouncilChanged();

    lcLog(1, "session #%d started by %s · %d items", content.sessionId, Util.stripRealm(Message.senderFqn or "?"), #items);

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

    -- A window still open from the previous session closes if we aren't on
    -- this one's council.
    closeAwardWindowIfNoAccess();

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
    bump("addItems");

    lcLog(1, "session #%d: %s added %d item%s · now %d items", content.sessionId, Util.stripRealm(Message.senderFqn or "?"),
        #content.items, (#content.items == 1) and "" or "s", #Session.items);

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
        council = LootCouncil.SelectedCouncilNames(),
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
    if (not LootCouncil.IsSessionLive()) then return false; end
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
    bump("response");

    -- Authoritative confirmation that SubmitResponse's optimistic send above
    -- actually made it out and back - clears any stale failure marker even
    -- if a later retry's own pcall result got missed for some reason.
    if (Message.isSelf) then
        item.sendFailed = false;
    end

    lcLog(1, "%s answered \"%s\" on %s", Message.senderName, responseLabel(Session, content.response),
        itemLabel(Session, content.itemSession));

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
    bump("vote");

    lcLog(1, "%s %s %s on %s", Message.senderName,
        content.approved and "voted for" or "took back their vote for", content.targetPlayer, itemLabel(Session, content.itemSession));

    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Refresh) then
        FL.UI.AwardWindow.Refresh();
    end
end
LootCouncil.CommActions.vote = applyVote;

--------------------------------------------------------------------------
-- Award + history (Phase 6)
--------------------------------------------------------------------------

--- Rebuilds HistoryIndex/HistoryItemIndex from scratch off LootCouncil.History
--- (an O(n) pass, but only ever run once per login/reload from Init - see
--- there). Also the correct thing to call after any bulk mutation of
--- LootCouncil.History that doesn't go through AddHistoryEntry/
--- RemoveHistoryEntry below (e.g. a future prune/archival pass that trims old
--- rows directly) so the indexes can't silently drift out of sync with it.
function LootCouncil.RebuildHistoryIndex()
    local history = LootCouncil.History or {};
    wipe(LootCouncil.HistoryIndex);
    wipe(LootCouncil.HistoryItemIndex);
    for i, entry in ipairs(history) do
        LootCouncil.HistoryIndex[entry.id] = i;
        if (entry.itemKey) then
            LootCouncil.HistoryItemIndex[entry.itemKey] = entry.id;
        end
    end
end

--- Appends `entry` to LootCouncil.History and keeps HistoryIndex/
--- HistoryItemIndex in sync. The only correct way to add a row - a raw
--- table.insert would leave the indexes pointing at stale/missing positions.
function LootCouncil.AddHistoryEntry(entry)
    local history = LootCouncil.History;
    table.insert(history, entry);
    LootCouncil.HistoryIndex[entry.id] = #history;
    if (entry.itemKey) then
        LootCouncil.HistoryItemIndex[entry.itemKey] = entry.id;
    end
end

--- Removes the entry with the given `id` from LootCouncil.History, if
--- present, and returns it. Swap-remove (move the last element into the
--- removed slot) rather than table.remove's shift-down: LootCouncil.History's
--- own array order was never meaningful (LootHistoryWindow always re-sorts
--- its own copy by awardedAt before displaying it), so there's nothing to
--- preserve by paying O(n) to keep it - this makes removal O(1) instead.
function LootCouncil.RemoveHistoryEntry(id)
    local history = LootCouncil.History;
    local index = LootCouncil.HistoryIndex[id];
    if (not index) then return nil; end

    local removed = history[index];
    local lastIndex = #history;
    if (index ~= lastIndex) then
        local moved = history[lastIndex];
        history[index] = moved;
        LootCouncil.HistoryIndex[moved.id] = index;
    end
    history[lastIndex] = nil;
    LootCouncil.HistoryIndex[id] = nil;
    if (removed.itemKey and LootCouncil.HistoryItemIndex[removed.itemKey] == id) then
        LootCouncil.HistoryItemIndex[removed.itemKey] = nil;
    end
    return removed;
end

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
---@param source string "local" (this client is the one awarding) or "live" (arrived via applyAward's broadcast) - passed through to Data/Store.lua's apply-outcome logging
function LootCouncil.RecordHistory(Session, itemSession, playerName, awardedBy, awardSeq, source)
    local item = Session.items[itemSession];
    if (not item) then return; end

    -- A Forever character's full name ("First Last") has a space in it, which
    -- Util.playerFqn() preserves for display purposes elsewhere - stripped
    -- here so the id string itself stays space-free.
    local initiatorKey = (Session.initiatorFqn or "?"):lower():gsub("%s+", "");
    local id = ("%s-%d-%d-%d"):format(initiatorKey, Session.id, itemSession, awardSeq);
    if (LootCouncil.HistoryIndex[id]) then return; end -- this exact award already recorded

    -- A re-award (awardSeq > 1) replaces this item's history row rather than
    -- appending alongside it - without this, reassigning an item left a
    -- stale row crediting the previous recipient sitting next to the new
    -- one. itemKey identifies this item within this session's leader's log
    -- (everything about `id` except awardSeq) - at most one history row ever
    -- exists per itemKey, so HistoryItemIndex points straight at the exact
    -- row to replace instead of scanning for an id-prefix match.
    local itemKey = ("%s-%d-%d"):format(initiatorKey, Session.id, itemSession);
    -- Session-internal reassignment, not a user-facing delete: every client
    -- derives the exact same replacement deterministically from its own copy
    -- of the session state, so this stays a direct local removal rather than
    -- a tombstoned Store delete (which is reserved for the officer-gated
    -- History UI action - see Sync/Live.lua). The removed row is still
    -- threaded through to Live.Award below purely so the history UI can
    -- incrementally drop it from its own indexes, same as before.
    local oldId = LootCouncil.HistoryItemIndex[itemKey];
    local replacedEntry;
    if (oldId) then
        replacedEntry = LootCouncil.RemoveHistoryEntry(oldId);
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

    local newEntry = {
        id = id,
        itemKey = itemKey,
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
    };
    -- Routed through Store so every write - a local award, a received award,
    -- the manual "Add Entry" row, and later phases' synced rows - shares one
    -- apply path (test-data guarding, itemString population, and the
    -- EntryApplied callback the history UI now refreshes from instead of the
    -- direct OnEntryUpserted call this replaces). This "award" broadcast
    -- (right above/below this call, in AwardItem/DisenchantItem/applyAward)
    -- stays exactly as it is - it drives Session.items state for the raid's
    -- council UI, not history. Live.Award (Phase 2) separately broadcasts
    -- this row as LIVE_ROW to the whole guild, but only when source=="local"
    -- - i.e. only on the one client that actually originated it, not on
    -- every raid member applying the "live"-sourced copy below - see
    -- Sync/Live.lua's header comment. replacedEntry rides along purely so
    -- the UI's EntryApplied handler can incrementally drop the superseded
    -- row too, on a reassignment.
    FL.Sync.Live.Award(newEntry, source, replacedEntry);
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

-- How long our own never-ended session stays live. Past this it's treated
-- as left over from an earlier raid, so the leader can start a fresh one.
local STALE_OWN_SESSION_SECONDS = 12 * 60 * 60;

--- Whether the current session is one this client can still act on: active,
--- and either ours and started recently, or led by someone in our group. A
--- session we were left holding from an earlier raid (the leader ended it
--- while we were offline, or never ended it) isn't live, so it can't block
--- starting a new one. Derived, never written back to Session.status, so a
--- leader who's only briefly out of the group brings the session back the
--- moment they rejoin - same rule CouncilSessionDomain's localVersion() uses.
function LootCouncil.IsSessionLive()
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return false; end
    if (Session.initiatorIsMe) then
        local started = Session.startedAtServer;
        return started == nil or (GetServerTime() - started) < STALE_OWN_SESSION_SECONDS;
    end
    return FL.Sync.CouncilSessionDomain.InMyGroup(Util.stripRealm(Session.initiatorFqn or ""));
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
    bump("award");
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
        lcLog(1, "couldn't start the trade with %s · %s, added to the trade queue", playerName, tostring(reason));
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

    LootCouncil.RecordHistory(Session, itemSession, playerName, Util.stripRealm(Util.UnitName("player")), awardSeq, "local");

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
    bump("award");

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel and FL.Settings.GetRaidChatLootCouncilAwardEnabled()) then
        local message = ("%s will be disenchanted!"):format(item.itemLink);
        if (previousAwardedTo and previousAwardedTo ~= recipient) then
            message = message .. (" (Re-assigned from %s)"):format(previousAwardedTo);
        end
        Util.SendChatMessageSafe(message, awardChannel);
    end

    LootCouncil.RecordHistory(Session, itemSession, recipient, Util.stripRealm(Util.UnitName("player")), awardSeq, "local");

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
    bump("award");

    LootCouncil.RecordHistory(Session, content.itemSession, content.winner, Message.senderName, content.awardSeq, "live");

    lcLog(1, "%s awarded %s to %s", Message.senderName, itemLabel(Session, content.itemSession), content.winner);

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
    bump("end");
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
    bump("end");

    lcLog(1, "session #%d ended by %s", content.sessionId, Message.senderName);
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
-- Leaving the group mid-session
--
--   - A raider who leaves drops their local copy (DropSession). It is NOT
--     marked ended: ended is terminal in sync (Data/CouncilSessionDomain.lua),
--     so an ended copy would never resync on rejoin - and would even be
--     pushed back to the raid as a "correction", ending it for everyone.
--     With no session held, the joinGroup HELLO (Sync/Coordinator.lua)
--     imports it again and ReplaceSession reopens the windows.
--   - The leader leaving ends the session for good. The leader can't
--     broadcast once out of the group, so every client ends it on its own
--     side: the leader when it leaves, each raider when it sees the leader
--     gone from the roster (endSessionLocally).
--------------------------------------------------------------------------

local function closeSessionWindows()
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Hide) then FL.UI.RespondWindow.Hide(); end
    if (FL.UI.AwardWindow and FL.UI.AwardWindow.Hide) then FL.UI.AwardWindow.Hide(); end
    if (FL.UI.StartSessionWindow and FL.UI.StartSessionWindow.Refresh) then
        FL.UI.StartSessionWindow.Refresh();
    end
end

--- Forgets the current session entirely (local only, nothing is sent) and
--- closes its windows. It comes back through sync if the group still has it.
---@param reason string for the debug log
function LootCouncil.DropSession(reason)
    local Session = LootCouncil.CurrentSession;
    if (not Session) then return; end
    lcLog(1, "session #%d dropped · %s", Session.id or 0, tostring(reason));
    FL.DB.lootCouncil.session = nil;
    LootCouncil.CurrentSession = nil;
    fireCouncilChanged();
    closeSessionWindows();
end

--- Ends the current session on this client only - the same state change as
--- applySessionEnd, for when no sessionEnd message can arrive (the leader
--- left the group).
---@param reason string for the debug log
local function endSessionLocally(reason)
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return; end
    Session.status = "ended";
    bump("end");
    lcLog(1, "session #%d ended locally · %s", Session.id or 0, tostring(reason));
    closeSessionWindows();
end

-- Wait after login before the first group check (the roster may not have
-- loaded yet), and debounce for roster updates - ending a session can't be
-- undone, so a half-loaded roster must never count as "left".
local GROUP_WATCH_LOGIN_DELAY = 5;
local GROUP_WATCH_DEBOUNCE = 2;

function LootCouncil.InitGroupWatcher()
    local inGroup;       -- nil until the first post-login check
    local leaderSeenFor; -- "leader#id" of the session whose leader we've seen in our group
    local pending = false;

    local function sessionKey(Session)
        return Util.stripRealm(Session.initiatorFqn or "?") .. "#" .. tostring(Session.id);
    end

    local function leaderInGroup()
        local Session = LootCouncil.CurrentSession;
        if (not Session or Session.initiatorIsMe) then return false; end
        return FL.Sync.CouncilSessionDomain.InMyGroup(Util.stripRealm(Session.initiatorFqn or ""));
    end

    -- Remembers that this session's leader is (or was) in our group. Run on
    -- every check and whenever a session starts or is imported, so a session
    -- whose leader we never saw - a stale one from an earlier raid - is the
    -- only kind that's never ended for "leader left".
    local function noteLeader()
        if (leaderInGroup()) then leaderSeenFor = sessionKey(LootCouncil.CurrentSession); end
    end
    LootCouncil.RegisterRosterChangedCallback(noteLeader);

    local function check()
        local now = IsInGroup();
        local Session = LootCouncil.CurrentSession;
        local active = Session ~= nil and Session.status == "active";

        if (inGroup and not now and Session) then
            if (Session.initiatorIsMe) then
                if (active) then
                    endSessionLocally("leaderLeft");
                    print("|cff8865ffForeverLoot|r You left the group - your loot council session has ended.");
                end
            else
                local wasActive = active and LootCouncil.IsSessionLive();
                LootCouncil.DropSession("leftGroup");
                if (wasActive) then
                    print("|cff8865ffForeverLoot|r You left the group - the loot council session was closed. It will resync if you rejoin.");
                end
            end
        elseif (now and active and not Session.initiatorIsMe and leaderSeenFor == sessionKey(Session)
            and not leaderInGroup()) then
            -- Only when the leader WAS in our group at the last check: a stale
            -- session from an earlier raid must never be ended (and its ended
            -- state then pushed back to that leader's raid by sync).
            endSessionLocally("leaderLeft");
            print(("|cff8865ffForeverLoot|r %s left the group - the loot council session has ended."):format(
                Util.stripRealm(Session.initiatorFqn or "?")));
        end

        inGroup = now;
        noteLeader();
    end

    local frame = CreateFrame("Frame");
    frame:RegisterEvent("PLAYER_ENTERING_WORLD");
    frame:RegisterEvent("GROUP_ROSTER_UPDATE");
    frame:SetScript("OnEvent", function(self, event)
        if (event == "PLAYER_ENTERING_WORLD") then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD"); -- later ones are zone changes
            C_Timer.After(GROUP_WATCH_LOGIN_DELAY, function()
                inGroup = IsInGroup();
                noteLeader();
            end);
            return;
        end
        if (inGroup == nil or pending) then return; end
        pending = true;
        C_Timer.After(GROUP_WATCH_DEBOUNCE, function()
            pending = false;
            check();
        end);
    end);
end

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
    bump("endEarly");
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
    bump("endEarly");

    lcLog(1, "session #%d ended early by %s · %d items left unassigned",
        content.sessionId, Message.senderName, #content.removedSessions);
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

--------------------------------------------------------------------------
-- Snapshot import (sync domain 2, Data/CouncilSessionDomain.lua)
--------------------------------------------------------------------------

--- Replaces CurrentSession wholesale with a session caught up from another
--- raid member's snapshot (a late join, reload or disconnect). `plain` is
--- the decoded snapshot - id, initiatorFqn, initiatorIsMe, startedAtServer,
--- rev, status, endedAt, responses, and items carrying itemLink,
--- awardedTo/At, awardCount, removedEarly, candidates and preVotes. Item
--- entries are rebuilt through buildSessionItemEntry so their shape matches
--- a live session exactly. `councilNames` becomes the session's council
--- (the saved roster is never touched). The caller has already decided
--- `plain` is newer than what we hold.
---@param plain table
---@param councilNames string[]|nil
function LootCouncil.ReplaceSession(plain, councilNames)
    local previous = LootCouncil.CurrentSession;
    local isNewSession = not previous or previous.id ~= plain.id
        or not Util.iEquals(previous.initiatorFqn, plain.initiatorFqn);

    local items = {};
    for i, src in ipairs(plain.items) do
        local item = buildSessionItemEntry(src.itemLink, i);
        item.awardedTo = src.awardedTo;
        item.awardedAt = src.awardedAt;
        item.awardCount = src.awardCount;
        item.removedEarly = src.removedEarly;
        item.candidates = src.candidates;
        item.preVotes = src.preVotes;

        -- arrivalIndex is local-only tie-breaking (see nextArrivalIndex);
        -- respondedAt order is the closest thing to arrival order a
        -- snapshot can offer.
        local names = {};
        for name in pairs(item.candidates) do table.insert(names, name); end
        table.sort(names, function(a, b)
            local ra, rb = item.candidates[a].respondedAt or 0, item.candidates[b].respondedAt or 0;
            if (ra ~= rb) then return ra < rb; end
            return a < b;
        end);
        for _, name in ipairs(names) do
            nextArrivalIndex = nextArrivalIndex + 1;
            item.candidates[name].arrivalIndex = nextArrivalIndex;
        end
        items[i] = item;
    end

    FL.DB.lootCouncil.session = {
        id = plain.id,
        initiatorFqn = plain.initiatorFqn,
        initiatorIsMe = plain.initiatorIsMe == true,
        startedAt = GetTime(),
        startedAtServer = plain.startedAtServer,
        status = plain.status,
        endedAt = plain.endedAt,
        items = items,
        responses = plain.responses,
        council = councilSet(councilNames),
        rev = plain.rev,
    };
    LootCouncil.CurrentSession = FL.DB.lootCouncil.session;

    -- Our own session coming back from a raider (SavedVariables lost to a
    -- crash): don't let the next SendToRaid reuse its id.
    local db = FL.DB.lootCouncil;
    if (plain.initiatorIsMe and plain.id > (db.nextSessionId or 0)) then
        db.nextSessionId = plain.id;
    end

    fireCouncilChanged();

    lcLog(1, "session #%d replaced by a synced copy · %d items, %s", plain.id, #items, tostring(plain.status));

    -- The synced copy may have a council we're no longer on.
    closeAwardWindowIfNoAccess();

    -- Only a session we didn't already have pops the windows, like a fresh
    -- sessionStart would; catching up one we hold just repaints.
    if (isNewSession and plain.status == "active") then
        if (FL.UI.RespondWindow and FL.UI.RespondWindow.MaybeAutoShow) then
            FL.UI.RespondWindow.MaybeAutoShow();
        end
        if (FL.UI.AwardWindow and FL.UI.AwardWindow.MaybeAutoShow) then
            FL.UI.AwardWindow.MaybeAutoShow();
        end
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
