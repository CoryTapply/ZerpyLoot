# ForeverLoot History Sync — Spec

Sep 30, 2026 · @Cory

## 1. Overview

ForeverLoot keeps every guild member's loot history converged using two paths: an immediate live broadcast when something happens, and a background anti-entropy sync that repairs whatever a client missed while offline. Within a few minutes of logging in outside an instance, a member who missed a week catches up. A brand-new member receives the whole retained history in roughly 5–10 minutes.

### Goals

- **Eventual consistency.** Every client that is online for a reasonable period ends up with the same set of rows, deletes and pins, whatever order it received them in.
- **No coordinator.** No client is special. Anyone who is online can supply data, and the system never needs to know in advance who will be online.
- **Deletes propagate.** A delete eventually reaches every client and is never undone by a client that still holds the old row.
- **Zero gameplay impact.** Automatic sync never runs inside dungeons or raids, and never competes with live loot-council traffic.
- **Bounded cost.** A guild that is already in sync spends about one small broadcast every 10–15 minutes. Bandwidth is only used when data actually differs.

### Non-goals

- Editing rows. Rows are immutable once created; they can only be deleted.
- Undeleting. A delete is permanent.
- Cross-guild sharing. Scope is one guild, over the GUILD channel plus whispers.
- Cryptographic trust. A client that deliberately modifies the addon can forge data; see section 11.

### Design in one paragraph

Each row has a unique id. Deletes are stored as **tombstones**, and "keep forever" is stored as a **pin**. Both are data that syncs like rows. Clients group entries into day buckets and keep an order-independent hash per bucket, rolled up into months and a single root hash. Clients announce their root hash with `HELLO`. When hashes differ, a client pairs up with a few peers over whisper, drills down the hash tree to the mismatched days, swaps id lists for those days, and transfers only the missing entries. Rows travel in a compact positional encoding with batch-local integer dictionaries for players and response types, then go through LibSerialize, LibDeflate and AceComm. Rows older than a guild-wide retention window are pruned on every client using the same rule, unless they are pinned.

## 2. Platform constraints

The binding constraint is the addon-message throttle: about one 255-byte message per second per prefix. Every other decision in this spec follows from that. WoW Forever is assumed to use modern retail addon-comm rules.

| Constraint | Value | Consequence for this design |
| --- | --- | --- |
| Max addon message size | 255 bytes, prefix excluded | Payloads are split into chunks. AceComm does this for us. |
| Per-prefix throttle | Burst of 10 messages, refills at 1 message/second, on all chat types including WHISPER and GUILD | One prefix moves about 250 bytes/s. Bulk sync is spread over several prefixes and several peers. |
| Global send budget | ChatThrottleLib (used by AceComm) caps total output at about 800 bytes/s and counts roughly 40 bytes of overhead per message. Exceeding the server's global limit can disconnect the player. | All traffic goes through AceComm/CTL. We never call `C_ChatInfo.SendAddonMessage` directly. |
| Boss encounter restriction | Addon messages cannot be sent during raid boss encounter combat | Live broadcasts are queued from `ENCOUNTER_START` to `ENCOUNTER_END`. Automatic sync never runs inside an instance at all (section 8). |
| Prefix length | 16 characters max; each prefix is registered with `C_ChatInfo.RegisterAddonMessagePrefix` (AceComm registers for us) | Prefixes `FLoot`, `FLootS1`, `FLootS2`, `FLootS3`. |
| Null bytes | Addon messages cannot carry byte `\000` | Compressed binary is encoded with `LibDeflate:EncodeForWoWAddonChannel` (section 4.1). |
| SavedVariables | Loaded and parsed at login and `/reload`, written at logout | Sync state that can be rebuilt, such as digests, is recomputed at login instead of saved. |

The exact limits in WoW Forever should be confirmed during beta. They live in one constants table (section 13) so they are easy to change.

**Measured on WoW Forever during development** (details in `docs/sync-deviations.md`):

- **No per-prefix throttle.** The real ceiling is ChatThrottleLib's total of about 0.7 KB/s per sender. Rotating `FLootS1`–`S3` is harmless and kept, but extra speed comes from extra senders (secondaries), not extra prefixes.
- **The server reorders messages** sent in the same instant. AceComm's multi-part reassembly can't cope, so `Transport` never hands AceComm more than one 255-byte piece. Each message goes out as `"~!"..payload` or numbered pieces `"~id:i:n:"..slice`, reassembled in any order. A message still missing pieces after 30 s is dropped with a warning.
- **GUILD-distribution addon messages are not relayed.** Every `GUILD` send is rewritten into one `WHISPER` per online guild member, or per known addon user (`fanout = "known"`: anyone whose message decoded cleanly in the last 30 days). Login, forced and every 4th periodic `HELLO` go to every online member so new users are found.

## 3. Data model

The store holds three kinds of entry, all keyed by the row id: **rows**, **tombstones** and **pins**. For any id, the only valid final states are {row}, {row + pin} and {tombstone}. A tombstone always wins.

### 3.1 History row (local schema, unchanged)

The local SavedVariables row keeps its current keyed shape, so existing UI code does not change. The compact form exists only on the wire (section 4). The example row from the current build:

| Field | Example | Type |
| --- | --- | --- |
| `id` | `zerpygrape-classicbetapvp2-6-1-9` | string, unique |
| `awardedAt` | `1790779277` | integer, server time (`GetServerTime()`) |
| `awardedBy` | `Zerpy Grape` | player name |
| `awardedTo` | `Zerpy Grape` | player name |
| `awardedToClass` | `HUNTER` | class token |
| `itemID` | `251533` | integer |
| `itemIcon` | `132409` | file id |
| `itemLink` | `[Forsaken Greataxe]` (the full link string) | item link |
| `itemSession` | `1` | integer |
| `sessionId` | `4` | integer |
| `responses` | up to 5 entries, keyed by player name | table |
| `responses[name].class` | `PALADIN` | class token |
| `responses[name].note` | `Small upgrade, would use for pvp mostly` | free text |
| `responses[name].response` | `{color="e6c229", kind="pvp", label="PvP"}` | table |
| `responses[name].votes` | `0` | integer |

`nextSessionId` in the screenshot belongs to the enclosing table, not the row. It is not synced.

### 3.2 Tombstone

`{ id, rowTime, deletedAt, deletedBy }`

- `rowTime` is the deleted row's `awardedAt`. It is required so the tombstone lands in the **same bucket** as the row it deletes, even when the tombstone arrives before the row ever did.
- Tombstones are kept forever. Deletes are rare and each tombstone is under 60 bytes, so 1,000 tombstones cost about 60 KB. Keeping them permanently guarantees a stale client can never bring a deleted row back.

### 3.3 Pin (keep forever)

`{ id, rowTime, pinnedAt, pinnedBy }`

- A pin exempts its row from retention pruning (section 10).
- Pins are created explicitly by a permitted user, or automatically at award time by the awarding client when the item is in the addon's fixed key-item set. Either way, the pin is data. Other clients never re-evaluate the set themselves, because members may run addon versions with different sets.
- Pins are add-only. There is no unpin in v1.

### 3.4 Apply rules

Every write to the store, whether from the local UI, a live broadcast or a sync batch, goes through one function: `Store:Apply(entry)`. It returns whether the entry changed anything.

1. **Tombstone for id X**: if a tombstone for X already exists, ignore it. Otherwise delete the row X and pin X if present, then store the tombstone.
2. **Row X**: ignore it if X is tombstoned, if X already exists, or if `rowTime < cutoff` and X is not pinned (section 10). Otherwise validate it (section 4.9) and store it.
3. **Pin X**: ignore it if X is tombstoned or already pinned. Otherwise store it. The pin is valid even if row X has not arrived yet.
4. Every change updates the digest incrementally (section 5) and fires a UI callback.

These rules are commutative and idempotent. Any delivery order, and any number of duplicate deliveries, produce the same final store.

### 3.5 Id requirements

- Ids must be globally unique and **byte-identical on every client**, because digests hash the id string.
- The format is `<leader fqn, lowercased, spaces removed>-<sessionId>-<itemSession>-<awardSeq>`, where the fqn is the session leader's `name-realm` as one string (a realm name may itself contain hyphens). Section 4.6 encodes ids structurally when they match this pattern, with a raw-string fallback. Manual entries (`manual-...`) and test rows (`zztest-...`) always use the fallback.

## 4. Wire encoding: shrinking rows for transmission

