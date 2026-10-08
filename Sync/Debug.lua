--[[
Logging for the sync system, plus the /fl debug slash-command handler
(dispatched to from the /fl handler in Debug.lua at the repo root - that
file is the slash dispatcher, this file is the logging engine).

Line format (docs/ForeverLoot History Sync — Spec.md, "Debug system" section):
    FL HH:MM:SS.mmm [CAT] text

Zero-cost when off: Log() checks IsOn(cat, level) before building any string.
Warn()/Err() always buffer (so rare problems are never lost) but only
chat-print while debug is enabled.
]]

local FL = ForeverLoot;
local Debug = FL.Sync.Debug;

-- Pending line, for repeat-collapsing: a line's first occurrence prints and
-- buffers immediately (so a tester sees it in real time); an identical
-- (catLabel, text) line repeated within DEBUG_COLLAPSE_SECONDS afterward is
-- counted instead of reprinted, and the count is reconciled once the window
-- closes with no further repeat, by rewriting that same buffered line as
-- "text (x12)" and reprinting it once to chat.
local pending = nil; -- { catLabel, text, count, lastTime, timerHandle, bufferIndex }

-- WoW's time()/date() have whole-second resolution; GetTime() has sub-second
-- precision but counts from an arbitrary point. The old version glued
-- date()'s seconds to GetTime()'s fraction, which don't line up - lines came
-- out with milliseconds going backwards within a second, and cross-client
-- comparisons could be off by up to a second. Instead, keep one offset
-- (wall clock minus GetTime()) and render GetTime() + offset. time() -
-- GetTime() never exceeds the true offset and reaches it just after each
-- wall-clock second ticks over, so keeping the largest value seen converges
-- on it within the first few lines.
local wallOffset;

local function timestamp()
    local now = GetTime();
    local candidate = time() - now;
    if (not wallOffset or candidate > wallOffset) then wallOffset = candidate; end
    local wall = wallOffset + now;
    local secs = math.floor(wall);
    return ("%s.%03d"):format(date("%H:%M:%S", secs), math.floor((wall - secs) * 1000));
end

local function formatLine(catLabel, text, count)
    local suffix = (count > 1) and (" (x%d)"):format(count) or "";
    return ("FL %s [%s] %s%s"):format(timestamp(), catLabel, text, suffix);
end

-- Tells the Debug Log window (UI/DebugLogWindow.lua) the buffer or a
-- setting changed, so an open window repaints. Looked up per call: the
-- window file loads after this one.
local function notifyWindow(what)
    local w = FL.UI and FL.UI.DebugLogWindow;
    if (w and w.OnDebugChanged) then w.OnDebugChanged(what); end
end

