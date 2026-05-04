# Halo Edge-Tracking Instrumentation — Design

**Date:** 2026-05-04
**Component:** `usage-pet-overlay/native/CodexUsageHalo.swift` + `install-floating-halo.mjs`
**Status:** Approved by user

## Problem

The Codex Pet Meter halo overlay loses sync with the Codex pet window during fast or large drags in any direction. The halo stops at an intermediate position while the pet keeps moving with the cursor. Symptom is not edge-specific — it occurs whenever movement exceeds the tracker's catch-up rate.

Two prior fix attempts (override `constrainFrameRect`, widen size filter) did not resolve the symptom.

## Diagnosis approach

Codex agent (independent second-opinion) ranked hypotheses:

| Hypothesis | Score |
|---|---|
| H1 — CGWindowList polling fallback returns nil at edge | Likely |
| H7 — AX subscription handle goes stale; `recheck()` doesn't re-find pet window | Likely (newly identified) |
| H3/H4 — `animator().setFrame` may bypass `constrainFrameRect` override | Possible |
| H6 — Size filter excludes container at edge after resize | Possible |
| H2 — Multi-monitor coord conversion bug | Excluded (single-monitor setup) |
| H5 — Codex self-clamps pet window | Unlikely (user observes pet still moves) |

User chose Option 3 (instrumentation-first) over targeted fixes. Rationale: avoids fixing the wrong thing; produces shareable evidence for root cause.

## Design

### What gets instrumented

Six trace event types are added to capture the full execution path of "pet position update → halo position update":

| Tag | Insertion point | Captured data |
|---|---|---|
| `ax-subscribe` | After `AXObserverAddNotification` calls in `subscribe()` | per-notification return code, pid |
| `ax-fire` | Inside `emit()`, augmented with `source` parameter | source (`callback` / `recheck`), petRect from AX |
| `ax-recheck` | Inside `recheck()` | handleAlive flag, sameWindow flag, attach attempts |
| `poll-tick` | Inside polling timer body in `addTimers()` | tick number, CGWindow result rect or nil |
| `apply` | Top of `applyPetWindowRect()` | petRect, currentFrame, targetFrame, distance, action (snap/animate/skip) |
| `setframe-after` | Async after `setFrame` in `applyPetWindowRect()` | requested vs actual frame (detects AppKit clamping) |

Line format: `TIMESTAMP TRACE tag=<tag> key=value key=value ...`
Greppable, awk-able, scannable.

### Toggle mechanism

CLI flag `--trace` enables trace mode. Without flag, app behaves unchanged (no perf cost, no log writes).

```
node install-floating-halo.mjs trace      # spawns with --trace
node install-floating-halo.mjs start      # spawns normally
node install-floating-halo.mjs trace-stop # snapshot + restart normal
```

### Log files

| Path | Purpose | Always-on? |
|---|---|---|
| `/tmp/codex-usage-halo.log` | Lifecycle events (launch, AX permission, calibration) | Yes |
| `/tmp/codex-usage-halo-trace.log` | Six trace event types, per-frame detail | Only when `--trace` |

Trace log is truncated at every `--trace` startup (no rotation needed for short reproduction sessions).

### Stale-handle detection

`recheck()` is upgraded to actively re-run `findPetWindow(axApp:)` every second and compare against the currently observed AXUIElement via `CFEqual(freshWin, oldWin)`. If different, teardown + resubscribe. This addresses H7 directly (and is itself a candidate fix, not just instrumentation).

### Reproduction protocol

User runs three fixed scenarios with ≥ 2 second gaps between (so log chunks are easy to separate):

1. **Scenario A** — Drag pet from screen center to left edge in ≤ 1 second
2. **Scenario B** — Same to right edge
3. **Scenario C** — Left/right zigzag, 5 cycles

Then `trace-stop` produces a timestamped snapshot at `/tmp/halo-trace-<unix-ms>.txt` for analysis.

### Code shape

New helpers added to `CodexUsageHalo.swift`:
- `let traceEnabled: Bool` — set from `CommandLine.arguments`
- `func traceLog(_ tag: String, _ kvs: String)` — guard-checked, append-only writer

Touched call sites (all minimal additions, no behavior change apart from `recheck()` stale-detection):
- `CodexPetTracker.subscribe`
- `CodexPetTracker.emit` (signature change: add `source` param)
- `CodexPetTracker.recheck` (logic change: re-find + compare)
- `HaloView.addTimers` (polling tick)
- `HaloView.applyPetWindowRect` (entry + post-setFrame)

`install-floating-halo.mjs` gets two new commands:
- `trace` — pkill, then `open --args --trace`
- `trace-stop` — pkill, snapshot trace log, restart normal

