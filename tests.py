# Key Visualizer — test harness
#
# Simulates the QML apply() routing logic in Python so we can test
# segment behavior without running Quickshell. Each test sends a
# sequence of Lua payloads and asserts the resulting entry segments.

from __future__ import annotations
import json
import time
from typing import Any

# ---- constants (mirrored from KeyVisualizer.qml) ----

MOD_LABELS = ["Super", "Ctrl", "Alt", "Alt R", "Shift", "Menu", "AltGr"]
TYPO_GROUP_MAX_KEYS = 24
LINGER_MS = 1000  # default

# ---- helpers ----

def mod_count_of(keys):
    return sum(1 for k in keys if k in MOD_LABELS)

def is_chord(keys):
    return mod_count_of(keys) > 0

def seg_keys_equal(a, b):
    if len(a) != len(b):
        return False
    return sorted(a) == sorted(b)

def is_superset_of(base, nxt):
    if len(nxt) <= len(base):
        return False
    for k in base:
        if k not in nxt:
            return False
    return True

# ---- entry / segments data model ----

class Segment:
    def __init__(self, kind: str, keys: list[str]):
        self.kind = kind       # "plain" | "chord"
        self.keys = list(keys)

    def copy(self):
        return Segment(self.kind, list(self.keys))

    def __repr__(self):
        return f"<{self.kind}:{''.join(self.keys) if self.kind == 'plain' else ' '.join(self.keys)}>"

class Entry:
    def __init__(self, segments: list[Segment], released_at: int = 0):
        self.segments = segments
        self.released_at = released_at   # 0 = held, ms epoch when released

    def copy(self):
        return Entry([s.copy() for s in self.segments], self.released_at)

    def all_keys(self):
        rv = []
        for s in self.segments:
            rv.extend(s.keys)
        return rv

    def __repr__(self):
        segs = ", ".join(repr(s) for s in self.segments)
        return f"[{segs}] rel={self.released_at}"

# ---- simulator ----

