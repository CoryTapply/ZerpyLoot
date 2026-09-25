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

    if (changed and FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
end

local function ensureItemInfoFrame()
    local itemInfoFrame = CreateFrame("Frame");
    itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED");
    itemInfoFrame:SetScript("OnEvent", function(_, _, itemID, success)
        if (success) then refreshSessionItemData(itemID); end
    end);
end

function LootCouncil.Init()
    FL.DB.lootCouncil = FL.DB.lootCouncil or {
        roster = {},
        draft = { items = {} },
        history = {},
        session = nil,
    };
    local db = FL.DB.lootCouncil;

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

    lcDebugPrint(("RECV %s <- %s (%s)"):format(tostring(Message.action), Message.senderFqn or "?", distribution));

    local handler = LootCouncil.CommActions[Message.action];
    if (handler) then handler(Message); end
end

--------------------------------------------------------------------------
-- Council membership (Phase 4+)
--------------------------------------------------------------------------

--- Pure roster check. Two separate, wider checks build on top of this -
--- CanAccessReviewWindow (window visibility) and CanVote (voting
--- eligibility) - both also let the session initiator in. This function
--- itself must stay the narrow roster-only check other code relies on.
---@param name string
function LootCouncil.IsCouncilMember(name)
    return LootCouncil.Roster[Util.stripRealm(name)] == true;
end

--- Whether the local player may open UI/LootCouncilReviewWindow.lua. Wider
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

--- Alphabetical array of every current council member's name, for display
--- and for broadcasting (see broadcastRosterSync/sessionStart below).
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
--- Shared by the live councilRoster push (applyCouncilRoster) and
--- sessionStart's own roster snapshot (applySessionStart).
---@param names string[]
local function applyRosterNames(names)
    wipe(LootCouncil.Roster);
    for _, name in ipairs(names) do
        if (type(name) == "string" and name ~= "") then
            LootCouncil.Roster[Util.stripRealm(name)] = true;
        end
    end
end

--- Broadcasts the current roster to the raid so every client's local roster
--- converges immediately, without waiting for the next session to start
--- (which also carries a roster snapshot - see applySessionStart). No
--- permission gating on receipt - mirrors sessionStart's own trust model
--- (any client can technically call RosterAdd/RosterRemove or SendToRaid;
--- the wire layer's anti-spoof check only guarantees identity, not intent).
local function broadcastRosterSync()
    pcall(lcSend, "councilRoster", { names = LootCouncil.RosterNames() }, "GROUP");
end

--- Adds `name` to the council roster. Returns false if already present.
---@param name string
function LootCouncil.RosterAdd(name)
    name = Util.stripRealm(name or "");
    if (name == "") then return false; end
    if (LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = true;
    broadcastRosterSync();
    return true;
end

--- Removes `name` from the council roster. Returns false if not present.
---@param name string
function LootCouncil.RosterRemove(name)
    name = Util.stripRealm(name or "");
    if (not LootCouncil.Roster[name]) then return false; end
    LootCouncil.Roster[name] = nil;
    broadcastRosterSync();
    return true;
end

--- Removes every current council roster member. Returns the number removed.
function LootCouncil.RosterClear()
    local n = Util.tcount(LootCouncil.Roster);
    if (n == 0) then return 0; end
    wipe(LootCouncil.Roster);
    broadcastRosterSync();
    return n;
end

--- Applied by every client when a councilRoster sync arrives (the live push
--- from RosterAdd/RosterRemove above). If this local player was just added
--- mid-session, automatically pop the Review & Vote window open for them -
--- matches the existing "broadcast pops the window" convention MaybeAutoShow
--- already uses for a brand-new session (see applySessionStart) - without
--- this, a newly-added council member would have no way to know they need
--- to open /flc themselves.
local function applyCouncilRoster(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.names) ~= "table") then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local wasMember = LootCouncil.IsCouncilMember(myName);

    applyRosterNames(content.names);

    lcDebugPrint(("Council roster synced from %s (%d members)"):format(Message.senderFqn or "?", #content.names));

    local becameMember = (not wasMember) and LootCouncil.IsCouncilMember(myName);
    local Session = LootCouncil.CurrentSession;
    if (becameMember and Session and Session.status == "active") then
        if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Show) then
            FL.UI.LootCouncilReviewWindow.Show(); -- Show() itself calls Refresh()
        end
    elseif (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
    end
end
LootCouncil.CommActions.councilRoster = applyCouncilRoster;

--- Pushes the full council roster to the raid - distinct from SendToRaid
--- below, which starts a new voting SESSION on the leader's draft item list.
--- Only meaningful to call as the raid leader/assistant (see
--- UI/SettingsWindow/Pages/LootCouncil.lua, which disables its "Sync to
--- Raid" button otherwise) - not gated here, matching this module's existing
--- trust model (see broadcastRosterSync's comment above).
function LootCouncil.SyncCouncilSettings()
    lcSend("councilSettingsSync", {
        names = LootCouncil.RosterNames(),
    }, "GROUP");
end

local function applyCouncilSettingsSync(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.names) ~= "table") then return; end

    applyRosterNames(content.names);

    print(("|cff8865ffForeverLoot|r Council settings synced from %s (%d members)."):format(
        Message.senderFqn or "?", #content.names));
end
LootCouncil.CommActions.councilSettingsSync = applyCouncilSettingsSync;

--------------------------------------------------------------------------
-- Session lifecycle
--------------------------------------------------------------------------

local nextSessionId = 0;

-- Applied locally by every client (initiator included, via the self-looped
-- broadcast) when a sessionStart message is processed - mirrors
-- RollTracker.lua's applyStart. The sessionId always comes from the message,
-- never generated locally, so every client agrees on the same id.
local function applySessionStart(Message)
    local content = Message.content;
    if (type(content) ~= "table" or type(content.items) ~= "table" or not content.sessionId) then
        return;
    end

    -- Roster snapshot carried alongside the session, so anyone who missed
    -- (or never received) a live councilRoster push still converges the
    -- moment a session starts - the live push above already covers the
    -- "mid-session" case, this covers "never got the memo" as a backstop.
    if (type(content.names) == "table") then
        applyRosterNames(content.names);
    end

    local items = {};
    for i, itemLink in ipairs(content.items) do
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

        items[i] = {
            session = i,
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

    FL.DB.lootCouncil.session = {
        active = true,
        id = content.sessionId,
        initiatorFqn = Message.senderFqn,
        initiatorIsMe = Message.isSelf,
        startedAt = GetTime(),
        status = "active",
        items = items,
    };
    LootCouncil.CurrentSession = FL.DB.lootCouncil.session;

    lcDebugPrint(("Loot council session %d started by %s (%d items)"):format(content.sessionId, Message.senderFqn or "?", #items));

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.MaybeAutoShow) then
        FL.UI.RespondWindow.MaybeAutoShow();
    end
    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.MaybeAutoShow) then
        FL.UI.LootCouncilReviewWindow.MaybeAutoShow();
    end
end
LootCouncil.CommActions.sessionStart = applySessionStart;

--- Broadcasts the leader's current session item list (owned by
--- Session/SessionItems.lua) to the raid as a new session.
---@return boolean success
function LootCouncil.SendToRaid()
    local sessionItems = FL.SessionItems.GetItems();
    if (#sessionItems == 0) then
        print("|cff8865ffForeverLoot|r Add at least one item to the list first.");
        return false;
    end

    nextSessionId = nextSessionId + 1;

    local itemLinks = {};
    for i, draftItem in ipairs(sessionItems) do
        itemLinks[i] = draftItem.itemLink;
    end

    lcSend("sessionStart", { sessionId = nextSessionId, items = itemLinks, names = LootCouncil.RosterNames() }, "GROUP");

    return true;
end

--------------------------------------------------------------------------
-- Responses (Phase 3)
--------------------------------------------------------------------------

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
---@param responseId string one of Constants.LOOT_COUNCIL_RESPONSES ids
---@param note string|nil
function LootCouncil.SubmitResponse(itemSession, responseId, note)
    local Session = LootCouncil.CurrentSession;
    if (not Session or Session.status ~= "active") then return; end
    local item = Session.items[itemSession];
    if (not item or item.awardedTo) then return; end
    if (not FL.Constants.LOOT_COUNCIL_RESPONSE_LABELS[responseId]) then return; end

    local myName = Util.stripRealm(Util.UnitName("player"));
    local _, classFile = UnitClass("player");

    local previous = item.candidates[myName];
    item.candidates[myName] = {
        class = classFile,
        response = responseId,
        note = note or "",
        respondedAt = (previous and previous.respondedAt) or GetServerTime(),
        approvals = (previous and previous.approvals) or {},
    };
    item.sendFailed = false;

    local ok = pcall(lcSend, "response", {
        sessionId = Session.id,
        itemSession = itemSession,
        response = responseId,
        note = note or "",
        class = classFile,
    }, "GROUP");

    if (not ok) then
        item.candidates[myName] = previous;
        item.sendFailed = true;
    end

    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
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

    local item = Session.items[content.itemSession];
    if (not item) then return; end

    local existing = item.candidates[Message.senderName];
    item.candidates[Message.senderName] = {
        class = content.class,
        response = content.response,
        note = content.note or "",
        respondedAt = (existing and existing.respondedAt) or GetServerTime(),
        approvals = (existing and existing.approvals) or {},
    };

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
    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
    end
end
LootCouncil.CommActions.response = applyResponse;

--------------------------------------------------------------------------
-- Voting (Phase 5)
--------------------------------------------------------------------------

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

    local candidate = item.candidates[targetPlayer];
    if (not candidate) then return; end -- can't vote for someone with no response yet

    local wasApproved = candidate.approvals[myName] == true;
    local approved = not wasApproved;

    -- Optimistic local mutation first (matches SubmitResponse). Set
    -- membership only - never store `false` (approvals is a set of names
    -- who approve, not a name->bool map, per docs/LOOT_COUNCIL_PLAN.md §1).
    candidate.approvals[myName] = approved or nil;

    local ok = pcall(lcSend, "vote", {
        sessionId = Session.id,
        itemSession = itemSession,
        targetPlayer = targetPlayer,
        approved = approved,
    }, "GROUP");

    if (not ok) then
        candidate.approvals[myName] = wasApproved or nil; -- roll back
    end

    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
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

    -- Independently re-verify the sender may vote - the whole point of this
    -- check is that we do NOT trust the sender's own belief about their
    -- permissions, only our own local session/roster state.
    if (not LootCouncil.CanVote(Message.senderName, Message.senderFqn)) then return; end

    local item = Session.items[content.itemSession];
    if (not item) then return; end

    local candidate = item.candidates[content.targetPlayer];
    if (not candidate) then return; end -- can't vote for someone with no response

    -- Set membership only - never store `false` (see ToggleVote above).
    candidate.approvals[Message.senderName] = content.approved or nil;

    lcDebugPrint(("%s %s %s for item %d"):format(Message.senderName,
        content.approved and "approved" or "unapproved", content.targetPlayer, content.itemSession));

    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
    end
end
LootCouncil.CommActions.vote = applyVote;

--------------------------------------------------------------------------
-- Award + history (Phase 6)
--------------------------------------------------------------------------

--- Appends an award to the persistent history log (FL.DB.lootCouncil.history),
--- deduped by "sessionId-itemSession-awardSeq" (one id per award EVENT, not
--- per item - an item can be re-awarded, each award gets its own history
--- row) so processing the same award broadcast twice can't create a
--- duplicate entry. Called by BOTH AwardItem (the leader's own optimistic
--- path) and applyAward (every other client's only path) - see
--- docs/LOOT_COUNCIL_PLAN.md §1: "every client appends to it... not just the
--- leader," so the log survives the leader disconnecting or swapping
--- characters.
---@param Session table the CurrentSession this award belongs to
---@param itemSession number
---@param playerName string the award winner
---@param awardedBy string realm-stripped name of the session leader
---@param awardSeq number this item's per-award sequence number (see item.awardCount)
function LootCouncil.RecordHistory(Session, itemSession, playerName, awardedBy, awardSeq)
    local item = Session.items[itemSession];
    if (not item) then return; end

    local id = ("%d-%d-%d"):format(Session.id, itemSession, awardSeq);
    for _, entry in ipairs(LootCouncil.History) do
        if (entry.id == id) then return; end -- this exact award already recorded
    end

    local responses = {};
    for name, candidate in pairs(item.candidates) do
        responses[name] = {
            response = candidate.response,
            note = candidate.note,
            votes = Util.tcount(candidate.approvals),
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
    if (not Session or not Session.initiatorIsMe) then
        print("|cff8865ffForeverLoot|r Only the loot council session leader can award this item.");
        return;
    end
    if (Session.status ~= "active") then return; end
    local item = Session.items[itemSession];
    if (not item) then return; end

    local awardSeq = (item.awardCount or 0) + 1;
    item.awardCount = awardSeq;
    item.awardedTo = playerName;
    item.awardedAt = GetServerTime();
    local candidate = item.candidates[playerName];

    local councilAwardId = Session.id * 10000 + itemSession; -- reuses Trade's existing
                                                               -- rollOffId-scoped dedupe unmodified
    FL.Trade.QueueRemoveByRollOff(councilAwardId);
    FL.Trade.QueueAdd({
        itemLink = item.itemLink, itemIcon = item.itemIcon, itemID = item.itemID,
        winner = playerName, rollOffId = councilAwardId, rollAmount = nil,
        classification = candidate and FL.Constants.LOOT_COUNCIL_RESPONSE_LABELS[candidate.response],
        winnerClass = candidate and candidate.class,
    });

    FL.Trade.AttemptTrade(playerName, item.itemLink, function(success, reason)
        if (success) then
            print(("|cff8865ffForeverLoot|r %s placed in the trade window with %s - accept the trade to finish."):format(item.itemLink, playerName));
            return;
        end
        lcDebugPrint(("Auto-trade to %s failed: %s"):format(playerName, tostring(reason)));
        print(("|cff8865ffForeverLoot|r Couldn't trade %s to %s (%s) - it stays in the trade queue."):format(
            item.itemLink, playerName, tostring(reason)
        ));
        if (FL.UI.TradeQueueWindow and FL.UI.TradeQueueWindow.Show) then
            FL.UI.TradeQueueWindow.Show();
        end
    end);

    local awardChannel = Util.GroupChatChannel();
    if (awardChannel) then
        pcall(SendChatMessage, ("%s was awarded to %s!"):format(item.itemLink, playerName), awardChannel);
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

    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
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

    if (FL.UI.LootCouncilReviewWindow and FL.UI.LootCouncilReviewWindow.Refresh) then
        FL.UI.LootCouncilReviewWindow.Refresh();
    end
    if (FL.UI.RespondWindow and FL.UI.RespondWindow.Refresh) then
        FL.UI.RespondWindow.Refresh();
    end
end
LootCouncil.CommActions.award = applyAward;
