# 2026-08-31 — Bots as session clients; AUTO mode is the first deliverable

Bead: chopaat-27z (depends on chopaat-uzu's session boundary). Owner
directive on the bead: bot-vs-bot AUTO — the game plays itself,
watchable, to placements, with a rematch loop — ships first; mixed
human/bot seats ride along in the same seat-config menu.

## Architecture: three small pieces, all on the game plane

- **`Chopaat.Bot`** — the decision contract plus shared observation
  arithmetic. `choose(observation, legal, rng) -> {action, rng}` where
  `observation` is exactly `Session.observe/1` (public, JSON-grade
  plain data) and `legal` is exactly `Session.legal_actions/2`. No
  cheating by construction: bots never see `Game` structs, `game/1`,
  or RNG state. Randomness threads as explicit `Chopaat.RNG` state, so
  every bot game is seed-reproducible. Bots may use `Chopaat.Board`'s
  pure geometry over the observation's board facts (geometry is public
  information); they may never touch `Mob.*`/`Scene*`/`Screens.*` — the
  boundary test's game-plane list now includes all five bot modules.
- **`Chopaat.Bot.Random`** (menu: Bot · easy) — uniform over legal.
  **`Chopaat.Bot.Heuristic`** (menu: Bot · normal) — the bead's ladder:
  captures > entering > advancing (prefer the leader) > safe stops;
  penalty for parking within dana reach (3 cells) of an active gate;
  forced khadus pick the least-bad pawn (landing keeping the most
  progress; a capturing khadu outranks all). Deterministic (first-max),
  so heuristic play is a pure function of the observation.
- **`Chopaat.Bot.Runner`** — one GenServer per bot seat, an ordinary
  session client: subscribes, debounces every event burst into a single
  `{:act, token}` after `delay_ms`, re-observes, and issues exactly one
  command when it's its turn (`throw`, `assign`, or `confirm_khadu` —
  the destructive commit stays explicit even for bots). Extra rolls and
  extra turns fall out of re-observing per event. `Chopaat.Bot.Supervisor`
  (one_for_one) hosts the runners for one session.

## Bot-crash policy (never wedge, never forfeit)

1. A raising/off-list `choose/3` is rescued in the runner and degraded
   to a legal-random pick for that decision, logged loudly. The seat
   keeps playing — forfeit the intelligence, never the seat.
2. A crashed runner process restarts (`:transient`, intensity 10/10s),
   re-subscribes, re-observes, resumes mid-turn (acting is idempotent —
   the runner holds no game state worth losing).
3. The session going down stops runners normally (monitor → `:normal`),
   so a dying game never spins restart churn.
4. Command rejections (races) are logged at debug and re-scheduled — an
   all-bot game cannot stall on a swallowed error.

Rejected alternative: "bot crash forfeits the seat" — with a pure
observe/act loop a restart is strictly safer than a forfeit, and the
soak use (indefinite auto games) wants self-healing.

## Pacing defaults

- `:chopaat, :bot_delay_ms` — default **1600 ms** between bot commands
  (longer than a tumble take, so throw → tumble → assign reads at a
  watchable cadence). Tests and headless soak run at 0. Pacing lives in
  the runner only; the session never waits (uzu ruling).
- `:chopaat, :auto_rematch_ms` — default **4000 ms** on the end screen
  with the auto-loop toggle ON (long enough to read the podium).

## Menu / screen surface

Per-seat chip cycles Human → Bot · easy → Bot · normal (4p and 6p);
AUTO sets every seat to Bot · normal and starts immediately. GameScreen
takes `params[:bots]` (seat → bot module), starts the linked runner
supervisor, and on bot turns renders as a spectator: same trays and
performances, header marks `bot`, no inputs, no pass-the-device prompt
toward bot seats, stray taps inert. Game over offers Rematch
(`Session.new_game(reshuffle: true)` — new_game gained the `:reshuffle`
option: same seats, fresh cosmetic shell set) and, in full-auto games,
the auto-rematch loop toggle (the standing soak).

## What the first soak caught (the mode paying for itself)

The very first unattended device game found two things:

1. **A rules-plane bug**: a khadu committed from lap position `x <
   khadu_reverse` (a frozen pawn at x=2 under a 30+30+25 pending total)
   made `Rules.action_path/2` walk *negative* track positions; the
   `{:moved}` event then carried a nonexistent cell name
   (`cell_t2_l2_r0`, row 0) and the 3D scene crashed on the lookup
   (screen remounted, game progress lost). Fixed: the khadu traversal
   keeps only on-board waypoints (the landing arithmetic — RULESET.md's
   `x - 4 + roll` — was already correct); regression tests at the rules
   and session-event layers pin it.
2. **Settle policy under soak**: one `Mob.Scene3d.scene/1` readback
   `:timeout` in 147 reads on the loaded pool emulator. Per the
   two-plane model `mismatch` (the renderer lying) stays strictly zero,
   but the AUTO sanity script tolerates rare readback *errors*
   (max(3, 2%) of settled throws), reporting each — an environmental
   read failure is not a presentation bug.

## Strength evidence (seeded, in `Chopaat.BotMatchTest`)

Over 500 mixed 4p games (2 heuristic + 2 random, seat pattern rotated):
heuristic seats win **87.2%** (parity 50%). Over 100 mixed 6p games
(3v3): **97%**. Asserted at >75% / >70% to leave wobble headroom. All
1000 headless auto games (mixed, all-heuristic, all-random, 4p and 6p)
terminate with complete placements, and every bot action is asserted
`∈ legal_actions` at decision time.