## Success criteria

After running the three scenarios and reviewing the trace log, we should be able to definitively answer:

1. During fast drag, does AX `kAXMovedNotification` fire at expected rate?
2. Are the petRects reported by AX accurate (matches CGWindow ground-truth)?
3. Does `recheck()` ever observe a window-handle change?
4. Does CGWindow polling return nil at edges?
5. After `setFrame`, does `window.frame` actually equal the requested frame?
6. Where in the chain does the halo position "stop tracking"?

The answers map directly to which hypothesis is the root cause → minimal targeted fix.

## Out of scope

- Fixing the bug itself (next pass, after diagnosis)
- Refactoring the existing `applyPetWindowRect` snap/animate split
- Changing AX permission flow
- Multi-monitor support (user is single-monitor)

## Risks

- Adding `recheck()` re-find is itself a behavior change (not pure observation). If this alone fixes the symptom, we won't be able to isolate which other hypothesis was also at play. Acceptable trade-off — Codex flagged this as the most likely fix anyway.
- Trace log writes happen on the main thread. At ~30Hz polling + AX events, this could add measurable latency. Mitigated by guard-checking `traceEnabled` first (compiled to tight branch when off) and by only enabling for short repro sessions.

## Next step

Hand off to `writing-plans` skill to produce detailed implementation plan with file/line-level edits.

---

## Findings (post-reproduction, 2026-05-04)

Trace snapshot: `/tmp/halo-trace-1777870679477.txt` (4581 lines, 3 reproduction scenarios A/B/C completed).

### Hypothesis verdicts

| Hypothesis | Verdict | Evidence |
|---|---|---|
| H1 — CGWindow at edge returns nil | **Ruled out** | 0 of 639 `poll-tick` events had `result=nil` |
| H3/H4 — `constrainFrameRect` bypassed by `animator().setFrame` | **Ruled out** | 85/85 `act=snap` events had `reqX==actX` (and `reqY==actY`) — no clamping |
| H6 — Pet container resizes at edges | **Ruled out** | Pet size constant 356×320 across all 1051 `ax-fire` events; pet X reached as low as 0 and as high as 1324 |
| H7 — AX subscription stale | **Ruled out** | 0 `ax-recheck sameWindow=false` events; subscription healthy throughout |
| **NEW — `NSAnimationContext.runAnimationGroup` + `animator().setFrame()` self-cancellation under repeat** | **CONFIRMED** | See timeline below |

### Smoking-gun timeline (excerpt from 04:57:03.016 onward)

| Time | Pet X (from AX) | Halo req X | Halo actual X | Action |
|---|---|---|---|---|
| 03.016 | 863 | 1066 | 857 | animate |
| 03.033 | 901 | 1104 | 857 | animate |
| 03.049 | 937 | 1140 | 857 | animate |
| 03.066 | 963 | 1166 | 857 | animate |
| 03.079 | 981 | 1140 | 857 | animate |
| 03.083 | 981 | 1184 | 857 | animate |
| 03.280 | 992 | 1195 | **1195** | **snap** |

Six consecutive `animator().setFrame()` requests over 70 ms produce zero visible movement — halo stays at X=857. The next call, taken via the `snap` branch (because pet had paused so distance dropped below 20), instantly applies. AX is firing healthily (30-50 Hz during fast drag); the failure is in AppKit's animation API behavior under high-frequency interruption.

### AX health summary

- `ax-subscribe` returned `moved=0 resized=0` (both `kAXErrorSuccess`)
- `ax-fire` events: 952 from AX callback + 99 from recheck heartbeat + 1 from initial attach = 1052 total
- AX callback rate during fast drag bursts: 30-50 events per second
- All `ax-fire` events showed valid pet positions reflecting cursor movement to extreme edges

### Action distribution (1781 non-skip applies)

- `animate`: 2010 calls (74% of all applies; 12× more than `snap`)
- `skip`: 601 calls (already at target, no-op)
- `snap`: 170 calls

The vast majority of update events take the `animate` path — exactly the path that fails under repeat.

### Recommended fix

Remove the `animate` branch from `HaloView.applyPetWindowRect` entirely; always `setFrame` directly:

```swift
// Replace the entire if/else block with:
window.setFrame(targetFrame, display: false)
```

Rationale:
- AX delivers updates at 30-50 Hz, fast enough that direct `setFrame` already looks smooth
- 100% of the 85 historical `snap` actions applied with zero pixel error and zero latency
- The animate path was intended for catch-up smoothing but ends up being the failure mode itself
- Catch-up scenarios (large gaps between halo and pet) are already covered by 4 Hz polling + 1 Hz `recheck` heartbeat — no animation needed

This is a ~10 line removal. No new code paths required.

