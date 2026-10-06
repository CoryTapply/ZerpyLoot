--[[
Logging and counters for the sync system, plus the /fl debug and
/fl sync status slash-command handlers (dispatched to from the existing /fl
handler in Debug.lua at the repo root - that file is the slash dispatcher,
this file is the logging engine; unrelated to that file's existing
/fl commdebug command, which toggles separate, older comm-traffic printing).

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
    local frameIndex = FL.DB.debug.frame or 1;
    local chatFrame = _G["ChatFrame" .. frameIndex] or DEFAULT_CHAT_FRAME;
    chatFrame:AddMessage(Debug.ColorizeLine(line));
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

local counters = {};
local loginTime;

function Debug.Count(key, n)
    counters[key] = (counters[key] or 0) + (n or 1);
end

--- Current value of a counter previously written with Debug.Count, or 0.
function Debug.GetCounter(key)
    return counters[key] or 0;
end

--- Wipes every counter (/fl sync stats reset, phase 2). `counters` is a
--- plain in-memory table, never persisted, so this is also what every
--- counter implicitly does on its own at the next /reload or login.
function Debug.ResetCounters()
    wipe(counters);
    loginTime = GetTime();
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

function Debug.SetFrame(n)
    n = tonumber(n);
    if (not n) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug frame <n>");
        return;
    end
    FL.DB.debug.frame = n;
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
--- (and spamhello) only run in test-data mode. Logs the plan's "refused"
--- line (debug log only).
local function requireTestData(cmd)
    if (Debug.IsTestDataMode()) then return true; end
    Debug.Log("TEST", 1, "%s: refused · needs /fl debug testdata on", cmd);
    return false;
end

function Debug.HandleLivetest()
    Debug.Log("TEST", 1, "livetest: queued on the award-updates gate");
    FL.Sync.Gate.QueueAwardUpdate(function()
        Debug.Log("TEST", 1, "livetest: ran");
    end, "livetest");
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
    elseif (word == "frame") then
        Debug.SetFrame(arg);
    elseif (word == "log" or word == "") then
        if (FL.UI.DebugLogWindow and FL.UI.DebugLogWindow.Show) then
            FL.UI.DebugLogWindow.Show();
        end
    elseif (word == "clear") then
        Debug.ClearLog();
    elseif (word == "gate") then
        if (arg ~= "auto" and arg ~= "open" and arg ~= "closed") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug gate auto|open|closed");
        else
            FL.Sync.Gate.SetOverride(arg);
            Debug.Log("TEST", 1, "gate: override set to %s", arg);
        end
    elseif (word == "livetest") then
        Debug.HandleLivetest();
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
    elseif (word == "prunedry") then
        FL.Sync.Retention.PruneDry();
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
    elseif (word == "roundtrip") then
        if (arg == "council") then
            FL.Sync.CouncilSessionDomain:Roundtrip();
        else
            FL.Sync.Codec.Roundtrip(arg);
        end
    elseif (word == "rawsend") then
        -- DIAGNOSTIC: calls C_ChatInfo.SendAddonMessage directly, bypassing
        -- AceComm/ChatThrottleLib, and prints the raw send result code per
        -- distribution. The receiving client logs "[COMM] rawsend diag
        -- received ..." (debug on) for each one that actually arrives -
        -- that's the delivery half of the test. CHANNEL (a hidden custom
        -- channel) is the candidate replacement for the GUILD relay this
        -- server doesn't do: both clients must run "rawsend CHANNEL" once to
        -- join it before a second run can test delivery.
        local which = arg:upper();
        local function try(dist, target)
            local ok, res = pcall(C_ChatInfo.SendAddonMessage, "FLoot", "diag", dist, target);
            print(("|cff8865ffForeverLoot|r rawsend %s: ok=%s result=%s"):format(dist, tostring(ok), tostring(res)));
        end
        if (which == "" or which == "GUILD") then try("GUILD"); end
        if (which == "" or which == "PARTY") then try("PARTY"); end
        if (which == "CHANNEL") then
            local channelName = "FLootSync";
            local id = GetChannelName(channelName);
            if (not id or id == 0) then
                JoinTemporaryChannel(channelName);
                print("|cff8865ffForeverLoot|r rawsend: joined channel " .. channelName .. " - run /fl debug rawsend CHANNEL on BOTH clients, then run it again to send.");
            else
                try("CHANNEL", id);
            end
        end
    elseif (word == "rawbytes") then
        -- DIAGNOSTIC: sends a fixed list of test strings, each a single
        -- raw addon message (no AceComm, no compression), to see whether
        -- this server drops or alters messages by CONTENT - "|" escape
        -- sequences, high bytes, control bytes. The receiving client (debug
        -- on) logs "[COMM] rawsend diag received ... text=..." for each one
        -- that arrives; a missing number was dropped, a changed text was
        -- altered.
        if (arg == "") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug rawbytes <name>");
        else
            local tests = {
                "plain", "a|b", "a||b", "a|Hitem:19019|h[x]|h", "a|Hzz", "a|cffff0000red|r", "a|Tx|t",
                "a|Kx|k", "a|nb", "a|", "a\128\200\255b", "a\r\nb", "a\001b\002c", "a\127b", "a%sb",
            };
            for i, text in ipairs(tests) do
                C_Timer.After((i - 1) * 0.5, function()
                    local ok, res = pcall(C_ChatInfo.SendAddonMessage, "FLoot", ("diag%d:%s"):format(i, text), "WHISPER", arg);
                    print(("|cff8865ffForeverLoot|r rawbytes #%d sent ok=%s result=%s"):format(i, tostring(ok), tostring(res)));
                end);
            end
        end
    elseif (word == "probe") then
        FL.Sync.Probe.Start(arg);
    elseif (word == "probestats") then
        FL.Sync.Probe.PrintStats();
    elseif (word == "forcedelete") then
        if (not requireTestData("forcedelete")) then return; end
        if (arg == "") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug forcedelete <id>");
        else
            FL.Sync.Live.ForceDelete(arg);
        end
    elseif (word == "maxserve") then
        if (not requireTestData("maxserve")) then return; end
        FL.Sync.Session.SetMaxServeOverride(arg);
    elseif (word == "spamhello") then
        if (not requireTestData("spamhello")) then return; end
        local n, target = string.match(arg, "^(%S*)%s*(%S*)$");
        FL.Sync.Peers.SpamHello(n, target);
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
        print("  on | off | level 1|2|3 | cat <CAT> on|off | frame <n>");
        print("  log | clear | gate auto|open|closed | livetest");
        print("  testdata on|off | gen <n> [old] | purgetest | wipehistory confirm | droplocal <n> [real]");
        print("  roundtrip [n|council] | forcedelete <id> | prunedry | keyitem add <itemID> | forcehello [raid] | maxserve <n> | spamhello <n> [name]");
        print("  (gen, droplocal, forcedelete, keyitem, maxserve and spamhello need testdata on)");
        print("  guilddirect on|off | rawbytes <name> | rawsend [GUILD|PARTY|CHANNEL] | probe <name|PARTY> <n> <perSec> [main|s1|s2|s3|rot] [prio] [bytes] | probestats");
    end
end

local function formatAgoShort(seconds)
    if (not seconds) then return "never"; end
    seconds = math.max(0, math.floor(seconds));
    if (seconds < 60) then return seconds .. "s ago"; end
    return math.floor(seconds / 60) .. "m ago";
end

--- This addon's memory use (plan Phase 8 build item 7), "1.9MB" / "850KB",
--- or "?" if the client lacks the API.
local function addonMemory()
    local update = UpdateAddOnMemoryUsage;
    local get = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage);
    if (not update or not get) then return "?"; end
    update();
    local kb = get(FL.name) or 0;
    if (kb >= 1024) then return ("%.1fMB"):format(kb / 1024); end
    return ("%dKB"):format(kb);
