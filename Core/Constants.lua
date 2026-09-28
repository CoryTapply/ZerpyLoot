local FL = ForeverLoot;
local Constants = FL.Constants;

-- Gargul's addon-comm prefix (Data/Constants.lua in Gargul). We register/send/listen
-- on this exact same prefix to interoperate with real Gargul clients.
Constants.COMM_CHANNEL = "GargulComm2";

-- Subset of Gargul's Comm.Actions we actually need (Data/Constants.lua:643-678).
Constants.Actions = {
    broadcastSoftRes = 3,
    response = 6,
    requestSoftResData = 8,
    startRollOff = 10,
    stopRollOff = 11,
};

-- Reverse lookup: action id -> name, used only for /zl commdebug printing.
Constants.ActionNames = {};
for name, id in pairs(Constants.Actions) do
    Constants.ActionNames[id] = name;
end

-- Gargul's Comm:listen drops any message whose declared `v` is older than this
-- (Data/Constants.lua:640, current Gargul release value). We declare a `v` that
-- satisfies Gargul's version check so our messages aren't silently rejected -
-- this is a protocol-compatibility handshake value, not an identity claim.
-- Bump this if a future Gargul release raises its own minimumAppVersion floor.
Constants.MIN_APP_VERSION = "7.7.36";
Constants.DECLARED_VERSION = "7.8.2";

-- Gargul's default roll-tracking brackets (Data/DefaultSettings.lua:155-158):
-- { label, min, max, priority, concernsOffspec, addPlusOne }
Constants.DEFAULT_BRACKETS = {
    { "MS", 1, 100, 2, false, false },
    { "OS", 1, 99, 3, true, false },
};

-- Loot council response options (Phase 3). This project's own dedicated
-- "ForeverLootLC" comm prefix uses plain string ids, not Gargul's numeric
-- action ids, so a simple ordered array is enough - order here is also the
-- button display order in UI/RespondWindow.lua.
--
-- `color` ({ r, g, b }, no alpha - each skin decides how strongly to apply
-- it) is a placeholder pick, one per response, purely so each response
-- button is visually distinct at a glance - not yet user-configurable. A
-- later options-panel phase is expected to let the user override these same
-- fields rather than replace this table's shape.
Constants.LOOT_COUNCIL_RESPONSES = {
    { id = "MAJOR",   label = "Major",   color = { 0.80, 0.20, 0.20 } }, -- red
    { id = "MINOR",   label = "Minor",   color = { 0.85, 0.55, 0.15 } }, -- orange
    { id = "OFFSPEC", label = "Offspec", color = { 0.20, 0.45, 0.80 } }, -- blue
    { id = "MOG",     label = "Transmog", color = { 0.65, 0.30, 0.80 } }, -- purple
    { id = "PASS",    label = "Pass",    color = { 0.25, 0.70, 0.30 } }, -- green
};

-- Reverse lookup: response id -> label, same convention as ActionNames above.
Constants.LOOT_COUNCIL_RESPONSE_LABELS = {};
for _, entry in ipairs(Constants.LOOT_COUNCIL_RESPONSES) do
    Constants.LOOT_COUNCIL_RESPONSE_LABELS[entry.id] = entry.label;
end

-- Synthetic response id for the Award window's placeholder row shown for a
-- party/raid member who hasn't answered this item's prompt yet. Deliberately
-- NOT one of the entries above - it's never sent over comm and must never
-- factor into the real response button order those drive (see
-- Awards.ResponseOrder, which sorts an id absent from that table last, after
-- every real response, for free).
-- "Awaiting" (not the longer "Awaiting Response") so the label still fits
-- the Response column's fixed pill width (UI/Sizes.lua colResponse), sized
-- for the real response labels above (all <= 7 characters).
Constants.LOOT_COUNCIL_AWAITING_RESPONSE_ID = "AWAITING";
Constants.LOOT_COUNCIL_RESPONSE_LABELS[Constants.LOOT_COUNCIL_AWAITING_RESPONSE_ID] = "Awaiting";

-- Shared "unselected" tint for a response button once its item has moved
-- into the "Responded" section - every button except the one actually
-- chosen switches to this grey, so the selection reads clearly at a glance.
Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR = { 0.35, 0.35, 0.35 };

-- Automatic Rolls (AutoRoll.lua, UI/AutoRollPopup.lua, the "Always roll on
-- these items" list). Order here is also the header-count order ("2 need ·
-- 1 greed · 2 pass") and the rule dropdown's row order.
Constants.AUTO_ROLL_RULE_ORDER = { "need", "greed", "pass", "manual" };
Constants.AUTO_ROLL_RULE_TITLE = { need = "Need", greed = "Greed", pass = "Pass", manual = "Manual" };
-- Present-participle form for AutoRoll.lua's per-roll chat print ("Needing on
-- [item]", "Manually rolling on [item]").
Constants.AUTO_ROLL_RULE_VERB = { need = "Needing", greed = "Greeding", pass = "Passing", manual = "Manually rolling" };

-- General settings page > "Sounds" section (UI/SettingsWindow/Pages/General.lua,
-- RollTracker.lua's roll-off start). Both dropdowns there list every
-- LibSharedMedia "sound" entry (LSM:List("sound") - whatever this or any
-- other installed addon has registered) via Util.playConfiguredSound
-- (Core/Util.lua), keyed by these two saved-value defaults.
--
-- SOUND_RAID_WARNING_KEY is a sentinel, not a real LSM key - PlaySound
-- SOUNDKIT ids aren't files LSM can Fetch, so Util.playConfiguredSound
-- special-cases this exact value to call PlaySound(SOUNDKIT.RAID_WARNING)
-- instead of PlaySoundFile. It's prepended onto the raid-warning dropdown's
-- option list by hand (see General.lua) since LSM itself has no record of it.
Constants.SOUND_RAID_WARNING_KEY = "Blizzard Raid Warning";

-- Our one bundled sound file (Media/Sounds/SonicRing.ogg), registered with
-- LSM below so it's Fetchable like any other sound key and shows up in both
-- dropdowns' option lists.
Constants.SOUND_SONIC_RING_KEY = "ForeverLoot: Sonic Ring";

local LSM = LibStub("LibSharedMedia-3.0");
LSM:Register(LSM.MediaType.SOUND, Constants.SOUND_SONIC_RING_KEY,
    "Interface\\AddOns\\ForeverLoot\\Media\\Sounds\\SonicRing.ogg");
