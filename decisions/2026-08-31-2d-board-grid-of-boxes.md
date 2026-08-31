# 2026-08-31 — The 2D board is a grid of boxes, not a canvas

Bead: chopaat-u8x. Implements the owner ruling that the 2D mode is a
CLIENT of the session boundary, deliberately canvas-grade simple, chosen
for verifiability over beauty — the debugging surface and the
always-playable fallback.

## Grid of tappable boxes over Mob.Canvas

`Mob.UI.canvas/1` strips its props to `width`/`height`/`draw`: canvas
draw ops carry **no per-element tap targets**, so a canvas board would
need raw coordinate hit-testing that neither `Mob.Test` nor a human can
address by name. A grid of `:box` primitives gives every board cell an
id that IS its cell address (`:cell_t2_l0_r5`) and an `on_tap` tag a
test can fire and a finger can hit — the tap tags double as the
machine-driving surface, and ScreenCase asserts the whole board as
plain data. `Chopaat.Screens.Board2D` is a pure function from
`Session.observe/1` plain data (occupancy keyed by cell-name strings —
exactly the render key the session-boundary doc promised) to a node
tree; it holds no state and sends no commands.

Layout: 4 players render the cross as a cross (19×19 slot grid, arms
t0 S / t1 E / t2 N / t3 W counter-clockwise, lane 0 on the CCW side per
`Chopaat.Board`; base pads in the corner beside each arm's lane 2, the
center 3×3 with per-seat home tallies). 6 players cannot box 60° arms,
so the six arms lay out flat as side-by-side strips under a center
bar — legibility over geometric fidelity, same cell addressing.

Visual language echoes the 3D board (board.py's palette, gamma-encoded
by `Setup.argb/1`): safe blue, gate ochre (solid active / ring when the
owner holds a tod), center gold, private middle lanes washed with the
owner's tint. Pawns are tinted discs with glyphs: stack count, `▸`
tipped, `✕` jammed. The seven shells are glyph discs flipped instantly
to the drawn configuration from `{:throw_result, ...}` — the manifest
makes the 2D and 3D outcomes identical by construction, so no
animation is needed or performed.

## Interaction reuses the 3D flow's messages

Cell taps arrive as `{:cell2d, name}` (selection, stack-cycling), base
pads as `{:pawn2d, ix}`, and target cells as the tray's existing
`{:action, action}` — so khadu targets route through the same confirm
dialog and the same legality/burn handling with zero new commit paths.
Only the board viewport swaps in `GameScreen`; session, HUD, khadu
confirm, and handoff are shared, which is what makes the mid-game
2D↔3D toggle the acceptance proof of the session boundary (same
session pid, same assigns — verified in ScreenCase and once on the
pool emulator, `evidence/android_emu_2d_toggle_*.png`).

## Fallback and debug

`Board2D.scene3d_supported?/0` probes `Mob.Scene3d.caps/0`
(`{:error, :nif_not_loaded}` ⇒ unsupported; tests pin it via
`:chopaat, :scene3d_support`). The menu defaults new games to 2D when
unsupported; a requested 3D board degrades to 2D with a one-line
notice, never silently. The debug toggle overlays cell addresses (arm/
lane/row labels) and a raw `seq · phase · turn · last event` line — the
at-a-glance readout.

## Consequences

- In 2D the presented state never lags the session (no tumble wait):
  `evidence/*_2d_acceptance.log` asserts `assigns.observed ==
  Session.observe/1` after every event batch on both platforms.
- Per-device persistence of the mode is NOT done (menu holds it for
  the app's lifetime); follow-up if the owner wants it durable.
- The Compose-side `Mob.Test.screenshot/1` cannot composite the scene3d
  GL surface (white/black board) and a big grid recomposition can take
  seconds on the emulator — full-frame `adb exec-out screencap` after a
  settle is the honest capture for board evidence.
