--[[
Sync settings page: the player's switches for automatic history sync (on/off,
pause until next login, sync now) and a live view of what sync is doing -
status, active transfers with progress bars and rates, known peers, the
local history, this login's outcome counts and a log of recent syncs.

Everything below the switches is hand-built full-width blocks (same
approach as General.lua's "Sounds" section) whose row counts change while
the page is open, so the page re-lays itself out on every refresh and
pushes its new height to the scroll area only when it changed. Refreshes
once a second from the page frame's own OnUpdate, which only runs while the
page is actually visible - nothing here costs anything while the settings
window is closed or on another page.

Data sources: Sync/Gate.lua (open/closed and why), Sync/Session.lua
(active sessions), Sync/Peers.lua (known peers), Sync/Stats.lua (rates,
recent-sync log, outcome counts, local history summary),
Sync/Coordinator.lua (next periodic check).

Every container frame gets an explicit height: a Frame left at zero
height renders no children on this client.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;
local Widgets = FL.UI.SettingsWidgets;
local Helpers = FL.Theme.Helpers;

local COLUMN_GAP = Widgets.COLUMN_GAP;
local SECTION_GAP = Sizes.layout.sectionGap;
local ROW_GAP = Sizes.layout.rowGap;
local LINE_HEIGHT = 18;          -- one status/label line
local TABLE_ROW_HEIGHT = 18;
local TRANSFER_ROW_HEIGHT = 40;  -- label line + bar line
local TRANSFER_ROW_GAP = 8;
local BAR_HEIGHT = 8;
local MAX_PEER_ROWS = 12;
local MAX_LOG_ROWS = 10;
local SYNC_NOW_COOLDOWN = 20;    -- seconds; HELLO_COLLECT_WINDOW plus margin, and well under the receivers' HELLO rate limit
local HISTORY_DOMAIN = FL.Sync.Constants.DOMAIN_HISTORY;

--------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------

local function hex(color)
    return ("ff%02x%02x%02x"):format(color[1] * 255, color[2] * 255, color[3] * 255);
end

local function paint(text, color)
    return ("|c%s%s|r"):format(hex(color), text);
end

local function formatNumber(n)
    local s = tostring(math.floor(n or 0));
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse();
    return (out:gsub("^,", ""));
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0));
    if (seconds < 60) then return seconds .. "s"; end
    local m = math.floor(seconds / 60);
    if (m < 60) then return ("%dm %ds"):format(m, seconds % 60); end
    return ("%dh %dm"):format(math.floor(m / 60), m % 60);
end

local function formatAgo(seconds)
    seconds = math.max(0, math.floor(seconds or 0));
    if (seconds < 10) then return "just now"; end
    if (seconds < 60) then return seconds .. "s ago"; end
    local m = math.floor(seconds / 60);
    if (m < 60) then return m .. "m ago"; end
    local h = math.floor(m / 60);
    if (h < 48) then return h .. "h ago"; end
    return math.floor(h / 24) .. "d ago";
end

--- "12", or "12 (+1 mark)" when pins/deletes moved too - a sync that only
--- carried a pin would otherwise read "0".
local function countWithMarks(rows, marks)
    local text = formatNumber(rows);
    if ((marks or 0) > 0) then
        text = text .. paint((" (+%s mark%s)"):format(formatNumber(marks), marks == 1 and "" or "s"), Colors.muted);
    end
    return text;
end

local function formatRowRate(perSecond)
    return ("%s rows/min"):format(formatNumber(perSecond * 60 + 0.5));
end

-- Gate.Status().reason -> why sync is waiting, as shown in the status line.
local WAIT_REASON_TEXT = {
    combat = "in combat",
    instance = "inside an instance",
    encounter = "boss encounter",
    loading = "loading screen",
    noguild = "not in a guild",
};

local STATE_TEXT = {
    OPENING = "Connecting",
    COMPARING = "Comparing",
    RECONCILING = "Transferring",
    FINISHING = "Finishing",
    SERVING = "Active",
};

--------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------

