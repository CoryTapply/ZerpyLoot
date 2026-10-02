# Sync system deviations from the spec

Per the implementation plan's own rule ("if the code forces a deviation,
write it down in `docs/sync-deviations.md` with the reason"), deviations
from `ForeverLoot History Sync — Spec.md` / `ForeverLoot Sync —
Implementation Plan.md` are recorded here as they come up, phase by phase.

## Phase 0: Namespace — `FL.Sync.*` instead of `ns.*`

The spec (section 12.1) assumes Lua's file-local addon namespace
(`local _, ns = ...`), with each module self-registering as `ns.Store`,
`ns.Gate`, etc.

ForeverLoot's existing codebase predates this spec and does not use that
convention anywhere. Every file instead attaches to a single global table,
`ForeverLoot` (aliased `local FL = ForeverLoot` at the top of every file),
whose sub-tables are pre-declared once in `Core/Init.lua` (e.g.
`FL.UI.RollWindow = FL.UI.RollWindow or {}`). Introducing a second, parallel
namespacing style alongside this one for just the sync system would be
inconsistent with every other module in the addon, and `local _, ns = ...`
would be dead/unused in every sync file anyway, since `FL` is a global, not
the addon table WoW hands each file as its second vararg.

**Resolution:** every `ns.X` in the spec and implementation plan is
implemented as `FL.Sync.X` instead. `Sync/Constants.lua` -> `FL.Sync.Constants`,
`Sync/Debug.lua` -> `FL.Sync.Debug`, `Sync/Scheduler.lua` -> `FL.Sync.Scheduler`,
`Sync/Gate.lua` -> `FL.Sync.Gate`, and so on for every module added in later
phases (`FL.Sync.Live`, `FL.Sync.Peers`, `FL.Sync.Session`,
`FL.Sync.Coordinator`, `FL.Sync.Domains`, `FL.Sync.Permissions`, etc. as each
is introduced), following this same rule. All `FL.Sync.*` sub-tables are
pre-declared in `Core/Init.lua` alongside every other module, following the
codebase's one established convention instead of adding a second one.

A direct consequence: `Sync/*.lua` files must load *after* `Core/Init.lua` in
the TOC (since `Core/Init.lua` is what creates the `ForeverLoot` global and
pre-declares `FL.Sync.*`), unlike spec section 12.1's literal file list,
which puts `Sync/Constants.lua` immediately after `Libs/` and before
anything resembling "Core." The new `# Sync` TOC section is placed
immediately after the existing `# Core` block instead, keeping it as early
as practically possible.

## Phase 1: History storage stays an array, not a dict-by-id

Spec section 12.5 shows `ForeverLootDB.history` as a fresh
`{ schema = 2, rows = { [id] = {...} }, tombstones = { [id] = {...} },
pins = { [id] = {...} } }` - every kind stored as a dict keyed directly by id.

This addon already stores rows in `FL.DB.lootCouncil.history`, an **array**,
with a separate `LootCouncil.HistoryIndex` (id -> array index) side table for
O(1) lookup, plus `LootCouncil.HistoryItemIndex` for same-session re-award
replacement. `UI/LootHistoryWindow.lua`'s sorting, filtering and incremental
index maintenance are all built directly on top of that array shape.
Restructuring it into a dict now would mean rewriting that UI's iteration
logic too - out of scope for "Store v2, migration, permissions," and directly
against the implementation plan's own rule that the history UI "must behave
exactly as before for players who never type a debug command."

**Resolution:** `Data/Store.lua` layers on top of the existing array +
`HistoryIndex`/`HistoryItemIndex` for rows, via the existing
`LootCouncil.AddHistoryEntry`/`RemoveHistoryEntry`, rather than owning a
`rows` dict of its own. Tombstones and pins have no prior storage at all, so
those genuinely are new dicts-by-id: `FL.DB.lootCouncil.tombstones` and
`FL.DB.lootCouncil.pins`. `FL.DB.lootCouncil` also had no `schema` field at
all before this phase (never versioned); it's treated as implicitly schema 1
and migrated to schema 2 in place.