end

--- One word per domain for the status line: a snapshot domain's current
--- session (or "none"), a set domain's compare result against the most
--- recently heard peer that compared it.
local function domainStatusWord(domain)
    if (domain.strategy == "snapshot") then
        local summary = domain:Summary();
        if (not summary) then return "none"; end
        return ("session=%s rev=%s"):format(tostring(summary[1]), tostring(summary[3]));
    end
    for _, peer in ipairs(FL.Sync.Peers.All()) do
        local result = peer.compares[domain.id];
        if (result == "same") then return "same-as-last-peer"; end
        if (result == "incompatible") then return "incompatible-with-last-peer"; end
        if (result) then return result .. "-from-last-peer"; end
    end
    return "no-peer-yet";
end

local function bufferedWarnings()
    local n = 0;
    for _, line in ipairs(FL.DB.debug.log) do
        if (line:find("%] WARN ") or line:find("%] ERR ")) then n = n + 1; end
    end
    return n;
end

--- /fl sync status - the plan's Phase 8 final layout, then the extra
--- perm/comm/scheduler lines earlier phases added.
function Debug.PrintSyncStatus()
    local C = FL.Sync.Constants;
    local d = FL.DB.debug;
    local g = FL.Sync.Gate.Status();
    local s = FL.Sync.Scheduler.Status();
    local st = FL.Sync.Store.Status();
    local p = FL.Sync.Permissions.Status();
    local w, a = FL.Sync.Digest.Root("W"), FL.Sync.Digest.Root("A");

    local domainParts = {};
    for _, domain in ipairs(FL.Sync.Domains.All()) do
        table.insert(domainParts, ("%d %s %s"):format(domain.id, domain.name, domainStatusWord(domain)));
    end
    local out, inCount = FL.Sync.Session.Counts();

    print(("FL sync status  addon=%s proto=%d memory=%s"):format(FL.Sync.Peers.AddonVersion(), C.PROTO_VERSION, addonMemory()));
    print(("  gate: sync=%s awardUpdates=%s group=%s reason=%s%s"):format(
        g.sync, tostring(g.awardUpdates), tostring(g.group), g.reason, (g.override and g.override ~= "auto") and (" override=" .. g.override) or ""));
    print(("  store: rows=%d tombstones=%d pins=%d test=%d"):format(st.rows, st.tombstones, st.pins, st.test));
    print(("  digest: W n=%d x=%08X  A n=%d x=%08X  cutoff=%s"):format(
        w.count, w.x, a.count, a.x, date("!%Y-%m-%d", FL.Sync.Retention.Cutoff())));
    print("  domains: " .. table.concat(domainParts, " | "));
    print(("  peers: known=%d  last hello out %s  last match heard %s"):format(
        FL.Sync.Peers.KnownPeerCount(), formatAgoShort(FL.Sync.Peers.LastHelloOutAgo()),
        formatAgoShort(FL.Sync.Peers.LastMatchAgo("GUILD"))));
    print(("  sessions: out=%d in=%d"):format(out, inCount));
    print(("  debug: %s level=%d testdata=%s (warnings buffered: %d)"):format(
        d.enabled and "on" or "off", d.level, d.testData and "on" or "off", bufferedWarnings()));
    print(("  config: retention=%d pruneReal=%s schema=%d missingItemString=%d"):format(
        C.RETENTION_MONTHS, C.PRUNE_REAL and "yes" or "no", st.schema, st.missingItemString));
    print(("  perm: policy=%s me=%q rank=%s canDelete=%s"):format(
        p.policy, p.me, tostring(p.rank), p.canDelete and "yes" or "no"));
    print(("  comm: knownAddonUsers=%d  scheduler: timers=%d queue=%d"):format(
        FL.Sync.Transport.KnownUserCount(), s.timers, s.queue));
