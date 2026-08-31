# Chopaat

A cross-and-circle board game (the Chaupar family) built with
[Mob](https://mobframework.com) — Elixir on the BEAM, native rendering on
iOS and Android — with 3D board, pieces, and cowrie-shell throws rendered
through [mob_scene3d](https://github.com/GenericJam/mob_scene3d).

**Status: rules engine landed.** The pure rules engine implements the
owner's authoritative [RULESET.md](RULESET.md) (the Gujarat variation) as
the default `Chopaat.Variant`; formalization choices and open owner
questions are recorded in `decisions/`. Screens, scene, and assets are in
flight — plan in the bead tracker (`bd list`); conventions in
[AGENTS.md](AGENTS.md).

This repo is also the **driving consumer** for mob_scene3d: game
development is expected to find plugin gaps, and those gaps get fixed
upstream, never worked around silently here (see AGENTS.md).

## Architecture at a glance

- **Rules engine** — pure Elixir functions over game state. No process
  state, no rendering, no randomness inside the rules: `Rules.throw_score/2`,
  `Rules.legal_actions/1`, `Rules.apply_action/2` and the `Game` reducer all
  take everything they need. Property tests and mass simulated playthroughs
  are the acceptance gate.
- **House rules are data, not code.** Chaupar/Chopaat variants disagree on
  shell-count values, extra-throw triggers, captures, and home-column
  entry. The rules engine takes a variant config struct; the family's
  exact rules live in a config file, changeable without touching logic.
- **The throw: rules first, animation performs the answer.** The RNG draws
  the outcome (auditable, property-tested for fairness), then the scene
  plays a pre-baked cowrie tumble animation whose final configuration
  matches the drawn count. There is **no runtime physics** — tumbles are
  Blender rigid-body sims baked to glTF animations at asset-build time,
  a library of several takes per outcome so throws don't look canned.
- **Screens** — standard Mob UI: menu, game screen (a `Scene3d` plus HUD),
  settings/variant selection, pass-and-play turn flow. Online multiplayer
  is out of scope for v1 (it's a Phoenix channel server when wanted).
- **Assets** — `.glb` only, per the mob_scene3d pipeline: board and pieces
  procedural via headless Blender; shells gen-AI or procedural with a
  Blender cleanup pass; everything gated by glTF-Validator +
  `gltf-transform inspect` budgets before it lands in `priv/`.

## Verification model

Layered, per the mob playbook — each layer needs no eyes below it:

1. **Rules**: property tests, fairness statistics, termination proofs,
   thousands of simulated games. Pure functions; agents own this outright.
2. **Scene truth**: `Mob.Scene3d.scene/1` readback asserts pieces are
   where the rules say; post-throw readback asserts shell orientations
   match the rolled value; `pick/3` asserts taps select the right piece.
3. **Visuals**: headless Blender renders (asset time) and device
   recordings (integration time) reviewed by the humans — batched contact
   sheets, not one-asset pings.
4. **Play**: physical phones, pass-and-play, the family. Definition of
   done for v1: a full game played to completion on two physical devices
   with no one touching a terminal.