class Sim:
    def __init__(self):
        self.entries: list[Entry] = []
        self.last_state_t = 0
        self.now_ms = 1000000   # synthetic clock

    def advance_ms(self, n):
        self.now_ms += n

    def apply(self, keys: list[str], t: int = None):
        """Simulate the QML apply() function."""
        if t is None:
            t = self.now_ms // 1000
        self.last_state_t = t

        nxt = list(keys)
        chord = is_chord(nxt)
        es = [e.copy() for e in self.entries]  # shallow copy

        if len(nxt) == 0:
            # release
            if es and es[0].released_at == 0:
                all_keys = es[0].all_keys()
                if mod_count_of(all_keys) >= len(all_keys):
                    es.pop(0)  # mods of nothing: drop
                else:
                    es[0].released_at = self.now_ms
        elif es and es[0].released_at == 0:
            # still held
            last_seg = es[0].segments[-1]
            sk = "chord" if chord else "plain"

            if last_seg.kind == sk and seg_keys_equal(last_seg.keys, nxt):
                # same keys — autorepeat
                if not chord:
                    merged = last_seg.keys + nxt
                    if len(merged) > TYPO_GROUP_MAX_KEYS:
                        merged = merged[-TYPO_GROUP_MAX_KEYS:]
                    es[0].segments[-1] = Segment("plain", merged)
                # chord: refresh no-op
            elif last_seg.kind == sk and is_superset_of(last_seg.keys, nxt):
                # buildup
                es[0].segments[-1] = Segment(sk, list(nxt))
            elif (last_seg.kind == "chord"
                  and len(nxt) < len(last_seg.keys)
                  and all(k in last_seg.keys for k in nxt)):
                # chord teardown
                es[0].segments[-1] = Segment(sk, list(nxt))
            elif last_seg and mod_count_of(last_seg.keys) >= len(last_seg.keys):
                # pure-modifier replacement
                es[0].segments[-1] = Segment(sk, list(nxt))
            else:
                # append new segment or merge plain
                if not chord and last_seg.kind == "plain":
                    merged = last_seg.keys + nxt
                    if len(merged) > TYPO_GROUP_MAX_KEYS:
                        merged = merged[-TYPO_GROUP_MAX_KEYS:]
                    es[0].segments[-1] = Segment("plain", merged)
                else:
                    es[0].segments.append(Segment(sk, list(nxt)))
                    self._cap_segments(es[0])
        else:
            # released recently or no entry
            if es and es[0].released_at != 0 and (LINGER_MS <= 0 or self.now_ms - es[0].released_at < LINGER_MS * 2 / 3):
                # released recently
                last_seg = es[0].segments[-1]
                if not chord and last_seg.kind == "plain":
                    merged = last_seg.keys + nxt
                    if len(merged) > TYPO_GROUP_MAX_KEYS:
                        merged = merged[-TYPO_GROUP_MAX_KEYS:]
                    es[0].segments[-1] = Segment("plain", merged)
                elif last_seg and mod_count_of(last_seg.keys) >= len(last_seg.keys):
                    es[0].segments[-1] = Segment("plain" if not chord else "chord", list(nxt))
                else:
                    es[0].segments.append(Segment("plain" if not chord else "chord", list(nxt)))
                    self._cap_segments(es[0])
                es[0].released_at = 0
            else:
                # stale / no entry — start fresh
                if es and es[0].released_at == 0:
                    es[0].released_at = self.now_ms
                sk = "chord" if chord else "plain"
                es.insert(0, Entry([Segment(sk, list(nxt))]))

        # trim to historyCount (we keep 1 for simplicity)
        while len(es) > 1:
            es.pop()
        self.entries = es

    def _cap_segments(self, entry):
        total = sum(len(s.keys) for s in entry.segments)
        while total > TYPO_GROUP_MAX_KEYS and len(entry.segments) > 1:
            total -= len(entry.segments[0].keys)
            entry.segments.pop(0)

    def seg_text(self, idx=0):
        """Return rendered text of entry[idx] segments for assertion."""
        if idx >= len(self.entries):
            return None
        parts = []
        for s in self.entries[idx].segments:
            if s.kind == "chord":
                parts.append(" ".join(s.keys))
            else:
                parts.append("".join(s.keys))
        return parts

    def seg_kinds(self, idx=0):
        if idx >= len(self.entries):
            return None
        return [s.kind for s in self.entries[idx].segments]

    def keys_of(self, idx=0):
        if idx >= len(self.entries):
            return None
        return [list(s.keys) for s in self.entries[idx].segments]

    def is_released(self, idx=0):
        if idx >= len(self.entries):
            return None
        return self.entries[idx].released_at != 0

# ---- tests ----

def test(name, steps):
    """Run a multi-step test. Each step is (keys_string_or_list, expected_segments).
    `keys_string_or_list` is either a list of key labels (the Lua payload)
    or the string "RELEASE" for an empty payload.
    After each step, advance the clock by 20ms (quick typing).
    """
    sim = Sim()
    for i, step in enumerate(steps):
        payload, expected = step
        if payload == "RELEASE":
            sim.apply([])
        else:
            sim.apply(list(payload))
        sim.advance_ms(20)

        got = sim.seg_text(0)
        kinds = sim.seg_kinds(0)
        if got != expected:
            print(f"  FAIL [{name}] step {i}: payload={payload}")
            print(f"    expected segments: {expected}")
            print(f"    got segments:      {got}")
            print(f"    kinds:             {kinds}")
            print(f"    entry:             {sim.entries[0] if sim.entries else 'EMPTY'}")
            return False
    return True

def run_all():
    passed = 0
    failed = 0

    for name, steps in TESTS:
        ok = test(name, steps)
        if ok:
            passed += 1
            print(f"  PASS {name}")
        else:
            failed += 1

    print(f"\n{'='*50}")
    print(f"  {passed} passed, {failed} failed out of {passed + failed}")

# ---- test cases ----

TESTS = []

# 1. plain typing
TESTS.append(("plain typing abc", [
    (["a"], ["a"]),
    (["b"], ["ab"]),
    (["c"], ["abc"]),
]))

# 2. single chord
TESTS.append(("single chord Ctrl+A", [
    (["Ctrl", "a"], ["Ctrl a"]),
]))

# 3. plain then chord  — this fails because plain is released then chord arrives
TESTS.append(("plain abc then chord Ctrl+A", [
    (["a"], ["a"]),
    (["b"], ["ab"]),
    (["c"], ["abc"]),
    (["Ctrl", "a"], ["abc", "Ctrl a"]),
]))