A 5-response row drops from about 1,360 bytes to about 280 bytes before compression, and to roughly 150–180 bytes per row once a batch is compressed. Nothing of value is lost. Every dropped byte is either a repeated key name, or a value the receiver can rebuild exactly from game data or from a dictionary sent alongside.

### 4.1 Library pipeline

Every message, including control messages, goes through the same five steps.

**Send:**

1. Build a **positional** Lua table (section 4.7). There are no string keys.
2. `LibSerialize:Serialize(tbl)` turns the table into a compact binary string. It writes small integers in 1–2 bytes, keeps types exact (integer vs string vs table), and writes a string that repeats within one call as a short back-reference.
3. `LibDeflate:CompressDeflate(serialized, { level = 9 })` compresses it. Level 9 is fine because payloads are capped at about 4 KB (section 9).
4. `LibDeflate:EncodeForWoWAddonChannel(compressed)` makes the bytes safe for the addon channel (explained below).
5. `AceComm:SendCommMessage(prefix, encoded, distribution, target, priority, progressCallback)` splits the string into 255-byte chunks, queues them through ChatThrottleLib at the given priority, and reassembles them on the other side.

**Receive:** `OnCommReceived(prefix, encoded, distribution, sender)` is called once with the fully reassembled string. Then `LibDeflate:DecodeForWoWAddonChannel`, then `LibDeflate:DecompressDeflate`, then `LibSerialize:Deserialize`, then validation (section 4.9). Any step that returns `nil` or `false` drops the message silently and increments a debug counter.

#### What "compress with LibDeflate and use its addon-channel encoder; it's standalone, not Ace" means

- **LibDeflate** is a pure-Lua implementation of DEFLATE, the same algorithm used by zip and gzip. It ships as its own library and does not belong to the Ace3 family. The earlier note that it is "standalone, not Ace" was only there because this project was thought to avoid Ace3. Now that the project uses AceComm, there is no conflict. LibDeflate simply sits between LibSerialize and AceComm.
- **Why an encoder is needed.** Compressed output is raw binary: any byte from 0 to 255 can appear, including byte 0 (`\000`). Addon messages cannot contain `\000`, so sending compressed bytes directly would corrupt or reject the message.
- **What `EncodeForWoWAddonChannel` does.** It rewrites the compressed string so that it contains no `\000`, at a size cost of only a few percent. `DecodeForWoWAddonChannel` reverses it exactly on the receiving side.
- **Which encoder to use.** LibDeflate ships three encoders. Use `EncodeForWoWAddonChannel` for all traffic here. `EncodeForPrint` produces printable text for copy-paste export strings and costs about 33% extra. `EncodeForWoWChatChannel` is for normal chat channels and is also larger. Neither is needed for addon messages.
- **Order matters.** Serialize first, then compress, then encode. Compressing already-encoded text wastes space, and encoding before compressing reintroduces `\000` bytes.

### 4.2 Field-by-field plan

| Field | Now (approx. bytes) | On the wire | Rebuilt on receive from |
| --- | --- | --- | --- |
| Key names (`awardedAt`, `responses`, `note`, …) | about 150 per row | 0 | Positional arrays: the position is the key |
| `id` | 33 | about 6: `{playerIdx, realm, a, b, c}`, or the raw string as a fallback | `format("%s-%s-%d-%d-%d", compact(leaderName), realm, a, b, c)` (4.6) |
| `awardedAt` | 10 | 5 (integer) | Same value |
| `awardedBy`, `awardedTo` | about 12 each | 1 each (player index) | Player dictionary (4.3) |
| `awardedToClass` | 6 | 0 | Player dictionary's class id |
| `itemID` | 6 | 0 | Parsed from the item string |
| `itemIcon` | 6 | 0 | `C_Item.GetItemInfoInstant("item:"..s)`, 5th return, instant and cache-free |
| `itemLink` | about 100–150 | about 30–50: the item string only (4.5) | Item string, re-linked by the client |
| `sessionId`, `itemSession` | 1 each | 1 each | Same value |
| Response player name (key) | about 12 × 5 | 1 × 5 | Player dictionary |
| `responses[].class` | about 7 × 5 | 0 | Player dictionary |
| `responses[].response` `{color, kind, label}` | about 45 × 5 | 1 × 5 (response-type index) | Response-type dictionary (4.4) |
| `responses[].votes` | 1 × 5 | 1 × 5 | Same value |
| `responses[].note` | 0–120 × 5 | unchanged | Same text; compression shrinks it |

After this plan, **notes make up about 75% of the remaining row.** Notes are the only field that cannot be shrunk without losing information, so compression is what reduces them.

### 4.3 Player dictionary (integer player names)

The guild has a fairly static set of players, and each row references up to 7 of them (awarder, recipient, 5 responders). Each **batch** carries a small dictionary, and rows refer to players by integer index into it.

- **Format:** a flat array of pairs, `{ name1, classId1, name2, classId2, … }`. Index `i` refers to the `i`-th pair.
- **Name:** the exact string stored in the local row (for example `Zerpy Grape`), so nothing is normalized away. Stored names never carry a realm suffix, so dictionary entries are bare names; the only realm on the wire is the one inside the id encoding (4.6).
- **Class id:** the numeric class id. The token-to-id map is built at load by iterating `GetNumClasses()` and `GetClassInfo(i)`, so it adapts to whatever classes WoW Forever has. Use `0` when the class is unknown, for example a player who only appears inside an id.
- **Building it:** the encoder walks the batch's rows and assigns indexes in first-seen order. The dictionary contains only players the batch actually references.
- **Cost:** a raid night's batch of 40 rows usually references 25–40 distinct players. That is about 600 bytes of dictionary, or about 15 bytes per row, compared with about 90 bytes per row for inline names. Compression shrinks it further.

**Why batch-local instead of a guild-wide numbering.** A permanent, guild-wide player-to-integer table would save a little more, but every client would have to agree on the numbering. Two officers adding a new recruit at the same time, while online in different groups, would assign conflicting numbers. Resolving that needs a coordinator or a merge protocol. With a batch-local dictionary, every message is self-contained, so there is nothing to agree on and nothing to corrupt. A session-level dictionary (sent once per sync session and referenced by later batches) is a possible v2 optimization if measurements show the dictionary overhead matters.

### 4.4 Response-type dictionary

- **Format:** a flat array of triples, `{ color, kind, label, … }`, with the index into it stored per response.
- **All three strings are kept.** Response buttons can be reconfigured over time, and history should show the label and color that were actually used when the vote happened.
- **Size:** a council typically uses 4–8 response types, so this dictionary is about 100–200 bytes per batch.

### 4.5 Item link to item string

The link carries much more than the item id, so it is **not** reduced to `itemID`. A link has three parts:

1. **Display wrapper:** the color code, `|H` … `|h`, the bracketed name and `|h|r`. The client can regenerate all of this from the item data.
2. **The item string:** `item:251533:enchant:gem1:gem2:gem3:gem4:suffix:unique:linkLevel:specID:modifiersMask:context:numBonusIDs:bonusID…:numModifiers:modifier…`. This is the information that matters. Bonus ids decide item level, upgrade track, sockets and tertiary stats. Context records the source difficulty. Modifiers and enchant/gem ids are recorded too.
3. **The display name.** It is derived from the item string, and is localized to the viewer's language on rebuild, which is a feature.

**On send:** `local s = link:match("|Hitem:([^|]+)|h")`. Send `s`, which is the item string without its `item:` prefix, verbatim. Every field is kept, including trailing empty ones, so the string round-trips exactly. There is no need to understand the field layout, so the plan survives link-format changes in WoW Forever.

**On receive:**

- `itemID` and `itemIcon` come from `C_Item.GetItemInfoInstant("item:"..s)`. This call is instant and needs no cache.
- `itemLink` comes from `select(2, C_Item.GetItemInfo("item:"..s))`. If the item is not cached yet, that returns `nil`. In that case, request the data (`C_Item.RequestLoadItemDataByID(itemID)`), wait for `GET_ITEM_INFO_RECEIVED` or use an `Item:ContinueOnItemLoad` callback, then fill the link in.
- **Local schema change:** rows gain one field, `itemString`, which becomes the source of truth. `itemLink` becomes a cache that the UI can rebuild at any time. Until it is filled, the UI shows a placeholder.

### 4.6 Id encoding

