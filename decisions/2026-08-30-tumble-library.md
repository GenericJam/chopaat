# Tumble animation library — decisions (bead chopaat-5gx)

Date: 2026-08-30. Lane: feat/tumble-library.

## What shipped

- `assets/scripts/tumble.py` — headless-Blender rigid-body bake:
  canonical collision proxy, 7-shell throws, in-script outcome
  classification, NLA-track export.
- `priv/assets/tumbles.glb` — 7 slot nodes `shell_0..shell_6`
  (placeholder proxy hull mesh, 796 tris, 1 material) + 32 named
  animations `throw_k{0..7}_v{0..3}`, keyframe-decimated
  (`gltf-transform resample --tolerance 0.001` in build.sh), 613 KB.
- `assets/tumble_manifest.json` — the runtime contract: per animation
  the outcome count, take, seed, duration and per-slot final
  orientation (`aperture_up[7]`), plus proxy fairness numbers and
  re-roll stats.
- `assets/scripts/tumble_preview.py` — mp4 settle previews that
  round-trip the shipped GLB with real pool meshes on the slots.
- gate.mjs: new `gateTumbles()` — see below.

## Decisions

1. **One tumbles.glb, not per-outcome files.** The 7 slot nodes and
   the placeholder mesh are shared; animations are transform-only
   tracks (~10–25 KB each, 613 KB total). Splitting would duplicate
   the node set per file and complicate the runtime contract (one
   scene instance, one animation namespace) for zero size benefit.
2. **Canonical proxy = convex hull at pool-mean dims** (0.0235 ×
   0.0166 × 0.0106 m, extent inside the 0.023–0.024 window; per-axis
   dims asserted inside the pool envelope and recorded in the
   manifest). Same center-bottom origin and dome-up rest as every
   pool member, so runtime mesh assignment is a plain mesh swap. The
   hull carries a small flat crest cap — collision-only detail so
   dome-down rest is stable (visual meshes keep full domes).
3. **Slot nodes carry the proxy mesh** (not empties): the file is
   self-previewable and documents the collision volume; the runtime
   swap replaces `shell_i`'s mesh exactly as tumble_preview.py does.
4. **Outcome targeting by biased start faces, honesty by assertion.**
   Each take starts k shells near aperture-up and 7−k near dome-up
   (±20° jitter, random yaw, randomized drop/impulse/spin via the
   kinematic-release launch); physics decides the final face and the
   take is accepted only if the classified outcome equals the target,
   every shell is unambiguous (|up| ≥ 0.7) and on-plate, and the
   settle fits the 1.5–2.5 s band. Full bake: 160 sims for 32 accepted
   takes (128 re-rolls; reasons recorded in the manifest stats).
5. **Settle is a stability window + tail convergence, not Bullet
   sleep.** Paid-for physics findings, asserted in comments/tests:
   - Bullet's default 0.04 m collision margin exceeds the shell size →
     explicit 0.4 mm margins.
   - Blender's rigid bodies treat the object origin as center of mass
     → sim runs on a centroid-origin mesh clone; baked keyframes are
     re-based to the center-bottom frame (`M_b = M_c @ T(0,0,-h)`).
   - Bodies with animated kinematic/transform fcurves are re-activated
     every frame (never sleep), and single-point dome contact top-spin
     has no rolling friction in Blender — so residual sub-mm/few-deg
     wobble never numerically stops. Takes end when every shell stays
     within 2.5 mm of its final position with stable classification;
     the last 0.4 s is smoothstep-converged onto the final simulated
     pose (error bounded by the measured wobble, not authored motion).
6. **Gate cross-check reads the GLB binary.** `gateTumbles()` parses
   the BIN chunk, takes the final rotation quaternion of every slot in
   every animation and re-classifies (glTF local +Y: upY = 1 −
   2(x²+z²) vs ±0.7): must match the manifest, names must parse as
   `throw_k{count}_v{take}` with count == aperture-up total, ≥4 takes
   per outcome 0..7, durations in band. Verified to fail on manifest
   tampering and pass on the shipped file.

## Runtime contract (for chopaat-hre / mob_scene3d-al6)

Place the tumbles scene origin at the board center-plate top surface
(board.py: 3×3 cells of 0.05 m). Assign the game's 7 drawn pool shell
meshes to `shell_0..shell_6`, play `throw_k{rolled}_v{random take}`,
and after the completion event assert via scene readback that each
slot's local +Y world direction matches `aperture_up` in
`assets/tumble_manifest.json`.
