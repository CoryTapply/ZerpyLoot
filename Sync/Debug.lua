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

local function timestamp()
    -- WoW's date() has no sub-second resolution; GetTime() is a float
    -- seconds-since-login with sub-second precision but isn't wall-clock
    -- aligned. Combining them is at most a few ms off true wall-clock
    -- milliseconds, which is fine for a debug tool.
    local ms = math.floor((GetTime() % 1) * 1000);
    return ("%s.%03d"):format(date("%H:%M:%S"), ms);
end

local function formatLine(catLabel, text, count)
    local suffix = (count > 1) and (" (x%d)"):format(count) or "";
    return ("FL %s [%s] %s%s"):format(timestamp(), catLabel, text, suffix);
end

local function appendToBuffer(line)
    local log = FL.DB.debug.log;
    table.insert(log, line);
    while (#log > FL.Sync.Constants.DEBUG_LOG_LINES) do
        table.remove(log, 1);
    end
end

local function printToChat(line)
    local frameIndex = FL.DB.debug.frame or 1;
    local chatFrame = _G["ChatFrame" .. frameIndex] or DEFAULT_CHAT_FRAME;
    chatFrame:AddMessage("|cff8865ffFL|r " .. line:sub(4)); -- color just the leading "FL" tag
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
        if (log[pending.bufferIndex]) then log[pending.bufferIndex] = line; end
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

function Debug.SetEnabled(enabled)
    FL.DB.debug.enabled = enabled and true or false;
    if (FL.DB.debug.enabled and FL.Sync.Gate and FL.Sync.Gate.LogCurrentState) then
        FL.Sync.Gate.LogCurrentState();
    end
end

function Debug.SetLevel(n)
    n = tonumber(n);
    if (not n or n < 1 or n > 3) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug level 1|2|3");
        return;
    end
    FL.DB.debug.level = n;
end

function Debug.SetCategory(catName, state)
    catName = (catName or ""):upper();
    if (catName == "") then
        print("|cff8865ffForeverLoot|r Usage: /fl debug cat <CAT> on|off");
        return;
    end
    FL.DB.debug.cats[catName] = (state ~= "off");
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
end

--- Whether this client accepts/generates zztest- rows (Data/Store.lua's
--- applyRow guard, and the gen/purgetest/droplocal commands below).
function Debug.IsTestDataMode()
    return FL.DB.debug.testData == true;
end

function Debug.SetTestDataMode(enabled)
    FL.DB.debug.testData = enabled and true or false;
end

function Debug.HandleLivetest()
    Debug.Log("TEST", 1, "livetest queued");
    FL.Sync.Gate.QueueLive(function()
        Debug.Log("TEST", 1, "livetest fired");
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
    elseif (word == "log") then
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
            Debug.Log("TEST", 1, "gate override=%s", arg);
        end
    elseif (word == "livetest") then
        Debug.HandleLivetest();
    elseif (word == "testdata") then
        if (arg ~= "on" and arg ~= "off") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug testdata on|off");
        else
            Debug.SetTestDataMode(arg == "on");
            Debug.Log("TEST", 1, "testdata %s", arg);
        end
    elseif (word == "gen") then
        local n, flag = string.match(arg, "^(%S*)%s*(%S*)$");
        FL.Sync.Store.GenerateTestRows(n, flag == "old");
    elseif (word == "prunedry") then
        FL.Sync.Retention.PruneDry();
    elseif (word == "keyitem") then
        local sub, itemID = string.match(arg, "^(%S*)%s*(%S*)$");
        itemID = tonumber(itemID);
        if (sub ~= "add" or not itemID) then
            print("|cff8865ffForeverLoot|r Usage: /fl debug keyitem add <itemID>");
        else
            FL.Sync.Constants.KEY_ITEMS[itemID] = true;
            Debug.Log("TEST", 1, "keyitem add itemID=%d", itemID);
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
        local n, real = string.match(arg, "^(%S*)%s*(%S*)$");
        FL.Sync.Store.DropLocal(n, real == "real");
    elseif (word == "roundtrip") then
        FL.Sync.Codec.Roundtrip(arg);
    elseif (word == "rawsend") then
        -- TEMPORARY DIAGNOSTIC (remove once resolved): calls
        -- C_ChatInfo.SendAddonMessage directly, bypassing AceComm/
        -- ChatThrottleLib's onSent callback entirely (which - see
        -- Net/Transport.lua's investigation - mismatches this bundled CTL's
        -- actual callback argument order and always reports success
        -- regardless of the real result). Prints the RAW return value(s)
        -- for "GUILD" and "PARTY" so we can see the true send result codes.
        local okGuild, resGuild = pcall(C_ChatInfo.SendAddonMessage, "FLoot", "diag", "GUILD");
        print(("|cff8865ffForeverLoot|r rawsend GUILD: ok=%s result=%s"):format(tostring(okGuild), tostring(resGuild)));
        local okParty, resParty = pcall(C_ChatInfo.SendAddonMessage, "FLoot", "diag", "PARTY");
        print(("|cff8865ffForeverLoot|r rawsend PARTY: ok=%s result=%s"):format(tostring(okParty), tostring(resParty)));
    elseif (word == "forcedelete") then
        if (arg == "") then
            print("|cff8865ffForeverLoot|r Usage: /fl debug forcedelete <id>");
        else
            FL.Sync.Live.ForceDelete(arg);
        end
    elseif (word == "maxserve") then
        FL.Sync.Session.SetMaxServeOverride(arg);
    elseif (word == "forcehello") then
        -- Ignores timers/suppression - runs right now, through the same
        -- Peers.Discover/Coordinator plan path every other trigger uses
        -- (plan Phase 4).
        Debug.Log("TEST", 1, "forcehello");
        FL.Sync.Coordinator.ForceHello();
    else
        print("|cff8865ffForeverLoot|r /fl debug commands:");
        print("  on | off | level 1|2|3 | cat <CAT> on|off | frame <n>");
        print("  log | clear | gate auto|open|closed | livetest");
        print("  testdata on|off | gen <n> [old] | purgetest | wipehistory confirm | droplocal <n> [real]");
        print("  roundtrip [n] | forcedelete <id> | prunedry | keyitem add <itemID> | forcehello | maxserve <n>");
    end
end

function Debug.PrintSyncStatus()
    local C = FL.Sync.Constants;
    local d = FL.DB.debug;
    local g = FL.Sync.Gate.Status();
    local s = FL.Sync.Scheduler.Status();
    local st = FL.Sync.Store.Status();
    local p = FL.Sync.Permissions.Status();

    print("FL sync status");
    print(("  proto=%d retention=%d debug=%s level=%d"):format(
        C.PROTO_VERSION, C.RETENTION_MONTHS, d.enabled and "on" or "off", d.level));
    print(("  gate: sync=%s live=%s reason=%s override=%s"):format(
        g.sync, g.live, g.reason, g.override));
    print(("  scheduler: timers=%d queue=%d"):format(s.timers, s.queue));
    print(("  store: schema=%d rows=%d tombstones=%d pins=%d test=%d missingItemString=%d"):format(
        st.schema, st.rows, st.tombstones, st.pins, st.test, st.missingItemString));
    print(("  perm: policy=%s me=%q rank=%s canDelete=%s"):format(
        p.policy, p.me, tostring(p.rank), p.canDelete and "yes" or "no"));
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
