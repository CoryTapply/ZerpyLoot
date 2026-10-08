# ForeverLoot

Loot council, roll tracking, soft-reserves and synced guild loot history. It speaks Gargul's addon-comm protocol, so ForeverLoot and Gargul users in the same raid can work together.

## Features

- **Loot council.** The raid leader starts a session for one or more items. Raiders answer with configurable response buttons (saved as profiles), and council members review the responses and award the items.
- **Loot history.** Every award is recorded and kept per guild. History syncs automatically between guild members running ForeverLoot.
- **Roll tracker.** Tracks roll-offs and announces soft-reserves for the item. When an item you soft-reserved comes up, it gets a gold border and its own alert sound.
- **Soft-reserves.** Imports softres.it's "Gargul Export" string and broadcasts it to the raid in a format Gargul can read.
- **Trade queue.** Lists items you still need to trade and highlights them in your bags (EllesmereUI Bags and Baganator are supported).
- **Automatic rolls.** Optional Need/Greed/Pass rules for Group Loot in raids and dungeons.

## Commands

| Command | What it does |
| --- | --- |
| `/fl` | Open settings |
| `/fl history` (`/fl h`) | Loot history window |
| `/fl roll [item link]` | Start a roll-off for that item |
| `/fl softres` | SoftRes import window |
| `/fl tradequeue` | Trade queue window |
| `/fl autoroll` | Automatic Rolls popup for your current raid or dungeon |
| `/fl minimap` | Show or hide the minimap button |
| `/fl resetpositions` | Reset every window to its default position |
| `/flc` | Loot council window (`/flc help` lists the council commands) |
| `/fl debug` | Debug log window |

## Sync

History sync runs only between members of your own guild, and everyone needs the same sync protocol version. When a release bumps the protocol (the changelog says so), everyone in the guild has to update before sync works again.

## Reporting bugs

Please include:

1. Your ForeverLoot version (shown in the AddOns list).
2. What you did and what happened.
3. Any Lua error text (turn errors on with `/console scriptErrors 1`).
4. For sync problems, a copy of the `/fl debug` log from around the time it happened.

## License

MIT, see [LICENSE](LICENSE). The bundled libraries and font keep their own licenses, which are listed there.

## Releasing

Pushing a version tag releases automatically (`.github/workflows/release.yml`):

1. Bump `## Version` in `ForeverLoot.toc`, add a matching `## <version>` heading to `CHANGELOG.md`, and commit.
2. `git tag v<version> && git push && git push --tags`

The workflow checks that the tag matches the TOC version and that the changelog has a section for it. It then builds the zip with `tools/package.sh`, uploads it to CurseForge with that changelog section, and creates a GitHub Release. Versions containing `alpha` or `beta` (e.g. `0.2.3-beta1`) upload as Alpha or Beta and are marked as prereleases on GitHub.

To release by hand instead, run `tools/package.sh`, then either `CF_API_KEY=... CF_GAME_VERSIONS=... tools/upload-curseforge.sh dist/ForeverLoot-<version>.zip <version>` or upload the zip on the CurseForge site.