local function newText(parent, role, color, width)
    local fs = parent:CreateFontString(nil, "OVERLAY");
    SetFont(fs, role or "body");
    fs:SetJustifyH("LEFT");
    fs:SetJustifyV("TOP");
    fs:SetTextColor(unpack(color or Colors.text));
    if (width) then
        fs:SetWidth(width);
        fs:SetWordWrap(false);
    end
    return fs;
end

--- A titled block (gold title + divider, like page:Section's) at a fixed
--- width. `contentTop` is where the block's own rows start.
local function newBlock(parent, title, width)
    local frame = CreateFrame("Frame", nil, parent);
    frame:SetWidth(width);
    frame:SetHeight(1);

    local titleText = frame:CreateFontString(nil, "OVERLAY");
    SetFont(titleText, "sectionHeader");
    titleText:SetTextColor(unpack(Colors.gold));
    titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0);
    titleText:SetText(title);

    local divider = frame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6);
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0);
    divider:SetHeight(FL.Pixel.PixelSize(1));

    return { frame = frame, width = width, contentTop = -(titleText:GetStringHeight() + 6 + ROW_GAP) };
end

local function newBar(parent, width)
    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate");
    track:SetSize(width, BAR_HEIGHT);
    Helpers.SetFlatBackdrop(track, Colors.syncBarTrack, Colors.controlBorder, 1);

    local fill = track:CreateTexture(nil, "ARTWORK");
    fill:SetTexture(Helpers.FLAT_TEXTURE);
    fill:SetVertexColor(unpack(Colors.syncBarFill));
    fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1);
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1);
    fill:SetWidth(1);

    local bar = { track = track, fill = fill, width = width };
    function bar:SetProgress(pct)
        pct = math.max(0, math.min(1, pct or 0));
        local inner = self.width - 2;
        self.fill:SetWidth(math.max(1, inner * pct));
        self.fill:SetShown(pct > 0);
    end
    bar:SetProgress(0);
    return bar;
end

--- Label/value rows for the two small summary blocks. Returns a setter
--- taking an array of { label, value } and the block's content height.
local function newPairList(block, count)
    local labelWidth = math.floor(block.width * 0.58);
    local rows = {};
    for i = 1, count do
        local y = block.contentTop - (i - 1) * LINE_HEIGHT;
        local label = newText(block.frame, "body", Colors.muted, labelWidth - 8);
        label:SetPoint("TOPLEFT", block.frame, "TOPLEFT", 0, y);
        local value = newText(block.frame, "body", Colors.text, block.width - labelWidth);
        value:SetPoint("TOPLEFT", block.frame, "TOPLEFT", labelWidth, y);
        rows[i] = { label = label, value = value };
    end
    return function(pairs_)
        for i, row in ipairs(rows) do
            local p = pairs_[i];
            row.label:SetText(p and p[1] or "");
            row.value:SetText(p and p[2] or "");
        end
    end, -block.contentTop + count * LINE_HEIGHT;
end

