# Asset round 3 — authentic pawns, cloth skin, out-of-frame tumble entry

Date: 2026-08-31. Lane: feat/assets-round3.
Beads: chopaat-xix (pawns), chopaat-a02 (cloth board), chopaat-huv
(tumble re-bake half only — the ThrowPresentation seam half stays with
the app lanes).

## 1. Authentic pawns (chopaat-xix)

### Reference research (owner ruling: research original sources first)

What makes a chaupar/pachisi pawn read as authentic:

- **Beehive/domed turned-wood form.** The canonical description across
  sources: "counters are made of wood in a beehive shape" — a squat
  domed body from the lathe, not a Staunton-style stemmed chess pawn.
  Antique north-Indian counters (narads) are "of domed form" with a
  "Mughal-esque architectural quality", 2.4–3.1 cm tall — i.e. roughly
  as wide as they are tall.
- **Lac-turnery finish (Channapatna).** Traditional pieces are turned
  on the lathe and colored by pressing lac sticks against the spinning
  wood, then polished with palm leaf — a glossy, saturated lacquer
  over visible turning. Modern artisan sets ship "Jet Black, Bright
  Red, Pineapple Yellow, Basil Green" pawns ~1" tall x 0.75" dia.
- **Two-tone decoration.** The owner's references show painted body in
  the player color with a contrasting band/collar and/or tip in
  natural wood / ivory — turned grooves take the second color cleanly
  on a lathe piece. (Antique ivory sets invert this: stained color
  over a natural ivory ground.)
- **Traditional player colors** are red, green, yellow, black
  (mastersofgames/tradgames); black is unusable on our dark cloth, so
  the 4p palette keeps red/green/yellow and substitutes a blue.

Reference URLs:
- https://www.tradgames.org.uk/games/Pachisi.htm ("beehive-shaped
  Chaupar pieces", cloth board)
- https://www.mastersofgames.com/rules/pachisi-rules.htm (16 beehive
  pieces in black/green/red/yellow; 6-cowrie throws)
- https://rollthedice.in/products/pagade-pawns (Channapatna pagade
  pawns: 1" x 0.75", lacquered, four classic colors)
- https://artsandculture.google.com/story/how-to-make-a-channapatna-toy-dastkari-haat-samiti/dgWhsovsWjHlLQ
  (the lac-turnery process: lathe + lac stick + palm-leaf polish)
- https://www.michaelbackmanltd.com/object/indian-pachisi-counters/
  (18th-c. stained-ivory narads, domed form, 2.4–3.1 cm)
- https://www.penn.museum/sites/expedition/the-indian-games-of-pachisi-chaupar-and-chausar/
  (cloth "boards", cross shape — piece detail thin, board context)
- Etsy market survey for contemporary handcrafted sets (cloth board +
  turned wooden pawns + cowries), e.g.
  https://www.etsy.com/listing/1107959430/handcrafted-chaupar-pachisi-game

### What shipped

- `pawn.py` rewritten: chaupar beehive profile (flared foot ring,
  squat domed body, waist, collar bead, dome head + finial), 44 mm
  tall x 26 mm base (slightly taller than the 1.33 reference ratio so
  the RULESET.md status poses stay readable at the 45° camera). The
  directional +X nose stays — tipped vs upside-down must read at a
  glance; the accent band is radially symmetric so the nose remains
  the direction cue. 1,464 tris (< 3k budget).
- **Two named materials** (the structural change): `pawn_body`
  (near-white 0.92; the runtime baseColorFactor override carries the
  player color; factor multiplies the grain texture so grain survives
  the tint) and `pawn_accent` (authored ivory/natural, never tinted).
  Lacquer look via KHR_materials_clearcoat.
- Wood grain embedded: 256x256 baseColor + roughness textures
  (cylindrical UVs, TEXCOORD_0), deterministic numpy generation.
  pawn.glb = 104 KB.