- **The id is parsed from the right:** `^(.-)%-(%d+)%-(%d+)%-(%d+)$` takes the three trailing numbers, and everything before them is one opaque leader prefix, however many hyphens it holds. The prefix must equal `(compact(awardedBy) .. "-" .. realm):lower()` for the row's own `awardedBy`, which is always the session leader. The id is then encoded as `{a, b, c}` and the decoder rebuilds the prefix from the row's `awardedBy` player-dictionary entry, so no separate leader lookup is needed.
- **Round-trip guard:** the encoder always checks `decodeId(encodeId(id)) == id`. If the check fails, it sends the raw string. The decoder tells the two forms apart by type (table or string).
- **Why exactness matters:** digests hash the id string, so any mismatch would make two clients disagree forever.

### 4.7 Batch layout

Every message starts with a common header: `{ PROTO_VERSION, MSG_TYPE, sessionToken, … }`. A `ROWS` message then continues:

```lua
{ 1, MSG.ROWS, "k7Q2", 3,                               -- proto, type, session token, batch number
  { "Zerpy Grape", 3, "Zerpy Frog", 2 },                  -- [5] players: name, classId pairs
  { "d93636", "text", "Main Bis", "e6c229", "pvp", "PvP" }, -- [6] response types: color, kind, label
  {                                                       -- [7] rows
    { {1, "classicbetapvp2", 4, 1, 1},                    -- [1] id
      1790779277,                                         -- [2] awardedAt
      1, 1,                                               -- [3] awardedBy, [4] awardedTo
      4, 1,                                               -- [5] sessionId, [6] itemSession
      "251533::::::::80:253::6:2:10390:10383::::::",      -- [7] item string (illustrative)
      { 2, 2, 0, "Small upgrade, would use for pvp mostly",  -- [8] responses, flat groups of 4:
        1, 1, 1, "This is my bis, i have a green still" },  --     player, responseType, votes, note
    },
  },
}
```

- **Responses** are flattened into groups of 4 (at most 20 values). This avoids a nested table per response. Sort order is by player name, so encoding is deterministic.
- **An empty note** is sent as `""`, never `nil`, so the groups of 4 stay aligned. `nil` inside an array breaks the array part in Lua.
- **Forward compatibility:** new row fields may only be **appended** (position 9 and up). Older decoders ignore trailing fields. Anything that changes meaning bumps `PROTO_VERSION`.

### 4.8 Size estimate for one 5-response row

| Stage | Bytes per row | Notes |
| --- | --- | --- |
| Current keyed table | about 1,360 | Your estimate |
| Positional + dictionaries, serialized | about 280 | About 75 bytes of structure plus about 200 bytes of notes (5 × 40) |
| Plus dictionary share in a 40-row batch | about 300 | About 20 bytes of dictionary per row |
| After LibDeflate, in a batch | about 150–180 | Estimate: English notes and repeated numbers compress well across a batch; measure with real data |
| Single live row, compressed | about 350 | Carries its own 7-player dictionary, and one row has little to compress; 2 AceComm chunks |

The note UI already caps notes at 120 characters. That bounds the worst case at about 680 bytes per row before compression.

### 4.9 Decode, validate, rebuild

The decoder rejects **individual rows**, not whole batches, when any of these checks fail:

- The header's `PROTO_VERSION` is unknown. This check drops the whole message.
- A field has the wrong type, or a player or response-type index is out of range for the batch dictionaries.
- There are more than 5 responses, or a note is longer than the cap.
- `awardedAt > GetServerTime() + 86400`, or `awardedAt < cutoff` when the id is not pinned locally.
- The item string does not match `^%d+[%d:%-]*$`.

Rows that pass are rebuilt into the local keyed schema, passed to `Store:Apply` and marked for the async item-link fill.

### 4.10 Optional: preset compression dictionary

`LibDeflate:CreateDictionary(str, strlen, adler32)` lets both sides share a preset text, for example common note words, response labels and realm names. This mainly helps **single-row live messages**, which otherwise have too little text for compression to find repeats in. The preset must be byte-identical on every client and is tied to `PROTO_VERSION`. It is a v2 optimization, to be done after measuring real payloads.

## 5. Digests and bucketing

One 32-bit root number (plus a count) tells two clients whether they are in sync. When they are not, a three-level tree (root, then month, then day) narrows the difference down to a few days of data in 2–3 round trips.

### 5.1 Entry hash

Each stored entry contributes one 32-bit hash:

- Row: `H("R:" .. id)`
- Tombstone: `H("D:" .. id)`
- Pin: `H("P:" .. id)`

`H` is FNV-1a 32-bit, written for Lua 5.1 doubles. The multiply by the FNV prime `16777619` would overflow the 53-bit precision of a double, so split it as `2^24 + 403`:

```lua
local band, bxor, lshift = bit.band, bit.bxor, bit.lshift
local TWO32 = 4294967296

local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = bxor(h, s:byte(i)) % TWO32
    -- h * 16777619 mod 2^32, without losing precision
    h = (lshift(band(h, 0xFF), 24) % TWO32 + h * 403) % TWO32
  end
  return h
end
```

`lshift(band(h, 0xFF), 24)` is `h * 2^24 mod 2^32`: only the low 8 bits survive the shift. The `% TWO32` normalizes WoW's signed 32-bit results to unsigned.

### 5.2 Bucket aggregate

Each bucket stores `{ count, x, s }`:

- `count`: the number of entries.
- `x`: the XOR of all entry hashes.
- `s`: the sum of all entry hashes, mod 2^32.

Both `x` and `s` are order-independent and **incremental**. Adding or removing an entry is one XOR and one add or subtract, with no rescan. Using two independent aggregates plus the count makes an accidental match between different sets vanishingly unlikely.

### 5.3 Bucket keys

A bucket key must come from data **inside** the entry, never from when it was received:

- **Day key:** `floor(rowTime / 86400)`, a UTC day number. `rowTime` is `awardedAt` for rows and the stored `rowTime` for tombstones and pins.
- **Month key:** `year * 12 + (month - 1)`, from `date("!*t", rowTime)`, in UTC.
- **Root:** the aggregate of all months.

### 5.4 Two trees: window and archive

- **Window tree:** every entry whose `rowTime >= cutoff` (section 10). This covers the recent 3–5 months, which is nearly all traffic.
- **Archive tree:** every entry with `rowTime < cutoff` that must be kept: pinned rows, their pins, and all old tombstones. It is small and changes rarely. Its leaves are months, not days.
- `HELLO` carries both roots, so a client can tell which tree differs.

### 5.5 Lifecycle

- **At login:** rebuild both trees from the store. With about 3,500 rows of roughly 35-byte ids, that is about 120,000 byte operations, a few milliseconds. The trees are **not** saved to SavedVariables, so they cannot drift out of sync with the data.
- **At runtime:** `Store:Apply` and the pruner call `Digest:Add(entry)` and `Digest:Remove(entry)`.
- **When the cutoff moves** (the first day of a new month, UTC), rebuild both trees. Entries that just aged out move from window to archive or are pruned.

### 5.6 Per-entry hashes for id lists

The entry hash from 5.1 doubles as a short id. When two clients compare a mismatched day, they exchange **lists of 32-bit entry hashes** instead of full ids: about 5 bytes each instead of about 35. Each side keeps a `hash → entry` map for the day buckets involved. If a collision inside one day bucket is ever detected (two local entries with the same hash), that bucket falls back to exchanging full ids.

## 6. Protocol message catalog

The protocol has 17 message types (15 from the original design, plus `PING` and `DONE_ACK`). Three of them are live broadcasts; the rest are for discovery and sync sessions. Every body is a positional table that starts with `PROTO_VERSION, MSG_TYPE`. Session messages then carry a `token`: 4 random characters chosen by the client that opened the session. Messages with an unknown or expired token are ignored, so late packets from an abandoned session are harmless.