end

--- "2026-09" from a spec 5.3 month key (year*12+(month-1)) - the reverse of
--- parseMonthArg below. Shared by /fl sync digest months' own output and by
--- parseMonthArg's accepted input, so copy-pasting a line from one back into
--- the other's argument just works.
local function monthKeyToLabel(monthKey)
    return ("%04d-%02d"):format(math.floor(monthKey / 12), (monthKey % 12) + 1);
end

--- Accepts either a raw monthKey integer or a "YYYY-MM" label (what
--- `digest months` itself prints) for /fl sync digest days <monthKey>.
local function parseMonthArg(arg)
    local y, m = arg:match("^(%d+)%-(%d+)$");
    if (y) then return tonumber(y) * 12 + (tonumber(m) - 1); end
    return tonumber(arg);
end

--- /fl sync digest (plan Phase 3).
function Debug.PrintDigest()
    local cutoff = FL.Sync.Retention.Cutoff();
    local w, a = FL.Sync.Digest.Root("W"), FL.Sync.Digest.Root("A");
    print(("FL digest  cutoff=%s"):format(date("!%Y-%m-%d", cutoff)));
    print(("  W  n=%d  x=%08X  s=%08X"):format(w.count, w.x, w.s));
    print(("  A  n=%d  x=%08X  s=%08X"):format(a.count, a.x, a.s));
