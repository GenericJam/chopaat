# AGENTS.md — chopaat

Conventions for agents (and humans) in this repo. These carry over the
discipline the Mob ecosystem converged on (`mob`, `mob_dev`, `mob_new`,
`mob_scene3d`, and the downstream prototype fleet) — rules that were paid
for are marked with why.

## Relationship to mob_scene3d (read this first)

This game is the **driving consumer** for the mob_scene3d plugin — the
same role the downstream prototype played for mob core. The contract:

- A plugin gap found here becomes a **bead in mob_scene3d's tracker**
  (`~/code/mob_scene3d`, `bd create` there), with a reproduction and
  device evidence. It does not get silently worked around in game code.
- A temporary workaround is allowed only with a bead reference in a code
  comment and a chopaat bead to remove it after the plugin release.
- Trackers are separate on purpose: chopaat beads are game work,
  mob_scene3d beads are plugin work. Cross-reference by full bead id
  (`mob_scene3d-xxx` / `chopaat-xxx`). Precedent: an earlier app's tracker
  carried `mob upstream:` beads and it worked, but ownership was
  clearer once split — don't merge them back.
- Never modify plugin code from this repo's lanes. Plugin work happens in
  mob_scene3d worktrees under its own review flow.

## Toolchain

Pinned in `.tool-versions` (mise reads it; **the zig pin requires mise** —
asdf cannot fetch historical Zig dev nightlies):

- erlang 29.0 · elixir 1.20.0-otp-29 · java temurin-17.0.18
- zig 0.17.0-dev.269+ebff43698 — exact dev version is deliberate; never
  bump casually (mob_dev's preflight hard-fails on any other version)

Run everything through `mise exec -- mix ...`. Asset tooling additionally
requires Blender (headless), Node (`gltf-transform`, glTF-Validator), and
Filament's `cmgen` — versions pinned in the asset scripts when they land.

## Gates — before any push

```
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix test                          # full suite, no default-skipped surprises
```

Plus, when native/asset surfaces exist: swiftlint / ktlint / clang-format
on touched sources, and the asset gate (below). Two-tier pre-push hook per
the mob pattern (`.githooks/`, `git config core.hooksPath .githooks`):
cheap checks always, full preflight when `mix.exs` changes.

## Game-specific discipline

- **Rules stay pure.** Game logic is pure functions over state — no
  processes, no side effects, no `:rand` calls inside rules (the throw
  value is an *input* to the rules). This is what makes the rules layer
  fully agent-verifiable: property tests, fairness chi-square over large
  samples, termination checks, mass simulated playthroughs.
- **House rules are config data.** Variant behavior (shell values,
  extra-throw triggers, captures, home entry) lives in a variant struct
  loaded from config. Never hardcode a variant choice; when the owner's
  written variant table is ambiguous, ask — do not guess and property-test
  the guess into concrete (a rules rewrite after acceptance is the most
  expensive kind).
- **Rules first, animation performs the answer.** No runtime physics.
  Shell throws draw from audited RNG, then play a baked tumble whose final
  configuration matches. After settle, assert via `Mob.Scene3d.scene/1`
  readback that shell orientations match the drawn value — the honest-
  harness principle applied to the core mechanic.

## Asset discipline

- `.glb` only in `priv/` (embedded buffers, one file per asset). KTX2 for
  standalone textures; cmgen-precomputed IBL. FBX/OBJ/USDZ never enter the
  repo — convert at authoring time.
- Every asset lands through the gate: Khronos glTF-Validator clean +
  `gltf-transform inspect` within budgets (tri count, material count,
  texture size, bounds — budgets recorded next to the asset scripts).
- Authoring is scripted and reproducible: headless Blender scripts live in
  the repo; a human-supplied binary asset with no generating script needs
  a bead explaining why. Tumble-library generation (rigid-body sim → bake
  → export, sorted by outcome) is a script, and its outcome-classification
  step is asserted, not eyeballed.
- Art direction reviews are **batched contact sheets** (headless renders,
  many variants per round). Ruling latency, not agent throughput, is the
  schedule risk — don't ping the human per shell.

## Device work

Same rules as the rest of the ecosystem, learned the hard way:

- **Verify effects, not exit codes.** Deploy tooling has exited 0 on
  silently skipped builds. After deploy: `adb shell pidof` / node connect /
  `Mob.Test.screen/1` before believing anything.
- One driver per device; leases with unique client ids; humans outrank
  agents; release leases in an exit path.
- **Never `mix mob.push` with a fleet attached** (fans out to every live
  node, ignores --device). Per-device `mix mob.deploy --native --device`.
- Pool-sim traps: per-device `MOB_SIM_RUNTIME_DIR` must exist; dist-port
  collisions are fatal on iOS — unique `SIMCTL_CHILD_MOB_NODE_SUFFIX` and
  port per session.
- Physical hardware for acceptance — emulators hide real bugs (API-level
  gaps, wide-color capture). Final game acceptance is pass-and-play on two
  physical phones.
- Evidence discipline: scene/frame readback for geometry, pixel sampling
  for exact color, **recordings for animation** (stills prove nothing
  about motion), screenshots for human-facing records.

## Review and coordination

- Adversarial review by default: refute, don't confirm; findings tagged
  Blocking/Suggestion/Question/Nit with file:line; runtime claims need a
  reproduction or traced interleaving. Fresh-context review beats
  author-context; findings become beads; any agent picks them up.
- Source-contract tests assert token-level strings + ordering, never
  whitespace blocks.
- PRs squash-merge; PR bodies list verification actually performed.
- Per-task git worktrees; never touch another lane's worktree or the
  user's primary checkouts; prune only your own merged lanes.
- Durable conclusions go in beads/PR comments/decision records
  (`decisions/`, dated markdown) — context windows are ephemeral; the
  artifact is the handoff.
- Releases (when this ships anywhere): changelog with every release,
  Keep a Changelog, entry in the bump commit; and if it's ever packaged,
  the packed-artifact lesson applies — compile-time resources ship inside
  the package, verified by fetching and compiling the published artifact.
