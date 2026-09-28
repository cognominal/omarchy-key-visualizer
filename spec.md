# Key Visualizer — Specification

## Overview

The Key Visualizer shows keystrokes on screen as a small floating card.
It is implemented as two cooperating parts:

1. **Capture** — a Lua script running inside Hyprland's config that listens
   to `input.keyboard.key` events and writes the currently held keys to a
   state file.
2. **Display** — a Quickshell QML panel that watches the state file and
   renders the key history in a floating card.

## Data Model

### State file (`$XDG_RUNTIME_DIR/omarchy-key-visualizer.json`)

Written by the Lua capture on every key change. Format:

```json
{"keys": ["Ctrl", "a"], "t": 1700000000}
```

- `keys`: array of key labels (strings) currently held. Empty array `[]` when
  nothing is pressed.
- `t`: Unix epoch seconds of the write (for staleness detection).

### Entry (in-memory, QML `root.entries` array)

Each entry represents a continuous typing run (one history row). Structure:

```ts
{
  segments: Array<{
    kind: "plain" | "chord",
    keys: string[]
  }>,
  releasedAt: number  // 0 while held, epoch ms when released
}
```

- `kind: "plain"` — typed characters fused without separators.
- `kind: "chord"` — a combo with modifiers, joined with spaces.
- `keys` — raw key labels as received from the Lua (before textSymbols
  mapping). Preserved for comparison (segKeysEqual, isSupersetOf).
- `releasedAt` — `0` while the entry is the current live combo; set to
  `Date.now()` when all keys go up.

### Chip group (derived, per-segment rendering)

Produced by `chipGroups(segments)`. Each segment maps to one group:

```ts
{ kind: "plain" | "chord", text: string }
```

- `text` — the display string: for plain segments the keys are concatenated
  without separators; for chord segments they are joined with spaces.
- All key labels are run through `textSymbols` before joining (so arrows,
  Space, Backspace etc. render as Unicode glyphs).

## Capture side (Lua)

### Key classification

- **Modifier keys**: Super (133/134), Ctrl (37/105), Alt (64/108),
  Alt R (108), Shift (50/62), Menu (135), AltGr (109).
- **Named keys** (non-printable): Esc, Backspace, Tab, Enter, Caps, F1–F24,
  Print, Scroll, Pause, Ins, Home, PgUp, Del, End, PgDn, arrows,
  Space, NumPad keys, media keys, brightness, etc. (defined in the
  `KEYS` table).
