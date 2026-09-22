# Adding a skin

A skin is one Lua file in this folder that calls `FL.Theme.RegisterSkin(key, def)`.

1. Create `UI/Theme/Skins/MySkin.lua`.
2. Add `UI\Theme\Skins\MySkin.lua` to `ForeverLoot.toc` **after** its base skin's file. TOC order is also the order of the options dropdown.

Nothing else changes: the dropdown, settings and every window pick the skin up from the registry.

## Smallest possible skin: a recolor

```lua
local FL = ForeverLoot;

FL.Theme.RegisterSkin("crimson", {
    name = "Crimson",                        -- dropdown label
    colors = { accent = { 0.8, 0.1, 0.1, 1 }, accentHover = { 0.9, 0.3, 0.3, 1 } },
});
```

`base` defaults to `"default"`. Anything the skin doesn't define comes from its base, so this gets the whole flat look with a red accent. Set `base = "blizzard"` to build on the Blizzard art instead (see `BlizzardThin.lua`).

## What a skin can define

Everything is optional; missing values and methods are inherited. Skins never reach into each other's files, only into their base.

**`colors`** - `windowBackground`, `windowBorder`, `outline`, `button`, `buttonHover`, `buttonBorder`, `close`, `closeHover`, `input`, `inputBorder`, `scrollbarThumb`, `scrollbarTrack`, `scrollbarBorder`, `accent`, `accentHover`, `danger`, `warning`, and `title` (window title color, falls back to `accent`).

**`metrics`** - `smallWindowHeight`, `countdownBarHeight`, `secondsBoxGap`, `deleteButtonArtKit`. Windows read these instead of checking which skin is active.

**`resizeHandle`** - look of the bottom-edge drag handle; fields (including `hitOffsetY`, `opacity`, and `tintChrome` / `dragOpacity`, which tint the chrome art via its `SetResizeHighlight(color, strength)` method instead of drawing a line) are documented above `Theme.MakeBottomResizable` in `Window.lua`.

**Methods** (plain functions, no `self`; read colors and metrics via `FL.Theme.colors` / `FL.Theme.metrics` so derived skins recolor them):

| Method | Purpose |
| --- | --- |
| `CreateWindowChrome(frame, width, height)` | Build border/background art and return it, or `nil` to use `ApplyWindowBackdrop` |
| `ApplyWindowBackdrop(frame)` | Backdrop for windows without chrome |
| `SetWindowBorderColor(frame, color)` | Recolor/reset the border of a chrome-less window |
| `CreateButton(parent)`, `CreateScrollFrame(parent)` | Which Blizzard template to use |
| `SkinButton(button, variant)` | `variant` is `"normal"`, `"accent"` or `"close"` |
| `SkinEditBox(editBox)`, `SkinInputBackground(frame)` | Inputs |
| `SkinBorder(frame)` | Flat outline around any frame |
| `SkinIconBorder(frame, icon)`, `SetIconBorderQuality(frame, quality)` | Item icon border and rarity tint |
| `SkinBarBorder(frame, bar)` | Status bar border |
| `StyleScrollBar(bar)` | Scrollbar look (auto-hide is handled by the core) |

`FL.Theme.Helpers` has shared building blocks (`SetFlatBackdrop`, `EnsureBackdrop`, `CreateChromeFrame`, `SetChromeAlertBorder`, `FLAT_TEXTURE`).

## Rules that keep skins independent

- Register with a unique key; a base must be loaded before the skins that extend it.
- Keep art constants and helper functions local to the skin's own file.
- Don't branch on the skin's key anywhere outside its own file. If a window needs a skin-dependent number, add a `metrics` entry (with a value in `Default.lua`) instead.
- Themes are locked in at login, so a skin change takes a `/reload`.