A direct consequence: `Data/Store.lua`'s `Init()` (the schema migration) must
run *after* `LootCouncil.Init()` (which creates `FL.DB.lootCouncil` and
aliases `LootCouncil.History`/`HistoryIndex`), and `Sync/Live.lua`'s `Init()`
(which registers new actions into `LootCouncil.CommActions`) must run after
both. Unlike Phase 0's foundational modules, Store/Live are therefore
inserted into `Core/Init.lua`'s `PLAYER_LOGIN` module list *after* the
`LootCouncil` entry, not at the top - see that file's comment. The files
themselves still load early in the TOC (right after Phase 0's Sync files),
since none of their *file-load-time* code touches `FL.LootCouncil` - only
their `Init()` functions and runtime calls do, both of which happen well
after every file has loaded.

## Phase 1: id format and "delete" are not what the spec guessed

Two more corrections, from reading the actual award code rather than
guessing from the row shape alone:

- **Id format.** Spec section 3.5 guesses ids look like
  `<leader name>-<realm>-<sessionId>-<itemSession>-<n>` (5 hyphen-joined
  parts). The real format, from `LootCouncil.RecordHistory`, is
  `<initiatorFqn, lowercased, spaces stripped>-<sessionId>-<itemSession>-<awardSeq>`
  (4 parts) - `Util.playerFqn()` already returns a single realm-qualified
  string, so there's no separately-addressable realm segment to encode. This
  doesn't require any code change (ids are already globally unique and
  byte-identical per spec section 3.5's actual requirement); it only
  corrects the spec's documentation of the existing format for whichever
  later phase reads section 3.5 expecting 5 parts (e.g. the id-encoding work
  in spec section 4.6).
- **No prior delete broadcast.** The spec assumes officer-gated deletes are
  an upgrade to an existing (if permission-less) delete feature. The History
  UI's delete affordance (lock button + per-row trash icon) did already
  exist, but it was 100% local - no broadcast of any kind, confirmed by the
  full list of `LootCouncil.CommActions` entries before this phase. Phase 1
  adds an entirely new wire action (`historyDelete`, plus `historyPin` for
  the Phase 3 pin feature) on the existing `ForeverLootLC` prefix, modeled on
  `applyAward`'s existing "never trust the sender's own claim" pattern - see
  `Sync/Live.lua`.

  (Superseded in Phase 2 - see "Live.Delete/Live.Pin move off `ForeverLootLC`"
  below. `historyDelete`/`historyPin` are gone; this entry is kept for the
  history of why Phase 1 built them that way.)

## Phase 2: id encoding (spec 4.6) - parse from the right, no separate realm field

Spec section 4.6 encodes an id as `{playerIdx, realm, a, b, c}`, matched
against the id pattern `^([^%-]+)%-([^%-]+)%-(%d+)%-(%d+)%-(%d+)$` (5
hyphen-separated parts: name, realm, then three numbers). Phase 1's id-format
correction (above) already established there's no separately-addressable
realm segment in the real id - `Util.playerFqn()`'s own `name .. "-" ..
realm` hyphen is baked into one opaque prefix before `LootCouncil.RecordHistory`
ever sees it, indistinguishable at the string level from the id's own
segment-delimiter hyphens the moment a realm name itself contains a hyphen
(e.g. "Area-52": `zerpygrape-area-52-6-1-9` has six hyphen-separated tokens,
not five, and the spec's naive left-to-right regex misparses it).

**Resolution:** `Net/Codec.lua`'s `EncodeId`/`DecodeId` parse from the
**right** instead: `^(.-)%-(%d+)%-(%d+)%-(%d+)$` captures the three trailing
numeric segments (sessionId, itemSession, awardSeq) and treats everything
before them - however many hyphens it contains - as one opaque leader
prefix. That prefix is then verified byte-for-byte against
`(compact(awardedBy) .. "-" .. realm):lower()`, computed from the row's own
`awardedBy` field rather than a second dictionary-only "leader" concept -
`LootCouncil.RecordHistory` always sets a row's `awardedBy` to the session
leader's name (confirmed by reading both call sites: the leader's own
`AwardItem`/`DisenchantItem` pass their own stripped name, and `applyAward`
passes `Message.senderName`, which it already validated equals
`Session.initiatorFqn`), so the same player-dictionary index already used
for the row's `awardedBy` field doubles as the id's leader reference - no
separate roster lookup needed. The existing round-trip guard (spec 4.6:
"the encoder always checks decodeId(encodeId(id)) == id") still applies
unchanged, and is what makes this safe even for ids that don't fit the
award-id shape at all (`manual-...`, `zztest-...`): the prefix/leader check
simply fails for those, falling back to the raw id string exactly as the
spec already intends for any id the compact scheme can't represent.

## Phase 2: Live.Award now broadcasts (reversing a Phase 1 decision)

Phase 1's `Sync/Live.lua` and `UI/LootHistoryWindow.lua` both carried a
comment stating "Live.Award never broadcasts by itself" - deliberate at the
time, since Phase 1 kept every broadcast on its *old* wire format and the
existing leader-only "award" council broadcast (`lcSend("award", ...)`,
still unchanged as of Phase 2 too) already delivered every award to the raid, with
`LootCouncil.RecordHistory` (called from both the leader's own path and
every other raid member's `applyAward` receive handler) recording history as
a side effect on each client that already has the row.

Phase 2's plan explicitly calls for "awards... sent as LIVE_ROW... on GUILD"
(spec section 7.1: a live broadcast reaches the whole guild, not just the
raid) - and the existing "award" broadcast is GROUP (raid/party)
distribution only, so a guild member who wasn't in the raid never received
it and never will through that path. Something has to add the guild-wide
reach Phase 1 never had a mechanism for.

**Resolution:** `Live.Award` now broadcasts LIVE_ROW, but **only when
`source == "local"`** - i.e. only on the single client that actually
originated the row (the leader's own `AwardItem`/`DisenchantItem` call, or
the manual "Add Entry" dialog), never on `source == "live"` (every other
raid member's `RecordHistory` call, arriving via the unchanged raid-only
"award" broadcast). Broadcasting unconditionally would mean N raid members
each re-broadcasting the same award to the guild the moment they receive it
- harmless for correctness (`Store:Apply` is idempotent) but wasteful. This
matches spec section 7.1's own wording ("their client" broadcasts, singular)
once "their client" is read as "whichever client actually performed the
action," which in this codebase's actual data flow is exactly the rows with
`source == "local"`.

## Phase 2: Live.Delete/Live.Pin move off `ForeverLootLC`

Phase 1's `historyDelete`/`historyPin` wire actions (see that phase's own
entry above) went out through `LootCouncil.Send`, i.e. on `ForeverLootLC`
with `channel = "GROUP"` - the same raid/party-only distribution every other
council message uses. That was always going to need replacing once the real
wire format arrived (the plan's Phase 2 build list says so explicitly:
"Remove the old history broadcast"), but it's also a correctness fix in its
own right: a delete/pin, like an award, needs to reach the whole guild (spec
goal: "Deletes propagate... eventually reaches every client"), not just
whoever happened to be in the raid at the time. `Live.Delete`/`Live.Pin` now
broadcast LIVE_DEL/LIVE_PIN through `Net/Transport.lua` on GUILD distribution
instead. The now-unused `LootCouncil.Send` public wrapper (added in Phase 1
specifically for this) was removed rather than left as dead code.

## Phase 2: Net/Transport.lua's `Send` takes an encoded string, not a body table

Spec section 12.2's module table describes `Transport.Send(type, body, dist,
target, {prio, lane, onSent})` - "body" reads as the raw positional message
table, implying Transport itself would call into `Codec` to encode it.

**Resolution:** `Transport.Send` instead takes an **already Codec-encoded
string**. Encoding - and the "`[CODEC] encode ...`" debug line, which needs
message-specific details (`rows=`, `players=`, `resp=`, `marks=`) that only
the caller knows - stays in `Net/Codec.lua` and whichever module builds a
given message type's body (`Sync/Live.lua` today; `Sync/Session.lua` from
Phase 5). `Transport` only decodes the generic envelope (`PROTO_VERSION` +
message type, via `Codec.DecodeMessage`) to pick a handler to dispatch
to - it has no way to know what a `ROWS` batch's body means vs a `LIVE_ROW`'s,
so it was never going to be able to own that debug line regardless of
`Send`'s exact signature.

## Phase 2: GUILD-distribution addon messages don't relay on this server - WHISPER fan-out workaround

**Status: open, workaround in place.** This is the one Phase 2 item that
isn't really "done," just unblocked - read this whole section before
touching `Net/Transport.lua`'s `Send` or `Sync/Live.lua` again.

### What we observed, in the order we found it

In-game testing (two clients, A and B, confirmed same guild AND same group)
found `LIVE_ROW` never reached B, despite A showing a full, clean send:

```
FL [CODEC] encode type=LIVE_ROW rows=1 players=2 resp=2 ser=146B cmp=133B enc=133B t=0.8ms
FL [COMM] send type=LIVE_ROW dist=GUILD prefix=FLoot prio=ALERT bytes=133 chunks=1
FL [COMM] sent type=LIVE_ROW bytes=133 dur=0.0s
FL [LIVE] out LIVE_ROW id=... queued=no
```

B showed **nothing at all** for that message, even with `/fl debug cat COMM
on` and `/fl debug level 2` set beforehand - not a self-filter trace, not a
CODEC reject, nothing. Steps taken to isolate it, each ruling out one layer:

1. **Stale build on B?** Ruled out - same computer, same files, confirmed
   identical to A's.
2. **B not really in the guild?** Ruled out - `/fl sync status`'s `perm:`
   line showed `rank=4` on B (a real, resolved `GetGuildRosterInfo` rank,
   not `nil`), so the guild-roster cache (`Sync/Permissions.lua`) has B
   correctly as a member.
3. **Does ANY addon-comm reach B at all?** Yes - the existing (Phase
   1-unchanged) raid-only "award" council broadcast reaches B fine (confirmed
   by both clients already having the award in their history before any of
   this debugging started), so `CHAT_MSG_ADDON` reception itself works on B.
4. **Is it specifically the distribution type?** Confirmed yes - temporarily
   changing `Sync/Live.lua`'s `Transport.Send` calls from `"GUILD"` to
   `Util.GroupDistribution("GROUP", nil)` (i.e. `"PARTY"`, since A/B were
   partied not raided) made `LIVE_ROW` arrive on B immediately and decode/apply
   cleanly:
   ```
   FL [COMM] recv type=LIVE_ROW from="Zc Grape" dist=PARTY bytes=133
   FL [CODEC] decode type=LIVE_ROW from="Zc Grape" ok=1 rejected=0 t=0.1ms
   FL [LIVE] in LIVE_ROW id=... from="Zc Grape" result=added
   ```
5. **Is the GUILD send itself actually failing, just silently?** This is
   where it got interesting. A's own "`[COMM] sent ... dur=0.0s`" line
   claims success, but that confirmation turned out to be **unconditionally
   fired regardless of outcome** - a real, separate bug: the bundled
   `AceComm-3.0`'s `SendCommMessage` builds its `onSent` callback assuming
   `ChatThrottleLib` calls back with the OLD 2-arg progress-style signature
   `(sent, total)`. This bundled `ChatThrottleLib` (`CTL_VERSION = 32`,
   `Libs/AceComm-3.0/ChatThrottleLib.lua`) actually calls back with a
   NEWER, different 3-arg result-style signature,
   `(callbackArg, didSend, sendResult)` (see `SendAddonMessageInternal` and
   `Despool`, both around line ~400-430 of that file). Because of the
   mismatch, AceComm's shim ends up binding its own `sent`/`total` locals to
   the SAME constant (the message's own byte length) no matter what, so
   `sent >= total` is always true and the real `didSend`/`sendResult`
   values are silently dropped. This matches spec section 9.1's own warning
   almost exactly ("the bundled AceComm and ChatThrottleLib must be recent
   enough to understand the... result codes... older copies drop messages");
   here it's closer to a version SKEW between the two bundled libraries than
   either one being simply "too old."

   To get the real result, `/fl debug rawsend` (a small permanent diagnostic
   command added to `Sync/Debug.lua` for this) calls
   `C_ChatInfo.SendAddonMessage` directly, bypassing AceComm/CTL's callback
   entirely:
   ```
   rawsend GUILD: ok=true result=0
   rawsend PARTY: ok=true result=0
   ```
   Both report `result=0` (`SendAddonMessageResult.Success`, per
   `ChatThrottleLib.lua`'s own enum). So the client-to-server send itself
   genuinely succeeds for GUILD, identically to PARTY - this is NOT a
   send-side error, and it is NOT priority/throttle related (lowering
   `ALERT` to `NORMAL`/`BULK` was considered and ruled out on this basis -
   priority only affects client-side queueing/pacing *before* a message is
   sent; it has no bearing on what the server does with it afterward).

### Conclusion

Put together: A's client successfully hands the GUILD-distribution message
to the server (`result=0`, confirmed via the raw API), but the server never
relays it to other guild members (B never receives it, on any debug level).
This is a **server-side GUILD-channel addon-message relay limitation on this
WoW Forever server** - not a bug in this addon's Lua, not a library-version
issue in the way "lowering priority" would fix, and not something that was
previously assumed to be a risk (the spec treats GUILD distribution as a
given throughout).

### What's in place now (the workaround)

`Net/Transport.lua`'s `Send` rewrites any `dist == "GUILD"` call (with no
explicit `target`) into one `"WHISPER"` per currently-online guild member
(`guildMemberNames()`, built from `GetNumGuildMembers`/`GetGuildRosterInfo`'s
`isOnline` field). Every call site (`Sync/Live.lua`'s `broadcastLiveRow`/
`broadcastLiveMark`) still asks for `"GUILD"` exactly as the spec describes
and has no idea this is happening - the whole workaround is contained in
`Transport.Send`, so finding and removing it later is a one-file change (see
that file's own header comment, marked "TEMPORARY WORKAROUND").

### What's still open, for whoever (probably future-you) picks this back up

1. **Ask whoever runs/knows this server** whether GUILD-channel addon-message
   relay is a known, fixable gap. If it gets fixed server-side, this entire
   workaround (the `dist == "GUILD"` branch in `Transport.Send`,
   `guildMemberNames()`) can just be deleted and every call site goes back to
   a real one-message GUILD broadcast with zero other changes needed.
2. **Resolved in Phase 4:** `Sync/Peers.lua`'s `HELLO`/`HELLO_ACK` sends go
   through `Transport.Send(..., "GUILD", nil, ...)` exactly like `LIVE_*`
   does, with no Peers-side knowledge of the fan-out - it inherits the same
   per-online-member WHISPER workaround for free, confirmed working in
   Phase 4's own two-client discovery checklist. The bandwidth-cost caveat
   in point 3 below still applies to `HELLO` traffic too, now that it's a
   second message type riding this same workaround - a periodic `HELLO`
   every ~12 minutes is one more `n`-WHISPER fan-out on top of whatever
   `LIVE_*` traffic is happening, not yet separately measured.
3. **Bandwidth cost isn't free:** this is `n` WHISPERs instead of 1 GUILD
   broadcast, `n` = online guild member count. Fine for small-scale testing;
   needs real measurement (or a different fix entirely) before Phase 8's
   "release to 3-5 guild members for a week" soak test, and especially
   before a full guild rollout - spec section 9's throughput budget was
   written assuming single broadcasts, not O(n) fan-out.
4. **The AceComm/ChatThrottleLib callback-signature mismatch (step 5 above)
   is a real bug independent of the GUILD issue** and still needs a proper
   fix - it wasn't the cause here (the real send result was genuinely
   success both times), but it means `Transport.Send`'s `onSent` and
   "`[COMM] sent ...`" confirmation line currently cannot be trusted to mean
   "the send actually succeeded," only "ChatThrottleLib finished attempting
   it." This is fine for Phase 2 (nothing depends on `onSent` yet) but WILL
   matter for Phase 5's backpressure (spec 9.2: "a sender queues its next
   batch only when AceComm's progress callback reports the previous batch
   fully sent") - a silently-failed send would look identical to a
   successful one right now, which could stall or silently drop a sync
   session's batches. Needs fixing (e.g. a corrected local `ctlCallback`
   that matches this bundled CTL's real signature, or bypassing AceComm's
   `SendCommMessage` callback path for a direct `ChatThrottleLib` call with
   the right signature) before Phase 5 is built, not after.
5. `/fl debug rawsend` (temporary diagnostic command, `Sync/Debug.lua`) is
   still in place - harmless to leave, useful if this needs re-testing
   later (e.g. after asking the server operator, or if GUILD relay starts
   working after a server-side fix/restart).

## Phase 3: `Store:Apply`'s expiry reject exempts test ids

Spec section 3.4's apply rule 2 is unconditional: "ignore \[a row\] if ...
`rowTime < cutoff` and X is not pinned" - no carve-out for test data. Taken
literally, once `Retention.IsExpired` stops being Phase 1/2's always-`false`
stub and starts actually comparing against the real cutoff, this rule would
reject every row `/fl debug gen <n> old` creates, since that command's
entire purpose (this same implementation plan, Phase 3's build list) is to
fabricate rows already 5-6 months old - deliberately past the 4-month
default retention window - so `/fl debug prunedry` and `Retention.Prune()`
have something to report/remove without waiting for real rows to actually
age for months. Applied literally, the expiry rule makes that tool
generate zero rows, which breaks the phase's own stated test flow (the
checklist's step "`gen 40 old`, `prunedry`. Expect `test=40`" could never
pass).

**Resolution:** `Data/Store.lua`'s `applyRow` skips the expiry reject for
ids matching the existing `zztest-` test-id pattern (`Store.IsTestId`),
leaving it in place unchanged for every real row. This only affects
whether a test row can be *created* in the first place; once stored, an
expired unpinned test row is classified and pruned exactly like a real one
(`Data/Digest.lua`'s `classifyRow` and `Data/Retention.lua`'s `Prune`/
`PruneDry` make no kind-of-id distinction beyond what's needed for
"test ids are always actually removed, real ids only when `PRUNE_REAL`").
The real protection spec 10.4 describes - a client offline for months
can't resurrect already-pruned data by logging in with stale rows - is
about genuine stale REAL data reaching other clients, which this exemption
doesn't touch: test rows never leave a tester's own client in the first
place (`Store.IsTestId` + test-data-mode gating on every receive path, plus
the existing `zztest-` reject-unless-tester guard right above this one).

## Phase 4: domains register from `Init()`, not "at load"

Spec 7.7's "Adding another domain" step 3 says "Register the domain at load
with `Domains.Register`." Taken literally, that means calling
`Domains.Register` from a domain file's raw top-level code, executed as
WoW parses the file - before `PLAYER_LOGIN`, before any module's `Init()`
runs.

`Domains.Register` logs a `[DOMAIN] register ...` line through
`Sync/Debug.lua`, which reads `FL.DB.debug`. `FL.DB` itself is only created
by `Core/Init.lua`'s `ADDON_LOADED` handler - which fires once, after every
one of this addon's TOC-listed files has already finished executing its
top-level code. So a literal "at load" `Domains.Register` call would index
a nil `FL.DB` and error, for every domain, forever.

**Resolution:** `Data/HistoryDomain.lua` calls `Domains.Register` from its
own `HistoryDomain.Init()`, run through `Core/Init.lua`'s normal
`PLAYER_LOGIN` module list (after `Debug.Init()`, so `FL.DB.debug` already
exists). The Phase 7 council-session domain should follow the same
pattern - register from its own `Init()`, not from file-scope.

## Phase 4: `Sync/Peers.lua`'s `SendHello`/`CollectResponders` collapse into `Discover`

Spec 12.2's module table lists `Peers`' public API as `SendHello(urgent)`,
`CollectResponders(window, cb)`, `KnownPeerCount()`, `HeardMatchingRoot(since)`.
Taken literally, `Sync/Coordinator.lua` would call `SendHello` then
`CollectResponders` as two separate steps for every trigger (login,
periodic, instance-exit, forced), and would own the "no responders -> retry
with urgent, up to 3 times" loop (spec 7.2 step 5) itself, re-implementing
it at every call site.

**Resolution:** `SendHello` and `CollectResponders` are kept as *local*
(non-public) helpers inside one public entry point, `Peers.Discover(scope,
trigger, cb)`, which owns the send + collect + retry-with-urgent loop as a
single unit - every trigger in `Sync/Coordinator.lua` (and
`Domains.NotifyChanged`, for a future domain) just calls `Discover` once
and gets a final `responders` list (possibly empty) in its callback. Same
reasoning as the already-recorded "Phase 2: `Net/Transport.lua`'s `Send`
takes an encoded string" deviation above: match what callers actually need
rather than the spec's abbreviated sketch. `KnownPeerCount` and
`HeardMatchingRoot(scope, since)` are still public exactly as the spec
names them (the latter gained a leading `scope` parameter, since this
codebase's `Peers` already has to track suppression per scope, for the
Phase 7 RAID-scope council domain as well as GUILD).

## Phase 4: HELLO's "free session slots" field is a placeholder

Spec section 6's `HELLO` body includes "free session slots" - how many more
inbound sync sessions this client could currently serve. Real accounting
needs `Sync/Coordinator.lua` to track actually-open inbound sessions, which
don't exist until Phase 5's `Sync/Session.lua` does. `Sync/Peers.lua`'s
`buildHelloBody` sends `Constants.MAX_SERVE` (the configured ceiling, not
the current free count) in that slot for now; nothing reads the field yet
on receive either. Phase 5 should replace the constant with a real
"`MAX_SERVE` minus currently-serving" count once sessions exist to count.

## Phase 5: `/fl debug gen` sliced across frames (found testing Test 4's `gen 500`)

Not a protocol deviation - an implementation-detail fix to the Phase 1 debug
tool `Store.GenerateTestRows`, recorded here because it changed observable
behavior (the `[TEST] gen ...` line's timing) and was found while running
this phase's own in-game checklist.

`/fl debug gen 500` (the plan's own Phase 5 Test 4 step, "Gate abort and
recovery") crashed with WoW's "script ran too long" error on a Classic
client, inside the loop that builds and applies each row. Nothing in that
loop is individually expensive (an `fnv1a` hash, a few table constructions,
one `Store.Apply`), but 500 iterations run as a single uninterrupted
synchronous loop apparently exceeds this client's execution-time budget for
one protected call - more cheaply than the obvious O(n) cost would suggest.

**Resolution:** `GenerateTestRows` now slices its loop across frames via
`Scheduler.Enqueue`, `GEN_ROWS_PER_SLICE = 20` rows at a time - the same
pattern `Data/Retention.lua`'s `Prune()` already uses for its own removal
loop (200 rows/frame there; 20 chosen here with more safety margin, since
each row generated does more work per item than a prune's removal does).
The final `[TEST] gen n=500 from=... to=... t=...ms` line is unchanged in
shape; `t=` now sums each slice's own profiled time rather than one
continuous span, so it still means "how much real work this took" despite
now spanning several real-world frames.

## Phase 5: per-target send serialization

Not a protocol deviation - a transport-layer bug fix in `Net/Transport.lua`,
found while diagnosing why batching `DAYS` (the entry directly above this
one) didn't actually fix the decode failures it was meant to fix.

After adding `DAYS` batching, the SAME test (`/fl debug gen 500` then
`forcehello`) started producing **two** decode failures in one attempt -
one `step=decompress`, one `step=deserialize` - instead of one. Splitting
one large message into several smaller ones should strictly reduce failure
risk if the problem were really about raw message size; getting worse
instead pointed somewhere else entirely: `sendFlatBatches` fired its batches
in a tight loop with no gap between them, and - once looked for -
`Sync/Session.lua`'s `advanceBuckets` (up to `BUCKETS_IN_FLIGHT` `HASHES`
sends back-to-back) and `beginCompare` (two `MONTHS` sends back-to-back)
already had the exact same pattern.

The actual mechanism: AceComm-3.0's receive-side multi-chunk reassembly
(`AceComm.multipart_spool`, in `Libs/AceComm-3.0/AceComm-3.0.lua`) is keyed
only by `prefix.."\t"..distribution.."\t"..sender` - there is no per-message
identifier at all. If two multi-chunk messages to the same target on the
same prefix+distribution are ever in flight at once, their chunks land in
the *same* spool slot: `OnReceiveMultipartFirst` unconditionally overwrites
whatever's already there (its own lost-data warning is commented out in the
vendored copy - see that function), and `OnReceiveMultipartNext`/`Last` blindly
append to whatever currently occupies the slot, with no check that it's the
continuation of the same message. So two back-to-back multi-chunk sends
(even on an otherwise-perfectly-reliable connection) can scramble both,
producing exactly the "some but not all bytes survived" corruption pattern
observed (`step=decompress` and `step=deserialize` are both "I got
*something*, but it's not valid" failures - very different from the
earlier, single, total-silence failure from before any batching existed).

**Resolution:** `Transport.Send` now queues per `(prefix, distribution,
target)` key and only starts the next queued send to that key once the
current one's completion is known (`onSent`/`onFail`, or a
`SEND_QUEUE_TIMEOUT` of 10s if neither fires - a send can still be
completely lost, as the original failure mode showed, and the queue must
not stall forever waiting for a callback that'll never come). This fixes
every call site at once - `sendFlatBatches`, `advanceBuckets`,
`beginCompare`, and anything written later - rather than requiring each one
to separately manage its own backpressure. `Sync/Session.lua`'s own
`drainOutgoing` (for `ROWS`/`MARKS`) and `sendFlatBatches` (for `DAYS`/
archive-`MONTHS`) still exist and still matter: they decide *when* a message
is ready to hand to `Transport.Send` and do session-level bookkeeping
(batch numbers, sent/recv counts); this is a lower layer that decides when
it's actually safe to put a given send on the wire, and the two compose
without conflict.

A `resolve(ok)` closure, shared between AceComm's real callback and the
timeout fallback, guards against calling `onSent` AND `onFail` for the same
send if the timeout fires first but AceComm's callback eventually arrives
anyway (just very late) - `resolve` only acts on its first call.

**Follow-up, same investigation:** even with overlapping sends eliminated,
the next test still silently lost exactly one message out of a burst of
three (8 addon-message chunks total, all reported sent with `dur=0.0s` -
ChatThrottleLib believed it had burst budget to send all of them
immediately). No corruption this time, no warning anywhere - the message
just never arrived, the same silent-loss signature as the very first
failure in this whole investigation. ChatThrottleLib's burst/refill model
(burst of 10, refill 1/s) is built around Blizzard's retail throttling
rules; spec section 2 already flags "the exact limits in WoW Forever should
be confirmed during beta" as an open question, and this looks like exactly
that - this server's real tolerance for a tight burst of addon messages may
be lower than what CTL assumes, so CTL sends "on schedule" by its own model
while the server drops the overflow. `Transport.lua`'s send queue now also
waits `SEND_QUEUE_GAP` (0.3s) between items already queued for the same
target, pacing this addon's own traffic more conservatively than CTL's
model calls for - cheap insurance against the exact limit being lower than
CTL assumes, without needing to know what that limit actually is. Only
applies between queued items; a lone send to an otherwise-idle target is
unaffected.

**Second follow-up:** even with both fixes above, a later test run (one that
otherwise worked very well - 27 of 55 buckets reconciled cleanly, batching/
serialization/pacing clearly doing their job) still lost exactly one bulk
`ROWS` message outright (2 chunks, logged as sent successfully by the
sender, zero trace on the receiver). This confirms a genuine non-zero
baseline message-loss rate on this server that no amount of pacing or
serialization on our end will ever fully eliminate - at some point this
becomes a question for whoever runs/maintains "WoW Forever" (same
unresolved category as the Phase 2 GUILD-relay finding), not something
fixable purely in this addon's Lua.

Given that, the more valuable fix turned out to be architectural rather than
transport-level: a single lost message shouldn't be allowed to waste an
entire session's worth of otherwise-successful work. `Sync/Session.lua` now
retries a bucket's own `WANT` (see `WANT_RETRY_DELAY`/`WANT_RETRY_MAX`,
`scheduleWantRetry`) if that bucket's data hasn't arrived after 8s, instead
of only the whole session timing out after 45s. This is safe because
re-answering a `WANT` it already answered is a harmless no-op on the
responder's side (`Store.Apply`'s own idempotency). **Known gap, not yet
fixed:** the mirror case - a bucket's `HASHES` (or a server's `HASHES`
reply) itself getting lost, before either side has even agreed on a `WANT`
to retry - isn't covered the same way. A naive "always re-reply to any
incoming HASHES for a bucket I've already answered" fix was considered and
rejected: since both sides already send `HASHES` to each other symmetrically
for every bucket, an unconditional "reply to every HASHES, even a repeat"
rule risks a ping-pong loop between the two clients that never terminates.
A correct fix needs a real retry-vs-first-contact distinction (e.g. a
sequence number or explicit retry flag on `HASHES` itself) that wasn't
implemented under time pressure - only the confirmed, observed failure
(a `WANT`'s response going missing) was fixed this session.

**Third follow-up, same investigation:** the very next test still failed -
this time on the FIRST message of an otherwise completely uncontended fresh
session (just `MONTHS` sent, then one `DAYS` reply, nothing else queued,
nothing else competing for bandwidth) - `step=deserialize` this time
(decompress succeeded; the decompressed bytes weren't valid serialized data).
This rules out cross-message collision (nothing else was in flight) and
rules out burst/throttle pressure (this was the very first send of the
session). It confirms a genuine baseline per-chunk loss rate on this server,
independent of anything this addon's send-side pacing can address - at this
point a question for the server operator, not a client-side bug.

Given that, the fix generalizes what the `WANT` retry already established:
the `COMPARING` phase (the one-time `MONTHS`/`DAYS` exchange at a session's
start) gets the identical treatment. `Sync/Session.lua`'s `beginCompare` now
retries an unanswered `MONTHS` request after `COMPARE_RETRY_DELAY` (8s), up
to `COMPARE_RETRY_MAX` times, exactly mirroring a bucket's own `WANT` retry -
safe because `handleMonthsRequest` is fully stateless per call and simply
recomputes and replies fresh regardless of whether the request was original
or a retry. A retry discards whatever partial reply accumulated from the
failed attempt (`windowReplyFlat`/`windowMismatchedMonths`, or
`archiveReplyFlat`) before resending, so a fresh reply can't get appended
onto stale leftovers from the attempt being retried. **This "accepted residual risk" turned out to be a real, observed bug, not
a rare edge case** - a session finished and reported `done` (with
`rootsMatch=no`) on a bucket list far too small to represent the actual
mismatch (dozens of buckets instead of ~120+ expected for a large backfill
against a nearly-empty peer). The mechanism: a retry's reset of
`windowReplyFlat`/`archiveReplyFlat` isn't enough by itself when the
ORIGINAL attempt's batches weren't actually lost, just delayed past the
8-second retry window (this server's loss-vs-delay behavior isn't reliably
distinguishable from the outside) - a straggler from that original attempt
arriving after the reset gets silently merged into the new attempt's
(otherwise-empty) accumulation, and if that straggler happens to carry
`isLast=true`, the compare phase completes immediately on a wildly
incomplete data set.

**Resolution:** every `MONTHS` request now carries a generation number
(`session.windowGen`/`.archiveGen`, both starting at 1), echoed back
unchanged on every `DAYS`/archive-`MONTHS`-reply batch `handleMonthsRequest`
sends. `scheduleCompareRetry` increments the relevant generation (alongside
its existing reset) on every retry; `onDays`/`onMonths` now check the
incoming batch's `gen` against the session's CURRENT one and silently drop
anything that doesn't match, logging `"stale gen=... current=... - dropped"`
at level 2. This is the same idea `HASHES`/`WANT`'s `tree,key` tagging
already uses to disambiguate concurrent buckets, extended with a generation
counter so a RETRIED request's replies can be told apart from the attempt
being retried.

**Fourth follow-up, and the actual root cause of the "incomplete sync"
symptom:** generation tagging alone did NOT fix the next test run - a
session reported `done` with a bucket count far too small again, and the
user confirmed the specific gap directly: an entire month (July) was
missing, a contiguous hole between two dates that otherwise synced fine.
That observation makes the real bug obvious in hindsight, and it has
NOTHING to do with retries or generations: `isLast` is a boolean that only
describes the FINAL batch in a sequence. If a MIDDLE batch is lost (not the
retry-vs-fresh-attempt staleness problem above - just ordinary loss, in a
single attempt, no retry involved at all) while the batch marked `isLast`
still arrives, the receiver sees `isLast == true`, declares the whole
transfer complete, and never notices the gap. This can happen on the very
first, only attempt of a session - no retry, no concurrent messages,
nothing exotic required - which is exactly what makes it worse than every
earlier failure mode in this investigation: those all either aborted
loudly (a decode warning, a session timeout) or got caught by a later fix;
this one produces a clean `done` line and a digest that looks plausible
while silently missing real data.

**Resolution:** every batched message - `DAYS`, the archive-tier `MONTHS`
reply, and (the same flaw existed here too, just not yet observed) `ROWS`
and `MARKS` - now tags itself with `batchIndex, totalBatches` instead of a
single `isLast` boolean. The receiver (`onDays`, the opener branch of
`onMonths`, and `onRowsOrMarks`) tracks every index it has actually
received in a set and only treats the transfer as complete once that set's
size equals `totalBatches` - i.e., it waits for ALL of them, not just
whichever one happens to carry the highest index. `Util.tcount` (already
used elsewhere in this codebase) counts the set regardless of arrival
order. This is a strictly stronger completion check than `isLast` ever
was, independent of and complementary to the generation tagging above
(generations reject a STALE batch from an old attempt; batch-index tracking
detects a MISSING batch from the current one - both are needed, neither
alone is sufficient).

## Phase 5: `Sync/Session.lua`'s wire format extends spec section 6's catalog

Spec section 6 describes `HASHES`, `WANT`, `ROWS` and `MARKS` in the
abbreviated form the rest of the spec uses throughout ("token, bucket key,
list of..." etc.) - close enough to build from for a single bucket in
isolation, but under-specified once `BUCKETS_IN_FLIGHT` (3, per spec 7.3
step 5) means several buckets are being reconciled through the same session
token at once, or once a bucket genuinely needs the spec's own 5.6 fallback.
`Sync/Session.lua`'s own header comment has the full list; summarized here:

- **`HASHES`/`WANT` carry an explicit `tree, key` pair.** The spec's body
  ("token, bucket key, list of hashes") already implies *a* bucket
  reference, just not which tree - needed because window buckets (day keys)
  and archive buckets (month keys) are both just integers, so a WANT with a
  bucket key alone is ambiguous once both trees are being reconciled in the
  same session (spec 7.3 step 2: archive is only compared when its root
  differs, but when it does, its one mismatched-month "bucket" and a
  window day bucket could legitimately share the same integer key).
- **`HASHES`/`WANT` carry an `idMode` flag.** Spec 5.6's collision fallback
  ("that bucket falls back to exchanging full ids") is implemented as a
  per-message boolean rather than a renegotiated bucket: whichever side's
  own `Digest.HasCollision(tree,key)` is true for that bucket sends raw
  `"kind:id"` strings instead of 32-bit hashes for that one exchange, and
  flags it. The two directions of one bucket's exchange decide this
  independently (each side only knows about collisions in its OWN copy of
  the bucket) - if the two sides disagree (one has a collision, the other
  doesn't), the comparison silently degrades to "both sides send
  everything" for that one bucket, which is still correct (duplicate
  entries are a no-op in `Store:Apply`) just not bandwidth-optimal. Given
  how rare an actual 32-bit collision is at this addon's scale, this
  corner case is accepted rather than solved with a negotiation round trip.
- **`DAYS` carries the server's own `mismatchedMonths` key list** alongside
  its day aggregates, and the archive-tier `MONTHS` reply always lists one
  entry per mismatched month - including months where the SERVER'S side is
  completely empty. Without this, a month that mismatches only because one
  side has zero entries in it (the other side has some) would contribute
  nothing to that reply's flat list at all (an empty bucket is never stored,
  so it never appears), leaving the opener with no way to learn that month
  needed reconciling in the first place.
- **`ROWS`/`MARKS` append `tree, key, isLast`** after their spec-listed
  fields, so the receiver knows which bucket's `WANT` a batch answers and
  when that bucket's transfer is complete (there is no dedicated
  "want satisfied" message in spec section 6's catalog). Spec 4.7's
  forward-compatibility rule - "new row fields may only be appended... older
  decoders ignore trailing fields" - is written about a single row's own
  fields, but the same reasoning applies to the enclosing batch envelope.
  `MARKS` also gains a `batchNum` field (spec only gives `ROWS` one) at the
  same wire position, so the receiver's "batch in #N" line can read it
  identically regardless of which kind arrived - one shared session-wide
  counter numbers every outgoing batch, `ROWS` or `MARKS` alike.
- **`DAYS` and the archive-tier `MONTHS` reply are capped at
  `DAYS_BATCH_SIZE` (40) tuples per message**, sent as however many messages
  that takes, each tagged `isLast` - the opener accumulates them until the
  last one arrives. Found necessary live-testing Test 4 ("Gate abort and
  recovery", `/fl debug gen 500`): a single `DAYS` reply covering every day
  of several mismatched months (100+ day-entries, several KB before
  compression) **reliably** failed with `[CODEC] WARN decode fail ...
  step=decompress` on the receiving client - reproduced identically twice in
  a row on the same payload, which rules out ordinary random packet loss (a
  genuinely random loss wouldn't fail the exact same way every time) and
  points to this server being unable to deliver an addon message past some
  size/chunk-count threshold intact. A comparably-sized `ROWS`/`MARKS`
  transfer in an earlier test *did* succeed (after one retry), which is
  consistent with `ROWS`/`MARKS` already being capped small by
  `BATCH_ROW_CHUNK` (spec 9.2's own batching principle) while `DAYS` had no
  such cap at all - its size scaled directly with how large the mismatch
  was, with nothing stopping a big backfill from producing a single
  enormous message. Giving `DAYS`/archive-`MONTHS` the same discipline
  `ROWS`/`MARKS` already has removes the class of payload that triggered
  this, regardless of the server's exact internal limit.
- **`WANT` is always sent in reply to `HASHES`, even with an empty list.**
  Found while implementing the bucket-completion check: if a side only sends
  `WANT` when it's actually missing something, "no `WANT` has arrived for
  this bucket yet" and "the peer looked and wants nothing from me" become
  indistinguishable to the other side (both leave its own give-count sitting
  at the same default zero). That ambiguity would let a bucket - and on the
  opener, potentially the whole session - finish and send `DONE` before a
  slower peer's real `WANT` and the data it's asking for ever arrive.
  Sending an explicit empty `WANT` turns "I want nothing" into a real,
  received fact instead of an absence that looks the same as "not yet."
- **Batch sizing uses a row-count heuristic (`BATCH_ROW_CHUNK = 40`), not a
  live byte-size check against `BATCH_TARGET_BYTES`.** Spec 9.2's own worked
  example ("about 4KB serialized... roughly a 40-row batch") is close enough
  to this addon's actual row sizes (spec 4.8's ~165-300B/row estimate after
  encoding) that re-serializing after every row just to measure size wasn't
  worth the added complexity for Phase 5. Revisit if Phase 6/8's real
  measurements (plan's own "paste the `avgRow`/`batch` sizes" step) show
  this heuristic is off by enough to matter.
- **`rootsMatch` on the `done` line is a loose comparison**, exactly as the
  plan's own text allows ("not an error... must turn into a match by the
  next periodic check"): the opener compares its own fresh root against the
  peer's root as captured from `HELLO_ACK` at discovery time (not a live
  re-query), and the server compares against a root it reconstructs by
  rolling up the opener's own initial `MONTHS` request body. Both are
  "best known at the time," not an authoritative live cross-check.
- **`BUSY_RETRY_AFTER = 60` (seconds)** for an `OPEN_REPLY` refusal is a
  plain local constant in `Sync/Session.lua`, not a `Sync/Constants.lua`
  entry - spec section 13's table has no tunable for this, and the plan's
  own sample line uses this exact value, so it's used directly rather than
  invented as a new guild-wide constant.

## Phase 5: `Net/Transport.lua`'s `onSent`/`onFail` fix (closing the Phase 2 TODO)

The Phase 2 "GUILD-distribution... WHISPER fan-out workaround" entry above
flagged a second, independent bug as something that "needs fixing... before
Phase 5 is built": AceComm-3.0's `SendCommMessage` callback is invoked as
`(callbackArg, sent, total, didSend)`, but `Net/Transport.lua`'s `sendOne`
only declared `function(_, sent, total)`, silently dropping the real
`didSend` boolean and relying on `sent >= total` alone - which, per that
investigation, is true on every call regardless of actual send outcome.

**Resolution:** `sendOne` now reads the 4th argument and only treats a
message as truly sent (firing `opts.onSent`, logging `"[COMM] sent..."`)
when no chunk reported `didSend == false`; otherwise it fires a new
`opts.onFail` and logs a `WARN`. No vendored library file needed editing -
this is exactly the "corrected local ctlCallback" option that entry's point
4 already named, just implemented as reading AceComm's existing (if
poorly-documented) 4th callback argument rather than writing a replacement
callback. This is what makes `Sync/Session.lua`'s batch backpressure (spec
9.2: "a sender queues its next batch only when the previous batch's `onSent`
fires") trustworthy.

## Phase 6: secondaries, multi-prefix concurrency, and their instrumentation

Phase 6 (spec 7.4, 9.2) adds parallel pull from up to `MAX_SECONDARIES`
secondaries and real multi-batch-in-flight throughput within one session.
Everything below lives in `Sync/Session.lua` unless noted; see that file's
own Phase 6 header section for the short version.

### The round-robin split happens in `Session.lua`, not `Coordinator.lua`

Spec 7.4 step 1 ("the opener assigns mismatched buckets round-robin... across
the primary and the secondaries") reads as something `Sync/Coordinator.lua`
could do at the same time it picks the primary (spec 7.2 step 4) - both
happen right after discovery collects responders, before any session even
exists.

In practice the two can't happen together: nobody knows which buckets
actually mismatch until the primary's own `COMPARING` phase (spec 7.3 step
3-4) finishes, which happens well after `Coordinator.lua`'s one-shot
`planDomain` call has already returned. **Resolution:** `Coordinator.lua`
only selects WHO the candidates are (primary + up to `MAX_SECONDARIES`
secondary names, unchanged logic from Phase 5) and passes the secondary list
straight through to `Session.Open`. The actual split
(`assignBucketsWithSecondaries`) runs inside `Session.lua`'s
`tryFinishCompare`, the one place that has the real bucket list, and is also
where the spec's own sample debug line ("plan d1 primary=... secondaries=[...]
assign B=4 C=3 D=3") gets logged - `Coordinator.lua` no longer logs its own
version of that line at all, since logging it before the counts are known
would just be a second, strictly-worse line.

### The primary's full session keeps the WHOLE bucket list, not its own share

Spec 7.4 step 3 is easy to misread as "the primary only handles its own
round-robin share." Taken that way, the primary's full-mode session would
shrink its own `bucketQueue` to just its share, same as every secondary's
pull session gets its own share. That's wrong: the step's actual text is
"the primary session still handles the push direction for EVERY bucket" -
the primary must still learn what IT is missing from the opener for every
single mismatched bucket (that's the push direction, unrelated to who's
pulling what), which requires a real HASHES exchange for every bucket, not
just the ones round-robined to it.

**Resolution:** `assignBucketsWithSecondaries` leaves `session.bucketQueue`
as the FULL list (same list `tryFinishCompare` always built), and only
annotates the entries delegated to a secondary with `.delegatedTo`. The
primary's own `advanceBuckets`/`onHashesReceived` therefore still runs a real
HASHES exchange for every bucket (so the primary's own want - push
direction - still resolves normally), but a delegated bucket's OWN want (the
opener pulling that bucket's data FROM the primary) is forced to an empty
WANT instead of a real diff (`skipWant` in `onHashesReceived` - see below).

### `skipWant`: one mechanism for two different "don't actually request this" cases

Two unrelated situations both reduce to "compute WANT as if nothing were
missing, regardless of the real diff":

1. A bucket on the primary's own full session that's been delegated to a
   secondary (above) - the opener still needs the primary's real HASHES list
   (saved for a possible later reassignment, see below) but deliberately
   doesn't want to pull this bucket's data from here.
2. A pull-mode SERVER (a secondary, answering an opener's assigned buckets) -
   spec 6's own notes already say "a secondary never requests data from the
   opener," so its own want side is never used at all, for any bucket, by
   definition of the mode.

Both end up sending an empty (not skipped - spec's own "WANT is always sent,
even empty" rule from Phase 5 still applies) WANT. Rather than two separate
code paths, `onHashesReceived` computes one `skipWant` boolean covering both
cases and always runs the same "send a WANT, real or forced-empty" tail.

### `maybeFinishBucket`'s completion condition splits by mode, not just role

Full mode's completion condition (`wantDone AND giveDone`, from Phase 5)
assumes data moves BOTH ways through every bucket. Pull mode only moves data
one way (opener pulls, server only gives - spec 6's own notes again) - so
checking both halves in pull mode would permanently block on whichever half
never happens (the opener's `giveDone`, since it's never asked for anything
by a pull-mode server; the server's `wantDone`, since it never computes a
real want at all). **Resolution:** the finish condition branches on
`session.mode`: full mode keeps the original `wantDone AND giveDone`; pull
mode checks only `wantDone` on the opener side or only `giveDone` on the
server side.

### `OPEN`'s pull-mode body carries `tree,key` pairs, not spec 6's bare "day keys"

Same reasoning as the existing Phase 5 deviation for `HASHES`/`WANT`'s
explicit `tree,key` field: a bare integer key is ambiguous between a window
day bucket and an archive month bucket the moment both trees can be in play
in the same sync, which Phase 6's round-robin split makes routine (a
secondary can easily be assigned a mix of window and archive buckets).
`OPEN`'s pull-mode body (`Sync/Session.lua`'s `openSecondaryPull`) is a flat
`tree,key,tree,key,...` list instead.

### Reassignment reuses the primary's ALREADY-SAVED remote hash list - no second round trip

Spec 7.4 step 4 ("if a secondary aborts or times out, its unfinished buckets
go back to the primary's queue") could be read as literally re-queuing the
bucket keys and letting the primary's normal `advanceBuckets` dequeue loop
pick them up fresh - which would mean a brand new HASHES exchange with the
primary for each one.

That's unnecessary: because the primary's full session already ran a real
HASHES exchange for EVERY bucket up front (the point directly above), the
primary already has the exact remote hash list for a delegated bucket
sitting unused (forced to an empty want). **Resolution:** `onHashesReceived`
now always saves the incoming list in full (`bucket.remoteList`,
`bucket.remoteIdMode`), not just its count, specifically so
`reassignBucketToPrimary` can recompute the REAL want from already-held data
the instant a secondary fails - no new message needed. The bucket's
`.finished`/`.delegated` state is reset and `inFlightCount`/`bucketsDone`
bookkeeping is unwound first if the bucket had already finished (its push
direction resolving independently of pull delegation can legitimately finish
before a reassignment ever happens).

### The primary can't declare itself done until every secondary has reported in

`advanceBuckets`'s finish check (own queue and in-flight both empty) is
Phase 5's entire completion condition for a session with no secondaries. With
secondaries, that's not enough - the primary's own queue can drain long before
a secondary finishes (or needs its leftovers reassigned). **Resolution:** the
same check additionally requires `session.secondariesRemaining <= 0`, which
starts at the number of secondaries that actually got a non-empty bucket
share and is decremented by `reportSecondaryFinished` as each one reports in
(success, abort, timeout, or an outright `OPEN_REPLY` refusal - all go
through the same function). This field is nil for every session that never
had secondaries (every Phase 5 session, and every pull-mode session itself,
which has none of its own), so the check is a no-op there - Phase 5's
behavior is unchanged when Phase 6's round-robin split never triggers (a
lone-primary discovery, or a bucket list too short to give any secondary a
share).

### Multi-prefix concurrency: one batch in flight PER PREFIX, not per session

Phase 5's `drainOutgoing` serialized an entire session to exactly one batch
in flight at a time (`session.sendingBatch`), rotating across
`FLootS1`-`S3` via `Net/Transport.lua`'s shared `lane="sync"` cursor. That
was necessary AT THE TIME because `Transport.lua`'s per-target send
serialization bug (see that file's own Phase 5 entry) hadn't been fixed yet -
but once it was fixed, `Transport.lua`'s queueing is strictly
per-`(prefix,distribution,target)`, meaning two batches to the SAME peer on
DIFFERENT prefixes were always safe to run at once (separate AceComm
multipart-spool slots - that collision is keyed by prefix too). Phase 5 just
never exploited this, rotating prefixes one-at-a-time for pacing only, not
concurrency.

**Resolution:** `drainOutgoing` now tracks up to `#PREFIX_SYNC` batches in
flight per session (`session.prefixBusy`, keyed by prefix), picking the next
free prefix in rotation instead of blocking on a single session-wide flag.
`Net/Transport.lua`'s `Send` gained `opts.prefix` to let the caller pick a
specific prefix directly, bypassing its own `prefixForLane` auto-rotation
(which stays in place, unchanged, for every other caller that just wants
"one of the bulk prefixes" with no concurrency tracking of its own - nothing
else needs more than one in flight).

### Instrumentation deviations

- **`[PERF] rate ...`'s `kbps` is real, not estimated.** Computing it from a
  row-count average (this addon's own ~165-300B/row estimate, spec 4.8)
  would drift from whatever a session's ACTUAL mix of rows/marks/batch
  overhead really cost. Cheaper fix: `Net/Transport.lua`'s handler dispatch
  now passes the real encoded byte length as a 4th argument to every
  registered handler (every OTHER handler ignores it harmlessly - Lua
  doesn't care about extra arguments); `Sync/Session.lua`'s `onRowsOrMarks`
  reads it into `session.recvBytes`, which `logSessionRate` divides by the
  session's own duration.
- **`[COMM] ctl queue ...` reports `Net/Transport.lua`'s OWN send queue, not
  ChatThrottleLib's internal one.** CTL's internal priority queues aren't
  part of its public API and have changed shape across bundled versions
  (the Phase 2 GUILD-relay investigation already found this bundled CTL
  deviates from the "standard" callback signature spec section 9.1 assumes) -
  reaching into its private tables to count queue depth would be fragile and
  version-specific. `Transport.lua`'s own per-(prefix,distribution,target)
  send queue (added in Phase 5) is both safer to read and more directly
  relevant: it's literally the thing Phase 6's multi-prefix concurrency
  change (above) feeds, so "is our own backpressure keeping up" is the more
  useful question to answer anyway. `Transport.QueueSample()` returns counts
  by priority plus how many prefixes currently have a send in flight;
  `Sync/Session.lua` samples it every 10s, only while at least one session is
  open.
- **No distinct `[COMM] WARN throttled ...` detection.** The plan's own debug
  table lists this as a sign of CTL throttling a prefix, but CTL doesn't
  expose a public "I am currently throttling this prefix" signal to detect
  proactively - only the outcome (a chunk's `didSend` coming back false,
  already surfaced by the Phase 5 `onSent`/`onFail` fix as `"[COMM] WARN send
  fail ..."`, now also carrying the prefix). Treated as the same symptom
  rather than inventing a separate, unobservable signal.

## Phase 6: `DONE` could race ahead of still-queued give-data, silently dropping rows

**Found live, in-game, on the first real 2-peer parallel backfill test** (3
accounts, 1500 real-shaped test rows): client C ended up with 1405 rows
instead of 1505 - missing exactly its oldest ~6.5 days, a contiguous block,
not scattered. `/fl sync digest` confirmed a real mismatch (`x`/`s` both
different, not just `n`), ruling out a measurement artifact.

### Diagnosis

The opener's own log for the session in question (`kIGW`, full mode, C as
server) showed the smoking gun directly:

```
[SESS] kIGW bucket 20608 local=11 remote=0 want=0 give=11
[SESS] kIGW done d1 sent=944 recv=0 marks=0 buckets=121 dur=2m55s rootsMatch=no
[COMM] send type=DONE ... target=Foreverloot Dev
[COMM] sent type=ROWS bytes=568 dur=6.9s   <- batch #82, confirmed sent AFTER DONE
[COMM] sent type=ROWS bytes=513 dur=6.9s   <- batch #83, confirmed sent AFTER DONE
```

`onWantReceived`'s own (pre-existing, Phase 5) comment already names the
root cause: a bucket's "give" is marked satisfied the moment its data is
QUEUED into `session.outQueue` ("intent/handoff, not confirmed delivery"),
not once it is actually confirmed sent over the wire. In Phase 5, with only
one batch in flight for the WHOLE session (`session.sendingBatch`), this
distinction rarely mattered in practice - the queue stayed close to empty by
the time a session could plausibly finish, since nothing could queue up
faster than the single in-flight send drained.

Phase 6's multi-prefix concurrency (this same file's `drainOutgoing`
rewrite, up to `#PREFIX_SYNC` batches in flight per session) removed that
accidental pacing. In this run, the last several buckets (20614 down to
20608, all with `remote=0` - C had nothing there yet, so no `WANT`-side
round-trip delay at all) resolved rapidly back-to-back in about 8 seconds,
queuing several buckets' worth of `ROWS` batches far faster than
`BUCKETS_IN_FLIGHT`-many concurrent sends could actually clear them. The
opener's bucket/queue bookkeeping (`inFlightCount == 0 and #bucketQueue ==
0`) hit "nothing left to do" while real data was STILL sitting in
`outQueue` or mid-flight on a prefix, called `finishSessionAsOpener`, which
unconditionally sends `DONE` right away. The moment C received that `DONE`,
it ran `onDone`'s server branch and called `closeSession` - and
`onRowsOrMarks`'s own `session.closed` guard silently dropped every batch
that arrived after that, exactly matching the missing contiguous block (the
oldest buckets, processed last in the newest-first queue).

Why the `WANT` side of the same session didn't have this problem: a
bucket's `wantSatisfied` is only ever set true once `onRowsOrMarks` has
actually seen every index 1..`totalBatches` (confirmed RECEIPT, not merely
"asked for") - the Phase 5 batch-completeness fix already guarantees this.
The asymmetry was specifically that the GIVE side never got the equivalent
guarantee, because Phase 5 never needed one (nothing could race ahead of a
single serialized in-flight batch).

### Resolution

`Sync/Session.lua`'s bucket-queue-draining check
(`session.inFlightCount == 0 and #session.bucketQueue == 0`, previously
followed immediately by `finishSessionAsOpener`) now routes through a new
`trySessionComplete(session)`, which ADDITIONALLY requires
`#session.outQueue == 0` and no prefix currently busy
(`anyPrefixBusy(session)`) before actually finishing. Critically, this
check isn't just run once from `advanceBuckets` - it's also re-run from
`drainOutgoing`'s own `onSent`/`onFail` callbacks, every time a send
actually confirms (success or failure), since THAT send completing might be
the exact thing that was blocking completion. This closes the race: a
session can no longer send `DONE` while anything it still owes the peer is
unconfirmed.

