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

-- Loot council response options are now user-configurable - see
-- Core/Responses.lua (FL.Responses), which owns the leader's live list
-- (FL.DB.responses.list), the session snapshot broadcast at session start,
-- and the id-less {label,color,kind} copy written into history. The ids
-- below are NOT part of that configurable list - they're synthetic,
-- non-real response ids used only for candidates who haven't answered (or
-- can't) this item's prompt, so they still need a label lookup table of
-- their own.
Constants.LOOT_COUNCIL_RESPONSE_LABELS = {};

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

-- Same synthetic-id convention as AWAITING above, for the two other reasons
-- a candidate row can be non-responsive: not connected to the game at all,
-- or connected but never proven (via LootCouncil.Presence) to be running
-- ForeverLoot. Never sent over comm, never part of a session's real response
-- snapshot (Core/Responses.lua), so Awards.ResponseOrder's math.huge
-- fallback sorts these last too.
Constants.LOOT_COUNCIL_OFFLINE_RESPONSE_ID = "OFFLINE";
Constants.LOOT_COUNCIL_RESPONSE_LABELS[Constants.LOOT_COUNCIL_OFFLINE_RESPONSE_ID] = "Offline";

Constants.LOOT_COUNCIL_NO_ADDON_RESPONSE_ID = "NO_ADDON";
Constants.LOOT_COUNCIL_RESPONSE_LABELS[Constants.LOOT_COUNCIL_NO_ADDON_RESPONSE_ID] = "No Addon";

-- Shared "unselected" tint for a response button once its item has moved
-- into the "Responded" section - every button except the one actually
-- chosen switches to this grey, so the selection reads clearly at a glance.
Constants.LOOT_COUNCIL_RESPONSE_UNSELECTED_COLOR = { 0.35, 0.35, 0.35 };

-- Sentinel `item.awardedTo` value for the Award window's disenchant button
-- (UI/AwardWindow.lua) - marks the item assigned via the exact same
-- LootCouncil.AwardItem/applyAward path a real award uses (so every client
-- converges the same way), without it ever matching a real candidate name.
Constants.LOOT_COUNCIL_DISENCHANT_RECIPIENT = "Disenchant";

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