end

function Debug.PrintDigestMonths()
    local months = FL.Sync.Digest.Months("W");
    if (#months == 0) then
        print("|cff8865ffForeverLoot|r No window months.");
        return;
    end
    for _, m in ipairs(months) do
        print(("  %s n=%d x=%08X s=%08X"):format(monthKeyToLabel(m.monthKey), m.count, m.x, m.s));
    end
end

function Debug.PrintDigestDays(arg)
    local monthKey = parseMonthArg(strtrim(arg or ""));
    if (not monthKey) then
        print("|cff8865ffForeverLoot|r Usage: /fl sync digest days <monthKey>");
        return;
    end
    local days = FL.Sync.Digest.DaysInMonth(monthKey);
    if (#days == 0) then
        print(("|cff8865ffForeverLoot|r No window days for %s."):format(monthKeyToLabel(monthKey)));
        return;
    end
    for _, d in ipairs(days) do
        print(("  %s n=%d x=%08X s=%08X"):format(date("!%Y-%m-%d", d.dayKey * 86400), d.count, d.x, d.s));
    end
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds));
    if (seconds < 60) then return seconds .. "s"; end
    return math.floor(seconds / 60) .. "m";
end

-- Message types a /fl sync stats line reports on, in the order spec section
-- 6 lists the live broadcasts - the only ones with any traffic before
-- Phase 4's discovery/session messages exist.
local STATS_MSG_NAMES = { "LIVE_ROW", "LIVE_DEL", "LIVE_PIN" };

local function statsLine(direction)
    local parts = {};
    for _, name in ipairs(STATS_MSG_NAMES) do
        local msgs = Debug.GetCounter(("comm.%s.%s.msgs"):format(direction, name));
        local bytes = Debug.GetCounter(("comm.%s.%s.bytes"):format(direction, name));
        table.insert(parts, ("%s %d msg%s %s"):format(name, msgs, msgs == 1 and "" or "s", Debug.FormatBytes(bytes)));
    end
    return table.concat(parts, " | ");
end

--- /fl sync stats (phase 2).
function Debug.PrintSyncStats()
    print(("FL sync stats (since login %s)"):format(formatDuration(GetTime() - (loginTime or GetTime()))));
    print("  sent:  " .. statsLine("sent"));
    print("  recv:  " .. statsLine("recv"));
    print(("  apply: added=%d dup=%d tombstoned=%d expired=%d invalid=%d rejected=%d"):format(
        Debug.GetCounter("store.apply.added"), Debug.GetCounter("store.apply.dup"),
        Debug.GetCounter("store.apply.tombstoned"), Debug.GetCounter("store.apply.expired"),
        Debug.GetCounter("store.apply.invalid"), Debug.GetCounter("store.apply.rejected")));
    print(("  codec: decodeFail=%d rowRejects=%d rawIds=%d"):format(
        Debug.GetCounter("codec.decodeFail"), Debug.GetCounter("codec.rowRejects"), Debug.GetCounter("codec.rawIds")));
end