### Required runtime change (NOT in this lane — recorded on chopaat-xix)

`Chopaat.Scene.pawn_entities/6` (and the `target_*` markers) set
`%Model{material: %Material{base_color: tint}}`. The plugin applies
that override to **every** material instance of the model
(mob_scene3d `MobScene3dBridge.kt applyMaterial` loops
`instance.materialInstances`), so on the two-material pawn it would
tint the ivory accent too. Two changes, after both lanes merge:

1. mob_scene3d: name-scoped material override surface (e.g.
   `Model.materials: %{"pawn_body" => %Material{...}}` or a
   `Material.target` field) — the native side filters
   materialInstances by glTF material name. Plugin gap → file in the
   mob_scene3d tracker per AGENTS.md.
2. chopaat GameScreen/Scene: scope the pawn tint (and the selected
   emissive lift) to `pawn_body`. Until then the runtime tints both
   materials — pawns stay fully player-colored (round-2 behavior),
   the two-tone appears when the scoped override lands. Palette
   values for `Chopaat.Setup` tints: assets/palettes.json
   `linear_rgba` (glTF linear factor semantics).

### Palettes (4p and 6p, colorblind-checked)

Okabe-Ito color-universal-design set (assets/palettes.json):
4p = vermillion #D55E00, green #009E73, yellow #F0E442, sky blue
#56B4E9 (traditional red/green/yellow + blue for the 4th seat; black
is unreadable on the dark cloth). 6p adds blue #0072B2 and purple
#CC79A7. Accent ivory #EFDDB8 authored in the asset.

Verification method (assets/scripts/colorblind_sim.py, run in the
pipeline): Machado, Oliveira & Fernandes (2009) severity-1.0
deuteranopia/protanopia matrices applied in linear RGB (the standard
physiologically-based simulation; what colorspacious/daltonlens
implement — implemented directly since Blender's python carries numpy
but no colorspacious), then min pairwise CIE76 ΔE in CIELAB/D65,
asserted ≥ 10, plus ΔE vs the dark cloth. Results
(assets/contact_sheets/palette_cvd_report.txt):

    players_4 normal : min pair ΔE 59.5   deutan: 33.6   protan: 37.2
    players_6 normal : min pair ΔE 26.4   deutan: 17.9   protan: 20.7
    min vs dark cloth ≥ 41.8 everywhere

Simulated sheets ship alongside the originals
(pawns_{4p,6p}{,_deutan,_protan}.png — poses on the dark board arm).

## 2. Cloth board skin (chopaat-a02)

Owner ruling: the board is cloth; wrinkles sell it. Kept the approved
dark palette + gold center; geometry budgets unchanged (no
displacement — normals do all the work).

- **Woven base**: 256px plain-weave baseColor + roughness tile
  (2 mm thread pitch, per-thread jitter, approved 0.020/0.018/0.016
  linear cloth color baked into the texture), tiled ~30x via a second
  planar UV layer (TEXCOORD_1, core-glTF REPEAT sampler — deliberately
  no KHR_texture_transform so no new plugin surface is assumed).
- **Wrinkle normal map**: 1024px, TEXCOORD_0 planar. Height field is a
  *scripted sculpt* — anisotropic fold ridges + low-frequency billow,
  amplitude masked strong within ~35 mm of the outline edges and
  boosted at the arm-shoulder crotches ("between arms"), floored at
  0.28 under the play field. Chosen over a Blender cloth sim for
  headless determinism and direct amplitude control; at the
  normal-map level the two are visually equivalent. Markings stay
  crisply legible *by construction* — the cell tiles are separate
  rigid meshes with their own materials; only the cloth slab carries
  the wrinkle normals (the play-field floor keeps the cloth they rest
  on visually flat). TANGENTs exported (slab triangulated for
  MikkTSpace).