Only affects full-mode sessions (and, in principle, a pull-mode opener that
somehow had something to give - which can't happen, since "a secondary
never requests data from the opener" per spec 6's own notes means a
pull-mode opener's `outQueue` is always empty) - `trySessionComplete` is a
no-op for server-role sessions entirely (they have no `bucketQueue`/
`inFlightCount` concept; they close only on receiving `DONE`, never on their
own initiative, so they were never at risk of this particular race).

## Phase 6: `HELLO_COLLECT_WINDOW` too short for this server's real round trip

**Found live, in-game, while re-testing the fix above.** A fresh client
(C) ran `/fl debug forcehello` repeatedly and got `[PEERS] responders
window=6s got=0 []` every single time, across 6 consecutive attempts (3
non-urgent + the `HELLO_RETRY` loop's own 3 urgent retries) - meaning
`Peers.Discover` gave up every round with zero candidates, even though both
other clients were guild members actively online and running the same
build.

Checking the actual `HELLO_ACK` arrival times against each window close
ruled out ordinary bad luck: BOTH peers answered EVERY single attempt, but
their acks consistently landed 0.5-4s AFTER the 6-second collection window
had already closed - not occasionally, every time, across 6 independent
attempts with fresh random jitter each round. The probability of random
`HELLO_REPLY_JITTER` (0-4s) landing unluckily late that consistently, for
both peers, six times running, is negligible - this is a real, systematic
round-trip time exceeding the window, not variance.

Spec section 13's `HELLO_COLLECT_WINDOW = 6` (and `HELLO_REPLY_JITTER`'s own
0-4s range) are sized assuming near-instant addon-message delivery, typical
of a normal Blizzard realm. "WoW Forever" has shown slower and less
reliable delivery throughout this whole project (the Phase 2 GUILD-relay
finding, the Phase 5 message-loss/corruption investigation, and now this) -
a ~7-10s real round trip (hello out -> peer receives -> jitter delay ->
ack sent -> ack received) is apparently just what this server's addon
message latency looks like, not a defect in the discovery logic itself.

**Resolution:** `Constants.HELLO_COLLECT_WINDOW` raised from 6 to 12
seconds - `HELLO_REPLY_JITTER`'s full 4s range plus real margin for the
kind of delay actually observed (the worst case seen live was +4.16s past
a 6s window, i.e. a ~10.2s round trip). This is a plain constant change,
not a logic change - `Sync/Peers.lua`'s discovery/collection code is
otherwise untouched. Worth revisiting if guild-wide testing later shows
this server's real latency is even higher (or lower) than this one test
session's sample suggests.

## Phase 6: closed the Phase 5 "lost HASHES, no retry" known gap

**Found live, in-game**, via the new `/fl sync window` (built this same
session): a 2-client test showed a session sitting at `buckets 0/46,
sent=0, recv=0` for over 3 minutes with zero outgoing traffic
(`[COMM] ctl queue bulk=0 normal=0 alert=0 prefixesBusy=0` on every 10s
sample) - the opener's initial `HASHES` sends for its first
`BUCKETS_IN_FLIGHT` (3) buckets, right after `COMPARING->RECONCILING`,
simply never got a reply. This is exactly the gap Phase 5's own deviations
entry flagged as accepted-but-unfixed: "a bucket's HASHES (or a server's
HASHES reply) itself getting lost before any WANT exists to retry isn't
covered by a retry." With no mechanism to recover, the session just sat
until `SESSION_IDLE_TIMEOUT` (45s) and aborted - annoying every time it
happened, though it did always recover via the next `HELLO`.

