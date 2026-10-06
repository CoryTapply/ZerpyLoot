--[[
Numbers for the Sync settings page (UI/SettingsWindow/Pages/Sync.lua) that
no sync module keeps on its own: smoothed per-session row rates, a short log of
recent sessions (kept across logins in FL.DB.syncLog), outcome counts for
this login, and a summary of the local history.

Nothing here affects the protocol. The only write back into sync state is
Peers.MarkMatched after a session ends with matching digests, which is
display-only too.

Rates are sampled by the settings page itself (Stats.Sample, once a second
while the page is visible) rather than by a timer here, so nothing runs
while nobody is looking. A transfer shows no rate until rows have been
moving for a few seconds while the page is open.
]]

local FL = ForeverLoot;
local Stats = FL.Sync.Stats;

local LOG_MAX = 20;          -- sessions kept in FL.DB.syncLog
local RATE_WINDOW = 30;      -- seconds a transfer's rate is averaged over
local RATE_MIN_SECONDS = 5;  -- rows must have moved this long before a rate is shown
local HISTORY_CACHE_SECONDS = 5;

-- This login's session outcomes - see outcomeOf.
local counts = { done = 0, timeout = 0, stopped = 0, refused = 0, failed = 0 };
local lastSuccess; -- newest "done" log record this login (also seeded from the saved log at Init)

-- [token] = { last = sample, list = samples in the window, oldest first } - see Stats.Sample.
local sessionSamples = {};

--------------------------------------------------------------------------
-- Session log
--------------------------------------------------------------------------

--- "done" | "timeout" | "stopped" | "refused" | "failed", or nil for an
--- ending not worth showing (a duplicate session dropped in favour of the
--- peer's own - the surviving one is logged instead).
local function outcomeOf(session)
    local reason = session.endReason;
    if (reason == nil) then return "done"; end
    if (reason == "dup") then return nil; end
    if (reason == "timeout") then return "timeout"; end
    if (reason == "gate") then return "stopped"; end
    if (reason == "busy" or reason == "refused") then return "refused"; end
    return "failed";
end

--- true/false from the exact final-roots comparison, nil when there wasn't one.
local function finalMatch(session)
    if (not session.rootsExact) then return nil; end
    return session.rootsMatch == true;
end

local function onSessionEnded(session)
    local outcome = outcomeOf(session);
    if (not outcome) then return; end
    counts[outcome] = counts[outcome] + 1;

    local record = {
        at = time(),
        peer = session.peer,
        role = session.role,
        mode = session.mode,
        helper = session.parent ~= nil,
        sent = session.sent or 0,
        recv = session.recv or 0,
        added = session.recvAdded or 0,
        marksAdded = session.marksAdded or 0,
        marksSent = session.marksSent or 0,
        dur = math.floor(GetTime() - session.startedAt + 0.5),
        outcome = outcome,
        reason = session.endReason,
        -- Only an exact final-roots comparison counts; the loose fallback
        -- reads "no" whenever rows flowed both ways.
        match = finalMatch(session),
    };

    FL.DB.syncLog = FL.DB.syncLog or {};
    table.insert(FL.DB.syncLog, 1, record);
    while (#FL.DB.syncLog > LOG_MAX) do table.remove(FL.DB.syncLog); end

    if (outcome == "done") then
        lastSuccess = record;
        -- A helper (pull) session only covers part of the history, so its
        -- digests matching proves nothing about the whole.
        if (finalMatch(session) == true and not session.parent) then
            FL.Sync.Peers.MarkMatched(session.peer, session.domainId);
        end
    end
    sessionSamples[session.token] = nil;
end

--- Newest first; the same tables kept in SavedVariables, so read-only.
function Stats.RecentSessions()
    return (FL.DB and FL.DB.syncLog) or {};
end

function Stats.Counts()
    return counts;
end

--- The newest completed session (this login, or the saved log's newest
--- "done" entry from an earlier one), or nil.
function Stats.LastSuccess()
    return lastSuccess;
end

--------------------------------------------------------------------------
-- Rates
--------------------------------------------------------------------------

-- Per-session rates average over the last RATE_WINDOW seconds. Rows
-- arrive in batches seconds apart, so a short window swings between a
-- whole batch and nothing; 30s spans several batches and still follows a
-- real speed change within half a minute. Samples start at the first
-- movement rather than the session's start, so the compare phase (no rows
-- yet) doesn't drag the rate down.

--- Takes one sample of every open session's row counters. Call about once
--- a second.
function Stats.Sample()
    local now = GetTime();

    local live = {};
    for _, s in ipairs(FL.Sync.Session.All()) do
        live[s.token] = true;
        local entry = sessionSamples[s.token];
        if (not entry) then
            entry = { last = { t = now, recv = s.recv, sent = s.sent } };
            sessionSamples[s.token] = entry;
        end
        local sample = { t = now, recv = s.recv, sent = s.sent };
        if (not entry.list and (s.recv ~= entry.last.recv or s.sent ~= entry.last.sent)) then
            entry.list = { entry.last }; -- the sample just before rows started moving
        end
        if (entry.list) then
            table.insert(entry.list, sample);
            -- Drop a sample once the next one is also a full window old, so
            -- the oldest kept is always the one at (or just before) the
            -- window's start.
            while (#entry.list > 2 and now - entry.list[2].t >= RATE_WINDOW) do
                table.remove(entry.list, 1);
            end
        end
        entry.last = sample;
    end
    for token in pairs(sessionSamples) do
        if (not live[token]) then sessionSamples[token] = nil; end
    end
end

--- One session's rows/sec in and out over the last RATE_WINDOW seconds, or
--- nil until rows have moved for at least RATE_MIN_SECONDS.
function Stats.SessionRates(token)
    local entry = sessionSamples[token];
    local list = entry and entry.list;
    if (not list or #list < 2) then return nil; end
    local first, last = list[1], list[#list];
    local dt = last.t - first.t;
    if (dt < RATE_MIN_SECONDS) then return nil; end
    return (last.recv - first.recv) / dt, (last.sent - first.sent) / dt;
end

--------------------------------------------------------------------------
-- Local history summary
--------------------------------------------------------------------------

local historyCache, historyCachedAt;

--- { rows, pinned, deleted }, recomputed at most every
--- HISTORY_CACHE_SECONDS (it walks the whole history).
function Stats.LocalHistory()
    local now = GetTime();
    if (historyCache and now - historyCachedAt < HISTORY_CACHE_SECONDS) then return historyCache; end

    local pins = (FL.DB.lootCouncil and FL.DB.lootCouncil.pins) or {};
    local rows, pinned = 0, 0;
    for _, row in ipairs(FL.LootCouncil.History or {}) do
        rows = rows + 1;
        if (pins[row.id]) then pinned = pinned + 1; end
    end
    local tombstones = (FL.DB.lootCouncil and FL.DB.lootCouncil.tombstones) or {};

    historyCache = { rows = rows, pinned = pinned, deleted = FL.Util.tcount(tombstones) };
    historyCachedAt = now;
    return historyCache;
end

function Stats.Init()
    for _, record in ipairs(Stats.RecentSessions()) do
        if (record.outcome == "done") then
            lastSuccess = record;
            break;
        end
    end
    FL.Sync.Session.OnEnded(onSessionEnded);
end
