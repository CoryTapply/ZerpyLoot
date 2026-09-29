--[[
The loot leader's configurable set of response buttons raiders see on the
Respond popup (UI/RespondWindow.lua) - replaces the old hard-coded
Constants.LOOT_COUNCIL_RESPONSES table. This module owns FL.DB.responses.list
(the leader's live, editable list - built by UI/SettingsWindow/Pages/
LootResponses.lua) plus every rule around it: how many of each kind are
allowed, id allocation, and how a SESSION's snapshot (a filtered copy taken
when a session starts - see Responses.SessionSnapshot) and a HISTORY copy (an
immutable {label,color,kind} record - see Responses.HistoryCopy) are built
from it. UI code should never read/write FL.DB.responses.list directly -
always through the functions here, so every validation rule lives in one
place.

Ids are only unique WITHIN a list, are never sent/stored outside that list's
own lifetime (a session snapshot, or - never - history), and get reused after
a delete: NextId is just "(highest id in the list) + 1", not a persistent
counter.
]]

local FL = ForeverLoot;
local Util = FL.Util;
local Responses = FL.Responses;

-- Public (not local) so the settings page can read the same limits for its
-- own "N of 8" counter / disabled-Add tooltip instead of duplicating them.
Responses.MIN_TEXT_RESPONSES = 1;
Responses.MAX_TEXT_RESPONSES = 8;
Responses.MAX_LABEL_LENGTH = 18;

local MIN_TEXT_RESPONSES = Responses.MIN_TEXT_RESPONSES;
local MAX_TEXT_RESPONSES = Responses.MAX_TEXT_RESPONSES;
local MIN_LABEL_LENGTH = 1;
local MAX_LABEL_LENGTH = Responses.MAX_LABEL_LENGTH;