--- /fl sync domains (plan Phase 4). A domain's own DebugLine() method, when
--- present, supplies the row's domain-specific suffix (spec 7.7's "Adding
--- another domain" step 5) - Data/HistoryDomain.lua implements one; a later
--- domain (e.g. Phase 7's council session) adds its own without this
--- function changing.
function Debug.PrintDomains()
    local domains = FL.Sync.Domains.All();
    if (#domains == 0) then
        print("|cff8865ffForeverLoot|r No domains registered.");
        return;
    end
    print("FL domains");
    for _, domain in ipairs(domains) do
        local extra = (domain.DebugLine and domain:DebugLine()) or "";
        print(("  %d %-14s %-9s %-6s gate=%-8s %s"):format(
            domain.id, domain.name, domain.strategy, domain.scope, domain.gate, extra));
    end
end

--- /fl sync peers (plan Phase 4). Shows every compared domain for each known
--- peer; a diverged history-domain comparison also shows the peer's window
--- count, matching the plan's own sample line.
function Debug.PrintPeers()
    local peerList = FL.Sync.Peers.All();
    print(("FL peers (known=%d, memory %dm)"):format(FL.Sync.Peers.KnownPeerCount(), FL.Sync.Constants.PEER_MEMORY / 60));
    if (#peerList == 0) then
        print("  (none heard from yet)");
        return;
    end

    for _, p in ipairs(peerList) do
        local parts = {};
        for domainId, result in pairs(p.compares) do
            local label = ("d%d=%s"):format(domainId, result);
            local summary = p.summaries[domainId];
            if (result == "diverged" and domainId == FL.Sync.Constants.DOMAIN_HISTORY and summary) then
                label = label .. (" W n=%d"):format(summary[1] or 0);
            end
            table.insert(parts, label);
        end
        print(("  %q heard %s ago  %s  ver=%s"):format(p.name, formatDuration(p.ago), table.concat(parts, "  "), tostring(p.version or "?")));
    end
end

--- /fl sync sessions (plan Phase 5).
function Debug.PrintSessions()
    local out, inCount = FL.Sync.Session.Counts();
    print(("FL sessions (out=%d in=%d, serving max %d)"):format(out, inCount, FL.Sync.Session.MaxServe()));
    local sessionList = FL.Sync.Session.All();
    if (#sessionList == 0) then
        print("  (none)");
        return;
    end
    for _, s in ipairs(sessionList) do
        print(("  %s d%d %s/%s peer=%q %s buckets %d/%d sent=%d recv=%d %s"):format(
            s.token, s.domainId, s.role, s.mode or "full", s.peer, s.state, s.bucketsDone, s.bucketsTotal, s.sent, s.recv, formatDuration(s.elapsed)));
    end
end

--- Backs /fl sync ... (status, dump <id>, stats) - split from HandleSlash
--- (/fl debug ...) since it's dispatched from a separate "sync" verb in the
--- root /fl handler.
function Debug.HandleSyncSlash(rest)
    rest = strtrim(rest or "");
    local word, arg = string.match(rest, "^(%S*)%s*(.-)$");
    word = word or "";

    if (word == "status" or word == "") then
        Debug.PrintSyncStatus();
    elseif (word == "dump") then
        FL.Sync.Store.Dump(arg);
    elseif (word == "stats") then
        if (arg == "reset") then
            Debug.ResetCounters();
            print("|cff8865ffForeverLoot|r sync stats reset.");
        else
            Debug.PrintSyncStats();
        end
    elseif (word == "digest") then
        local sub, subarg = string.match(arg, "^(%S*)%s*(.-)$");
        if (sub == "" or sub == nil) then
            Debug.PrintDigest();
        elseif (sub == "months") then
            Debug.PrintDigestMonths();
        elseif (sub == "days") then
            Debug.PrintDigestDays(subarg);
        else
            print("|cff8865ffForeverLoot|r Usage: /fl sync digest [months|days <monthKey>]");
        end
    elseif (word == "domains") then
        Debug.PrintDomains();
    elseif (word == "peers") then
        Debug.PrintPeers();
    elseif (word == "sessions") then
        Debug.PrintSessions();
    elseif (word == "window") then
        if (FL.UI.SyncStatusWindow and FL.UI.SyncStatusWindow.Toggle) then
            FL.UI.SyncStatusWindow.Toggle();
        end
    else
        print("|cff8865ffForeverLoot|r /fl sync commands:");
        print("  status | dump <id> | stats | stats reset | digest [months|days <monthKey>]");
        print("  domains | peers | sessions | window");
    end
end

function Debug.Init()
    FL.DB.debug = FL.DB.debug or {};
    local d = FL.DB.debug;
    d.enabled = (d.enabled == true); -- default off
    d.level = d.level or 1;
    d.cats = d.cats or {}; -- [CATNAME] = false means muted; absent/true = active
    d.frame = d.frame or 1;
    d.log = d.log or {}; -- array of plain-text lines, capped at DEBUG_LOG_LINES
    d.testData = (d.testData == true); -- default off

    loginTime = GetTime(); -- counters themselves are never persisted, so this always starts fresh too

    -- If debug was already on before this reload, Gate.Init() (which runs
    -- right after this in the PLAYER_LOGIN order) logs the login GATE line
    -- on its own - nothing more to do here.
end