| Type | Name | Channel | Prefix | CTL priority | Body after the header |
| --- | --- | --- | --- | --- | --- |
| 1 | `HELLO` | GUILD or RAID (the domain scope) | `FLoot` | NORMAL | scope, addon version, free session slots, flags (`urgent`), then one `domainId, summary` pair per domain in that scope (7.7). The history summary is the window root and archive root `{count, x, s}` plus the cutoff month key and retention months. |
| 2 | `HELLO_ACK` | WHISPER | `FLoot` | NORMAL | Same fields as `HELLO` |
| 3 | `OPEN` | WHISPER | `FLoot` | NORMAL | domain id, token, mode (`full` or `pull`), and for `pull` mode the list of assigned day keys |
| 4 | `OPEN_REPLY` | WHISPER | `FLoot` | NORMAL | token, accepted (boolean), retry-after seconds when refused |
| 5 | `MONTHS` | WHISPER | `FLoot` | NORMAL | token, tree (`W` or `A`), flat list of `monthKey, count, x, s` |
| 6 | `DAYS` | WHISPER | `FLoot` | NORMAL | token, flat list of `dayKey, count, x, s` for the months requested |
| 7 | `HASHES` | WHISPER | `FLoot` | NORMAL | token, bucket key, list of 32-bit entry hashes (or full ids in fallback mode) |
| 8 | `WANT` | WHISPER | `FLoot` | NORMAL | token, list of entry hashes the sender is missing |
| 9 | `ROWS` | WHISPER | `FLootS1`–`S3` | BULK | token, batch number, player dictionary, response-type dictionary, rows (section 4.7) |
| 10 | `MARKS` | WHISPER | `FLootS1`–`S3` | BULK | token, player dictionary, flat list of `kind (D or P), id, rowTime, at, byPlayerIdx` |
| 11 | `DONE` | WHISPER | `FLoot` | NORMAL | token, entries sent, entries received |
| 12 | `ABORT` | WHISPER | `FLoot` | NORMAL | token, reason code (`gate`, `timeout`, `busy`, `version`) |
| 13 | `SNAP_GET` | WHISPER | `FLoot` | NORMAL | domain id: asks a peer for its full snapshot of a snapshot-strategy domain (7.7) |
| 14 | `SNAP` | WHISPER | `FLoot` | NORMAL | domain id, version, payload from the domain's Export(); sent as the reply to SNAP\_GET, or pushed when the sender holds the newer version |
| 15 | `PING` | WHISPER | `FLoot` | NORMAL | token: keeps a primary session alive while the opener waits on its secondaries (every 15 s); the server answers with its own `PING` |
| 16 | `DONE_ACK` | WHISPER | `FLoot` | NORMAL | token, flat `tree, key` list of buckets the server still wants data for; the server only closes when the list is empty |
| 20 | `LIVE_ROW` | GUILD | `FLoot` | ALERT | player dictionary, response-type dictionary, one row |
| 21 | `LIVE_DEL` | GUILD | `FLoot` | ALERT | one tombstone |
| 22 | `LIVE_PIN` | GUILD | `FLoot` | ALERT | one pin |

Notes:

- **Control messages stay small.** Everything except `ROWS` and `MARKS` fits in one or two 255-byte chunks. A `DAYS` reply for a full month is about 31 × 14 bytes, roughly 2 chunks.
- **Symmetry.** In `full` mode both peers send `HASHES` and `WANT`, so data flows both ways. In `pull` mode only the opener requests; the other side only answers.
- **Tombstones and pins** use the same id encoding and player dictionary as rows.
- **Fields added during development** (all appended, so the leading fields above are unchanged):
  - `OPEN` pull mode carries a flat `tree, key` list instead of bare day keys, since window days and archive months are both integers.
  - `OPEN_REPLY` may append `"dup"` when two clients opened full sessions to each other at once; the session opened by the alphabetically lower name survives.
  - `MONTHS` requests carry a generation number, echoed on every `DAYS` and archive `MONTHS` reply batch, so replies to a retried request can be told from stragglers.
  - `DAYS` carries the server's mismatched month keys, and is sent in batches of 40 tuples, each with `batchIndex, totalBatches, gen`.
  - `HASHES` is `token, tree, key, idMode, list, isRetry`; `WANT` is `token, tree, key, idMode, list`. `WANT` is always sent, even empty. Only the opener retries `HASHES` (8 s, 3 tries), and the peer re-answers a message flagged `isRetry`.
  - `ROWS` and `MARKS` append `tree, key, batchIndex, totalBatches`; `MARKS` also has a batch number in the same position as `ROWS`. A bucket's transfer completes when every index has arrived, or when every entry it asked for is in the store.
- **The `HELLO` / `HELLO_ACK` header is fixed forever:** `PROTO_VERSION, MSG_TYPE, scope, addon version`. A client reads the addon version from a peer on another `PROTO_VERSION` from those slots, to show the update hint, without decoding anything else.
- **Abuse limits.** At most 5 `HELLO`s and 3 `OPEN`s per sender per minute are handled; the rest are dropped. A reassembled message over 64 KB is dropped before decoding.

## 7. Sync flows

Live broadcasts deliver data to whoever is online right away. `HELLO` checks at login and every 12 minutes find anyone who fell behind. A sync session with one full partner, plus up to two pull-only helpers, closes the gap.

### 7.1 Live push

1. When a council member awards an item, deletes a row or pins a row, their client calls `Store:Apply` locally first.
2. The client then broadcasts `LIVE_ROW`, `LIVE_DEL` or `LIVE_PIN` on GUILD at ALERT priority.
3. **Live broadcasts are allowed inside dungeons and raids.** They are human-paced and only a handful of messages. The single exception is during a boss encounter: the message waits in the `Gate` queue until `ENCOUNTER_END`, then sends.
4. Receivers call `Store:Apply`. Duplicates and out-of-order arrival are harmless (section 3.4).
5. If a broadcast is lost, for example because the sender disconnects mid-send, nothing special happens. Anti-entropy repairs it later.

### 7.2 Discovery at login

1. After the first `PLAYER_ENTERING_WORLD`, wait `LOGIN_DELAY` (20 s ± 10 s of jitter) **and** until the gate is open (outside any instance, out of combat; section 8).
2. Broadcast `HELLO` with a summary for each GUILD-scope domain (7.7).
3. **Peers whose summaries all match stay silent.** Peers with any differing domain reply with `HELLO_ACK`, after 0–4 s of random delay, with probability `p = min(1, TARGET_RESPONDERS / max(1, knownPeers))`.
   - `TARGET_RESPONDERS` is 3.
   - `knownPeers` is the number of distinct clients heard from (`HELLO` or `HELLO_ACK`) in the last 30 minutes.
   - A peer whose own gate is closed (in an instance or in combat) never replies.
4. The opener collects replies for `HELLO_COLLECT_WINDOW` (12 s). It picks a **primary**: the responder with the highest window count, with random tie-breaks. Up to 2 more responders become **secondaries**.
5. **No replies at all:** after 30 s, retry `HELLO` with the `urgent` flag, which doubles `p`. After 3 attempts, give up until the next periodic check.
6. Silence after a `HELLO` does not prove the client is in sync, because nobody may be online. Proof arrives when the client hears someone else's `HELLO` with identical roots.

### 7.3 Full session with the primary

1. The opener sends `OPEN(full)`. If the reply is a refusal, it tries the next responder.
2. The opener sends `MONTHS` for the window tree, and for the archive tree if the archive roots differ.
3. The peer compares and replies with `DAYS` for every window month that differs. Archive leaves are months, so archive mismatches skip straight to step 4.
4. The opener compares the day aggregates and builds the list of mismatched buckets, **newest first**.
5. For each mismatched bucket, with at most `BUCKETS_IN_FLIGHT` (6) in flight:
   1. Both sides send `HASHES` for that bucket.
   2. Each side computes which hashes it lacks and sends `WANT`.
   3. Each side answers the other's `WANT` with `ROWS` and `MARKS` batches on the sync prefixes.
6. When all buckets are done and every batch it owes is confirmed sent, the opener sends `DONE`. The server answers `DONE_ACK` listing any bucket whose data it still lacks; the opener resends those and sends `DONE` again, at most 4 times. If the roots still differ, for example because new live data arrived during the session, it does **not** loop immediately. The next periodic check handles it.
7. If two clients open full sessions to each other, only one survives (see `OPEN_REPLY` in section 6). A full session that aborts for any reason other than `gate` or `dup` triggers a rediscovery about 30 s later.

### 7.4 Parallel pull from secondaries

The throttle limits each **sender**, so receiving from three peers roughly triples download speed.

1. After step 4 above, the opener assigns mismatched buckets round-robin, newest first, across the primary and the secondaries.
2. Each secondary gets `OPEN(pull, dayKeys)`. The opener sends `HASHES` for those days, and the secondary replies with `ROWS` and `MARKS` for whatever the opener lacks. A secondary never requests data from the opener.
3. The primary session still handles the **push direction for every bucket**. Pull work for buckets assigned to secondaries is skipped on the primary.
4. If a secondary aborts or times out, its unfinished buckets go back to the primary's queue. The primary's saved `HASHES` list for that bucket is reused, so no new round trip is needed.
5. **Top-up.** A secondary may hold less than the primary. When a secondary finishes, each of its buckets is checked against the primary's hashes (or, for buckets the primary skipped because ours was empty, the primary's compare-phase aggregate), and anything still missing is pulled from the primary.
6. Overlap is harmless. The same row arriving twice is a no-op in `Store:Apply`.