-- Same 12 presets the settings page's color palette popover shows - kept
-- here (not only in UI/SettingsWindow/Colors.lua) so Responses.AddText can
-- pick "the first preset not already used" without the Core module reaching
-- into a UI file. Colors.lua builds its float-RGB copy off this same list
-- (see UI/SettingsWindow/Colors.lua's responsePalette) rather than
-- duplicating the hex values a second time.
Responses.PALETTE_PRESETS = {
    "d93636", "e8922a", "e6c229", "3fb34f", "2fb8a8", "2f7fd9",
    "6b6bf0", "b04fd9", "d94f9c", "a07040", "cfc6b8", "8a8176",
};

Responses.DEFAULT_LIST = {
    { id = 1, kind = "text", label = "Major",    color = "d93636" },
    { id = 2, kind = "text", label = "Minor",    color = "e8922a" },
    { id = 3, kind = "text", label = "Offspec",  color = "2f7fd9" },
    { id = 4, kind = "pvp",  label = "PvP",      color = "e6c229", enabled = true },
    { id = 5, kind = "mog",  label = "Transmog", color = "b04fd9", enabled = true },
    { id = 6, kind = "pass", label = "Pass",     color = "8a8176" },
};

--------------------------------------------------------------------------
-- List helpers
--------------------------------------------------------------------------

function Responses.CloneList(list)
    local copy = {};
    for i, entry in ipairs(list) do
        copy[i] = {
            id = entry.id,
            kind = entry.kind,
            label = entry.label,
            color = entry.color,
            enabled = entry.enabled,
        };
    end
    return copy;
end

function Responses.Init()
    FL.DB.responses = FL.DB.responses or { list = Responses.CloneList(Responses.DEFAULT_LIST) };

    -- Migration: saved lists from before the "pvp" kind existed won't have
    -- one - insert it (ahead of Transmog/Pass, whichever comes first, so it
    -- lands in the same default position a fresh DEFAULT_LIST gives it) so
    -- upgraders get it without losing any of their own customizations to
    -- the rest of the list. Runs every login but is a no-op once the entry
    -- exists.
    local list = FL.DB.responses.list;
    local hasPvp = false;
    for _, entry in ipairs(list) do
        if (entry.kind == "pvp") then hasPvp = true; break; end
    end
    if (not hasPvp) then
        local insertAt = #list + 1;
        for i, entry in ipairs(list) do
            if (entry.kind == "mog" or entry.kind == "pass") then insertAt = i; break; end
        end
        table.insert(list, insertAt, {
            id = Responses.NextId(list), kind = "pvp", label = "PvP", color = "e6c229", enabled = true,
        });
    end
end

--- The live, editable list - the settings page mutates this (via the
--- functions below) in place.
function Responses.GetList()
    return FL.DB.responses.list;
end

function Responses.GetById(list, id)
    for _, entry in ipairs(list) do
        if (entry.id == id) then return entry; end
    end
    return nil;
end

local function findIndexById(list, id)
    for i, entry in ipairs(list) do
        if (entry.id == id) then return i; end
    end
    return nil;
end

local function countTextEntries(list)
    local count = 0;
    for _, entry in ipairs(list) do
        if (entry.kind == "text") then count = count + 1; end
    end
    return count;
end

--------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------

--- Trims and validates a candidate label for a "text" response. `excludeId`
--- (optional) lets a rename check uniqueness against every OTHER text entry
--- without tripping over itself. Returns ok, errorMessage, trimmedLabel.
function Responses.ValidateLabel(list, label, excludeId)
    local trimmed = Util.Trim(label or "");
    if (#trimmed < MIN_LABEL_LENGTH) then
        return false, "Every response needs a label.";
    end
    if (#trimmed > MAX_LABEL_LENGTH) then
        trimmed = trimmed:sub(1, MAX_LABEL_LENGTH);
    end

    for _, entry in ipairs(list) do
        if (entry.kind == "text" and entry.id ~= excludeId and Util.iEquals(entry.label, trimmed)) then
            return false, "Two responses can't share a label.";
        end
    end

    return true, nil, trimmed;
end

--- (highest id in the list) + 1, or 1 if the list is empty. Ids are reused
--- after a delete - there's no persistent counter.
function Responses.NextId(list)
    local maxId = 0;
    for _, entry in ipairs(list) do
        if (entry.id > maxId) then maxId = entry.id; end
    end
    return maxId + 1;
end

--------------------------------------------------------------------------
-- CRUD
--------------------------------------------------------------------------

--- Inserts a new "text" response right after the last existing text-kind
--- entry (so it lands before Transmog/PvP/Pass when those come after the
--- text block). Picks the first "New"/"New 2"/"New 3"... label not already taken
--- and the first palette preset not already used by any entry (falling back
--- to the first preset if every preset is already spoken for).
function Responses.AddText(list)
    if (countTextEntries(list) >= MAX_TEXT_RESPONSES) then
        return nil, "Up to 8 custom responses";
    end

    local label = "New";
    local suffix = 1;
    while (true) do
        local ok = Responses.ValidateLabel(list, label);
        if (ok) then break; end
        suffix = suffix + 1;
        label = "New " .. suffix;
    end

    local usedColors = {};
    for _, entry in ipairs(list) do usedColors[entry.color] = true; end
    local color = Responses.PALETTE_PRESETS[1];
    for _, preset in ipairs(Responses.PALETTE_PRESETS) do
        if (not usedColors[preset]) then color = preset; break; end
    end

    local entry = { id = Responses.NextId(list), kind = "text", label = label, color = color };

    local insertAt = #list + 1;
    for i, e in ipairs(list) do
        if (e.kind == "text") then insertAt = i + 1; end
    end
    table.insert(list, insertAt, entry);

    return entry;
end

--- Refuses mog/pvp/pass ids, and refuses deleting the last remaining text entry.
function Responses.DeleteText(list, id)
    local entry = Responses.GetById(list, id);
    if (not entry or entry.kind ~= "text") then
        return false, "Only custom responses can be deleted.";
    end
    if (countTextEntries(list) <= MIN_TEXT_RESPONSES) then
        return false, "Keep at least one response";
    end

    table.remove(list, findIndexById(list, id));
    return true;
end

function Responses.Rename(list, id, newLabel)
    local entry = Responses.GetById(list, id);
    if (not entry or entry.kind ~= "text") then
        return false, "Only custom responses can be renamed.";
    end

    local ok, err, trimmed = Responses.ValidateLabel(list, newLabel, id);
    if (not ok) then return false, err; end

    entry.label = trimmed;
    return true;
end

--- Works for any kind, including "pass" (its color can still change even
--- though its label/position can't).
function Responses.Recolor(list, id, hex)
    local entry = Responses.GetById(list, id);
    if (not entry) then return false, "Unknown response."; end
    entry.color = hex;
    return true;
end

function Responses.SetMogEnabled(list, enabled)
    for _, entry in ipairs(list) do
        if (entry.kind == "mog") then
            entry.enabled = enabled;
            return true;
        end
    end
    return false;
end

function Responses.SetPvpEnabled(list, enabled)
    for _, entry in ipairs(list) do
        if (entry.kind == "pvp") then
            entry.enabled = enabled;
            return true;
        end
    end
    return false;
end

--- Swaps `id`'s entry with its previous neighbor. Refuses to move "pass"
--- (it's always last) - nothing before pass can ever swap PAST it this way
--- since pass, being last, is never itself the "previous neighbor" of
--- anything but the position immediately above it.
function Responses.MoveUp(list, id)
    local entry = Responses.GetById(list, id);
    if (not entry or entry.kind == "pass") then return false; end

    local index = findIndexById(list, id);
    if (not index or index <= 1) then return false; end

    list[index], list[index - 1] = list[index - 1], list[index];
    return true;
end

--- Swaps `id`'s entry with its next neighbor. Refuses to move "pass", and
--- refuses moving anything into pass's slot (i.e. the row immediately above
--- pass can't move down) - this is what keeps pass always last.
function Responses.MoveDown(list, id)
    local entry = Responses.GetById(list, id);
    if (not entry or entry.kind == "pass") then return false; end

    local index = findIndexById(list, id);
    if (not index) then return false; end
    local nextEntry = list[index + 1];
    if (not nextEntry or nextEntry.kind == "pass") then return false; end

    list[index], list[index + 1] = list[index + 1], list[index];
    return true;
end

function Responses.ResetToDefaults()
    FL.DB.responses.list = Responses.CloneList(Responses.DEFAULT_LIST);
end

--------------------------------------------------------------------------
-- Session snapshot / history copy
--------------------------------------------------------------------------

--- A copy of the current settings list with disabled "mog"/"pvp" entries
--- dropped - this is what gets broadcast at session start
--- (LootCouncil.SendToRaid) and is the ONLY list every raider's Respond
--- popup and Review & Vote pill ever reads from for the lifetime of that
--- session. Ids in this snapshot are the session's ids - never re-derived
--- from the (possibly since-edited) live settings list.
function Responses.SessionSnapshot()
    local list = Responses.GetList();
    local snapshot = {};
    for _, entry in ipairs(list) do
        if (not ((entry.kind == "mog" or entry.kind == "pvp") and entry.enabled == false)) then
            table.insert(snapshot, { id = entry.id, kind = entry.kind, label = entry.label, color = entry.color });
        end
    end
    return snapshot;
end

--- Resolves `id` against `sessionList` (a session's own snapshot - NEVER the
--- live settings list, since ids/labels/colors can drift between sessions)
--- and returns a plain, id-less {label, color, kind} copy suitable for
--- writing into history. History must never store a response id - only this
--- copy, so a later rename/recolor/delete in settings can't change what a
--- past award's history entry shows.
function Responses.HistoryCopy(sessionList, id)
    local entry = sessionList and Responses.GetById(sessionList, id);
    if (not entry) then return nil; end
    return { label = entry.label, color = entry.color, kind = entry.kind };
end
