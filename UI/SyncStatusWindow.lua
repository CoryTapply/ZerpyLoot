--[[
/fl sync window - a movable, auto-refreshing window showing live history-
sync progress: known peers and whether they match, every active session
(who's syncing with whom, what state, how many buckets/rows), lifetime
per-peer row totals for this login, and a feed of recent retries/warnings/
failures pulled from the same debug-log buffer /fl debug log already
exposes - built so a tester can watch a sync happen without reading raw
chat output line by line.

Built on UI/DebugLogWindow.lua's exact chrome (title bar + single
scrollable read-only EditBox) rather than a bespoke multi-column grid
widget - the content is rebuilt as plain formatted text every refresh tick
and dropped into the same EditBox, which keeps this file simple and reuses
already-proven window code instead of hand-rolling column-aligned frames
that can't be visually tested before shipping. Every container frame below
gets an explicit SetSize/SetHeight call for the same reason DebugLogWindow
does: a container Frame left at its default zero height renders no
children on this client even with nothing clipping it.
]]

local FL = ForeverLoot;
local SyncStatusWindow = FL.UI.SyncStatusWindow;
local Theme = FL.Theme;
local Pixel = FL.Pixel;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes.syncStatus;
local SharedLayout = FL.UI.Sizes.layout;
local SetFont = FL.UI.SetFont;
local Skin = FL.UI.Skin;

local WINDOW_WIDTH = Sizes.window.width;
local WINDOW_HEIGHT = Sizes.window.height;
local POSITION_KEY = "syncStatusWindow";
local REFRESH_INTERVAL = 1; -- seconds; only actually does anything while the window is shown

local frame, editBox, scrollFrame;
local tickerStarted = false;

--------------------------------------------------------------------------
-- Content: rebuilt fresh every refresh tick from Sync/Peers.lua,
-- Sync/Session.lua and the debug-log ring buffer - nothing here is cached
-- across ticks, so this always reflects current state with no separate
-- "did anything change" bookkeeping to get wrong.
--------------------------------------------------------------------------

local function formatAgo(seconds)
    seconds = math.max(0, math.floor(seconds or 0));
    if (seconds < 60) then return seconds .. "s"; end
    return math.floor(seconds / 60) .. "m" .. (seconds % 60) .. "s";
end

local function formatElapsed(seconds)
    seconds = math.max(0, math.floor(seconds or 0));
    local m, s = math.floor(seconds / 60), seconds % 60;
    if (m > 0) then return ("%dm%ds"):format(m, s); end
    return ("%ds"):format(s);
end

