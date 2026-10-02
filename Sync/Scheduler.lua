--[[
Timers and a per-frame work queue, shared by every sync module so timing and
CPU-budget decisions live in one place (docs/ForeverLoot History Sync — Spec.md
section 12.2).

After/Every/Cancel wrap the same C_Timer primitives already used elsewhere in
this addon (C_Timer.NewTimer + :Cancel(), e.g. RollTracker.lua's
stopTimerHandle / Trade.lua's timeoutTimer) - NewTicker is new to this
codebase but is the correct cancellable-repeating primitive. Enqueue/the
OnUpdate work queue is genuinely new infrastructure: no OnUpdate-driven queue
exists anywhere else in the addon today.

Nothing in Phase 0 calls Enqueue or Every yet - no later-phase consumer
exists. Debug.lua and Gate.lua deliberately use raw C_Timer internally rather
than this module, so the three foundational modules don't depend on each
other's Init() order.
]]

local FL = ForeverLoot;
local Scheduler = FL.Sync.Scheduler;

local handles = {}; -- [handle] = true; one-shots remove themselves just before firing
local queue = {};   -- FIFO of { fn, name }
local workFrame;

local function jitteredDelay(sec, jitter)
    jitter = jitter or 0;
    return sec + (math.random() * 2 - 1) * jitter;
end

-- Fires fn once after sec seconds (± jitter). Returns a handle usable with
-- Scheduler.Cancel.
function Scheduler.After(sec, jitter, fn, name)
    local delay = jitteredDelay(sec, jitter);
    local scheduledAt = GetTime() + delay;
    local h;
    h = C_Timer.NewTimer(delay, function()
        handles[h] = nil;
        local late = math.max(0, (GetTime() - scheduledAt) * 1000);
        FL.Sync.Debug.Log("SCHED", 2, "timer fire name=%s late=%dms", name or "?", late);
        fn();
    end);
    handles[h] = true;
    return h;
end

-- Fires fn every sec seconds (± jitter, fixed once at creation). Returns a
-- handle usable with Scheduler.Cancel.
function Scheduler.Every(sec, jitter, fn, name)
    local delay = jitteredDelay(sec, jitter);
    local h;
    h = C_Timer.NewTicker(delay, function()
        FL.Sync.Debug.Log("SCHED", 2, "timer fire name=%s late=0ms", name or "?");
        fn();
    end);
    handles[h] = true;
    return h;
end

function Scheduler.Cancel(h)
    if (not h) then return; end
    h:Cancel();
    handles[h] = nil;
end

-- Queues fn to run on a later frame, inside the per-frame time budget. Used
-- for work too large to do in one frame (batch decode, pruning slices, ...).
function Scheduler.Enqueue(fn, name)
    table.insert(queue, { fn = fn, name = name });
    if (#queue > 10) then
        FL.Sync.Debug.Log("SCHED", 2, "queue depth=%d", #queue);
    end
end

function Scheduler.Status()
    local count = 0;
    for _ in pairs(handles) do count = count + 1; end
    return { timers = count, queue = #queue };
end

function Scheduler.Init()
    workFrame = CreateFrame("Frame");
    workFrame:SetScript("OnUpdate", function()
        if (#queue == 0) then return; end

        local budget = FL.Sync.Constants.FRAME_BUDGET_MS;
        local frameStart = debugprofilestop();

        while (#queue > 0 and (debugprofilestop() - frameStart) < budget) do
            local task = table.remove(queue, 1);
            local taskStart = debugprofilestop();
            local ok, err = pcall(task.fn);
            local used = debugprofilestop() - taskStart;

            if (used > budget) then
                FL.Sync.Debug.Warn("PERF", "overrun task=%s used=%.1fms budget=%dms", task.name or "?", used, budget);
            end
            if (not ok) then
                FL.Sync.Debug.Warn("SCHED", "task error name=%s err=%s", task.name or "?", tostring(err));
            end
        end
    end);
end