local function appendToBuffer(line)
    local log = FL.DB.debug.log;
    table.insert(log, line);
    while (#log > FL.Sync.Constants.DEBUG_LOG_LINES) do
        table.remove(log, 1);
    end
    notifyWindow("log");
end

local function printToChat(line)
    DEFAULT_CHAT_FRAME:AddMessage(Debug.ColorizeLine(line));
end

-- Reconciles a finished collapse window: if the line only ever occurred
-- once, it was already printed/buffered by emit() and there's nothing more
-- to do. If it repeated, rewrite the buffered copy with the final count and
-- show that update once in chat.
local function flushPending()
    if (not pending) then return; end
    if (pending.count > 1) then
        local line = formatLine(pending.catLabel, pending.text, pending.count);
        local log = FL.DB.debug.log;
        if (log[pending.bufferIndex]) then log[pending.bufferIndex] = line; notifyWindow("log"); end
        if (FL.DB.debug.enabled) then printToChat(line); end
    end
    pending = nil;
end

local function emit(catLabel, text)
    local now = GetTime();
    if (pending and pending.catLabel == catLabel and pending.text == text
        and (now - pending.lastTime) < FL.Sync.Constants.DEBUG_COLLAPSE_SECONDS) then
        pending.count = pending.count + 1;
        pending.lastTime = now;
        if (pending.timerHandle) then pending.timerHandle:Cancel(); end
        pending.timerHandle = C_Timer.NewTimer(FL.Sync.Constants.DEBUG_COLLAPSE_SECONDS, flushPending);
        return;
    end

    flushPending(); -- a different line interrupts/finalizes whatever was pending

    -- First occurrence: print and buffer immediately, then watch for repeats.
    local line = formatLine(catLabel, text, 1);
    appendToBuffer(line);
    if (FL.DB.debug.enabled) then printToChat(line); end

    pending = { catLabel = catLabel, text = text, count = 1, lastTime = now, bufferIndex = #FL.DB.debug.log };
    pending.timerHandle = C_Timer.NewTimer(FL.Sync.Constants.DEBUG_COLLAPSE_SECONDS, flushPending);
end

function Debug.IsOn(cat, level)
    local d = FL.DB.debug;
    if (not d or not d.enabled) then return false; end
    if (d.cats[cat] == false) then return false; end
    return level <= d.level;
end

function Debug.Log(cat, level, fmt, ...)
    if (not Debug.IsOn(cat, level)) then return; end
    emit(cat, fmt:format(...));
end

function Debug.Warn(cat, fmt, ...)
    emit(cat, "WARN " .. fmt:format(...));
end

function Debug.Err(cat, fmt, ...)
    emit(cat, "ERR " .. fmt:format(...));
end

--- "412B" or "4.9KB" (spec's fixed unit spelling for every byte count in a
--- debug line). Shared by every sync module's CODEC/COMM lines instead of
--- each formatting bytes its own way.
function Debug.FormatBytes(n)
    n = n or 0;
    if (n < 1024) then return ("%dB"):format(n); end
    return ("%.1fKB"):format(n / 1024);
end

--- The one time format every log line uses: "340ms", "4.2s", "2m05s".
---@param seconds number|nil
function Debug.FormatTime(seconds)
    seconds = math.max(0, seconds or 0);
    if (seconds < 1) then return ("%dms"):format(math.floor(seconds * 1000 + 0.5)); end
    if (seconds < 60) then return ("%.1fs"):format(seconds); end
    local whole = math.floor(seconds);
    return ("%dm%02ds"):format(math.floor(whole / 60), whole % 60);
end

local DOMAIN_NAMES = { [1] = "history", [2] = "council" };

--- Every log category, in display order, with what it covers - the Debug
--- Log window's category dropdown (docs/debug-logs.md has the same list).
--- `color` is the [CAT] tag's color (hex RRGGBB), in chat and the window.
--- Related categories share a hue family: sync discovery blues, council
--- purple, history sync teals/greens, wire-level greys, roll/softres warm.
Debug.CATEGORIES = {
    { name = "GATE",    desc = "when sync may run",     color = "e6c229" },
    { name = "PEERS",   desc = "finding peers",         color = "4fc3f7" },
    { name = "COUNCIL", desc = "loot council",          color = "c58cff" },
    { name = "SESS",    desc = "history sync sessions", color = "4fd9a8" },
    { name = "LIVE",    desc = "guild award updates",   color = "ff9f43" },
    { name = "PERM",    desc = "officer checks",        color = "e07a9a" },
    { name = "COMM",    desc = "sends and receives",    color = "8fa3b8" },
    { name = "CODEC",   desc = "encoding",              color = "7f9a9b" },
    { name = "STORE",   desc = "history writes",        color = "a3d977" },
    { name = "DIGEST",  desc = "history hashes",        color = "6fbf73" },
    { name = "DOMAIN",  desc = "sync domains",          color = "9ad0ec" },
    { name = "PRUNE",   desc = "retention",             color = "d9a066" },
    { name = "ITEM",    desc = "item info",             color = "d4c08a" },
    { name = "ROLL",    desc = "roll-offs",             color = "ffd166" },
    { name = "SOFTRES", desc = "softres",               color = "f78fb3" },
    { name = "SCHED",   desc = "timers and tasks",      color = "a0aab0" },
    { name = "PERF",    desc = "slow tasks, speed",     color = "e8922a" },
    { name = "TEST",    desc = "debug commands",        color = "5dade2" },
};

local CATEGORY_COLORS = {};
for _, c in ipairs(Debug.CATEGORIES) do CATEGORY_COLORS[c.name] = c.color; end
local DEFAULT_CATEGORY_COLOR = "cccccc";

--- A category's tag color as hex RRGGBB.
function Debug.CategoryColor(catName)
    return CATEGORY_COLORS[catName] or DEFAULT_CATEGORY_COLOR;
end

--- A stored (plain) log line with color codes added for display: purple
--- "FL", grey timestamp, the [CAT] tag in its category color, and WARN/ERR
--- in yellow/red. The saved buffer itself stays plain, so a copied log has
--- no color codes in it.
function Debug.ColorizeLine(line)
    local out = line:gsub("^FL (%S+) %[(%u+)%]", function(ts, cat)
        return ("|cff8865ffFL|r |cff8a8a8a%s|r |cff%s[%s]|r"):format(ts, Debug.CategoryColor(cat), cat);
    end, 1);
    out = out:gsub("%]|r WARN ", "]|r |cffd9b54aWARN|r ", 1);
    out = out:gsub("%]|r ERR ", "]|r |cffff6b5eERR|r ", 1);
    return out;
end

--- Level names for the UI, by level number.
Debug.LEVEL_NAMES = { "Normal", "Verbose", "Very verbose" };

function Debug.IsCategoryOn(catName)
    return FL.DB.debug.cats[catName] ~= false;
end

--- "history" / "council" for a sync domain id, in place of "d1" / "d2".
function Debug.DomainName(id)
    return DOMAIN_NAMES[id] or ("domain " .. tostring(id));
end

function Debug.SetEnabled(enabled)
    FL.DB.debug.enabled = enabled and true or false;
    if (FL.DB.debug.enabled and FL.Sync.Gate and FL.Sync.Gate.LogCurrentState) then
        FL.Sync.Gate.LogCurrentState();
    end
    notifyWindow("settings");
end

function Debug.SetLevel(n)
    n = tonumber(n);
    if (not n or n < 1 or n > 3) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug level 1|2|3");
        return;
    end
    FL.DB.debug.level = n;
    notifyWindow("settings");
end

function Debug.SetCategory(catName, state)
    catName = (catName or ""):upper();
    if (catName == "") then
        print("|cff8865ffForeverLoot|r Usage: /fl debug cat <CAT> on|off");
        return;
    end
    FL.DB.debug.cats[catName] = (state ~= "off");
    notifyWindow("settings");
end

function Debug.ClearLog()
    wipe(FL.DB.debug.log);
    notifyWindow("log");
end

--- Whether this client accepts/generates zztest- rows (Data/Store.lua's
--- applyRow guard, and the gen/purgetest/droplocal commands below).
function Debug.IsTestDataMode()
    return FL.DB.debug.testData == true;
end

function Debug.SetTestDataMode(enabled)
    FL.DB.debug.testData = enabled and true or false;
    notifyWindow("settings");
end

--- Plan Phase 8 build item 5: commands that fabricate, drop or force data
--- only run in test-data mode. Logs the plan's "refused" line (debug log
--- only).
local function requireTestData(cmd)
    if (Debug.IsTestDataMode()) then return true; end
    Debug.Log("TEST", 1, "%s: refused · needs /fl debug testdata on", cmd);
    return false;
end

function Debug.HandleSlash(rest)
    rest = strtrim(rest or "");
    local word, arg = string.match(rest, "^(%S*)%s*(.-)$");
    word = word or "";
    arg = arg or "";

    if (word == "on") then
        Debug.SetEnabled(true);
    elseif (word == "off") then
        Debug.SetEnabled(false);
    elseif (word == "level") then
        Debug.SetLevel(arg);
    elseif (word == "cat") then
        local catName, catState = string.match(arg, "^(%S*)%s*(%S*)$");
        Debug.SetCategory(catName, catState);
    elseif (word == "log" or word == "") then
        if (FL.UI.DebugLogWindow and FL.UI.DebugLogWindow.Show) then
            FL.UI.DebugLogWindow.Show();
        end
    elseif (word == "clear") then
        Debug.ClearLog();
    elseif (word == "testdata") then
        if (arg ~= "on" and arg ~= "off") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug testdata on|off");
        else
            Debug.SetTestDataMode(arg == "on");
            Debug.Log("TEST", 1, "testdata: turned %s", arg);
        end
    elseif (word == "gen") then
        if (not requireTestData("gen")) then return; end
        local n, flag = string.match(arg, "^(%S*)%s*(%S*)$");
        FL.Sync.Store.GenerateTestRows(n, flag == "old");
    elseif (word == "keyitem") then
        if (not requireTestData("keyitem")) then return; end
        local sub, itemID = string.match(arg, "^(%S*)%s*(%S*)$");
        itemID = tonumber(itemID);
        if (sub ~= "add" or not itemID) then
            print("|cff8865ffForeverLoot|r Usage: /fl debug keyitem add <itemID>");
        else
            FL.Sync.Constants.KEY_ITEMS[itemID] = true;
            Debug.Log("TEST", 1, "keyitem: added item %d as a key item", itemID);
        end
    elseif (word == "purgetest") then
        FL.Sync.Store.PurgeTestRows();
    elseif (word == "wipehistory") then
        if (arg ~= "confirm") then
            print("|cff8865ffForeverLoot|r This permanently deletes ALL history (every row, tombstone and pin) on THIS client, with no undo. Type /fl debug wipehistory confirm to proceed.");
        else
            FL.Sync.Store.WipeHistory();
        end
    elseif (word == "droplocal") then
        if (not requireTestData("droplocal")) then return; end
        local n, real = string.match(arg, "^(%S*)%s*(%S*)$");
        FL.Sync.Store.DropLocal(n, real == "real");
    elseif (word == "probe") then
        FL.Sync.Probe.Start(arg);
    elseif (word == "forcedelete") then
        if (not requireTestData("forcedelete")) then return; end
        if (arg == "") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug forcedelete <id>");
        else
            FL.Sync.Live.ForceDelete(arg);
        end
    elseif (word == "guilddirect") then
        if (arg ~= "on" and arg ~= "off") then
            print(("|cff8865ffForeverLoot|r Usage: /fl debug guilddirect on|off (currently %s)"):format(
                FL.Sync.Transport.IsGuildDirect() and "on" or "off"));
        else
            FL.Sync.Transport.SetGuildDirect(arg == "on");
            print(("|cff8865ffForeverLoot|r GUILD sends now go %s."):format(
                (arg == "on") and "over the real GUILD channel (the default)" or "as whispers to each guild member, until /reload"));
            Debug.Log("TEST", 1, "guilddirect: turned %s", arg);
        end
    elseif (word == "forcehello") then
        -- Ignores timers/suppression - runs right now, through the same
        -- Peers.Discover/Coordinator plan path every other trigger uses
        -- (plan Phase 4).
        local scope = (arg:upper() == "RAID") and "RAID" or "GUILD";
        Debug.Log("TEST", 1, "forcehello: asking %s now", (scope == "RAID") and "the group (council)" or "the guild (history)");
        FL.Sync.Coordinator.ForceHello(scope);
    else
        print("|cff8865ffForeverLoot|r /fl debug commands (/fl debug alone opens the Debug Log window):");
        print("  on | off | level 1|2|3 | cat <CAT> on|off | log | clear");
        print("  testdata on|off | gen <n> [old] | purgetest | wipehistory confirm | droplocal <n> [real]");
        print("  forcedelete <id> | keyitem add <itemID> | forcehello [raid]");
        print("  (gen, droplocal, forcedelete and keyitem need testdata on)");
        print("  guilddirect on|off | probe <name|PARTY> <n> <perSec> [main|s1|s2|s3|rot] [prio] [bytes]");
    end
end

function Debug.Init()
    FL.DB.debug = FL.DB.debug or {};
    local d = FL.DB.debug;
    d.enabled = (d.enabled == true); -- default off
    d.level = d.level or 1;
    d.cats = d.cats or {}; -- [CATNAME] = false means muted; absent/true = active
    d.frame = nil; -- retired /fl debug frame setting
    d.log = d.log or {}; -- array of plain-text lines, capped at DEBUG_LOG_LINES
    d.testData = (d.testData == true); -- default off

    -- If debug was already on before this reload, Gate.Init() (which runs
    -- right after this in the PLAYER_LOGIN order) logs the login GATE line
    -- on its own - nothing more to do here.
end