### 7.5 Periodic check

1. Every `PERIODIC_INTERVAL` (12 min ± 3 min), if the gate is open and no session is running:
   - If a `HELLO` or `HELLO_ACK` with roots identical to ours was heard in this interval, skip. The guild is in sync as far as we know.
   - Otherwise, broadcast `HELLO`. Replies and sessions then follow 7.2–7.4.
2. **Hearing a mismatched `HELLO` does not make us open a session.** The sender opens one with whoever replies, and full sessions are symmetric, so both sides converge.
3. In a guild that is already in sync, suppression means about **one `HELLO` per interval for the whole guild**, not one per member.

### 7.6 Serving requests

- A client serves at most `MAX_SERVE` (2) sessions at a time. Further `OPEN`s get `OPEN_REPLY(refused, retryAfter)`.
- When a serving client's gate closes, it sends `ABORT(gate)` and drops the session. The opener moves on to its next candidate.
- If no message arrives on a session for `SESSION_IDLE_TIMEOUT` (45 s), the session is dropped silently.

### 7.7 Sync domains: one handshake for many kinds of data

Discovery itself (`HELLO`, `HELLO_ACK`, picking responders, suppression) knows nothing about loot history. It works on **sync domains**. Each domain registers the same small interface and declares how a mismatch is repaired. Loot history is domain 1, a running loot-council session is domain 2, and any later shared data registers the same way, without touching `Peers` or `Coordinator`.

#### Two repair strategies

| Strategy | Fits | Summary carried in `HELLO` | How a mismatch is repaired |
| --- | --- | --- | --- |
| `set` | Large collections that grow and occasionally delete (loot history) | Digest roots `{count, x, s}` | A sync session per domain (7.3–7.4) |
| `snapshot` | Small state replaced as a whole (the current council session) | A version such as `{sessionId, startedAt, rev, ended, leader}` | One round trip: `SNAP_GET` then `SNAP`, or a pushed `SNAP` when we hold the newer version |

#### Domain interface

```lua
-- Sync/Domains.lua: every domain is a table with these fields and methods
local Domain = {
  id       = 2,                -- small integer, unique and permanent (it goes on the wire)
  name     = "councilSession",
  strategy = "snapshot",       -- "set" or "snapshot"
  scope    = "RAID",           -- "GUILD" or "RAID": which channel its HELLO goes to
  gate     = "live",           -- "sync": outside instances only; "live": anywhere except boss encounters
}
function Domain:Summary() end                         -- small positional table for HELLO; nil = nothing to offer
function Domain:Compare(remoteSummary, remoteName) end -- "same" | "remoteNewer" | "localNewer" | "diverged" | "incompatible"
function Domain:SummaryFor(remoteSummary) end         -- optional: HELLO_ACK summary in reply to a given remote one

-- snapshot strategy
function Domain:Export() end                          -- returns version, payload (positional, ready for Codec)
function Domain:Import(version, payload, sender) end  -- validate, apply if newer; returns changed

-- set strategy
function Domain:Tree() end                            -- Root, Months, Days, Hashes, Lookup (the Digest API)
function Domain:EncodeEntries(hashes) end             -- ROWS / MARKS batches
function Domain:ApplyEntries(decoded, sender) end     -- calls the domain's Apply for each entry
```

The registry offers `Domains.Register(domain)`, `Domains.Get(id)`, `Domains.InScope(scope)` and `Domains.NotifyChanged(id)`. The last one lets a domain ask for an early `HELLO`, for example right after a leader starts a session.

#### How the handshake uses domains

