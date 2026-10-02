--[[
Every tunable for the history-sync system (docs/ForeverLoot History Sync —
Spec.md section 13), in one read-only table. No Init() - nothing here
changes at runtime, and nothing here depends on anything else loading first.

Namespace note: the spec writes these as `ns.X` (file-local
`local _, ns = ...`). This addon instead uses a global `ForeverLoot` table
("FL"); see docs/sync-deviations.md.

Values marked "guild-wide" in the spec must match on every client to sync
(PROTO_VERSION and RETENTION_MONTHS also travel inside every HELLO).
Most of these are unused until later phases but are defined now, in full,
per the Phase 0 build instructions.
]]

local FL = ForeverLoot;
local Constants = FL.Sync.Constants;

Constants.PROTO_VERSION          = 1;          -- guild-wide: wire format version
Constants.RETENTION_MONTHS       = 4;          -- guild-wide: window length (spec section 10)
Constants.PREFIX_MAIN            = "FLoot";    -- guild-wide: live + control messages
Constants.PREFIX_SYNC            = { "FLootS1", "FLootS2", "FLootS3" }; -- guild-wide: bulk ROWS/MARKS
Constants.MAX_RESPONSES          = 5;          -- guild-wide: validation cap
Constants.NOTE_MAX_LEN           = 120;        -- guild-wide: validation cap and UI limit

-- "base ± jitter" values are kept as { base, jitter } tables (not a single
-- number) since Scheduler.After(sec, jitter, fn, name) needs both halves
-- separately.
Constants.LOGIN_DELAY            = { base = 20, jitter = 10 };    -- seconds before the first HELLO
Constants.PERIODIC_INTERVAL      = { base = 720, jitter = 180 };  -- 12 min +- 3 min, periodic check
Constants.HELLO_REPLY_JITTER     = 4;          -- seconds, 0..4, delay before HELLO_ACK
-- 12s, not spec's 6s: live-tested on "WoW Forever" (Phase 6), both peers'
-- HELLO_ACK consistently arrived 0.5-4s AFTER a 6s window had already
-- closed, every single attempt (not occasional bad luck - see
-- docs/sync-deviations.md "Phase 6: HELLO_COLLECT_WINDOW too short for this
-- server's real round trip"). 6s assumes near-instant delivery, which this
-- server doesn't have; 12s gives HELLO_REPLY_JITTER's full 4s plus real
-- margin for the kind of delay actually observed.
Constants.HELLO_COLLECT_WINDOW   = 12;         -- seconds the opener waits for replies
Constants.HELLO_RETRY            = { delay = 30, maxTries = 3 }; -- retry when nobody replies

Constants.TARGET_RESPONDERS      = 3;          -- expected number of HELLO_ACKs
Constants.PEER_MEMORY            = 1800;       -- 30 min, seconds; window for counting knownPeers
Constants.MAX_SECONDARIES        = 2;          -- pull-only helpers per session
Constants.MAX_SERVE               = 2;          -- inbound sessions served at once
Constants.BUCKETS_IN_FLIGHT      = 3;          -- concurrent buckets per session
Constants.BATCH_TARGET_BYTES     = 4096;       -- ROWS batch size, serialized
Constants.SESSION_IDLE_TIMEOUT   = 45;         -- seconds; drop a silent session
Constants.COMBAT_RESUME_DELAY    = 5;          -- seconds to wait after leaving combat
Constants.FRAME_BUDGET_MS        = 4;          -- Scheduler time slice

Constants.DELETE_POLICY          = "officers"; -- guild-wide: "anyone" | "council" | "officers"
Constants.OFFICER_RANK_MAX       = 1;          -- guild-wide: highest rank index counted as officer

Constants.DOMAIN_HISTORY         = 1;          -- guild-wide: wire id of the loot-history domain
Constants.DOMAIN_COUNCIL_SESSION = 2;          -- guild-wide: wire id of the council-session domain

Constants.SESSION_END_TTL        = 600;        -- 10 min, seconds; ended council session advertising

-- Phase 3 additions (spec section 10):
Constants.PRUNE_REAL             = false;      -- safety switch: real pruning stays off until Phase 8;
                                                -- expired real rows are kept on disk but excluded from
                                                -- the digest and never sent, as if they were pruned.
Constants.KEY_ITEMS_VERSION      = 1;          -- guild-wide: bump when KEY_ITEMS below changes, so every
                                                -- client pins its matching in-window rows once at login
Constants.KEY_ITEMS = {
    -- Fixed set of item ids that get pinned automatically at award time
    -- (spec 10.5). Empty until the guild decides which items qualify;
    -- /fl debug keyitem add <itemID> adds one in-memory, for testing, until
    -- the next /reload.
};

-- Phase 0 additions - not in spec section 13's table, needed by
-- Sync/Debug.lua's ring buffer and repeat-collapsing.
Constants.DEBUG_LOG_LINES        = 500;
Constants.DEBUG_COLLAPSE_SECONDS = 2;

-- Phase 2 addition: the protocol message catalog (spec section 6), as a
-- name -> wire id map plus its reverse, so every module logs/dispatches by
-- the same fixed numbers instead of each inventing its own. Ids 3-8, 11-19
-- (session/discovery messages) aren't used until Phase 4+ but are numbered
-- now, matching the spec table, so a later phase never has to renumber
-- anything already on the wire.
Constants.MSG = {
    HELLO     = 1,  HELLO_ACK = 2,  OPEN  = 3,  OPEN_REPLY = 4,
    MONTHS    = 5,  DAYS      = 6,  HASHES = 7, WANT       = 8,
    ROWS      = 9,  MARKS     = 10, DONE  = 11, ABORT      = 12,
    SNAP_GET  = 13, SNAP      = 14,
    LIVE_ROW  = 20, LIVE_DEL  = 21, LIVE_PIN = 22,
};
Constants.MSG_NAMES = {};
for name, id in pairs(Constants.MSG) do
    Constants.MSG_NAMES[id] = name;
end