# 4. chord then plain
TESTS.append(("chord Ctrl+A then plain b", [
    (["Ctrl", "a"], ["Ctrl a"]),
    (["b"], ["Ctrl a", "b"]),
]))

# 5. Shift+A (Shift folded by Lua)
TESTS.append(("Shift alone then A (pure-mod replacement)", [
    (["Shift"], ["Shift"]),
    (["A"], ["A"]),   # ["Shift"] replaced by ["A"]
]))

# 6. modifier alone shows then disappears on release
TESTS.append(("mod alone Ctrl shows then disappears", [
    (["Ctrl"], ["Ctrl"]),
    ("RELEASE", None),   # released — mods of nothing, entry dropped
]))

# 7. chord buildup: Ctrl -> Ctrl+A
TESTS.append(("chord buildup Ctrl then Ctrl+A", [
    (["Ctrl"], ["Ctrl"]),
    (["Ctrl", "a"], ["Ctrl a"]),   # replaces in place
]))

# 8. chord teardown: Ctrl+A -> Ctrl (A released)
TESTS.append(("chord teardown Ctrl+A -> Ctrl", [
    (["Ctrl", "a"], ["Ctrl a"]),
    (["Ctrl"], ["Ctrl"]),   # teardown, replaced in place
]))

# 9. teardown then release
TESTS.append(("chord teardown then release", [
    (["Ctrl", "a"], ["Ctrl a"]),
    (["Ctrl"], ["Ctrl"]),
    ("RELEASE", None),   # mods of nothing — dropped
]))

# 10. pure typo then release
TESTS.append(("plain then release", [
    (["a"], ["a"]),
    (["b"], ["ab"]),
    ("RELEASE", ["ab"]),   # entry released
]))

# 11. re-press quickly after release
TESTS.append(("re-press quickly after release", [
    (["a"], ["a"]),
    ("RELEASE", ["a"]),
    (["a"], ["aa"]),   # merged into last plain segment
]))

# 12. chord after plain
TESTS.append(("plain then chord after release", [
    (["a"], ["a"]),
    ("RELEASE", ["a"]),
    (["Ctrl", "a"], ["a", "Ctrl a"]),
]))

# 13. multiple modifiers
TESTS.append(("multiple modifiers Ctrl+Shift+A", [
    (["Ctrl", "Shift", "a"], ["Ctrl Shift a"]),
]))

# 14. plain -> chord -> plain
TESTS.append(("plain -> chord -> plain", [
    (["a"], ["a"]),
    (["Ctrl", "x"], ["a", "Ctrl x"]),
    (["b"], ["a", "Ctrl x", "b"]),
]))

# 15. pure modifier replacement when released recently
TESTS.append(("Shift released then A pressed quickly", [
    (["Shift"], ["Shift"]),
    ("RELEASE", None),   # mods of nothing, dropped
    (["A"], ["A"]),      # fresh entry
]))

# 16. plain autorepeat (simulated as repeated same-key while held)
TESTS.append(("plain autorepeat same key while held", [
    (["a"], ["a"]),
    (["a"], ["aa"]),
    (["a"], ["aaa"]),
]))

# 17. chord autorepeat does NOT duplicate
TESTS.append(("chord autorepeat same payload while held", [
    (["Ctrl", "a"], ["Ctrl a"]),
    (["Ctrl", "a"], ["Ctrl a"]),   # same — refresh, no duplicate
]))

# 18. Ctrl alone released, then plain b fresh
TESTS.append(("Ctrl alone released then plain b fresh", [
    (["Ctrl"], ["Ctrl"]),
    ("RELEASE", None),         # mods of nothing — dropped
    (["b"], ["b"]),            # fresh entry
]))

# 19. various mod + char combos
TESTS.append(("Super+V", [
    (["Super", "v"], ["Super v"]),
]))

TESTS.append(("Alt+Tab", [
    (["Alt", "Tab"], ["Alt Tab"]),
]))

# 20. Shift+A held with autorepeat
TESTS.append(("Shift+A autorepeat", [
    (["Shift"], ["Shift"]),
    (["A"], ["A"]),       # pure-mod replacement
    (["A"], ["AA"]),      # autorepeat — appended
    (["A"], ["AAA"]),     # autorepeat — appended
]))


if __name__ == "__main__":
    run_all()