1. **Building `HELLO`.** `Peers` sends one `HELLO` per scope. It carries a `domainId, summary` pair for every registered domain in that scope whose gate is open. Domains whose `Summary()` returns `nil` are left out, but the `HELLO` still goes out (a late joiner's RAID `HELLO` carries nothing). It is skipped only when every domain in the scope has its gate closed. A receiver treats a snapshot domain missing from a `HELLO` as `Compare(nil)`, which is `localNewer` when it holds something.
2. **Unknown domains.** A receiver ignores domain ids it does not know. Clients on an older addon version keep syncing the domains they share with newer clients.
3. **Replying.** The receiver calls `Compare` for every domain in the `HELLO`. If any result is not `same`, it replies with `HELLO_ACK` under the usual probability rule, carrying its own summaries for those domains.
4. **Repairing.** The opener handles each mismatched domain by its strategy:
   - `snapshot`, `remoteNewer`: send `SNAP_GET` to the responder with the highest version. One responder is enough.
   - `snapshot`, `localNewer`: push our `SNAP` to that responder.
   - `set`: `OPEN` a session for that domain id, plus secondaries, as in 7.3–7.4.
5. **Independence.** Repairs are per domain. A long history backfill on the BULK sync prefixes never delays a snapshot, which travels on `FLoot` at NORMAL priority.

#### Triggers

- **Login and periodic checks** run per scope, as in 7.2 and 7.5. A scope's periodic `HELLO` is skipped when every one of its domain summaries matched a `HELLO` heard during the interval.
- **RAID-scope domains also trigger** when the player joins a raid group (`GROUP_ROSTER_UPDATE`), after a `/reload` inside a raid, and whenever the domain calls `Domains.NotifyChanged`.

#### Gating per domain

- **History:** gate `sync`, so it runs outside instances only (section 8).
- **Council session:** gate `live`, because the session runs while the raid is inside the instance. It is allowed anywhere except during boss encounters. The state is small and the repair is a single message pair, so this stays within the "human-paced" budget that live broadcasts already use.

#### Example: the council-session domain

- **State:** the running session: session id, leader, council members, items and their status, responses and votes.
- **Every client counts `rev`.** Responses and votes come from raiders, so every client bumps `rev` once for each change it applies (the network apply handlers, plus the leader's own optimistic paths). Members who saw the same messages hold the same `rev`.
- **Version and `Compare`:** the summary is `{sessionId, startedAt, rev, ended, leader}`, with `startedAt` in server time. Ended beats active for the same session. Otherwise the leader's copy wins for its own session, then the higher `rev`. For a different session, the later `startedAt` wins, so a new session supersedes an old one.
- **Only sessions whose leader is in our group** are advertised or imported, so an old session left in SavedVariables can't leak into an unrelated raid. `SNAP_GET` is only answered for group members, and is retried once after 15 s.
- **Ended sessions are not advertised.** `Summary()` returns `nil` as soon as a session ends; `SESSION_END_TTL` is unused. A member who still advertises it as active gets the ended version through `SummaryFor` in the `HELLO_ACK`.
- **Payload:** `Export` reuses the `Codec` player and response-type dictionaries plus LibDeflate. AceComm chunks it when it is larger than one message.
- **Live updates are unchanged.** The leader still broadcasts each change on RAID as it happens. The snapshot path only catches up someone who joined late, reloaded or disconnected mid-session.

#### Adding another domain

1. Pick a permanent `id`, a `strategy`, a `scope` and a `gate`.
2. Implement the interface methods for that strategy.
3. Register the domain from its module's `Init()` with `Domains.Register` (not at file load: the debug log it writes to doesn't exist yet).
4. Add its payload encoding to `Codec`, and cover it in /fl debug roundtrip.
5. Add its lines to /fl sync domains and its scenarios to the implementation plan's in-game checklists.

## 8. Gating and scheduling

Automatic sync runs only when the player is outside any instance and out of combat. Live broadcasts may run anywhere except during a boss encounter.

| Gate | Checked with | Automatic sync (`HELLO`, sessions) | Live broadcast |
| --- | --- | --- | --- |
| Inside a dungeon, raid, battleground or arena | `IsInInstance()`; re-checked on `PLAYER_ENTERING_WORLD` and `ZONE_CHANGED_NEW_AREA` | Blocked | Allowed |
| Boss encounter | `ENCOUNTER_START` / `ENCOUNTER_END` | Blocked | **Queued**, then flushed on `ENCOUNTER_END` |
| In combat | `InCombatLockdown()`, `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` | Paused; resumes 5 s after combat ends | Allowed |
| Loading screen | Between `LOADING_SCREEN_ENABLED` and `PLAYER_ENTERING_WORLD` | Blocked | Queued |
| Not in a guild | `IsInGuild()` | Blocked | Blocked |

Rules:

- **Pausing.** When the gate closes mid-session, the client stops pulling new batches from its outgoing queue and sends `ABORT(gate)`. AceComm chunks already handed to ChatThrottleLib finish sending; they are small and on BULK priority.
- **No resume state.** An aborted session is simply dropped. Sessions are idempotent, so the next `HELLO` after the gate reopens picks up whatever is still missing.
- **Jitter everywhere.** Every timer (login delay, periodic interval, reply delay) is randomized. This stops 40 raiders who zone out together from all broadcasting `HELLO` in the same second.
- **Instance exit.** Leaving an instance counts like a login: after `LOGIN_DELAY`, send `HELLO`. Raid members who missed live broadcasts during an encounter-queue edge case get repaired then.
- **Send failures.** If AceComm's callback reports that a message could not be sent, the live queue retries it once the gate is open. Sync messages are not retried; the session times out and recovers on its own.

## 9. Throughput and throttling budget

Each sender moves about 600 bytes per second of payload, so pulling from three peers gives a receiver about 1.8 KB/s. At that rate a new member gets 4 months of history in about 5–6 minutes, compared with about 5.5 hours for raw rows from a single peer.

### 9.1 Budget

- **ChatThrottleLib** (inside AceComm) allows about 800 bytes/s in total and charges about 40 bytes of overhead per message. A full 255-byte chunk therefore costs about 295 bytes of budget, which caps a client at about **2.7 chunks per second** across all prefixes.
- **Per-prefix throttle:** 1 chunk per second per prefix. Three sync prefixes (`FLootS1`–`S3`) let bulk data use roughly the whole CTL budget. `FLoot` stays free for control and live messages.
- **Priorities:** live messages use ALERT, control messages NORMAL and bulk data BULK. CTL always serves higher priorities first, so a live award is never stuck behind a backfill.
- **Bundled library versions:** the bundled AceComm and ChatThrottleLib must be recent enough to understand the per-prefix throttle result codes (Ace3 release r1341 or later). Older copies drop messages when a prefix is throttled.

### 9.2 Batching

- **Batch size:** about 4 KB serialized per `ROWS` batch, which is roughly 2 KB after compression, or about 9 chunks. That is large enough for good compression and small enough that an abort wastes little.
- **Prefix rotation:** a session's outgoing batches rotate across `FLootS1`–`S3`.
- **Backpressure:** a sender queues its next batch only when AceComm's progress callback reports the previous batch fully sent. That keeps at most one batch per prefix in CTL's queue, so aborts take effect quickly.

### 9.3 Expected sync times

Assumptions: about 165 wire bytes per row, 600 B/s per sender, and 200 rows per week.

| Situation | Rows | Wire size | From 1 peer | From 3 peers |
| --- | --- | --- | --- | --- |
| Missed one raid night | about 70 | about 12 KB | about 20 s | about 7 s |
| Missed one week | 200 | about 33 KB | about 1 min | about 20 s |
| Missed one month | about 870 | about 145 KB | about 4 min | about 1.5 min |
| New member, 4-month window | about 3,500 | about 580 KB | about 16 min | about 5–6 min |

Add about 10% for control messages. For comparison, raw 1,360-byte rows at one prefix's 240 B/s would take about 5.5 hours for the new-member case.

### 9.4 CPU

- Compression and decompression run through the `Scheduler` work queue: one batch per frame, with a time budget of about 4 ms per frame.
- Hashing is incremental after login. The login rebuild takes a few milliseconds.
- Item-link rebuilds for received rows are also throttled, to about 20 per frame, to avoid spikes from item data loading.

## 10. Retention and pruning

An unpinned row is pruned once its `awardedAt` falls before a guild-wide cutoff, and every client computes the same cutoff. Pruning therefore never creates digest mismatches, and an old client can never re-introduce pruned rows.

### 10.1 The cutoff

- `cutoff` = 00:00 UTC on the first day of the month that is `RETENTION_MONTHS` months before the current month, using `GetServerTime()`.
- Rounding to a month boundary makes every client agree, even with small clock differences.
- `RETENTION_MONTHS` defaults to **4** (confirmed). It is one guild-wide value: a constant in the addon, sent in `HELLO`. Clients whose retention value differs from ours do not sync with us, and they show an "update ForeverLoot" hint instead.
- **Why not "prune if space allows".** Pruning based on each client's free space would give every client a different set of rows. Their digests would differ forever, and clients would keep resending pruned rows to each other.

### 10.2 What is kept

| Entry | `rowTime >= cutoff` | `rowTime < cutoff` |
| --- | --- | --- |
| Unpinned row | Kept (window tree) | **Pruned** |
| Pinned row + its pin | Kept (window tree) | Kept (archive tree) |
| Tombstone | Kept (window tree) | Kept forever (archive tree) |

### 10.3 When pruning runs

- At login, after the store loads, and again whenever the cutoff moves (a new UTC month).
- It runs in the `Scheduler` in slices of 200 rows per frame, and then triggers a digest rebuild.

### 10.4 Rejecting old data

`Store:Apply` refuses an unpinned row with `rowTime < cutoff`. A client that has been offline for 6 months logs in with old rows, and those rows reach nobody. When that client runs its own pruning at login, before its first `HELLO`, it converges too.

### 10.5 Pinning ("keep forever")

- **Manual pin:** a permitted user pins a row from the history UI. This creates a pin entry and sends `LIVE_PIN`.
- **Automatic pin:** at award time, the awarding client checks the item id against KEY\_ITEMS, a fixed set of item ids in the addon code that users cannot configure. If it matches, the client creates the pin in the same action as the row.
- **The pin is the record.** Other clients never re-check KEY\_ITEMS, so members on different addon versions still agree. When a release adds items to the set, each client pins its matching in-window rows once at login without broadcasting, and sync spreads those pins; duplicate pins are no-ops.
- Pinned rows, their pins and all old tombstones are what grows long-term. At 200 rows per week, even pinning 10% of rows adds only about 1,000 rows per year.

### 10.6 Storage estimate

About 3,500 window rows at about 1,360 bytes each is about 4.8 MB of SavedVariables. That is workable, but it makes `/reload` noticeably slower. A later option is to store rows locally in the compact positional form as well, which would cut the file to about 1 MB. That change stays out of scope for v1, because it touches the UI data layer.

## 11. Permissions and trust

Permissions are enforced where an action is created and checked again on live broadcasts. Relayed sync data is accepted as-is, because re-checking it against current ranks would make clients disagree over time.

### 11.1 Policy setting

`DELETE_POLICY` is one of:

- `anyone`: the old behavior, being retired.
- `council`: members of the current session's council.
- `officers`: guild rank index at or below `OFFICER_RANK_MAX`.

The chosen policy is officers: a delete is valid only if its author held an officer rank at the moment they deleted. The UI and live receivers check the rank then; relayed copies are not re-checked later (11.3), which is exactly what "at the time of the delete" needs. The same policy applies to manual pins.

### 11.2 Where it is enforced

1. **Creation (the UI).** The delete and pin buttons are only shown to permitted players. The resulting tombstone or pin records `deletedBy` or `pinnedBy`.
2. **Live receive.** For `LIVE_DEL` and `LIVE_PIN`, the receiver checks that the AceComm `sender` equals `deletedBy`/`pinnedBy`, and that the sender is permitted **right now**, using `GetGuildRosterInfo` rank or the council list. Failures are ignored and logged. The check is cheap and blocks casual misuse.
3. **Relayed sync (`MARKS`).** Accepted without a rank check.

### 11.3 Why relayed data is not re-checked

Suppose an officer deletes a row today and is demoted next month. Clients that got the tombstone live keep it. A client that syncs next month would re-check against the current roster and reject it. The two groups would disagree permanently. Validation must give the same answer on every client at any time, and "current rank" does not.

### 11.4 Honest limits

Any member who edits their addon files can forge rows, tombstones or pins, and relayed data cannot be authenticated without cryptographic signatures, which are not practical here. For a single guild this is an acceptable trust level. The mitigations are:

- `deletedBy` makes every delete attributable.
- An officer-only "deleted rows" audit view lists tombstones with who and when.
- A debug log of rejected live messages shows who sent them.

## 12. Architecture: Lua modules

The sync system is 18 small modules in three groups (sync logic, data, wire format) on top of the libraries the project already ships. `Store:Apply` is the only way data is written. `Codec` plus `Transport` are the only way bytes reach the network. `Gate` and `Scheduler` decide when anything runs.

&#91;embedded content: module architecture · 18 modules in 3 groups over the existing libraries\]

Arrows show which layer calls which. The UI also reads `Store` directly to render history, and `Gate` and `Scheduler` wrap every timer and every send.

### 12.1 File layout and load order

The TOC loads files in the order listed. Modules share the addon namespace (`local _, ns = ...`) and register themselves as `ns.Store`, `ns.Codec` and so on.

```text
ForeverLoot/
  Libs/                 -- already present: LibSerialize, LibDeflate, AceComm-3.0,
                        -- ChatThrottleLib, CallbackHandler-1.0
  Sync/Constants.lua
  Sync/Scheduler.lua
  Sync/Gate.lua
  Data/Store.lua
  Data/Digest.lua
  Data/Retention.lua
  Data/ItemLinks.lua
  Net/Codec.lua
  Net/Transport.lua
  Sync/Permissions.lua
  Sync/Live.lua
  Sync/Domains.lua
  Data/HistoryDomain.lua
  Data/CouncilSessionDomain.lua
  Sync/Peers.lua
  Sync/Session.lua
  Sync/Coordinator.lua
  Sync/Debug.lua
```

### 12.2 Module responsibilities

| Module | Owns | Public API | Uses |
| --- | --- | --- | --- |
| `Constants` | All tunables (section 13) | read-only table | none |
| `Scheduler` | Timers and a per-frame work queue | `After(sec, jitter, fn)`, `Every(sec, jitter, fn)`, `Cancel(h)`, `Enqueue(fn)`, which runs within `FRAME_BUDGET_MS` | `C_Timer`, an `OnUpdate` frame |
| `Gate` | Instance, combat, encounter and loading state; the live queue | `CanSync()`, `CanLive()`, `QueueLive(fn)`, `OnChange(cb)` | WoW events |
| `Store` | `ForeverLootDB.history`: rows, tombstones and pins | `Apply(entry, source)` returns changed, `Get(id)`, `IsTombstoned(id)`, `IsPinned(id)`, `IterateBucket(key)`; fires `EntryApplied` through CallbackHandler | `Digest`, `Retention` |
| `Digest` | Window and archive trees; `hash → entry` maps | `EntryHash(kind, id)`, `Add(kind, id, rowTime)`, `Remove(…)`, `Rebuild()`, `Root(tree)`, `Months(tree)`, `Days(monthKeys)`, `Hashes(bucketKey)`, `Lookup(hash)` | `bit` |
| `Retention` | Cutoff and the pruning pass | `Cutoff()`, `IsExpired(rowTime)`, `Prune()`, `AutoPin(row)` returns bool; fires `CutoffChanged` | `Store`, `Scheduler` |
| `ItemLinks` | Async item-link rebuild queue | `ItemStringFromLink(link)`, `Resolve(row)` | `C_Item`, `Item` mixin |
| `Codec` | Wire format (section 4) | `EncodeMessage(tbl)` returns string, `DecodeMessage(str)` returns table or nil, `EncodeRows(rows)`, `DecodeRows(players, types, wireRows)` returns rows and errors, `EncodeId`, `DecodeId`, `EncodeMarks`, `DecodeMarks` | LibSerialize, LibDeflate |
| `Transport` | Prefix registration, prefix rotation, dispatch by message type | `Send(type, body, dist, target, {prio, lane = "main" or "sync", onSent})`, `Register(type, fn(body, sender, dist))` | AceComm, `Codec` |
| `Permissions` | Delete and pin policy | `CanDelete(player)`, `CanPin(player)`, `CheckLive(sender, mark)` | Guild roster API, council data |
| `Live` | Entry point for the existing UI; `LIVE_*` handlers | `Award(row)`, `Delete(id)`, `Pin(id)` | `Store`, `Retention`, `Permissions`, `Transport`, `Gate` |
| `Peers` | `HELLO` / `HELLO_ACK`; the known-peers table | `SendHello(urgent)`, `CollectResponders(window, cb)`, `KnownPeerCount()`, `HeardMatchingRoot(since)` | `Digest`, `Transport`, `Gate` |
| `Session` | One session's state machine (12.3) | `Session.New{peer, role, mode, token, buckets}`, `:Handle(msg)`, `:Abort(reason)`; events `Finished`, `BucketsReturned` | `Digest`, `Store`, `Codec`, `Transport`, `Scheduler` |
| `Coordinator` | Login, periodic and per-domain triggers, peer choice, per-domain repair (snapshot or set), bucket assignment, `MAX_SERVE` | `Start()` | `Peers`, `Session`, `Gate`, `Scheduler` |
| `Domains` | Registry of sync domains and the domain interface (7.7) | Register(domain), Get(id), InScope(scope), NotifyChanged(id) | none |
| `HistoryDomain` | Adapter that exposes loot history as domain 1, set strategy, GUILD scope, sync gate | Implements Summary, Compare, Tree, EncodeEntries, ApplyEntries | Store, Digest, Codec |
| `CouncilSessionDomain` | Adapter that exposes the running council session as domain 2, snapshot strategy, RAID scope, live gate | Implements Summary, Compare, Export, Import | Existing council session code, Codec |
| `Debug` | Counters and `/flsync` slash command | `Count(key)`, `Log(fmt, ...)` | all modules, read-only |

### 12.3 Session state machine

| State | Role | Entered when | Next |
| --- | --- | --- | --- |
| `OPENING` | opener | `OPEN` sent | `COMPARING` on accept; the opener tries its next candidate on refusal |
| `COMPARING` | opener, full | `OPEN_REPLY` accepted | `MONTHS` sent, then `DAYS` received; then `RECONCILING` with the bucket queue, or `DONE` if nothing differs |
| `RECONCILING` | both | Mismatched buckets are known | At most 3 buckets in flight, each going `HASHES` → `WANT` → `ROWS`/`MARKS`; `DONE` when the queue is empty |
| `SERVING` | server | `OPEN` accepted | Answers `MONTHS`, `DAYS`, `HASHES` and `WANT`; ends on `DONE` |
| `DONE` | both | All buckets finished | Session released; `Finished` event with stats |
| `ABORTED` | both | Gate closed, idle timeout, `ABORT` received, or version mismatch | Session released; a secondary's unfinished buckets go back to the primary |

### 12.4 Key flows through the modules

**Award (live):**

1. The existing UI calls `Live.Award(row)`.
2. `Retention.AutoPin(row)` decides whether a pin is created too.
3. `Store:Apply(row)` (and `Store:Apply(pin)`) updates the store and calls `Digest:Add`.
4. `Transport.Send(LIVE_ROW, …, "GUILD", nil, {prio = "ALERT"})`, wrapped in `Gate.QueueLive` while an encounter is active.

**Receiving a sync batch:**

1. AceComm delivers the reassembled string.
2. `Transport` decodes it with `Codec.DecodeMessage` and dispatches it to `Session:Handle`.
3. `Scheduler.Enqueue` runs `Codec.DecodeRows` within the frame budget.
4. `Store:Apply` is called for each row, then `ItemLinks.Resolve`.

**Login:**

1. `Store` loads and migrates, then `Retention.Prune()`, then `Digest.Rebuild()`.
2. `Coordinator` waits for `Gate.CanSync()` and `LOGIN_DELAY`, then calls `Peers.SendHello()`.
3. `Peers.CollectResponders` returns the candidates, and `Coordinator` creates sessions.

### 12.5 SavedVariables schema (v2)

```lua
ForeverLootDB.history = {
  schema     = 2,
  rows       = { [id] = { --[[ existing keyed row ]] itemString = "251533:..." } },
  tombstones = { [id] = { rowTime = 1790779277, deletedAt = 1790800000, deletedBy = "Zerpy Grape" } },
  pins       = { [id] = { rowTime = 1790779277, pinnedAt  = 1790800000, pinnedBy  = "Zerpy Grape" } },
}
```

The migration from schema 1 to 2 adds `itemString` to each row, parsed from its `itemLink`, and creates empty `tombstones` and `pins` tables.

### 12.6 Reference: `Store:Apply`

```lua
function Store:Apply(e, source)
  local id = e.id
  if e.kind == "D" then
    if self.tombstones[id] then return false end
    if self.rows[id] then self.rows[id] = nil; Digest:Remove("R", id, e.rowTime) end
    if self.pins[id] then self.pins[id] = nil; Digest:Remove("P", id, e.rowTime) end
    self.tombstones[id] = { rowTime = e.rowTime, deletedAt = e.at, deletedBy = e.by }
    Digest:Add("D", id, e.rowTime)
  elseif e.kind == "P" then
    if self.tombstones[id] or self.pins[id] then return false end
    self.pins[id] = { rowTime = e.rowTime, pinnedAt = e.at, pinnedBy = e.by }
    Digest:Add("P", id, e.rowTime)
  else -- "R"
    if self.tombstones[id] or self.rows[id] then return false end
    if Retention:IsExpired(e.row.awardedAt) and not self.pins[id] then return false end
    self.rows[id] = e.row
    Digest:Add("R", id, e.row.awardedAt)
  end
  self.callbacks:Fire("EntryApplied", e, source)
  return true
end
```

`Digest:Add` and `Digest:Remove` choose the window or archive tree from `rowTime` and the current cutoff.

## 13. Configuration constants

All tunables live in `Sync/Constants.lua`. Values marked "guild-wide" must match on every client. `PROTO_VERSION` and `RETENTION_MONTHS` are also sent in `HELLO`.

| Constant | Default | Guild-wide | Purpose |
| --- | --- | --- | --- |
| `PROTO_VERSION` | 2 | Yes | Wire format version. Peers with a different value ignore each other. 1 was only used by development builds. |
| `RETENTION_MONTHS` | 4 | Yes | Window length (section 10) |
| `PREFIX_MAIN` | `FLoot` | Yes | Live and control messages |
| `PREFIX_SYNC` | `FLootS1`, `FLootS2`, `FLootS3` | Yes | Bulk `ROWS` and `MARKS` |
| `MAX_RESPONSES` | 5 | Yes | Validation cap |
| `NOTE_MAX_LEN` | 120 | Yes | Validation cap and UI limit |
| `LOGIN_DELAY` | 20 s ± 10 s | No | Delay before the first `HELLO` |
| `PERIODIC_INTERVAL` | 12 min ± 3 min | No | Periodic check |
| `HELLO_REPLY_JITTER` | 0–4 s | No | Delay before `HELLO_ACK` |
| `HELLO_COLLECT_WINDOW` | 12 s | No | How long the opener waits for replies (6 s was too short for WoW Forever's round trip) |
| `HELLO_RETRY` | 30 s, max 3 tries | No | Retry when nobody replies |
| `TARGET_RESPONDERS` | 3 | No | Expected number of `HELLO_ACK`s |
| `PEER_MEMORY` | 30 min | No | Window for counting `knownPeers` |
| `MAX_SECONDARIES` | 2 | No | Pull-only helpers per session |
| `MAX_SERVE` | 2 | No | Inbound sessions served at once |
| `BUCKETS_IN_FLIGHT` | 6 | No | Concurrent buckets per session (sessions are latency-bound, not bandwidth-bound) |
| `BATCH_TARGET_BYTES` | 4,096 (serialized) | No | `ROWS` batch size; batches are actually cut at 40 rows, which lands close to this |
| `SESSION_IDLE_TIMEOUT` | 45 s | No | Drop a silent session |
| `COMBAT_RESUME_DELAY` | 5 s | No | Wait after leaving combat |
| `FRAME_BUDGET_MS` | 4 ms | No | Scheduler time slice |
| `DELETE_POLICY` | `officers` | Yes | `anyone`, `council` or `officers` |
| `OFFICER_RANK_MAX` | 1 | Yes | Highest rank index counted as officer |
| `DOMAIN_HISTORY` | 1 | Yes | Wire id of the loot-history domain; never reused |
| `DOMAIN_COUNCIL_SESSION` | 2 | Yes | Wire id of the council-session domain; never reused |
| `SESSION_END_TTL` | 10 min | No | Unused: ended council sessions are no longer advertised |
| `PRUNE_REAL` | true | No | Real pruning on (it was off until the release) |
| `RATE_LIMITS` | `HELLO` 5, `OPEN` 3 | No | Messages handled per sender per `RATE_LIMIT_WINDOW` (60 s) |
| `MAX_MESSAGE_BYTES` | 65,536 | No | Larger reassembled messages are dropped undecoded |

## 14. Edge cases and failure modes

| Situation | What happens |
| --- | --- |
| A tombstone arrives before its row | The tombstone is stored in the row's bucket (via `rowTime`). When the row arrives later, `Store:Apply` rejects it. |
| The same row arrives live and through sync | The second copy is a no-op. |
| Two clients delete the same row | The first tombstone applied wins locally. The second is ignored, and both clients hash only `D:id`, so digests match. `deletedBy` can differ between clients; it is informational only. |
| A peer disconnects mid-session | The session idle timeout drops it. Secondaries' buckets go back to the primary. Remaining gaps are fixed at the next check. |
| New live data arrives during a session | It changes the digest mid-session. The session finishes what it planned, and the next periodic check reconciles the rest. |
| The month boundary passes during a session | The cutoff moves, so both sides rebuild their trees. The next session compares cleanly. At worst, one session transfers a few rows that are then pruned. |
| Two 32-bit entry hashes collide in one day | The day never matches by hashes. After 2 failed sessions on the same day, that bucket switches to full-id lists (section 5.6). |
| A peer runs a different `PROTO_VERSION` or `RETENTION_MONTHS` | Its `HELLO` is ignored for sync, and the UI shows an "update ForeverLoot" hint when that peer's version is newer. |
| The item is not in the client cache | The row is stored with its `itemString`. The link fills in asynchronously, and the UI shows a placeholder until then. |
| A malformed or hostile batch | Rows that fail validation are skipped. The session continues. A counter per sender is kept for debugging. |
| One client alone holds a row and never logs in again | That row is lost unless it reached someone first. The live broadcast at creation makes this very unlikely during raid nights. |
| The guild is split into two online groups that never overlap | Each group converges on its own. They merge as soon as any one member is online at the same time as the other group. |
| A player is renamed | Old rows keep the old name string. History records what was true at the time. |
| A client's clock is wrong | Timestamps and cutoff come from `GetServerTime()`, not the local clock, so this cannot happen. |

## 15. Testing plan and rollout

All testing happens in the game. The debug system (categories, levels, a copyable log buffer and status commands) is the test harness, and debug commands fake the hard cases: missed data, closed gates and bulk history. The phased build, the exact debug lines and each phase's in-game checklist are in the companion doc, ForeverLoot Sync — Implementation Plan.

### 15.1 Key in-game checks (2–3 clients)

1. Zero-history account backfill timing, compared with section 9.3.
2. Award during a boss encounter: the message is queued and sent after `ENCOUNTER_END`.
3. Enter a dungeon mid-session: `ABORT(gate)` is sent, and the session recovers on exit.
4. `/reload` mid-session.
5. A throttled prefix does not drop messages (confirms the bundled AceComm/CTL version).
6. Item-link rebuild for items that are not cached.

### 15.2 Rollout

1. **Phase 1:** the new store (tombstones, `itemString`) and the codec. Live messages use the new format. A one-time migration adds `itemString` to existing rows by parsing their `itemLink`.
2. **Phase 2:** digests plus `HELLO` with sessions disabled, as a dry run. Log mismatches to measure how often they happen.
3. **Phase 3:** sync sessions on, with a single primary.
4. **Phase 4:** secondaries, pins and pruning.

Every phase increments `PROTO_VERSION` whenever the wire format changes. A client ignores peers on another version, and shows an update hint when the peer's version is newer.

## 16. Open questions

- [x] Is the id format always `<lowercase name>-<realm>-<sessionId>-<itemSession>-<n>`, and whose name is it? Answered: the session leader's fqn, with 3 numbers after it (section 3.5).
- [ ] Is there already a length cap on response notes? If not, is 120 characters acceptable?
- [ ] Which rules define "key items" and "key players" for automatic pins, and who maintains those lists?
- [ ] Is `RETENTION_MONTHS = 4` the right starting value?
- [x] What are the actual addon-message limits in WoW Forever? Measured: no per-prefix throttle, about 0.7 KB/s per sender, messages reordered, GUILD relay broken (section 2).
- [ ] Do stored player names include a realm suffix for players from connected realms?
- [ ] Should the council policy (`DELETE_POLICY = council`) mean the council of the session the row came from, or anyone who has ever been on a council?