local function addPeersSection(add)
    local peerList = FL.Sync.Peers.All();
    add(("Peers (known=%d)"):format(FL.Sync.Peers.KnownPeerCount()));
    if (#peerList == 0) then
        add("  (none heard from yet)");
        return;
    end

    local historyId = FL.Sync.Constants.DOMAIN_HISTORY;
    for _, p in ipairs(peerList) do
        local result = p.compares and p.compares[historyId];
        local label = result or "?";
        local summary = p.summaries and p.summaries[historyId];
        if (result == "diverged" and summary) then
            label = label .. (" (W n=%d)"):format(summary[1] or 0);
        end
        add(("  %-24s heard %-6s ago   d1=%-26s ver=%s"):format(
            ("%q"):format(p.name), formatAgo(p.ago), label, tostring(p.version or "?")));
    end
end

local function addSessionsSection(add)
    local outCount, inCount = FL.Sync.Session.Counts();
    add(("Sessions (out=%d in=%d, serving max %d)"):format(outCount, inCount, FL.Sync.Session.MaxServe()));
    local sessionList = FL.Sync.Session.All();
    if (#sessionList == 0) then
        add("  (none active)");
        return;
    end

    for _, s in ipairs(sessionList) do
        add(("  %s  %s/%-4s peer=%-24s %-11s buckets %3d/%-3d  sent=%-4d recv=%-4d  %s"):format(
            s.token, s.role, s.mode or "full", ("%q"):format(s.peer), s.state,
            s.bucketsDone, s.bucketsTotal, s.sent, s.recv, formatElapsed(s.elapsed)));
    end
end

local function addPeerTotalsSection(add)
    add("Rows this login, by peer");
    local totals = FL.Sync.Session.PeerTotals();
    if (#totals == 0) then
        add("  (none yet)");
        return;
    end

    for _, t in ipairs(totals) do
        add(("  %-24s received: added=%-5d other=%-4d   sent=%d"):format(
            ("%q"):format(t.name), t.recvAdded, t.recvOther, t.sent));
    end
end

-- Only this client's OWN send-confirm latency is observable here - see
-- Net/Transport.lua's RecentSends() for the important caveat (it says
-- nothing about how long a PEER took to receive/process/reply, which is
-- what a slow handshake actually feels like from this side).
local function addSendLatencySection(add)
    add("Send latency (this client's own outgoing sends, most recent 30)");
    local sends = FL.Sync.Transport.RecentSends();
    if (#sends == 0) then
        add("  (none yet)");
        return;
    end

    local minDur, maxDur, total, failCount, overTwoSec = math.huge, 0, 0, 0, 0;
    for _, s in ipairs(sends) do
        minDur = math.min(minDur, s.dur);
        maxDur = math.max(maxDur, s.dur);
        total = total + s.dur;
        if (not s.ok) then failCount = failCount + 1; end
        if (s.dur > 2) then overTwoSec = overTwoSec + 1; end
    end
    add(("  n=%d  min=%.1fs  avg=%.1fs  max=%.1fs  failed=%d  over 2s=%d"):format(
        #sends, minDur, total / #sends, maxDur, failCount, overTwoSec));

    -- Newest first, most-recent-10 only - the summary line above already
    -- covers the full 30-entry window; this is just enough recent detail
    -- to eyeball whether slowness is steady or a one-off spike.
    local shown = 0;
    for i = #sends, 1, -1 do
        local s = sends[i];
        add(("    %-9s %5s  dur=%5.1fs  %-4s target=%s"):format(
            s.type, FL.Sync.Debug.FormatBytes(s.bytes), s.dur, s.ok and "ok" or "FAIL", tostring(s.target)));
        shown = shown + 1;
        if (shown >= 10) then break; end
    end
end

-- Substrings that mark a debug-log line as worth surfacing here, covering
-- every retry/failure/warning category this sync system produces: bucket
-- and compare-phase WANT retries, reassignment on a secondary's abort,
-- session aborts, stale (superseded-generation) batches, OPEN refusals, and
-- a peer declining to ack a HELLO (`-> silent reason=...` - deliberately
-- NOT the generic "ack decide" substring, which would also match every
-- ordinary "-> reply" decision and drown this feed in routine traffic; the
-- silent case is the one that's actually worth a tester's attention, e.g.
-- when a session never opens and the question is "did anyone even decide
-- not to answer, and why") - see docs/sync-deviations.md's Phase 5/6
-- entries for what each one means.
local INTERESTING_PATTERNS = { "WARN", "retry", "reassign", "abort", "stale", "refuse", "-> silent" };

local function lineIsInteresting(line)
    for _, pattern in ipairs(INTERESTING_PATTERNS) do
        if (line:find(pattern, 1, true)) then return true; end
    end
    return false;
end

-- Newest first (the buffer itself is oldest-to-newest, append-only) - a live
-- status window should show the latest event without scrolling.
local function addRecentActivitySection(add, maxLines)
    add("Recent retries / warnings / failures");
    local log = (FL.DB and FL.DB.debug and FL.DB.debug.log) or {};
    local shown = 0;
    for i = #log, 1, -1 do
        if (lineIsInteresting(log[i])) then
            add("  " .. log[i]);
            shown = shown + 1;
            if (shown >= maxLines) then break; end
        end
    end
    if (shown == 0) then add("  (none)"); end
end

local function buildContent()
    local lines = {};
    local function add(s) table.insert(lines, s); end

    addPeersSection(add);
    add("");
    addSessionsSection(add);
    add("");
    addPeerTotalsSection(add);
    add("");
    addSendLatencySection(add);
    add("");
    addRecentActivitySection(add, 25);

    return table.concat(lines, "\n");
end

--------------------------------------------------------------------------
-- Window chrome - identical structure to UI/DebugLogWindow.lua.
--------------------------------------------------------------------------

local function createTitleBar()
    local titleBar = CreateFrame("Frame", nil, frame);
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    titleBar:SetHeight(Sizes.titleBarHeight);

    titleBar:EnableMouse(true);
    titleBar:RegisterForDrag("LeftButton");
    titleBar:SetScript("OnDragStart", function() frame:StartMoving(); end);
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing();
        Pixel.SnapPosition(frame, function(x, y) FL.Settings.SetWindowPosition(POSITION_KEY, x, y); end);
    end);

    local title = titleBar:CreateFontString(nil, "OVERLAY");
    SetFont(title, "windowTitle");
    title:SetPoint("CENTER", titleBar, "CENTER", 0, 0);
    title:SetText("ForeverLoot - Sync Status");
    title:SetTextColor(unpack(Colors.titlePurple));

    local divider = titleBar:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 2, 0);
    divider:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -2, 0);
    divider:SetHeight(Pixel.PixelSize(1));

    local closeButton = CreateFrame("Button", nil, titleBar, "BackdropTemplate");
    closeButton:SetPoint("TOPRIGHT", titleBar, "TOPRIGHT", -8, -8);
    Skin.CloseButton(closeButton);
    closeButton:SetScript("OnClick", function()
        FL.NotifyWindowClosed("SyncStatus");
        frame:Hide();
    end);

    return titleBar;
end

local function createBody(titleBar)
    local body = CreateFrame("Frame", nil, frame, "BackdropTemplate");
    body:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", Sizes.contentPadX, -Sizes.contentPadTop);
    body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -Sizes.contentPadX, Sizes.contentPadBottom);
    Skin.Backdrop(body, Colors.controlBg, Colors.controlBorder);

    local scrollbarSpace = SharedLayout.scrollbarWidth + SharedLayout.scrollbarInset;

    scrollFrame = CreateFrame("ScrollFrame", "ForeverLootSyncStatusWindowScroll", body, "UIPanelScrollFrameTemplate");
    scrollFrame:SetPoint("TOPLEFT", body, "TOPLEFT", Sizes.textInset, -Sizes.textInset);
    scrollFrame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -(Sizes.textInset + scrollbarSpace), Sizes.textInset);

    local scrollBar = Skin.ScrollBar(scrollFrame);
    if (scrollBar) then
        scrollBar:ClearAllPoints();
        scrollBar:SetPoint("TOP", scrollFrame, "TOP", 0, 0);
        scrollBar:SetPoint("BOTTOM", scrollFrame, "BOTTOM", 0, 0);
        scrollBar:SetPoint("RIGHT", body, "RIGHT", -Sizes.textInset, 0);
    end

    editBox = CreateFrame("EditBox", nil, scrollFrame);
    editBox:SetMultiLine(true);
    editBox:SetAutoFocus(false);
    SetFont(editBox, "small");
    editBox:SetTextColor(unpack(Colors.description));
    editBox:SetWidth(scrollFrame:GetWidth());
    scrollFrame:SetScrollChild(editBox);
    scrollFrame:SetScript("OnSizeChanged", function(self, width) editBox:SetWidth(width); end);

    -- Read-only display: dropping focus re-selects everything (so a click
    -- still lets a tester Ctrl+C a snapshot), rather than letting a stray
    -- keypress edit the buffer.
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); end);
    editBox:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0); end);

    body:EnableMouse(true);
    body:SetScript("OnMouseDown", function() editBox:SetFocus(); end);
    scrollFrame:SetScript("OnMouseDown", function() editBox:SetFocus(); end);

    return body;