### Why a naive fix was rejected in Phase 5, and what actually closes it

Phase 5's own entry already considered and rejected "always reply to any
incoming `HASHES`, even a repeat" - since both sides send `HASHES`
symmetrically, an unconditional "reply to every one" rule risks a
ping-pong: each side's reply would itself look like "an incoming HASHES"
to the other, triggering ANOTHER reply, forever.

**Resolution:** an explicit `isRetry` flag on the `HASHES` message itself
(same idea as the compare phase's generation tag, or `WANT`'s own
always-reply-even-empty rule) breaks the symmetry safely:

- Only the OPENER schedules retries (`scheduleHashesRetry`, called once
  from `advanceBuckets` right after the bucket's initial
  `sendHashesForBucket` - never from inside `sendHashesForBucket` itself),
  on the same `_DELAY`/`_MAX`-retry shape as `WANT`'s and the compare
  phase's existing retries (8s delay, 3 attempts). The RESPONDER never
  starts a timer of its own.
- `onHashesReceived`'s reactive-reply guard changes from `if not
  bucket.sentHashesOut` to `if not bucket.sentHashesOut or isRetry` - a
  genuinely fresh bucket still replies once as before, but a message
  explicitly flagged `isRetry` forces a FRESH resend of this side's own
  hash list even if it already replied once (covering the case where the
  ORIGINAL exchange partly succeeded - this side's reply went out fine,
  but that reply itself is what got lost, which a plain `sentHashesOut`
  guard would otherwise permanently skip resending).
- Since the RESPONDER only ever reacts to an incoming `isRetry` flag it
  never produces itself, and the OPENER's own retries are capped at
  `HASHES_RETRY_MAX`, the total number of round trips this can ever
  produce is strictly bounded by the opener's own schedule - no path
  exists for the responder to trigger an additional round on its own, so
  the ping-pong case Phase 5 was worried about can't occur.

`sendHashesForBucket` also now clears `bucket.myLookup` on every call
(including a fresh, non-retry one, harmlessly) - `myLookupFor` lazily
caches it off `myEntries`/`myIdMode`, both of which `sendHashesForBucket`
rebuilds from scratch every time it runs, so a stale cached lookup from an
earlier call could otherwise survive a resend.

## Phase 4: addon version string source

Spec section 6 lists "addon version" as a `HELLO`/`HELLO_ACK` field but
never says where it comes from. `Sync/Peers.lua` reads it from the TOC's
`## Version:` line via `C_AddOns.GetAddOnMetadata` (falling back to the
older global `GetAddOnMetadata` if that namespace doesn't exist on this
client), the same metadata this addon's own TOC already declares. Nothing
acts on the value yet - comparing it against the local version and showing
the "a newer ForeverLoot is available" hint is Phase 8's job (spec section
8's rollout list item 1); this phase only carries the field over the wire
and stores whatever a peer reports in `/fl sync peers`' `ver=` column.