- **Character keys** (printable): US layout alphanumeric and symbol keys
  (defined in the `CHARS` table). `SHIFTED` table maps shifted symbols
  (!, @, #, $, %, ^, &, *, (, ), _, +, {, }, :, ", ~, <, >, ?).
  Uppercase letters are produced when Shift is held.

### Label derivation

```
labels() = non-shift-modifiers + Shift?(if binding or no printable) + key_labels
```

- `non_shift_mods_down()` — returns the active modifiers other than Shift,
  in display order: Super, Ctrl, Alt, Alt R, Shift, Menu, AltGr.
- `binding` — true when any non-Shift modifier is held.
- `key_label(kc, binding)`:
  1. If key is in `KEYS` → return the named label (e.g. "Esc", "Up").
  2. Else if in `CHARS` → if `binding` return uppercase; else if Shift
     is down return `SHIFTED[kc]` or uppercase; else return the char.
  3. Unknown key → `"Key " + evdev_code`.

### State emission

The capture writes the state file on every `input.keyboard.key` event
(key down or up). Only the currently *pressed* keys are reported. The
order of non-modifier keys in `combo` is the order they were pressed.

## Display side (QML)

### apply() — state ingestion

Called on every state file change. Routing:

1. **Empty payload** (`next.length === 0`):
   - Current entry (if any) enters its linger window (`releasedAt =
     Date.now()`).
   - If the entry is entirely modifiers (mods of nothing), it is dropped
     immediately instead of lingering.

2. **Still held** (`es[0].releasedAt === 0`):
   - **Same keys** (order-independent equality) → refresh (no-op).
   - **Superset** (keys grew, e.g. `["Ctrl"]` → `["Ctrl", "a"]`) → update
     last segment in place.
   - **Subset** (keys shrank, e.g. `["Ctrl", "a"]` → `["Ctrl"]`) → update
     last segment in place.
   - **Other change** → if new keys are plain and last segment is plain,
     merge into it; otherwise append as new segment.

3. **Released recently** (`releasedAt !== 0`, within linger window):
   - If new keys are plain and last segment is plain, merge keys into it.
   - Otherwise append as new segment.
   - Entry is revived (`releasedAt = 0`).

4. **Stale / no entry** → start a fresh entry.

### chipGroups(segments) — display groups

Each segment becomes one display group:

```
plain segment → [{ kind: "plain", text: keys.join("") }]     // tight
chord segment → [{ kind: "chord", text: keys.join(" ") }]    // spaced
```

All key labels are mapped through `textSymbols` before joining:

| Key label | Unicode | Glyph | Name |
|-----------|---------|-------|------|
| `Space`   | U+2423  | `␣`   | OPEN BOX |
| `Tab`     | U+21E5  | `⇥`   | RIGHTWARDS ARROW TO BAR |
| `Enter`   | U+21B5  | `↵`   | DOWNWARDS ARROW WITH CORNER LEFTWARDS |
| `Backspace` | U+232B | `⌫`  | ERASE TO THE LEFT |
| `Del`     | U+2326  | `⌦`   | ERASE TO THE RIGHT |
| `Esc`     | U+238B  | `⎋`   | BROKEN CIRCLE WITH NORTHWEST ARROW |
| `Up`      | U+2191  | `↑`   | UPWARDS ARROW |
| `Down`    | U+2193  | `↓`   | DOWNWARDS ARROW |
| `Left`    | U+2190  | `←`   | LEFTWARDS ARROW |
| `Right`   | U+2192  | `→`   | RIGHTWARDS ARROW |
| `Caps`    | U+21EA  | `⇪`   | UPWARDS WHITE ARROW FROM BAR |

### Rendering

Each entry renders as a single row inside the card (BorderSurface):

```
┌─────────────────────────────────────┐
│ abc Ctrl A Super ↑ ␣ ⌫ def         │  ← one row per entry
│ ↑plain ↑chord                      │
└─────────────────────────────────────┘
```

- One `Row` per entry (from `displayModel()`).
- Each segment renders as a `Text` item in the row.
- Plain segments: normal text color (`Color.popups.text`).
- Chord segments: accent color (`Color.accent`).
- No per-segment rectangle/chip borders — just colored text.

### Linger / history

- `lingerMs` (config, default 1000ms): how long a released entry stays
  visible before being pruned.
- `lingerMs = 0`: never prune (entry stays until pushed out by cap).
- `historyCount` (config, default 1, range 1–5): how many entries stack.
- A 250ms timer prunes expired entries and caps the stack.

## Configuration

Written to `~/.config/omarchy/key-visualizer.json`. Hot-reloaded.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `position` | string | `"bottom-center"` | Screen edge: `top-*` / `bottom-*` + `left`/`center`/`right` |
| `margin` | int | 67 | Distance from screen edge (px) |
| `lingerMs` | int | 1000 | How long a released entry stays (ms); 0 = keep until next key |
| `historyCount` | int | 1 | Number of stacked entries (1–5) |
| `showMouse` | bool | true | Show mouse icon with lit buttons |
| `cursorRing` | bool | true | Ring around cursor while mouse button held |
| `offsetX` | int | 0 | Fine-tune horizontal offset (px) |
| `offsetY` | int | 0 | Fine-tune vertical offset (px) |

## Bar menu

The bar icon (keyboard glyph) opens a popup with:

- **Show keys** — pause/resume toggle.
- **Show mouse buttons** — toggle mouse chip.
- **Cursor ring** — toggle cursor ring.
- **Position** — dropdown (6 presets).
- **D-pad** — fine-tune position by 4px nudges.

No "Display mode" filter (always shows all keys). No "Inline keys"
toggle (always inline, chords always in accent color).

## Edge cases

1. **Mods of nothing**: An entry that contains only modifier keys (e.g.
   just `["Ctrl"]`) is dropped the moment all keys go up — no linger,
   no history row. While held it appears on screen.

2. **Autorepeat / duplicate write**: Same-key payload while held is
   silently ignored (refreshes the entry, no duplicate segment).

3. **Stale capture**: If the state file stops updating for >1.5s while
   an entry is held, the entry is treated as released (self-heals).

4. **Max keys**: The total key count across all segments is capped at 24
   (`typingGroupMaxKeys`). Oldest segments are dropped first.

5. **Chord building**: Intermediate states (Ctrl down, then Ctrl+A) update
   the last segment in place — no duplicate segments for partial chords.

6. **Chord teardown**: Releasing a key from a chord (Ctrl+A → Ctrl while
   Ctrl still held) updates the segment in place.

7. **Consecutive plain typing**: Each key press merges into the last plain
   segment if within the linger window — no per-key segment fragmentation.