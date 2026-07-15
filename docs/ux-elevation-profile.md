# UX review request — elevation profile interactions in a hiking map app

## App context

**Rando** is a personal iPhone app for following hiking routes offline. One screen:

```
┌─────────────────────────────┐
│                             │
│   Topo MAP (MapLibre)       │  ← standard map gestures:
│   · GPX route (purple)      │    drag = pan, pinch = zoom
│   · GPS dot (blue/red =     │
│     on/off track)           │
│                             │
├─────────────────────────────┤
│  ELEVATION PROFILE card     │  ← the subject of this review
│  header: title + stats      │    (~200 pt tall, docked overlay)
│  [mini-map strip when zoomed]│
│  chart: km × elevation      │
└─────────────────────────────┘
```

The profile card shows the route linearized: kilometers on x, elevation on y.
Typical routes range from 3 km day hikes to 80+ km multi-day GRs (7,000+ GPS
points), so the full-extent view is heavily compressed and **zooming into a
section is essential**.

Usage context worth keeping in mind: outdoors, one-handed, quick glances,
sometimes gloves — favors big targets, forgiving gestures, and few modes.

## Jobs the profile card must serve

| # | Job | Nature |
|---|-----|--------|
| 1 | Read the whole hike at a glance (shape, total km / D+ / D−) | passive |
| 2 | Inspect a section in detail (zoom, pan) | navigation |
| 3 | Measure between two points (distance, D+, D− of a segment) | measurement |
| 4 | See current GPS position along the profile | passive |

Measurement (job 3) is a core feature: it drives a stats readout in the card
header AND highlights the corresponding segment on the map above (orange).

## The core problem

Jobs 2 and 3 both want the **horizontal drag** on a ~330×130 pt plot. Two
established grammars collide:

- **Document grammar** (text/photo selection): drag *selects a range*.
- **Map grammar** (the map sitting 200 pt above): drag *pans*, pinch *zooms*.

We started document-first (drag = create measurement) because measurement was
built before zoom existed. Zoom was then added as "zoom-to-selection" (the
selection doubles as zoom target), which entangled the two concepts. Several
iterations of locally-reasonable patches followed, each fixing a symptom:

1. Edge handles on the selection (adjust vs re-create conflict) — fine.
2. Zoom-to-selection + reset button + double-tap accelerators.
3. "Zoom button seems dead" → show it only when it would change the view.
4. "Can't extend selection past the zoomed window" → edge auto-pan machinery.
5. "No way to navigate while zoomed" → mini-map strip with draggable window.
6. "Can't zoom without selecting first" → pinch-to-zoom + double-tap-to-zoom.
7. Header/state mismatches → per-state header rules.

Result: ~12 interactions on one small card, still described by the user
(me/Seb) as "slightly off". Diagnosis: **no patch path to coherence while one
gesture means two things**; the accumulation itself became a smell.

## Current model (v2, "map grammar") — shipped as a revertable trial commit

Organizing principle: *the profile is a map of the trail in profile view; a
measurement is an object you place on it* (like a pin), not a drag side-effect.

| Interaction | Effect |
|---|---|
| drag on chart | pan the zoomed window (no-op at full extent) |
| pinch | zoom, anchored at pinch point; pinch-out past full = reset |
| double-tap | zoom in 2× at tap point |
| **long-press** | **place a measurement** at that spot (haptic), ~30% of window wide |
| **ruler button** (header) | place a measurement at window center |
| drag a **handle** | adjust that measurement edge (the ONLY drag affecting it) |
| ✕ button | remove the measurement |
| ⊕ button (when useful) | zoom the view to frame the measurement |
| ⊖ button / mini-map | zoom out / context + drag-window-to-pan (visible only when zoomed) |

States are now orthogonal: (measurement: none/some) × (zoom: full/window).
The header always describes exactly what the chart shows — measurement stats,
else visible-window stats, else trace totals.

Deliberate design decisions along the way:
- **Y-scale is FIXED to the full trace at all zoom levels** — adaptive y made
  identical slopes look different while panning ("more misleading than
  anything else"). Gradient honesty over vertical resolution.
- Zoomed slices are re-downsampled from full resolution, so zoom reveals real
  detail (the chart otherwise displays a ~1000-point reduction for perf).
- No animated domain transitions (perf architecture + mark identity).

## Trade-offs made / open questions for review

1. **Measurement lost its immediacy.** v1: swipe across the chart = instant
   measurement. v2: long-press or button first. Is placed-object worth the
   extra step? Is long-press discoverable enough (ruler button is the visible
   fallback)?
2. **Extending a measurement beyond the zoomed window** now requires: pan,
   then drag the handle. v1 had hold-at-edge auto-pan (deleted as complexity).
   Acceptable? Worth re-adding for handle drags only?
3. **Double-tap zooms in but nothing symmetric zooms out** (pinch-out, ⊖, or
   mini-map do). Apple Maps uses two-finger-tap for zoom-out; SwiftUI makes
   that gesture awkward. Live with asymmetry?
4. **Mini-map strip** (appears only when zoomed): context + pan affordance,
   costs ~26 pt of card height and one more concept. Keep / always show /
   drop in favor of pinch-pan only?
5. **The ⊕ "frame the measurement" button** — earns its place, or redundant
   now that pinch/double-tap navigation is cheap?
6. **Default measurement width** when placed = 30% of visible window,
   centered at press/center. Better heuristic? (e.g., snap to the enclosing
   climb via elevation minima detection?)
7. **Anything fundamentally better we're not seeing?** e.g. a dedicated
   full-screen profile mode on tap (more room = fewer compromises), Apple-
   Fitness-style scrubbing with one finger + measurement via two sequential
   taps, etc. Constraint: the card must stay useful in the one-glance,
   one-hand, on-trail context; heavy modes hurt there.

## Non-negotiable technical constraints (context for feasibility)

- Swift Charts re-render of the full mark set is the perf ceiling: the chart
  is wrapped in an equality-gated subview and must NOT re-render per gesture
  tick; all interactive visuals are drawn in an overlay above it. Continuous
  gestures (pan/pinch) are quantized (~1% of span per update).
- iOS 17 SwiftUI gestures: no spatial long-press (worked around via
  sequenced gesture), no reliable two-finger tap, `MagnifyGesture` provides
  pinch anchor.

*Both interaction models are in git history: map-grammar trial is commit
`33c9934`; reverting that commit restores drag-to-select v1 exactly.*