- Both boards: board.glb 788 KB, board_6p.glb 1.15 MB — embedded PNG,
  under the 2 MB `maxFileKB` budget, so no KTX2 needed (gate now
  enforces the threshold; exceed it → gltf-transform KTX2 per the
  round ruling). Node addressing contract untouched (gate asserts).
- Evidence: board_light/dark sheets at the sheet camera, plus
  **cloth_closeup.png** — raking light (9° warm key) across the arm
  margin toward the gold center; the folds catching that light are
  the selling shot.
- Note for the integration lane: first device run should eyeball the
  cloth (TEXCOORD_1 sampling + tangent-space normals through the
  plugin renderer); embedded glTF textures already render today, and
  no extension beyond core glTF + existing clearcoat/specular is used.

## 3. Tumble re-bake: out-of-frame entry (chopaat-huv, re-bake half)

Owner ruling: current falling look APPROVED; v1 shells must enter
from out of frame (top) at the ACTUAL game camera.

- Game framing read from `lib/chopaat/scene.ex` rig/1 (READ-ONLY):
  4p camera (0, 1.05, 0.78), 6p (0, 1.20, 0.90), both pitch −52°,
  fov_y 45°, tumbles origin at center_home (glTF y 0.011). Mirrored
  as `GAME_CAMERAS` in tumble.py with a keep-in-sync note.
- **Honest high-energy variants were piloted and rejected** (numbers
  in the bake logs): dropping from above the frustum (~0.72–0.87 m)
  arrives at 2.2–3.9 m/s even with heavy drag; Blender's Bullet
  exposes no rolling friction, so shells roll off-plate in >95% of
  attempts across three physics tunings (0–1 accepted in 240 sims
  each). Ballistics forbids arriving slowly from a high start — a
  backward-integrated gravity trajectory from a gentle launch comes
  from *below* frame, not above.
- **Shipped design**: the sim is the byte-identical approved round-2
  throw; each shell gets a baked entry segment built backward from
  its launch state — constant tumble (the launch spin), ~3 m/s
  descent easing into the exact launch velocity over 8 frames (the
  splice is C1-continuous), walked upward until above the top frustum
  plane of BOTH cameras with an 8% tan-space margin (+2 frames), an
  out-of-frame hold padding the seven shells to one frame range. The
  entry is authored presentation over an asserted physical settle —
  consistent with "rules first, animation performs the answer".
- Same manifest contract (outcome/take/duration/per-slot orientation),
  same classification rigor (assert outcomes, re-roll ambiguous):
  32 takes from 232 sims, durations 1.50–2.48 s (band 1.5–2.5 kept;
  the entry counts toward the duration). Manifest gains an `entry`
  section (cameras, clearance, margin, fall speed).
- Verification: tumble.py asserts frames 1–2 of every shell of every
  take out-of-frame at both cameras; **gate.mjs re-derives the first
  translation keyframe of every slot from the GLB binary and asserts
  it above both frusta** (alongside the existing final-quaternion
  re-classification). Visual acceptance:
  **tumble_entry_4p.png / tumble_entry_6p.png** — 8 outcomes x 6
  frames rendered AT the game cameras (360x400 game aspect): frame 1
  shows no shells (verified pixel-identical board-only tiles), then
  the stream enters from the top edge and settles on the plate.
- tumbles.glb: 875 KB after resample (entry keyframes added ~40%).
- The ThrowPresentation module boundary + future shake-and-spill
  remain with the app lanes (recorded on chopaat-huv).

## Gate extensions

- budgets.json: `maxTextureDim` (per-embedded-PNG pixel cap, read from
  PNG IHDR in the GLB binary) and `maxFileKB` (whole-file cap; the
  KTX2 trigger). Boards: 3 textures / 1024 px / 2 MB. Pawn: 4 textures
  / 256 px / 256 KB, tris 3k.
- gateTumbles: the out-of-frame entry re-derivation described above;
  fails if the manifest lacks the `entry` contract.
