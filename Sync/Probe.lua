--[[
Addon-message loss/latency probe (/fl debug probe).
Debug-only: nothing here sends anything unless a tester types the command.

Why it exists (docs/sync-deviations.md "Phase 6 review"): live testing kept
hitting messages that were "confirmed sent, never delivered" or arrived many
seconds late, and the only evidence was scattered session logs, where our
own queueing (Net/Transport.lua's per-target queue, ChatThrottleLib's single
FIFO per prefix) and the server's behaviour can't be told apart. The probe
sends n sequence-numbered messages at a fixed rate, bypassing Transport's own
queue and pacing (`noQueue`), so what it measures is AceComm/CTL plus the
server:

- The receiver tallies what it got (one-way loss, out-of-order) and echoes
  each probe straight back.
- The sender times each echo (round trip) and counts the ones missing.

Comparing runs at different rates, sizes, prefixes and distributions shows
whether loss depends on the rate (a hidden server throttle - fixable on our
side by pacing below it) or stays flat (a baseline loss rate - a question
for the server operator, now with numbers).
]]

local FL = ForeverLoot;
local Probe = FL.Sync.Probe;
local Util = FL.Util;
local Constants = FL.Sync.Constants;
local MSG = Constants.MSG;

local REPORT_GRACE = 15; -- seconds after the last send before the sender prints its report

local outRuns = {}; -- [runId] = sender-side run
local inRuns = {};  -- [sender .. ":" .. runId] = receiver-side tally

local function say(fmt, ...)
    if (FL.Sync.Debug.IsOn("TEST", 1)) then
        FL.Sync.Debug.Log("TEST", 1, fmt, ...);
    else
        print("|cff8865ffForeverLoot|r " .. fmt:format(...));
    end
end

local ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
local function randomString(len)
    local out = {};
    for i = 1, len do
        local idx = math.random(#ID_CHARS);
        out[i] = ID_CHARS:sub(idx, idx);
    end
    return table.concat(out);
end

local function prefixFor(arg, seq)
    arg = (arg or "main"):lower();
    if (arg == "main") then return Constants.PREFIX_MAIN; end
    if (arg == "rot") then return Constants.PREFIX_SYNC[((seq - 1) % #Constants.PREFIX_SYNC) + 1]; end
    local i = tonumber(arg:match("^s(%d)$"));
    return (i and Constants.PREFIX_SYNC[i]) or Constants.PREFIX_MAIN;
end

local function reportOut(run)
    local echoed, sum, minR, maxR = 0, 0, nil, nil;
    for _, rtt in pairs(run.rtt) do
        echoed = echoed + 1;
        sum = sum + rtt;
        minR = (minR and math.min(minR, rtt)) or rtt;
        maxR = (maxR and math.max(maxR, rtt)) or rtt;
    end
    local loss = (run.n > 0) and (100 * (run.n - echoed) / run.n) or 0;
    local fmt = FL.Sync.Debug.FormatTime;
    say("probe #%s to %s: %d of %d echoed back (%.0f%% lost) · round trip %s, %d send failures, %s %s, %dB each, prefix %s, %s priority",
        run.id, run.target or run.dist:lower(), echoed, run.n, loss,
        echoed > 0 and ("min %s / avg %s / max %s"):format(fmt(minR), fmt(sum / echoed), fmt(maxR)) or "none",
        run.sendFail, run.perSec > 0 and (("%.1f/s"):format(run.perSec)) or "burst", "via " .. run.dist:lower(),
        run.enc or 0, run.prefixArg, run.prio:lower());
end

local function reportIn(t)
    local got = Util.tcount(t.got);
    local loss = (t.n > 0) and (100 * (t.n - got) / t.n) or 0;
    say("probe #%s from %s: got %d of %d (%.0f%% lost) · %d out of order, arrived over %s, via %s",
        t.runId, t.sender, got, t.n, loss, t.outOfOrder, FL.Sync.Debug.FormatTime((t.lastAt or 0) - (t.firstAt or 0)),
        tostring(t.dist):lower());
end

--- /fl debug probe <name|PARTY|RAID|GUILD> <n> <perSec> [main|s1|s2|s3|rot] [ALERT|NORMAL|BULK] [bytes]
--- perSec 0 = send all n at once (burst).
function Probe.Start(arg)
    -- Names on this server can contain spaces ("Nelly Knifesplice") but
    -- never digits, so the name is every word before the first number.
    local words = {};
    for w in string.gmatch(arg or "", "%S+") do table.insert(words, w); end
    local nameParts, i = {}, 1;
    while (words[i] and not words[i]:match("^%d")) do table.insert(nameParts, words[i]); i = i + 1; end
    local target = (#nameParts > 0) and table.concat(nameParts, " ") or nil;
    local n, perSec = tonumber(words[i]), tonumber(words[i + 1]);
    local prefixArg, prio, bytes = words[i + 2] or "", words[i + 3] or "", tonumber(words[i + 4]);
    if (not target or not n or not perSec) then
        print("|cff8865ffForeverLoot|r Usage: /fl debug probe <name|PARTY|RAID|GUILD> <n> <perSec> [main|s1|s2|s3|rot] [ALERT|NORMAL|BULK] [bytes]");
        return;
    end

    local dist = "WHISPER";
    local upper = target:upper();
    if (upper == "PARTY" or upper == "RAID" or upper == "GUILD") then dist, target = upper, nil; end
    prio = (prio ~= "" and prio:upper()) or "NORMAL";
    bytes = bytes or 20;

    local run = {
        id = randomString(4), target = target, dist = dist, n = n, perSec = perSec,
        prefixArg = (prefixArg ~= "" and prefixArg) or "main", prio = prio, bytes = bytes,
        sentAt = {}, rtt = {}, sendFail = 0,
    };
    outRuns[run.id] = run;
    local pad = randomString(bytes); -- random letters, so compression can't shrink the size we asked for

    say("probe #%s: sending %d to %s · %s, %dB each, prefix %s, %s priority",
        run.id, n, target or dist:lower(), perSec > 0 and (("%.1f/s"):format(perSec)) or "all at once", bytes, run.prefixArg, prio:lower());

    -- Raw C_Timer, not Scheduler.After: every Scheduler timer writes a
    -- "[SCHED] timer fire" line, which would flood the log buffer here.
    for seq = 1, n do
        local delay = (perSec > 0) and ((seq - 1) / perSec) or 0;
        C_Timer.After(delay, function()
            run.sentAt[seq] = GetTime();
            local encoded = FL.Sync.Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.PROBE, run.id, seq, n, pad });
            run.enc = #encoded;
            FL.Sync.Transport.Send(MSG.PROBE, encoded, dist, target, {
                prio = prio, prefix = prefixFor(run.prefixArg, seq), noQueue = true,
                onFail = function() run.sendFail = run.sendFail + 1; end,
            });
        end);
    end

    -- Report REPORT_GRACE after the last send AND after the last echo (each
    -- echo pushes it back): a fixed delay printed "echoLoss=45%" for a burst
    -- whose echoes were simply still arriving - delivery of 40 x 500B took
    -- ~27s at ChatThrottleLib's rate.
    run.reportGen = 0;
    run.armReport = function(delay)
        run.reportGen = run.reportGen + 1;
        local gen = run.reportGen;
        C_Timer.After(delay, function() if (run.reportGen == gen) then reportOut(run); end end);
    end;
    local lastDelay = (perSec > 0) and ((n - 1) / perSec) or 0;
    run.armReport(lastDelay + REPORT_GRACE);
end

local function onProbe(body, senderName, distribution)
    local runId, seq, n = body[3], body[4], body[5];
    if (type(runId) ~= "string" or type(seq) ~= "number") then return; end
    local sender = Util.stripRealm(senderName);
    local key = sender .. ":" .. runId;

    local t = inRuns[key];
    if (not t) then
        t = { runId = runId, sender = sender, dist = distribution, n = n or 0, got = {}, maxSeq = 0, outOfOrder = 0, firstAt = GetTime(), reportGen = 0 };
        inRuns[key] = t;
    end
    -- One summary per run, REPORT_GRACE after the LAST probe arrived (each
    -- arrival pushes it back) - reporting a fixed time after the first one
    -- printed a partial count while a slow run was still going.
    t.reportGen = t.reportGen + 1;
    local gen = t.reportGen;
    C_Timer.After(REPORT_GRACE, function() if (t.reportGen == gen) then reportIn(t); end end);
    if (seq < t.maxSeq) then t.outOfOrder = t.outOfOrder + 1; end
    t.maxSeq = math.max(t.maxSeq, seq);
    t.got[seq] = true;
    t.lastAt = GetTime();

    local encoded = FL.Sync.Codec.EncodeMessage({ Constants.PROTO_VERSION, MSG.PROBE_ECHO, runId, seq });
    FL.Sync.Transport.Send(MSG.PROBE_ECHO, encoded, "WHISPER", sender, { prio = "NORMAL", noQueue = true });
end

local function onEcho(body)
    local run = outRuns[body[3]];
    local seq = body[4];
    if (not run or not run.sentAt[seq] or run.rtt[seq]) then return; end
    run.rtt[seq] = GetTime() - run.sentAt[seq];
    run.armReport(REPORT_GRACE);
end

function Probe.Init()
    FL.Sync.Transport.Register(MSG.PROBE, onProbe);
    FL.Sync.Transport.Register(MSG.PROBE_ECHO, onEcho);
end
