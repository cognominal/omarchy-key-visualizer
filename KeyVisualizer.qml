import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Key Visualizer — shows the keys you press as small chips at the bottom of
// the screen. The capture side is key-visualizer.lua (Hyprland Lua): it listens
// to the compositor's key events and writes the current combination to
// $XDG_RUNTIME_DIR/omarchy-key-visualizer.json. This panel watches that file
// and renders. No images, no animations: the combo appears while held and
// lingers briefly after release (like keyviz's Duration), then vanishes.
// With historyCount > 1 the last few combos stack as a fading history,
// keyviz-style.
//
// On first load the panel also appends a small guarded block to
// ~/.config/hypr/hyprland.lua that dofiles the capture script, so install
// is just add + enable; Hyprland auto-reloads its config on save. The
// block no-ops if the plugin folder is later removed.
Item {
  id: root

  property bool opened: false
  // History of recent combinations, newest first. Each entry is
  // { keys: [...], releasedAt: 0|ms }: 0 while it is the combo currently
  // being pressed; an epoch ms once a newer combo or a release superseded
  // it. The history tick prunes entries whose linger window passed. With
  // historyCount 1 this is exactly "the current combo, lingering".
  property var entries: []
  // Epoch (seconds) of the last state payload we successfully parsed. Used
  // to detect a dead capture: if no new payload arrives within maxStateAgeMs
  // and the top combo was never released, we treat it as released so the
  // panel self-heals instead of freezing on a stale combo forever.
  property real lastStateT: 0
  // Raw JSON of the last `keys` array actually applied. The Lua side
  // chmods the state file after every write (secure_write), which fires a
  // second, content-identical file-changed event; without this guard that
  // redundant re-apply() re-derives the same "next" from a since-mutated
  // top entry (e.g. after a merge) and no longer recognizes it as the same
  // combo, corrupting the history. Any repeat of the same payload is a
  // pure echo and is skipped outright.
  property string lastAppliedNextRaw: ""
  // How many combos stay on screen (1..5, default 1). Older entries fade
  // out via the entryOpacity() gradient; a count of 1 is the classic
  // current-combo-only display.
  property int historyCount: 1
  // How long the last combination stays on screen after the keys are
  // released (keyviz's "Duration"; keyviz defaults to 5000ms). The combo
  // lingers intact, then vanishes in one frame — no fade. 0 means "always
  // show": entries never expire, so the stack only shrinks when newer
  // combos push old ones out of the history window.
  property int lingerMs: 1000
  // Manual fine-tune offsets (px) applied on top of the preset position.
  // Written by the panel D-pad buttons; reset when a dropdown preset is chosen.
  property int offsetX: 0
  property int offsetY: 0
  // Adaptive vertical anchor: when the newest row's Y is in the upper half the
  // group is top-anchored (history grows down, newest at top) so the newest
  // chip stays at a stable Y; in the lower half it is bottom-anchored (grows
  // up). offsetY is ALWAYS the absolute Y of the newest row's top edge, so the
  // D-pad and the drag both mean the same thing and never diverge. The card's
  // Y is derived from offsetY below, so crossing the half never jumps.
  property bool isTopHalf: false
  function updateIsTopHalf() {
    if (!panel) return
    var n = root.offsetY < panel.height / 2
    if (n !== isTopHalf) isTopHalf = n
  }

  // Drop state written more than this long ago (e.g. from a previous shell
  // session after a restart) so a stale combo never sticks on screen.
  readonly property int maxStateAgeMs: 1500

  // Cap on how many plain typed keys accumulate into one box (see apply()'s
  // typing-merge branch) before the oldest are dropped, so a long typing
  // burst never grows the card past a sane width.
  readonly property int typingGroupMaxKeys: 24

  // Options read from config.json in the plugin folder (created with
  // defaults on first run, hot-reloaded on save):
  //   position one of the six corners/edges: top/bottom + left/center/right.
  //            Middle positions were dropped — the stack anchors to the top
  //            (grows down) or the bottom (grows up) edge.
  //   margin   distance from the screen edge in px (default 67).
  //   lingerMs how long a released combo stays (default 1000).
  //   historyCount how many combos stack on screen (1..5, default 1).
  property string position: "bottom-center"
  property int margin: Style.space(67)
  //   showMouse  show a mouse box beside the card that lights up the
  //              clicked button (default true).
  //   cursorRing draw a ring around the cursor while a button is held
  //              (default true).
  property bool showMouse: true
  property bool cursorRing: true
  readonly property var modLabels: ["Super", "Ctrl", "Alt", "Alt R", "Shift", "Menu", "AltGr"]

  // Options live at ~/.config/omarchy/key-visualizer.json rather than inside the
  // plugin folder on purpose: the shell watches every file under
  // ~/.config/omarchy/plugins/ and reloads all plugin code on any change, so
  // a config edit there would tear down and rebuild the panel. Editing this
  // file updates the display live.
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/key-visualizer.json"
  // Pre-1.3.1 config lived in the watched plugin dir; migrated once on first
  // load after the move.
  readonly property string legacyConfigPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/felixzsh.key-visualizer/config.json"

  readonly property string statePath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime || runtime.length === 0) return ""
    if (runtime === "/tmp") return ""
    return runtime + "/omarchy-key-visualizer.json"
  }

  // Super-held flag written by the Lua capture hook. While Super is down the
  // overlay's input mask covers the card, so a SUPER+drag moves the visualizer
  // itself (the Lua has unbound the compositor's SUPER+mouse while it is mapped).
  property bool superHeld: false
  readonly property string superPath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime || runtime.length === 0) return ""
    if (runtime === "/tmp") return ""
    return runtime + "/omarchy-key-visualizer-super"
  }
  // True while the cursor hovers the card with Super held: the moment when the
  // compositor's SUPER+mouse move/resize binds are temporarily unbound so the
  // drag captures the visualizer instead of a window underneath.
  property bool overCard: false
  // Whether the SUPER+mouse binds are currently unbound by us (avoids redundant
  // hyprctl eval calls on every hover transition).
  property bool dragArmed: false
  // Debug overlay: shows the live position/dimensions/quadrant of the card
  // next to it, while dragging and after release. Toggled via the plugin CLI.
  property bool debugOverlay: false

  Component.onCompleted: updateIsTopHalf()

  // Latch the vertical anchor (top/bottom half) whenever the offset changes
  // (drag or D-pad). Typing only changes card height/entries, not offsetY, so
  // this does not fire while a combo is being held.
  onOffsetYChanged: updateIsTopHalf()

  // Pause flag shared with the bar widget: while the file holds "1" the
  // display is frozen (keys are ignored). The bar button writes/removes the
  // file; both sides watch it, so a click on any monitor updates all of them.
  property bool paused: false
  // Persisted next to the config so the pause state survives restarts
  // (the runtime dir is wiped on reboot).
  readonly property string pausePath: Quickshell.env("HOME") + "/.config/omarchy/key-visualizer.paused"

  // ------------------------------------------------------------- layout

  readonly property int cardPad: Style.space(10)
  readonly property int chipGap: Style.space(8)
  readonly property int entryGap: Style.space(6)
  readonly property int chipPadX: Style.space(9)
  readonly property int chipPadY: Style.space(4)
  readonly property int chipHeight: Math.ceil(chipFontMetrics.height) + 2 * chipPadY

  // Groups the entry's keys into chips: a "named" key (Esc, Tab, F1,
  // Backspace, Super, ...) always has a multi-character label and gets its
  // own chip, collapsing a run of identical repeats (autorepeat, or the
  // same key retyped back to back) into a "Label×N" count badge — it reads
  // as itself, not as a word, so spelling it out N times would just be
  // noise. A single printable character is different: it already reads
  // fine repeated (autorepeat "a" is legibly "aaaaaa"), so consecutive
  // single-character keys are grouped into one chip and printed as a plain
  // fused string instead, with no count suffix and no per-letter borders.
  // Space and Tab typed without modifiers are part of the text too, so
  // they're rendered as their Unicode symbols (␣, ⇥) and fused into the
  // current string chip; other action keys (Enter, Backspace, Del, Esc)
  // also get a Unicode glyph (↵, ⌫, ⌦, ⎋) so they're legible in the
  // typing stream. Directional arrows get symbols (↑ ↓ ← →) as well.
  // TextSymbols apply to all keys regardless of chord status, so "Ctrl ↑"
  // reads as a direction shorthand instead of "Ctrl Up".
  readonly property var textSymbols: ({
    "Space": "\u2423",     // ␣  OPEN BOX
    "Tab": "\u21E5",       // ⇥  RIGHTWARDS ARROW TO BAR
    "Enter": "\u21B5",      // ↵  DOWNWARDS ARROW WITH CORNER LEFTWARDS
    "Backspace": "\u232B",  // ⌫  ERASE TO THE LEFT
    "Del": "\u2326",        // ⌦  ERASE TO THE RIGHT
    "Esc": "\u238B",        // ⎋  BROKEN CIRCLE WITH NORTHWEST ARROW
    "Up": "\u2191",        // ↑  UPWARDS ARROW
    "Down": "\u2193",      // ↓  DOWNWARDS ARROW
    "Left": "\u2190",      // ←  LEFTWARDS ARROW
    "Right": "\u2192",     // →  RIGHTWARDS ARROW
    "Caps": "\u21EA",       // ⇪  UPWARDS WHITE ARROW FROM BAR
  })

  function chipGroups(segments) {
    var groups = []
    for (var si = 0; si < segments.length; si++) {
      var seg = segments[si]
      var mapped = seg.keys.map(function (k) { return root.textSymbols[k] || k })
      var joined = seg.kind === "chord" ? mapped.join(" ") : mapped.join("")
      groups.push({ kind: seg.kind, text: joined })
    }
    return groups
  }

  function groupDisplayText(group) {
    return group.text
  }

  // Mouse buttons: each has its own color, used both for the highlighted
  // segment of the fixed mouse chip and for the cursor ring.
  readonly property var buttonColors: ({ "L": "#4c9aff", "M": "#2ecc71", "R": "#ff9f43" })
  readonly property int mouseIconHeight: Math.round(chipFontMetrics.height * 1.15)
  readonly property int mouseIconWidth: Math.round(mouseIconHeight * 0.7)

  // Stateless measurement: FontMetrics.advanceWidth(text) returns the
  // width for the given string directly. The previous shared TextMetrics
  // (text set imperatively inside the width bindings) went stale from the
  // third chip onwards, collapsing every container to single-char width.
  function chipGroupWidth(group) {
    return Math.ceil(chipFontMetrics.advanceWidth(root.groupDisplayText(group))) + 2 * chipPadX
  }

  function rowWidth(segments) {
    var groups = root.chipGroups(segments)
    var w = 0
    for (var i = 0; i < groups.length; i++) w += root.chipGroupWidth(groups[i])
    return w + Math.max(0, groups.length - 1) * chipGap
  }

  // The card sizes to the widest history row, not the current one, so a
  // wider older entry never clips.
  function contentWidth() {
    var w = 0
    for (var i = 0; i < root.entries.length; i++) w = Math.max(w, rowWidth(root.entries[i].segments))
    return w
  }

  function contentHeight() {
    if (root.entries.length === 0) return 0
    return root.entries.length * root.chipHeight + (root.entries.length - 1) * root.entryGap
  }

  function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
  }

  // Y of the card's top edge derived from offsetY (the newest row's top Y).
  // In the top half the newest is the first row (card top); in the bottom half
  // it is the last row (card bottom). This keeps the newest at offsetY in both
  // halves regardless of how many entries are stacked.
  function cardTopY() {
    var borderTop = card ? card.borderTop : 0
    var pad = root.cardPad
    if (root.isTopHalf) return root.offsetY - borderTop - pad
    return root.offsetY - borderTop - pad - (root.contentHeight() - root.chipHeight)
  }

  // Default newest-row Y for the current preset. offsetY==0 means "preset
  // default" (the dropdown resets it), so we map it to where the preset anchors
  // the group: top presets put the newest near the top edge, bottom presets
  // near the bottom edge.
  function defaultOffsetY() {
    if (!panel) return 0
    var borderTop = card ? card.borderTop : 0
    var borderBottom = card ? card.borderBottom : 0
    if (root.position.indexOf("top") !== -1) return root.margin + borderTop + root.cardPad
    return panel.height - root.margin - borderBottom - root.cardPad - root.chipHeight
  }

  // History stacking direction derived from the adaptive anchor. Recomputed
  // after drag release / offset changes so it follows the card.
  function stackDown() {
    return root.isTopHalf
  }

  // Stack fade: the current combo is fully opaque and every older entry
  // steps down in opacity (tunable here). Clamped so the oldest row of a
  // 5-deep stack stays readable.
  function entryOpacity(pos) {
    return Math.max(0.25, 1 - pos * 0.22)
  }

  // Strict superset: every key of `base` is in `next` and `next` has more
  // keys. The Lua emits on every key-down, so a chord pressed key-by-key
  // without releasing arrives as growing states (Super, then Super Ctrl,
  // then Super Ctrl Shift...). Those partials must never become history
  // rows — only the complete combo at release matters.
  function isSupersetOf(base, next) {
    if (next.length <= base.length) return false
    for (var i = 0; i < base.length; i++) if (next.indexOf(base[i]) === -1) return false
    return true
  }

  function trimEntries(list) {
    while (list.length > root.historyCount) list.pop()
    return list
  }

  // Row order for the card. When the card sits in the bottom half the history
  // stacks upward with the newest on the bottom edge; in the top half it
  // stacks downward with the newest on top. Each item carries its original
  // index so the fade always measures distance from the newest combo.
  function displayModel() {
    var list = []
    var n = root.entries.length
    if (!root.stackDown()) {
      for (var i = n - 1; i >= 0; i--) list.push({ entry: root.entries[i], pos: i })
    } else {
      for (var j = 0; j < n; j++) list.push({ entry: root.entries[j], pos: j })
    }
    return list
  }

  function modCountOf(keys) {
    var n = 0
    for (var i = 0; i < keys.length; i++) if (root.modLabels.indexOf(keys[i]) !== -1) n++
    return n
  }

  FontMetrics {
    id: chipFontMetrics
    font: chipFont
  }

  readonly property var chipFont: Qt.font({
    family: Style.font.family,
    pixelSize: Style.font.title,
    bold: true
  })

  // ------------------------------------------------------------- state

  // Each entry in root.entries is:
  //   { segments: [{ kind: "plain"|"chord", keys: [label, ...] }],
  //     releasedAt: 0|ms }
  // "plain" segments are typed characters fused tight; "chord" segments
  // are combos with modifiers, joined with spaces and rendered in accent.
  // Everything appends to the current entry — no separate history rows.

  function apply() {
    var next = []
    if (!root.paused) {
      try {
        var parsed = JSON.parse(stateFile.text())
        if (parsed && Array.isArray(parsed.keys)) {
          var age = Math.floor(Date.now() / 1000) - (parsed.t || 0)
          if (age <= Math.ceil(root.maxStateAgeMs / 1000)) next = parsed.keys
          if ((parsed.t || 0) > 0) root.lastStateT = parsed.t
        }
      } catch (e) {}
    }

    var nextRaw = JSON.stringify(next)
    if (nextRaw === root.lastAppliedNextRaw) return
    root.lastAppliedNextRaw = nextRaw

    var isChord = root.modCountOf(next) > 0
    var es = root.entries.slice()

    if (next.length === 0) {
      // All keys released: the current entry enters its linger window.
      if (es.length > 0 && es[0].releasedAt === 0) {
        var allSegKeys = []
        for (var si = 0; si < es[0].segments.length; si++)
          allSegKeys = allSegKeys.concat(es[0].segments[si].keys)
        // A chord made only of modifiers is "mods of nothing": drop it.
        if (root.modCountOf(allSegKeys) >= allSegKeys.length) {
          es.shift()
        } else {
          es[0] = { segments: es[0].segments, releasedAt: Date.now() }
        }
      }
    } else if (es.length > 0 && es[0].releasedAt === 0) {
      // Still held. Refresh or append.
      var lastSeg = es[0].segments[es[0].segments.length - 1]
      if (lastSeg && lastSeg.kind === (isChord ? "chord" : "plain")
          && root.segKeysEqual(lastSeg.keys, next)) {
        // Same keys again (autorepeat / duplicate write): refresh, no
        // duplicate segment.
        es[0] = { segments: es[0].segments, releasedAt: 0 }
      } else if (lastSeg && lastSeg.kind === (isChord ? "chord" : "plain") && root.isSupersetOf(lastSeg.keys, next)) {
        // Building a chord key-by-key: update the last segment in place.
        es[0].segments[es[0].segments.length - 1] = { kind: lastSeg.kind, keys: next.slice() }
        es[0] = { segments: es[0].segments, releasedAt: 0 }
      } else if (lastSeg && lastSeg.kind === (isChord ? "chord" : "plain")
                 && next.length < lastSeg.keys.length
                 && next.every(function(k) { return lastSeg.keys.indexOf(k) !== -1 })) {
        // Chord teardown: a modifier/released key went up. Update the
        // last segment in place instead of appending a duplicate.
        es[0].segments[es[0].segments.length - 1] = { kind: lastSeg.kind, keys: next.slice() }
        es[0] = { segments: es[0].segments, releasedAt: 0 }
      } else {
        // New keys while still holding: merge into the last plain segment
        // if still plain, otherwise append as a new segment.
        var appended = es[0].segments.slice()
        var lastSeg = appended[appended.length - 1]
        if (!isChord && lastSeg && lastSeg.kind === "plain") {
          var mergedKeys = lastSeg.keys.concat(next)
          if (mergedKeys.length > root.typingGroupMaxKeys)
            mergedKeys = mergedKeys.slice(mergedKeys.length - root.typingGroupMaxKeys)
          appended[appended.length - 1] = { kind: "plain", keys: mergedKeys }
        } else {
          appended.push({ kind: isChord ? "chord" : "plain", keys: next.slice() })
          // Cap total keys to typingGroupMaxKeys (drop oldest segments first).
          var total = 0
          for (var si2 = 0; si2 < appended.length; si2++)
            total += appended[si2].keys.length
          while (total > root.typingGroupMaxKeys && appended.length > 1) {
            total -= appended[0].keys.length
            appended.shift()
          }
        }
        es[0] = { segments: appended, releasedAt: 0 }
      }
    } else {
      // Previous entry was released (or none exists).
      if (es.length > 0 && es[0].releasedAt !== 0 &&
          (root.lingerMs <= 0 || Date.now() - es[0].releasedAt < root.lingerMs * 2 / 3)) {
        // Released recently: merge into the last plain segment if still
        // plain, otherwise append as a new segment.
        var appended = es[0].segments.slice()
        var lastSeg = appended[appended.length - 1]
        if (!isChord && lastSeg && lastSeg.kind === "plain") {
          var mergedKeys = lastSeg.keys.concat(next)
          if (mergedKeys.length > root.typingGroupMaxKeys)
            mergedKeys = mergedKeys.slice(mergedKeys.length - root.typingGroupMaxKeys)
          appended[appended.length - 1] = { kind: "plain", keys: mergedKeys }
        } else {
          appended.push({ kind: isChord ? "chord" : "plain", keys: next.slice() })
          // Cap total keys to typingGroupMaxKeys (drop oldest segments).
          var total = 0
          for (var si2 = 0; si2 < appended.length; si2++)
            total += appended[si2].keys.length
          while (total > root.typingGroupMaxKeys && appended.length > 1) {
            total -= appended[0].keys.length
            appended.shift()
          }
        }
        es[0] = { segments: appended, releasedAt: 0 }
      } else {
        // Stale release or no entry: start fresh.
        if (es.length > 0 && es[0].releasedAt === 0) {
          es[0] = { segments: es[0].segments, releasedAt: Date.now() }
        }
        es.unshift({ segments: [{ kind: isChord ? "chord" : "plain", keys: next.slice() }], releasedAt: 0 })
      }
    }
    root.entries = root.trimEntries(es)
    root.updateOpened()
  }

  // Whether two key arrays are equal (order-independent).
  function segKeysEqual(a, b) {
    if (a.length !== b.length) return false
    var sa = a.slice().sort()
    var sb = b.slice().sort()
    for (var i = 0; i < sa.length; i++) if (sa[i] !== sb[i]) return false
    return true
  }

  // Prunes entries whose linger window passed and caps the stack at
  // historyCount, keyviz's tick-style. With lingerMs 0 entries never
  // expire: the stack only shrinks when newer combos push old ones out.
  Timer {
    id: historyTick
    interval: 250
    repeat: true
    running: root.entries.length > 0
    onTriggered: {
      // If the capture stopped updating (crashed, plugin unloaded, or a
      // config reload disabled it), the top combo may be stuck with
      // releasedAt === 0 forever because no empty "all keys up" payload
      // ever arrives. Treat a stale state file as a release so the combo
      // lingers normally and then clears, instead of freezing on screen.
      if (root.entries.length > 0 && root.entries[0].releasedAt === 0 &&
          root.lastStateT > 0 &&
          Math.floor(Date.now() / 1000) - root.lastStateT > Math.ceil(root.maxStateAgeMs / 1000)) {
        root.entries[0] = { segments: root.entries[0].segments, releasedAt: Date.now() }
      }
      var now = Date.now()
      var kept = []
      for (var i = 0; i < root.entries.length; i++) {
        var e = root.entries[i]
        if (e.releasedAt === 0 || root.lingerMs <= 0 || now - e.releasedAt < root.lingerMs) kept.push(e)
      }
      root.entries = root.trimEntries(kept)
      root.updateOpened()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.apply()
    onFileChanged: reload()
  }

  FileView {
    id: pauseFile
    path: root.pausePath
    watchChanges: true
    printErrors: false
    onLoaded: root.pauseLoaded(text() === "1")
    onFileChanged: reload()
  }

  FileView {
    id: superFile
    path: root.superPath
    watchChanges: true
    printErrors: false
    onLoaded: root.superHeld = (text() === "1")
    onFileChanged: reload()
  }

  // ------------------------------------------------------- cursor ring

  // Written by the Lua capture while a mouse button is held:
  // { buttons: ["L", ...], x, y } in global compositor coordinates.
  readonly property string mousePath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (!runtime || runtime.length === 0) return ""
    if (runtime === "/tmp") return ""
    return runtime + "/omarchy-key-visualizer-mouse.json"
  }
  property var ringButtons: []
  // Last non-empty set of held buttons: what the ring draws, so it keeps
  // its colors while fading out after release.
  property var ringShown: []
  property real ringX: 0
  property real ringY: 0
  readonly property int ringSize: Style.space(44)
  readonly property int ringStroke: Math.max(3, Style.space(4))

  // Mouse box: a small box of its own, on screen the whole time the
  // visualizer is on, pinned at the position preset's anchor (plus the drag
  // offset) so it never moves while typing. The key card sits beside it.
  // The held buttons light up; a quick click stays lit for mouseFlashMs.
  property var mouseHeld: []
  property var mouseLit: []
  readonly property bool mouseBoxOn: root.showMouse && !root.paused
  readonly property int mouseFlashMs: 300

  function updateOpened() {
    root.opened = root.entries.length > 0
  }

  // Top-left corner of the mouse box, in panel coordinates.
  function mouseBoxX() {
    var w = mouseBox.width
    var p = root.position
    var base = 0
    if (p.indexOf("left") !== -1) base = root.margin
    else if (p.indexOf("right") !== -1) base = panel.width - w - root.margin
    else base = Math.round((panel.width - w) / 2)
    return root.clamp(base + root.offsetX, 0, panel.width - w)
  }

  function mouseBoxY() {
    return root.clamp(root.offsetY - mouseBox.borderTop - root.cardPad, 0, panel.height - mouseBox.height)
  }

  // X for a box of width w placed beside the mouse box on the inward side:
  // left of it for right-anchored presets, right of it otherwise. Used by
  // the key card and the on/off notice.
  function besideMouseBoxX(w) {
    if (root.position.indexOf("right") !== -1) return root.mouseBoxX() - root.chipGap - w
    return root.mouseBoxX() + mouseBox.width + root.chipGap
  }

  // On/off notice, shown briefly in its own box when the display is paused
  // or resumed, never in the key history.
  property string statusText: ""

  Timer {
    id: statusTimer
    interval: 1500
    onTriggered: root.statusText = ""
  }

  Timer {
    id: mouseFlashTimer
    interval: root.mouseFlashMs
    onTriggered: if (root.mouseHeld.length === 0) root.mouseLit = []
  }

  function applyMouse(raw) {
    var buttons = []
    var parsed = null
    try { parsed = JSON.parse(raw || "{}") } catch (e) {}
    if (parsed && Array.isArray(parsed.buttons) && !root.paused) buttons = parsed.buttons
    var prevHeld = root.mouseHeld
    root.mouseHeld = buttons
    if (buttons.length > 0) {
      mouseFlashTimer.stop()
      root.mouseLit = buttons
    } else if (prevHeld.length > 0) {
      mouseFlashTimer.restart()
    }
    if (!root.cursorRing) buttons = []
    if (buttons.length > 0 && isFinite(parsed.x) && isFinite(parsed.y)) {
      root.ringX = parsed.x
      root.ringY = parsed.y
    }
    var wasHeld = root.ringButtons.length > 0
    root.ringButtons = buttons
    if (buttons.length > 0) {
      if (JSON.stringify(buttons) !== JSON.stringify(root.ringShown)) root.ringShown = buttons
      ringFade.stop()
      cursorRingItem.opacity = 1
    } else if (wasHeld) {
      // Released: the ring stays where the button went up and fades out,
      // keeping the colors of the last held set.
      ringFade.restart()
    }
  }

  FileView {
    id: mouseFile
    path: root.mousePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyMouse(text())
    onFileChanged: reload()
  }

  onRingShownChanged: ringCanvas.requestPaint()

  onPausedChanged: if (root.paused) {
    root.entries = []
    root.opened = false
  }

  // False until the pause flag has been read once, so the shell starting up
  // (or reloading the plugin) does not flash the on/off notice.
  property bool pauseStateKnown: false

  // Applies the pause flag and, on a real change, shows a transient
  // "Key visualizer on/off" notice in its own box beside the mouse box —
  // on every monitor, since each instance watches the flag.
  function pauseLoaded(p) {
    var changed = root.pauseStateKnown && p !== root.paused
    root.paused = p
    root.pauseStateKnown = true
    if (!changed) return
    root.lastAppliedNextRaw = ""
    root.statusText = "Key visualizer " + (p ? "off" : "on")
    statusTimer.restart()
  }

  function setPaused(p) {
    if (p === root.paused) return
    // Always rewrite the flag with "0" or "1", never delete it: the
    // FileView watcher fires on content changes but not on deletion.
    var cmd = p
      ? "printf 1 > " + Util.shellQuote(root.pausePath)
      : "printf 0 > " + Util.shellQuote(root.pausePath)
    pauseToggleProc.command = ["sh", "-c", cmd]
    pauseToggleProc.running = true
  }

  Process {
    id: pauseToggleProc
  }

  // --------------------------------------------------------------- options

  function applyConfig(raw) {
    var cfg = {}
    try { cfg = JSON.parse(raw || "{}") } catch (e) {}
    if (typeof cfg.position === "string" && cfg.position.length > 0) {
      // Pre-history versions had middle positions ("center-left" etc.);
      // they were dropped, so fold any leftover into the bottom row.
      var pos = cfg.position
      if (pos.indexOf("center") === 0 || pos.indexOf("middle") === 0) pos = "bottom" + pos.slice(pos.indexOf("-"))
      root.position = pos
    }
    if (isFinite(cfg.margin) && cfg.margin >= 0) root.margin = Math.round(cfg.margin)
    if (isFinite(cfg.lingerMs) && cfg.lingerMs >= 0) root.lingerMs = Math.round(cfg.lingerMs)
    if (isFinite(cfg.historyCount)) root.historyCount = Math.max(1, Math.min(5, Math.round(cfg.historyCount)))
    root.showMouse = cfg.showMouse !== false
    root.cursorRing = cfg.cursorRing !== false
    if (isFinite(cfg.offsetX)) root.offsetX = Math.round(root.clamp(cfg.offsetX, -2000, 2000))
    if (isFinite(cfg.offsetY)) {
      var oy = Math.round(root.clamp(cfg.offsetY, -2000, 2000))
      // offsetY==0 means "preset default" (the dropdown resets it), so map it
      // to the preset's anchor and write the real value back so the bar panel
      // and the config stay in sync.
      if (oy === 0) {
        var def = root.defaultOffsetY()
        root.offsetY = def
        root.persistConfig()
      } else {
        root.offsetY = oy
      }
    }
    root.updateIsTopHalf()
  }

  // Round-trips the current options to the shared config. Used by the SUPER+drag
  // to persist the offset on release (it updates offsetX/offsetY live while
  // dragging, then commits once). Mirrors the panel's writeConfig.
  function persistConfig() {
    var cfg = {
      position: root.position,
      margin: root.margin,
      lingerMs: root.lingerMs,
      historyCount: root.historyCount,
      showMouse: root.showMouse,
      cursorRing: root.cursorRing,
      offsetX: root.offsetX,
      offsetY: root.offsetY
    }
    persistProc.command = ["sh", "-c",
      "printf '%s\\n' '" + JSON.stringify(cfg) + "' > " + Util.shellQuote(root.configPath)]
    persistProc.running = true
  }

  Process {
    id: persistProc
  }

  // While the cursor hovers the card with Super held, temporarily unbind the
  // compositor's SUPER+mouse move/resize so the drag reaches the visualizer
  // instead of a window underneath. Restored the moment the cursor leaves or
  // Super is released, so normal window dragging keeps working elsewhere.
  // Done via `hyprctl eval` so the shell can toggle the Lua-defined binds live.
  function armSuperDrag() {
    dragBindProc.command = ["sh", "-c",
      "hyprctl eval \"hl.unbind('SUPER + mouse:272'); hl.unbind('SUPER + mouse:273')\""]
    dragBindProc.running = true
  }

  function disarmSuperDrag() {
    dragBindProc.command = ["sh", "-c",
      "hyprctl eval \"hl.unbind('SUPER + mouse:272'); hl.unbind('SUPER + mouse:273'); hl.bind('SUPER + mouse:272', hl.dsp.window.drag(), {mouse=true}); hl.bind('SUPER + mouse:273', hl.dsp.window.resize(), {mouse=true})\""]
    dragBindProc.running = true
  }

  Process {
    id: dragBindProc
  }

  function updateSuperDrag() {
    if (dragArea.dragging) return
    var shouldArm = root.superHeld && root.overCard && root.opened
    if (shouldArm && !root.dragArmed) {
      root.dragArmed = true
      root.armSuperDrag()
    } else if (!shouldArm && root.dragArmed) {
      root.dragArmed = false
      root.disarmSuperDrag()
    }
  }

  onSuperHeldChanged: {
    if (!root.superHeld) root.overCard = false
    root.updateSuperDrag()
  }
  onOverCardChanged: root.updateSuperDrag()

  function migrateConfig() {
    // First load with the new location: carry over values from the old
    // plugin-dir config (if any) and remove it, or seed the defaults.
    var defaults = '{"position": "bottom-center", "margin": 67, "lingerMs": 1000, "historyCount": 1, "showMouse": true, "cursorRing": true, "offsetX": 0, "offsetY": 0}'
    migrateProc.command = ["sh", "-c",
      "if [ -f " + Util.shellQuote(root.legacyConfigPath) + " ]; then "
      + "cp " + Util.shellQuote(root.legacyConfigPath) + " " + Util.shellQuote(root.configPath) + "; "
      + "rm -f " + Util.shellQuote(root.legacyConfigPath) + "; "
      + "else printf '%s\\n' '" + defaults + "' > " + Util.shellQuote(root.configPath) + "; fi"]
    migrateProc.running = true
  }

  Process {
    id: migrateProc
  }

  property bool configSeeded: false

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.applyConfig(text())
      // First run: write the defaults so the file is discoverable and the
      // options can be tuned without hunting for them. Guarded because the
      // shell injects `manifest` after instantiation, which re-fires this.
      if (!root.configSeeded) {
        root.configSeeded = true
        if (root.configPath !== "" && text() === "") root.migrateConfig()
      }
    }
    onFileChanged: reload()
  }

  // ------------------------------------------------- capture hook injection
  //
  // The capture script (key-visualizer.lua) must run inside Hyprland's Lua
  // config, but the plugin cannot register itself there — the user owns
  // hyprland.lua. On first load we append a small guarded block that
  // dofiles the script; Hyprland auto-reloads its config on save, so the
  // whole install is: add + enable. The block is idempotent and no-ops if
  // the plugin folder is later removed, so uninstalling never breaks the
  // config.

  readonly property string captureMarker: "-- [key-visualizer] capture hook"
  readonly property string captureBlock: {
    var lines = [
      "",
      "-- [key-visualizer] capture hook (managed by the plugin; safe to remove)",
      'local kc_path = os.getenv("HOME") .. "/.config/omarchy/plugins/felixzsh.key-visualizer/key-visualizer.lua"',
      'local kc_file = io.open(kc_path, "r")',
      'if kc_file then kc_file:close(); dofile(kc_path) end',
      ""
    ]
    return lines.join("\n")
  }

  function maybeInjectCapture(raw) {
    if (!raw) return
    if (raw.indexOf(root.captureMarker) !== -1) return
    var kept = []
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      // Drop an older plain dofile line (manual installs, previous versions)
      // so the block below is the only reference and stays upgradeable.
      if (lines[i].indexOf("key-visualizer.lua") !== -1) continue
      kept.push(lines[i])
    }
    console.log("key-visualizer: injecting capture hook into hyprland.lua")
    hyprConfFile.setText(kept.join("\n") + root.captureBlock)
    injectReloadTimer.start()
  }

  Timer {
    id: injectReloadTimer
    interval: 400
    onTriggered: reloadProc.running = true
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
  }

  FileView {
    id: hyprConfFile
    path: Quickshell.env("HOME") + "/.config/hypr/hyprland.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.maybeInjectCapture(text())
    onFileChanged: reload()
  }

  // Lifecycle required for panel plugins: summoning is a no-op because the
  // display is driven by the state file; hiding closes the window.
  function open(payloadJson) {}
  function close() { root.opened = false }

  IpcHandler {
    target: "key-visualizer"
    function ping(): string { return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function paused(): string { return root.paused ? "true" : "false" }
    function pause(): string { root.setPaused(true); return "ok" }
    function resume(): string { root.setPaused(false); return "ok" }
    function toggle(): string { root.setPaused(!root.paused); return "ok" }
    function debug(): string { root.debugOverlay = !root.debugOverlay; return root.debugOverlay ? "on" : "off" }
    function debugState(): string { return root.debugOverlay ? "on" : "off" }
  }

  // ------------------------------------------------------------- display

  PanelWindow {
    id: panel
    // Also mapped for the always-on mouse box, the on/off notice, and the
    // cursor ring while it fades.
    visible: root.opened || root.mouseBoxOn || root.statusText !== "" || cursorRingItem.opacity > 0
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "key-visualizer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Click-through normally; while Super is held the card's area captures the
    // pointer so a SUPER+drag moves the visualizer (see dragArea). While
    // dragging, capture the whole surface so the drag does not cut off when
    // there is no window underneath.
    mask: root.superHeld ? (dragArea.dragging ? fullMask : cardMask) : emptyMask

    // Two pre-declared regions so the mask can switch between "click-through"
    // (empty) and "capture the card" without rebuilding a region per frame.
    Region {
      id: emptyMask
    }
    Region {
      id: cardMask
      item: card
    }
    Region {
      id: fullMask
      x: 0
      y: 0
      width: panel.width
      height: panel.height
    }

    BorderSurface {
      id: card
      visible: root.entries.length > 0
      width: card.borderLeft + root.cardPad + root.contentWidth() + root.cardPad + card.borderRight
      height: card.borderTop + root.cardPad + root.contentHeight() + root.cardPad + card.borderBottom
      // Preset base position + manual offset, clamped so the card stays on
      // screen. A nudge that would cross a screen edge is silently ignored.
      x: {
        var p = root.position
        var gW = card.width
        var hi = panel.width - card.width
        // Beside the pinned mouse box when it is on, so the box never moves.
        if (root.mouseBoxOn) return root.clamp(root.besideMouseBoxX(card.width), 0, panel.width - card.width)
        var base = 0
        if (p.indexOf("left") !== -1) base = root.margin
        else if (p.indexOf("right") !== -1) base = panel.width - gW - root.margin
        else base = Math.round((panel.width - gW) / 2)
        return root.clamp(base + root.offsetX, 0, hi)
      }
      // The card's Y is derived so the newest row sits at offsetY (stable in
      // both halves); the card is then clamped on screen.
      y: {
        var cy = root.cardTopY()
        if (cy < 0) cy = 0
        else if (cy + card.height > panel.height) cy = panel.height - card.height
        return cy
      }
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Column {
        anchors.fill: parent
        anchors.topMargin: card.borderTop + root.cardPad
        anchors.leftMargin: card.borderLeft + root.cardPad
        anchors.bottomMargin: card.borderBottom + root.cardPad
        anchors.rightMargin: card.borderRight + root.cardPad
        spacing: root.entryGap

        Repeater {
          model: root.displayModel()

          delegate: Row {
            required property var modelData
            spacing: root.chipGap
            opacity: root.entryOpacity(modelData.pos)

            // Single line per entry, all segments rendered inline
            Repeater {
              model: root.chipGroups(modelData.entry.segments)

              delegate: Text {
                required property var modelData
                text: modelData.text
                font: root.chipFont
                color: modelData.kind === "chord" ? Color.accent : Color.popups.text
              }
            }
          }
        }
      }
    }

    // Mouse box: always on screen while the visualizer is on, pinned at the
    // preset's anchor (see mouseBoxX), level with the card's newest row. It
    // never scrolls with the key history. The mouse's segments light up in
    // the held buttons' colors.
    BorderSurface {
      id: mouseBox
      visible: root.mouseBoxOn
      width: borderLeft + root.cardPad + root.mouseIconWidth + 2 * root.chipPadX + root.cardPad + borderRight
      height: borderTop + root.cardPad + root.chipHeight + root.cardPad + borderBottom
      x: root.mouseBoxX()
      y: root.mouseBoxY()
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Canvas {
        id: mouseIcon
        anchors.centerIn: parent
        width: root.mouseIconWidth
        height: root.mouseIconHeight
        property var lit: root.mouseLit
        property color lineColor: Color.popups.text
        onLitChanged: requestPaint()
        onLineColorChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          var w = width, h = height
          var r = w / 2
          var split = h * 0.45
          var mid0 = w * 0.38, mid1 = w * 0.62
          var segs = { "L": [0, mid0], "M": [mid0, mid1], "R": [mid1, w] }
          ctx.reset()
          ctx.lineWidth = 1.5
          function body() {
            ctx.beginPath()
            ctx.roundedRect(0.75, 0.75, w - 1.5, h - 1.5, r - 0.75, r - 0.75)
          }
          ctx.save()
          body()
          ctx.clip()
          for (var i = 0; i < lit.length; i++) {
            var seg = segs[lit[i]]
            if (!seg) continue
            ctx.fillStyle = root.buttonColors[lit[i]]
            ctx.fillRect(seg[0], 0, seg[1] - seg[0], split)
          }
          ctx.restore()
          ctx.strokeStyle = lineColor
          body()
          ctx.stroke()
          ctx.beginPath()
          ctx.moveTo(0, split); ctx.lineTo(w, split)
          ctx.moveTo(mid0, 0); ctx.lineTo(mid0, split)
          ctx.moveTo(mid1, 0); ctx.lineTo(mid1, split)
          ctx.stroke()
        }
      }
    }

    // On/off notice: its own box, beside the mouse box (or at the anchor
    // when the mouse box is off), shown for a moment after a pause toggle.
    BorderSurface {
      id: statusBox
      visible: root.statusText !== ""
      // Above the card: a key pressed right after resuming must not hide it.
      z: 5
      width: borderLeft + root.cardPad + Math.ceil(chipFontMetrics.advanceWidth(root.statusText)) + 2 * root.chipPadX + root.cardPad + borderRight
      height: mouseBox.height
      x: root.showMouse
        ? root.clamp(root.besideMouseBoxX(width), 0, panel.width - width)
        : root.clamp(root.mouseBoxX() + (root.position.indexOf("right") !== -1 ? mouseBox.width - width : 0), 0, panel.width - width)
      y: root.mouseBoxY()
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Text {
        anchors.centerIn: parent
        text: root.statusText
        font: root.chipFont
        color: Color.popups.text
      }
    }

    // Cursor ring: follows the pointer while any mouse button is held,
    // colored by the held button(s) — one arc per button when several are
    // down — and fades out where the button was released. The overlay's
    // input mask stays empty, so the ring never intercepts the click.
    Item {
      id: cursorRingItem
      width: root.ringSize
      height: root.ringSize
      x: root.ringX - (panel.screen ? panel.screen.x : 0) - width / 2
      y: root.ringY - (panel.screen ? panel.screen.y : 0) - height / 2
      opacity: 0
      visible: opacity > 0
      z: 20

      Canvas {
        id: ringCanvas
        anchors.fill: parent
        onPaint: {
          var ctx = getContext("2d")
          var b = root.ringShown
          ctx.reset()
          if (b.length === 0) return
          var c = width / 2
          var rad = c - root.ringStroke / 2 - 1
          ctx.lineWidth = root.ringStroke
          ctx.lineCap = "butt"
          var step = 2 * Math.PI / b.length
          for (var i = 0; i < b.length; i++) {
            var start = -Math.PI / 2 + i * step
            ctx.beginPath()
            ctx.arc(c, c, rad, start, start + step)
            ctx.strokeStyle = root.buttonColors[b[i]] || Color.accent
            ctx.stroke()
          }
        }
      }

      NumberAnimation on opacity {
        id: ringFade
        running: false
        to: 0
        duration: 250
        easing.type: Easing.OutQuad
      }
    }

    // SUPER+drag: when Super is held the card's mask captures the pointer, so
    // pressing and dragging on the card moves the visualizer live. While the
    // cursor hovers the card with Super held, the compositor's SUPER+mouse
    // move/resize binds are temporarily unbound so the drag reaches us instead
    // of a window underneath; they are restored when the cursor leaves (or
    // Super is released), so normal window dragging keeps working elsewhere.
    MouseArea {
      id: dragArea
      x: card.x
      y: card.y
      width: card.width
      height: card.height
      enabled: root.superHeld && root.opened
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: dragging ? Qt.ClosedHandCursor : Qt.SizeAllCursor

      property bool dragging: false
      property real grabX: 0
      property real grabY: 0
      property int grabOffsetX: 0
      property int grabOffsetY: 0

      onEntered: root.overCard = true
      onExited: root.overCard = false
      onPressed: {
        var p = dragArea.mapToItem(null, mouse.x, mouse.y)
        grabX = p.x
        grabY = p.y
        grabOffsetX = root.offsetX
        grabOffsetY = root.offsetY
        dragging = true
      }
      onPositionChanged: {
        if (!(mouse.buttons & Qt.LeftButton)) return
        var p = dragArea.mapToItem(null, mouse.x, mouse.y)
        root.offsetX = Math.round(root.clamp(grabOffsetX + (p.x - grabX), -2000, 2000))
        root.offsetY = Math.round(root.clamp(grabOffsetY + (p.y - grabY), -2000, 2000))
      }
      onReleased: { dragging = false; root.persistConfig(); root.updateIsTopHalf(); root.updateSuperDrag() }
      onCanceled: { dragging = false; root.persistConfig(); root.updateIsTopHalf(); root.updateSuperDrag() }
    }

    // Debug overlay: live readout of the card's position/dimensions and the
    // movement state, shown next to the card while moving and after release.
    // Toggle with: omarchy-shell key-visualizer debug
    readonly property var debugFont: Qt.font({
      family: Style.font.family,
      pixelSize: Style.font.bodySmall,
      bold: false
    })

    FontMetrics {
      id: debugFontMetrics
      font: debugFont
    }

    BorderSurface {
      id: debugOverlay
      visible: root.debugOverlay
      width: debugFontMetrics.advanceWidth(debugText.text) + root.cardPad * 2
      height: debugFontMetrics.height + root.cardPad * 2
      x: card.x + card.width + Style.space(12)
      y: card.y
      z: 10
      color: Util.alpha(Color.popups.background, 0.95)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
      radius: Style.cornerRadius

      Text {
        id: debugText
        anchors.fill: parent
        anchors.margins: root.cardPad
        verticalAlignment: Text.AlignVCenter
        font: root.debugFont
        color: Color.popups.text
        text: {
          var lb = "\n"
          return "x=" + Math.round(card.x) + " y=" + Math.round(card.y)
            + lb + "w=" + Math.round(card.width) + " h=" + Math.round(card.height)
            + lb + "offX=" + root.offsetX + " offY=" + root.offsetY
            + lb + "half=" + (root.isTopHalf ? "top" : "bottom")
            + (root.debugDragging ? " DRAG" : "")
        }
      }
    }
    readonly property bool debugDragging: dragArea.dragging
  }
}
