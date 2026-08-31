# Integration: pick-to-move, native tumble contract, move performance

- Date: 2026-08-31
- Bead: `chopaat-hre`
- Status: accepted

## Context

Master had the seams (pickable pawns, `{:pawn_picked, id}`, the Throws
boundary with an instant-delivery Baked impl, khadu confirm, BoardMap
cell transforms); mob_scene3d master had the verified animation contract
(`%Animation{}` playback, `{:animation_done, play_id}` at most once per
play_id, `scene/1` readback with per-node world transforms). This bead
wires them into a playable game and asserts the contract live.

## Decisions

1. **Target markers, not tint-only highlighting.** A selected pawn gets
   an emissive lift, and every legal landing for it grows a *pickable*
   marker entity — the neutral pawn asset flattened to a disc
   (`scale {1.1, 0.16, 1.1}`), emissive in the player tint (khadu
   landings in red — they burn dana/pagdu and stay behind the confirm
   dialog). The action is encoded in the marker's entity id
   (`target_assign_{i}_{ix}` / `target_khadu_{i}_{ix}` /
   `target_bonus_{ix}`, `Scene.decode_target/1`), so tapping a marker IS
   committing the action — no marker→action registry to drift. No new
   asset, no new plugin surface. Landings come from
   `Rules.action_path/2`, a step-expansion of `move_target/4` (same wrap
   rule per step), so the path always agrees with the rules' landing.

2. **Move performance is screen-side interpolation.** A committed
   movement action plays as an eased per-cell hop (`Chopaat.Scene.Move`:
   smoothstep lerp + sine lift per traversed cell, rotation nlerp
   start→end so tipped pawns stand up in motion), ticked by
   `{:move_tick, ref}` self-messages at 30 Hz, expressed as ordinary IR
   transforms — the viewport diff ships one `set_transform` per frame.
   The rules apply *first*; the animation performs the answer. The final
   tick drops the override, so the settled scene pose (stack fan-out,
   tip, home ring) is the landing by construction. Handoff and game-over
   renders are deferred until the landing so the viewport survives the
   performance.

3. **The throw honesty check lives in the screen, on-device.**
   `Chopaat.Throws.Native` (device default, set in `MobApp.on_start/0` —
   device BEAMs don't read Mix config) draws the exact RNG sequence the
   Baked impl draws (delegation, so host predictions replay the device
   bit-for-bit), lets the plugin deliver `{:animation_done, play_id}`,
   and on completion the screen runs `Throws.settle_check/2`:
   `Mob.Scene3d.scene/1` readback, each tumble slot's local +Y world-Y
   component classified with tumble.py's own rule (aperture-up ⇔
   ≤ −0.7; |up| < 0.7 is ambiguous and fails) against the manifest's
   per-slot array. Verdicts are counted in `assigns.settle` — the device
   acceptance asserts `ok == throws, mismatch == error == skipped == 0`.
   A mismatch logs loudly and the rules are trusted, never the visual.

4. **Slot-mesh substitution: the plugin surface does not exist —
   `replace_entity` does not suffice.** `Model.asset` is whole-instance
   and structural (a changed asset diffs to destroy+recreate of the
   entire instance, its animations included), and an entity cannot
   parent to a *named glTF node* of another instance (parent refs are
   entity ids). Filed `mob_scene3d-kgd` (per-node mesh assignment or
   named-node attachment). v1 workaround, tagged in
   `Chopaat.Scene.tumbles_entity/2`: the canonical proxy hulls perform
   the flight, the game's cosmetic pool shells pose at rest after settle
   (the visible swap that already existed). Removal: `chopaat-25o`.

5. **Camera stays the fixed per-player-count framing** the screens lane
   tuned (board fully visible, ~52° down-angle). The active-player focus
   shift was the bead's explicit nice-to-have and was skipped for device
   time.

6. **Scripted device acceptance is a driver script, not ExUnit**
   (`scripts/device_acceptance.exs`): a full 4-player game to placements
   driven over distribution — `tap_id` for throw/handoff/confirm (real
   touch path), the `{:pawn_picked, id}` seam for pick-to-move (select →
   assert marker → tap marker), one real ray `pick/3` probe — with
   per-move native world-transform assertions against `Scene.build`
   (skipped only while the handoff hides the board: the viewport
   unmounts with it), per-throw settle-verdict assertions, tipped/upright
   native pose checks, and frame_stats entity-leak checks. The
   capture-cycle recording is triggered by simulating each upcoming turn
   locally from the live `{game, rng}` snapshot — possible only because
   the whole pipeline is deterministic from the seed. `:throw_speed`
   (plugin `Animation.speed`) compresses clips 4× for the scripted runs;
   the settle contract is pose-based and speed-independent.

## Consequences

- `mob.exs` (gitignored, machine-local) must exist for device deploys;
  the canonical shape is committed to the adoption record and this repo
  recreates it per checkout (plus `android/local.properties`).
- The hex pin for mob_scene3d is still pending — no release exists yet
  (checked `mix hex.info mob_scene3d`, 2026-08-31); the path dep stays
  until the plugin cuts one.
- Per-turn handoff unmount/remount of the viewport survived a full
  scripted game on both pool targets (entity counts flat), so the
  simple "handoff replaces the board" render stands for v1.