--- A table with a muted header row and pooled body rows. `columns` is an
--- array of { title, x (fraction of the width) }. Returns an object whose
--- :SetRows(list of arrays of cell text) sizes the table to fit.
local function newTable(block, columns, maxRows)
    local width = block.width;
    local cellX, cellW = {}, {};
    for i, col in ipairs(columns) do
        cellX[i] = math.floor(col[2] * width);
        local nextX = columns[i + 1] and math.floor(columns[i + 1][2] * width) or width;
        cellW[i] = nextX - cellX[i] - 6;
    end

    for i, col in ipairs(columns) do
        local fs = newText(block.frame, "small", Colors.muted, cellW[i]);
        fs:SetPoint("TOPLEFT", block.frame, "TOPLEFT", cellX[i], block.contentTop);
        fs:SetText(col[1]);
    end

    local bodyTop = block.contentTop - TABLE_ROW_HEIGHT;
    local rows = {};
    local empty = newText(block.frame, "body", Colors.muted, width);
    empty:SetPoint("TOPLEFT", block.frame, "TOPLEFT", 0, bodyTop);
    local more = newText(block.frame, "small", Colors.muted, width);

    local tbl = { height = 0 };
    function tbl:SetRows(list, emptyText)
        local shown = math.min(#list, maxRows);
        for i = 1, shown do
            local row = rows[i];
            if (not row) then
                row = {};
                for c = 1, #columns do
                    local fs = newText(block.frame, "body", Colors.text, cellW[c]);
                    fs:SetPoint("TOPLEFT", block.frame, "TOPLEFT", cellX[c], bodyTop - (i - 1) * TABLE_ROW_HEIGHT);
                    row[c] = fs;
                end
                rows[i] = row;
            end
            for c, fs in ipairs(row) do
                fs:SetText(list[i][c] or "");
                fs:Show();
            end
        end
        for i = shown + 1, #rows do
            for _, fs in ipairs(rows[i]) do fs:Hide(); end
        end

        empty:SetShown(#list == 0);
        empty:SetText(emptyText or "");
        local bodyRows = math.max(1, shown);
        if (#list > shown) then
            more:ClearAllPoints();
            more:SetPoint("TOPLEFT", block.frame, "TOPLEFT", 0, bodyTop - shown * TABLE_ROW_HEIGHT);
            more:SetText(("+%d more"):format(#list - shown));
            more:Show();
            bodyRows = bodyRows + 1;
        else
            more:Hide();
        end
        self.height = -bodyTop + bodyRows * TABLE_ROW_HEIGHT;
    end
    return tbl;
end

--------------------------------------------------------------------------
-- Page
--------------------------------------------------------------------------

FL.UI.SettingsWindow.RegisterPage("sync", "Sync", function(page)
    page:Header("Sync", "Shares loot history with guild members who run ForeverLoot.");

    local width = page.contentWidth;
    local colWidth = math.floor((width - COLUMN_GAP) / 2);
    local lastSyncNowAt;

    ----------------------------------------------------------------------
    -- Automatic Sync (left) - the switches
    ----------------------------------------------------------------------

    local controls = newBlock(page.frame, "Automatic Sync", colWidth);

    -- A plain SectionMethods object (same as General.lua's Sounds columns)
    -- so the checkbox gets the shared look, search entry, reset default and
    -- refresher.
    local checkboxHolder = CreateFrame("Frame", nil, controls.frame);
    checkboxHolder:SetPoint("TOPLEFT", controls.frame, "TOPLEFT", 0, controls.contentTop);
    checkboxHolder:SetWidth(colWidth);
    checkboxHolder:SetHeight(1);
    local checkboxSection = setmetatable({
        page = page, frame = checkboxHolder, width = colWidth,
        startY = 0, nextRowY = 0, rows = {}, items = {},
    }, Widgets.SectionMethods);

    local update; -- defined below; every control refreshes the page straight away

    checkboxSection:Checkbox{
        key = "sync.autoSync",
        label = "Sync loot history automatically",
        desc = "Compares loot history with guild members in the background and fills in anything missing. "
            .. "New awards are still shared live while this is off.",
        tooltip = "Turning this off stops all background sync traffic. Other players won't see you as a sync peer.",
        default = true,
        onChange = function() update(); end,
    };

    local pauseButton = Widgets.CreateFlatButton(controls.frame, "Pause Until Next Login");
    pauseButton:SetSize(180, Sizes.controls.button);
    pauseButton:SetScript("OnClick", function()
        FL.Settings.SetSyncPausedThisLogin(not FL.Settings.GetSyncPausedThisLogin());
        update();
    end);
    pauseButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
        GameTooltip:AddLine("Stops sync until you log out and back in. A /reload keeps it paused.", 1, 1, 1, true);
        GameTooltip:Show();
    end);
    pauseButton:HookScript("OnLeave", function() GameTooltip:Hide(); end);

    local syncNowButton = Widgets.CreateFlatButton(controls.frame, "Sync Now");
    syncNowButton:SetSize(110, Sizes.controls.button);
    syncNowButton:SetPoint("LEFT", pauseButton, "RIGHT", 8, 0);
    syncNowButton:SetScript("OnClick", function()
        lastSyncNowAt = GetTime();
        FL.Sync.Coordinator.ForceHello("GUILD");
        update();
    end);

    local controlsNote = controls.frame:CreateFontString(nil, "OVERLAY");
    SetFont(controlsNote, "helper");
    controlsNote:SetJustifyH("LEFT");
    controlsNote:SetJustifyV("TOP");
    controlsNote:SetSpacing(2);
    controlsNote:SetTextColor(unpack(Colors.muted));
    controlsNote:SetWidth(colWidth);

    ----------------------------------------------------------------------
    -- Status (right)
    ----------------------------------------------------------------------

    local status = newBlock(page.frame, "Status", colWidth);
    local STATUS_LINES = 5;
    local statusLines = {};
    for i = 1, STATUS_LINES do
        local fs = newText(status.frame, i == 1 and "sectionHeader" or "body", Colors.text, colWidth);
        fs:SetPoint("TOPLEFT", status.frame, "TOPLEFT", 0, status.contentTop - (i - 1) * LINE_HEIGHT - (i > 1 and 4 or 0));
        statusLines[i] = fs;
    end
    local statusHeight = -status.contentTop + STATUS_LINES * LINE_HEIGHT + 4;

    ----------------------------------------------------------------------
    -- Transfers (full width)
    ----------------------------------------------------------------------

    local transfers = newBlock(page.frame, "Transfers", width);
    local transferEmpty = newText(transfers.frame, "body", Colors.muted, width);
    transferEmpty:SetPoint("TOPLEFT", transfers.frame, "TOPLEFT", 0, transfers.contentTop);
    local transferRows = {};
    local BAR_WIDTH = math.floor(width * 0.4);

    local function acquireTransferRow(i)
        local row = transferRows[i];
        if (row) then return row; end
        local y = transfers.contentTop - (i - 1) * (TRANSFER_ROW_HEIGHT + TRANSFER_ROW_GAP);
        row = {};
        row.label = newText(transfers.frame, "body", Colors.text, width - 120);
        row.label:SetPoint("TOPLEFT", transfers.frame, "TOPLEFT", 0, y);
        row.elapsed = newText(transfers.frame, "small", Colors.muted, 110);
        row.elapsed:SetJustifyH("RIGHT");
        row.elapsed:SetPoint("TOPRIGHT", transfers.frame, "TOPRIGHT", 0, y);
        row.bar = newBar(transfers.frame, BAR_WIDTH);
        row.bar.track:SetPoint("TOPLEFT", transfers.frame, "TOPLEFT", 0, y - 22);
        row.detail = newText(transfers.frame, "small", Colors.description, width - BAR_WIDTH - 12);
        row.detail:SetPoint("LEFT", row.bar.track, "RIGHT", 12, 0);
        transferRows[i] = row;
        return row;
    end

    local function setTransferRowShown(row, shown)
        row.label:SetShown(shown);
        row.elapsed:SetShown(shown);
        row.bar.track:SetShown(shown);
        row.detail:SetShown(shown);
    end

    ----------------------------------------------------------------------
    -- Peers (full width)
    ----------------------------------------------------------------------

    local peersBlock = newBlock(page.frame, "Peers", width);
    local peersTable = newTable(peersBlock, {
        { "Player", 0 }, { "History", 0.22 }, { "Version", 0.48 }, { "Last heard", 0.64 },
        { "Received", 0.77 }, { "Sent", 0.91 },
    }, MAX_PEER_ROWS);

    ----------------------------------------------------------------------
    -- Your History (left) / This Login (right)
    ----------------------------------------------------------------------

    local historyBlock = newBlock(page.frame, "Your History", colWidth);
    local setHistoryPairs, historyHeight = newPairList(historyBlock, 3);

    local loginBlock = newBlock(page.frame, "This Login", colWidth);
    local setLoginPairs, loginHeight = newPairList(loginBlock, 7);

    ----------------------------------------------------------------------
    -- Recent Syncs (full width)
    ----------------------------------------------------------------------

    local logBlock = newBlock(page.frame, "Recent Syncs", width);
    local logTable = newTable(logBlock, {
        { "When", 0 }, { "Player", 0.13 }, { "Started by", 0.33 }, { "Received", 0.49 },
        { "Sent", 0.65 }, { "Duration", 0.74 }, { "Result", 0.85 },
    }, MAX_LOG_ROWS);

    ----------------------------------------------------------------------
    -- Content
    ----------------------------------------------------------------------

    local function updateControls(gate)
        local autoSync = FL.Settings.GetAutoSyncEnabled();
        local paused = FL.Settings.GetSyncPausedThisLogin();

        pauseButton.text:SetText(paused and "Resume Sync" or "Pause Until Next Login");
        pauseButton:SetEnabled(autoSync);

        local cooling = lastSyncNowAt and (GetTime() - lastSyncNowAt) < SYNC_NOW_COOLDOWN;
        local busy = FL.Sync.Session.AnyActive();
        syncNowButton.text:SetText(cooling and "Checking..." or "Sync Now");
        syncNowButton:SetEnabled(gate.sync == "open" and FL.Sync.Gate.CanSync() and not cooling and not busy);

        if (not autoSync) then
            controlsNote:SetText("Automatic sync is off. Your history won't receive awards you missed while offline.");
        elseif (paused) then
            controlsNote:SetText("Paused. Sync turns back on the next time you log in (a /reload keeps it paused).");
        elseif (busy) then
            controlsNote:SetText("A sync is running. Sync Now is available again once it finishes.");
        else
            controlsNote:SetText("Sync Now asks online guild members to compare histories right away instead of waiting for the next check.");
        end
    end

    local function updateStatus(gate, sessionList, peerList)
        local autoSync = FL.Settings.GetAutoSyncEnabled();
        local paused = FL.Settings.GetSyncPausedThisLogin();

        local known, same, different = 0, 0, 0;
        for _, p in ipairs(peerList) do
            local result = p.compares and p.compares[HISTORY_DOMAIN];
            known = known + 1;
            if (result == "same") then same = same + 1;
            elseif (result == "diverged" or result == "incompatible") then different = different + 1; end
        end

        local headline, color;
        if (not autoSync) then
            headline, color = "Off", Colors.syncWarn;
        elseif (paused) then
            headline, color = "Paused until next login", Colors.syncWarn;
        elseif (gate.sync ~= "open") then
            headline = "Waiting: " .. (WAIT_REASON_TEXT[gate.reason] or gate.reason or "?");
            color = (gate.reason == "noguild") and Colors.syncBad or Colors.syncWarn;
        elseif (not FL.Sync.Gate.CanSync()) then
            headline, color = "Unavailable: digest self-test failed", Colors.syncBad;
        elseif (#sessionList > 0) then
            headline, color = "Syncing", Colors.syncGood;
        elseif (known == 0) then
            headline, color = "Looking for peers", Colors.muted;
        elseif (different == 0 and same > 0) then
            headline, color = "Up to date", Colors.syncGood;
        elseif (different > 0) then
            headline, color = ("Differs from %d peer%s"):format(different, different == 1 and "" or "s"), Colors.syncWarn;
        else
            headline, color = "Waiting for the next check", Colors.muted;
        end
        statusLines[1]:SetText(headline);
        statusLines[1]:SetTextColor(unpack(color));

        if (known == 0) then
            statusLines[2]:SetText("No peers heard from in the last 30 minutes");
        else
            statusLines[2]:SetText(("In sync with %d of %d peer%s"):format(same, known, known == 1 and "" or "s"));
        end

        local last = FL.Sync.Stats.LastSuccess();
        if (last) then
            statusLines[3]:SetText(("Last sync: %s with %s (%s new)"):format(
                formatAgo(time() - last.at), last.peer, formatNumber(last.added)));
        else
            statusLines[3]:SetText("Last sync: none yet");
        end

        local nextIn = FL.Sync.Coordinator.NextCheckIn();
        if (gate.sync == "open" and nextIn) then
            statusLines[4]:SetText("Next automatic check: in " .. formatDuration(nextIn));
        else
            statusLines[4]:SetText("Next automatic check: when sync can run");
        end

        -- Newest version any peer runs, if newer than ours.
        local mine = FL.Sync.Peers.AddonVersion();
        local newestName, newestVersion;
        for _, p in ipairs(peerList) do
            if (FL.Sync.Peers.CompareToMine(p.version) == 1
                and (not newestVersion or FL.Sync.Peers.CompareVersions(p.version, newestVersion) == 1)) then
                newestName, newestVersion = p.name, p.version;
            end
        end
        if (newestVersion) then
            statusLines[5]:SetText(paint(("Update available: %s has %s (you have %s)"):format(newestName, newestVersion, mine), Colors.syncWarn));
        else
            statusLines[5]:SetText(paint("ForeverLoot " .. mine, Colors.muted));
        end
    end

    local function transferLabel(s)
        local who = paint(s.peer, Colors.gold);
        if (s.role == "opener") then
            if (s.mode == "pull") then return ("Downloading from %s (helper)"):format(who); end
            return ("Syncing with %s"):format(who);
        end
        if (s.mode == "pull") then return ("%s is downloading from you (helper)"):format(who); end
        return ("%s is syncing with you"):format(who);
    end

    --- Returns the number of transfer rows shown.
    local function updateTransfers(sessionList)
        for i, s in ipairs(sessionList) do
            local row = acquireTransferRow(i);
            setTransferRowShown(row, true);

            row.label:SetText(("%s  %s"):format(transferLabel(s), paint(STATE_TEXT[s.state] or s.state, Colors.muted)));
            row.elapsed:SetText(formatDuration(s.elapsed));

            local inRate, outRate = FL.Sync.Stats.SessionRates(s.token);
            local parts = {};
            local pct = 0;

            -- Rough rows-to-go from the two window counts taken when the
            -- session started (they include deletions and pins, hence the
            -- "~"). Whichever side had more is the direction rows mostly
            -- flow. Not for helper sessions: they carry only part of the
            -- history, so the whole-history difference doesn't apply.
            local expectIn, expectOut;
            if (s.mode == "full" and s.remoteCount and s.startLocalCount) then
                local diff = s.remoteCount - s.startLocalCount;
                if (diff > 0) then expectIn = diff; elseif (diff < 0) then expectOut = -diff; end
            end

            if (s.role == "opener" and s.bucketsTotalKnown and s.bucketsTotal > 0) then
                pct = s.bucketsDone / s.bucketsTotal;
            elseif (expectIn) then
                pct = s.recvAdded / expectIn;
            elseif (expectOut) then
                pct = s.sent / expectOut;
            end

            if (s.state == "OPENING") then
                table.insert(parts, "waiting for reply");
            elseif (s.state == "COMPARING") then
                table.insert(parts, "comparing histories");
            end
            table.insert(parts, "received " .. countWithMarks(s.recvAdded, s.marksAdded));
            table.insert(parts, "sent " .. countWithMarks(s.sent, s.marksSent));
            if (inRate and (inRate + outRate) > 0.05) then
                table.insert(parts, formatRowRate(inRate + outRate));
            end

            local remaining, rate;
            if (expectIn) then
                remaining, rate = math.max(0, expectIn - s.recvAdded), inRate;
            elseif (expectOut) then
                remaining, rate = math.max(0, expectOut - s.sent), outRate;
            end
            if (remaining and remaining > 0) then
                local eta = (rate and rate > 0.05) and (" · ~" .. formatDuration(remaining / rate) .. " left") or "";
                table.insert(parts, ("~%s rows to go%s"):format(formatNumber(remaining), eta));
            end

            row.bar:SetProgress(pct);
            row.detail:SetText(table.concat(parts, "  ·  "));
        end
        for i = #sessionList + 1, #transferRows do
            setTransferRowShown(transferRows[i], false);
        end

        transferEmpty:SetShown(#sessionList == 0);
        transferEmpty:SetText("No transfers running.");
        return #sessionList;
    end

    local function updatePeers(peerList)
        local totalsByName = {};
        for _, t in ipairs(FL.Sync.Session.PeerTotals()) do totalsByName[t.name] = t; end

        local list = {};
        for _, p in ipairs(peerList) do
            local result = p.compares and p.compares[HISTORY_DOMAIN];
            local history;
            if (result == "same") then
                history = paint("In sync", Colors.syncGood);
            elseif (result == "diverged") then
                -- Window entry counts (rows plus delete/pin marks), so only a
                -- rough "how far apart" - hence the "~".
                local theirs = p.summaries and p.summaries[HISTORY_DOMAIN] and p.summaries[HISTORY_DOMAIN][1];
                local gap = "";
                if (theirs) then
                    local diff = theirs - FL.Sync.Digest.Root("W").count;
                    if (diff > 0) then
                        gap = (" (~%s more)"):format(formatNumber(diff));
                    elseif (diff < 0) then
                        gap = (" (~%s fewer)"):format(formatNumber(-diff));
                    else
                        gap = " (same size)";
                    end
                end
                history = paint("Different", Colors.syncWarn) .. paint(gap, Colors.muted);
            elseif (result == "incompatible") then
                history = paint("Incompatible", Colors.syncBad);
            else
                history = paint("Unknown", Colors.muted);
            end

            local version = tostring(p.version or "?");
            local cmp = FL.Sync.Peers.CompareToMine(p.version);
            if (cmp == 1) then
                version = paint(version .. " (newer)", Colors.syncWarn);
            elseif (cmp == -1) then
                version = version .. paint(" (older)", Colors.muted);
            end

            local t = totalsByName[p.name];
            table.insert(list, {
                p.name, history, version, formatAgo(p.ago),
                t and formatNumber(t.recvAdded) or "-",
                t and formatNumber(t.sent) or "-",
            });
        end
        peersTable:SetRows(list, "No ForeverLoot users heard from in the last 30 minutes.");
    end

    local function updateHistory()
        local h = FL.Sync.Stats.LocalHistory();
        setHistoryPairs({
            { "Rows stored", formatNumber(h.rows) },
            { "Pinned rows", formatNumber(h.pinned) },
            { "Deletions tracked", formatNumber(h.deleted) },
        });
    end

    local function updateLogin()
        local c = FL.Sync.Stats.Counts();
        local added = 0;
        local sent = 0;
        for _, t in ipairs(FL.Sync.Session.PeerTotals()) do
            added = added + t.recvAdded;
            sent = sent + t.sent;
        end
        setLoginPairs({
            { "Completed", paint(formatNumber(c.done), c.done > 0 and Colors.syncGood or Colors.text) },
            { "Timed out", paint(formatNumber(c.timeout), c.timeout > 0 and Colors.syncBad or Colors.text) },
            { "Stopped (combat, instance, off)", formatNumber(c.stopped) },
            { "Refused (peer busy)", formatNumber(c.refused) },
            { "Failed", paint(formatNumber(c.failed), c.failed > 0 and Colors.syncBad or Colors.text) },
            { "Rows received", formatNumber(added) },
            { "Rows sent", formatNumber(sent) },
        });
    end

    local RESULT_TEXT = {
        timeout = { "Timed out", Colors.syncBad },
        stopped = { "Stopped", Colors.syncWarn },
        refused = { "Busy", Colors.muted },
        failed = { "Failed", Colors.syncBad },
    };

    local function updateLog()
        local list = {};
        for i, r in ipairs(FL.Sync.Stats.RecentSessions()) do
            if (i > MAX_LOG_ROWS) then break; end
            local result;
            if (r.outcome == "done") then
                -- A full session that ended with different digests still
                -- moved data; the next check picks up the rest.
                if (r.match == false and not r.helper) then
                    result = paint("Partial", Colors.syncWarn);
                else
                    result = paint("Complete", Colors.syncGood);
                end
            else
                local entry = RESULT_TEXT[r.outcome] or { r.outcome, Colors.muted };
                result = paint(entry[1], entry[2]);
            end
            local startedBy = (r.role == "opener") and "You" or "Them";
            if (r.helper or r.mode == "pull") then startedBy = startedBy .. paint(" (helper)", Colors.muted); end
            table.insert(list, {
                formatAgo(time() - r.at), r.peer, startedBy,
                countWithMarks(r.added, r.marksAdded),
                countWithMarks(r.sent, r.marksSent), formatDuration(r.dur), result,
            });
        end
        logTable:SetRows(list, "No syncs recorded yet.");
    end

    ----------------------------------------------------------------------
    -- Layout: stacks every block from the top and returns the bottom Y.
    ----------------------------------------------------------------------

    local transferCount = 0;
    local lastHeight;

    local function layout()
        local y = page.contentTop or -46;

        controls.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, y);
        local checkboxHeight = checkboxSection:Reflow();
        -- Reflow's height already ends with one row gap.
        local buttonsY = controls.contentTop - checkboxHeight;
        pauseButton:SetPoint("TOPLEFT", controls.frame, "TOPLEFT", 0, buttonsY);
        controlsNote:SetPoint("TOPLEFT", controls.frame, "TOPLEFT", 0, buttonsY - Sizes.controls.button - ROW_GAP);
        local controlsHeight = -(buttonsY - Sizes.controls.button - ROW_GAP) + controlsNote:GetStringHeight();
        controls.frame:SetHeight(controlsHeight);

        status.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", colWidth + COLUMN_GAP, y);
        status.frame:SetHeight(statusHeight);
        y = y - math.max(controlsHeight, statusHeight) - SECTION_GAP;

        transfers.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, y);
        local transferHeight = -transfers.contentTop
            + math.max(1, transferCount) * (TRANSFER_ROW_HEIGHT + TRANSFER_ROW_GAP) - TRANSFER_ROW_GAP;
        if (transferCount == 0) then transferHeight = -transfers.contentTop + LINE_HEIGHT; end
        transfers.frame:SetHeight(transferHeight);
        y = y - transferHeight - SECTION_GAP;

        peersBlock.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, y);
        peersBlock.frame:SetHeight(peersTable.height);
        y = y - peersTable.height - SECTION_GAP;

        historyBlock.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, y);
        historyBlock.frame:SetHeight(historyHeight);
        loginBlock.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", colWidth + COLUMN_GAP, y);
        loginBlock.frame:SetHeight(loginHeight);
        y = y - math.max(historyHeight, loginHeight) - SECTION_GAP;

        logBlock.frame:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, y);
        logBlock.frame:SetHeight(logTable.height);
        y = y - logTable.height;

        page.contentBottomOverride = y;
        return -y;
    end

    update = function()
        FL.Sync.Stats.Sample();
        local gate = FL.Sync.Gate.Status();
        local sessionList = FL.Sync.Session.All();
        local peerList = FL.Sync.Peers.All();

        updateControls(gate);
        updateStatus(gate, sessionList, peerList);
        transferCount = updateTransfers(sessionList);
        updatePeers(peerList);
        updateHistory();
        updateLogin();
        updateLog();

        local height = layout();
        page.frame:SetHeight(math.max(1, height));
        -- Only once the page is on screen (the first build is sized by
        -- Registry itself), and only when the height actually changed.
        if (lastHeight and height ~= lastHeight and page.frame:IsVisible()) then
            FL.UI.SettingsRegistry.RefreshCurrentPage();
        end
        lastHeight = height;
    end;

    update();
    page:AddLayoutHook(function() update(); end);

    -- Once a second while visible. OnUpdate never runs for a hidden frame,
    -- so this stops by itself when the window closes or another page is
    -- selected. The same goes for the peer status check, which keeps the
    -- Peers table current; SendStatus throttles itself to STATUS_INTERVAL.
    local sinceRefresh = 0;
    page.frame:SetScript("OnUpdate", function(_, elapsed)
        sinceRefresh = sinceRefresh + elapsed;
        if (sinceRefresh < 1) then return; end
        sinceRefresh = 0;
        FL.Sync.Peers.SendStatus("page");
        update();
    end);
    page.frame:HookScript("OnShow", function()
        sinceRefresh = 0;
        FL.Sync.Peers.SendStatus("pageOpen");
        update();
    end);
end, 55);