end

local function ensureFrame()
    if (frame) then return; end

    local savedPosition = FL.Settings.GetWindowPosition(POSITION_KEY);

    frame = CreateFrame("Frame", "ForeverLootSyncStatusWindow", UIParent, "BackdropTemplate");
    frame:Hide();
    frame:SetMovable(true);
    frame:SetFrameStrata("DIALOG");
    Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1);

    Pixel.RegisterWindow(frame, {
        width = WINDOW_WIDTH, height = WINDOW_HEIGHT,
        x = savedPosition and savedPosition.x or 0, y = savedPosition and savedPosition.y or 0,
    }, function() Theme.Helpers.SetFlatBackdrop(frame, Colors.windowBg, Colors.border, 1); end);

    local titleBar = createTitleBar();
    createBody(titleBar);
end

--- Rebuilds the text and redraws it, preserving the current scroll
--- position (SetText alone would otherwise snap the view back to the top
--- on every tick, fighting anyone who scrolled down to read something).
local function refresh()
    if (not frame or not frame:IsShown()) then return; end
    local scrollPos = scrollFrame:GetVerticalScroll();
    editBox:SetText(buildContent());
    scrollFrame:SetVerticalScroll(scrollPos);
end

-- Deliberately a raw C_Timer, not FL.Sync.Scheduler.Every - every timer
-- that module creates unconditionally logs its own "[SCHED] timer fire
-- ..." line (see that file's own code), which is exactly the right amount
-- of detail for an actual sync timer but pure noise for a once-a-second UI
-- refresh with no diagnostic value of its own - at 1s it would dominate
-- the 500-line debug-log ring buffer and push out the real sync events
-- this window exists to help read. Same reasoning Sync/Debug.lua and
-- Sync/Gate.lua already use raw C_Timer internally for.
local function ensureTicker()
    if (tickerStarted) then return; end
    tickerStarted = true;
    C_Timer.NewTicker(REFRESH_INTERVAL, refresh);
end

function SyncStatusWindow.Show()
    ensureFrame();
    ensureTicker();
    refresh();
    frame:Show();
end

function SyncStatusWindow.Hide()
    if (frame) then frame:Hide(); end
end

function SyncStatusWindow.IsShown()
    return frame ~= nil and frame:IsShown();
end

function SyncStatusWindow.Toggle()
    if (SyncStatusWindow.IsShown()) then SyncStatusWindow.Hide(); else SyncStatusWindow.Show(); end
end

function SyncStatusWindow.ResetPosition()
    FL.Settings.ClearWindowPosition(POSITION_KEY);
    if (frame) then Pixel.ResetPosition(frame); end
end
