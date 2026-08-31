# 2026-08-31 — The session boundary: game hosted, presentation a client

Bead: chopaat-uzu. Implements the owner ruling recorded in AGENTS.md
("Presentation is a client", 2026-08-31): the game must be hostable with
no renderer anywhere. Before this, `GameScreen` held the `Chopaat.Game`
state in its own assigns and threaded `Chopaat.RNG` itself — the screen
WAS the host. Now `Chopaat.Session` is the host and every presentation
(3D today; 2D at chopaat-u8x; a projected web client, possible-not-built)
plus every headless driver (bots at chopaat-27z; the machine API at
chopaat-85o) is a client of the same process.

## The session

`Chopaat.Session` (GenServer) owns: the pure `Chopaat.Game` reducer, the
`Chopaat.RNG` state (ALL randomness is server-side), the variant, the
player config and cosmetic seed (`Chopaat.Setup`), and — via the game
facts — the drought-assist state (the session applies the 70/30 bias the
rules facts dictate). Commands in, events out, all plain data.

```
start_link(opts)                  :setup | :players/:names/:variant, :rng_seed,
                                  :game (fixture/resume), :draw (test seam), :name
new_game(session, opts)           rematch: fresh game, same seats
observe(session)                  full public state, strictly JSON-serializable
game(session) / setup(session)    struct snapshots (in-BEAM client convenience)
export(session)                   %{game, rng, setup, seq} — predictors/persistence
legal_actions(session, seat)      the exact Rules.action() terms accepted
throw(session, seat)              session draws shells + cosmetic, applies the roll
assign(session, seat, action)     non-khadu actions
confirm_khadu(session, seat, a)   the explicit destructive commit
subscribe/unsubscribe(session)    event stream
```

Every accepted command returns `{:ok, events}` *and* broadcasts the same
events to every subscriber as `{:chopaat_session, session_pid, seq,
event}`, `seq` strictly increasing, broadcast-before-reply (a client that
commands and subscribes has its own events queued when the call returns).
Seat-checked (`{:error, :not_your_turn}`); khadu via `assign/3` is
refused with `{:error, :khadu_requires_confirmation}` — the burn (*dana
ane pagdu badi gaya*) is explicit at the API level, not just in the HUD.

Dependency direction: clients MAY depend on game modules (the 3D screen
builds scenes from `game/1` structs; the 2D client will draw from
`observe/1` cell names); game modules may NEVER depend on presentation.
`Chopaat.Throws` is presentation-plane (it names Mob IR animation state).

## Event vocabulary (designed for renderers)

Payloads are maps; positions are `%{state: :base | :track | :home, track:
n | nil, cell: "cell_t2_l0_r5" | "center_home" | nil}` — the cell-name
string is the render key (the 2D board draws straight from it; 3D maps it
through BoardMap). The chopaat-85o protocol doc will formalize the wire
serialization of these events; this table is the vocabulary contract.

| event | payload | renderer meaning |
| --- | --- | --- |
| `{:game_started, e}` | `variant, num_players, turn` | reset the board |
| `{:throw_result, e}` | `seat, shells, up_count, score, special, entry, cosmetic, phase, rolls, pending, bonus_steps` | perform the tumble; update trays |
| `{:moved, e}` | `seat, pawn, action, roll, from, to, path` | hop the pawn along `path` |
| `{:captured, e}` | `seat, victim_seat, victim_pawn, cell, tod_earned, victim_tod_lost` | send the victim home; gate flourish |
| `{:khadu, e}` | `seat, pawn, roll, burned: %{dana: [..], pagdu: n}` | announce the burn |
| `{:wasted, e}` | `seat, roll (score or :bonus)` | announce the waste |
| `{:turn_passed, e}` | `seat, next_seat, extra_turn` | handoff prompt / extra-turn banner |
| `{:placement, e}` | `seat, rank` | podium update |
| `{:game_over, e}` | `placements, loser` | final report |

`observe/1` (the machine-facing snapshot) is strictly JSON-serializable —
`:json.encode/1` round-trips it in the test suite: seq, variant,
num_players, turn, phase, rolls/pending/bonus_steps, captured_this_turn,
placements, board geometry facts (arms/home/connector/gate/marker/
khadu_skip), per-seat `{name, color, tod, gate, assisted, drought,
pawns}` with pawn facts `{state, track, cell, bypass, tipped, jammed}`,
and occupancy keyed by cell-name strings. `jammed` is defined hard: gate
active and even the smallest throw-table score would cross it. Action
terms (`{:assign, i, ix}` etc.) stay the reducer's tuple grammar — they
are "the exact terms the session accepts"; their JSON encoding is 85o's.

## The throw flow: presentation grace, not dependency

`throw/2` draws shells (fair or assisted per `Game.assisted?/2`) plus one
uniform *cosmetic* integer and applies the roll immediately — the session
never waits for any renderer ack, so a headless client (auto-play, the
machine API) advances at full speed with no renderer compiled anywhere.
Pacing is client-local: the 3D screen keeps rendering its pre-throw state
until its tumble settles (`{:animation_done, play_id}`), then adopts the
session's truth; bot cadence (27z) is delay in the bot driver, never
session gating. The cosmetic integer is the one presentation channel:
each renderer maps it onto its take library (`rem` by take count —
`Chopaat.Throws.perform/2` for 3D; the 2D flip picks the same way), so
every client and every host-side predictor (`Session.draw_throw/2` over
`Session.export/1`) presents the identical outcome. `Chopaat.Throws`
therefore shrank from outcome-drawing to pure performance:
`perform(up_count, cosmetic)` + `schedule_done` + `settle_check`.

Settle verification stays client-side by design: it verifies the RENDERER
against the session's truth (two-plane model) — a mismatch is a
presentation bug by construction, logged loudly, counted in
`assigns.settle`, and the session's state stands.

## The boundary test (the ruling's teeth)

`test/chopaat/boundary_test.exs`: the game plane —
`Chopaat.{Game, Rules, Board, Variant, Throw, Pawn, RNG, Session, Setup}`
— may not reference `Mob.*`, `Chopaat.Scene*`, or `Chopaat.Screens.*`.
Mechanics: per-module BEAM `:atoms` chunk (catches remote calls AND
struct literals/module-atom references, which leave no call site), plus a
transitive walk of the `:imports` remote-call graph inside `Chopaat.*`
(no laundering a Mob dependency through an intermediary such as
`Chopaat.Throws`). A third test pins the module list against silent
renames. `mix test` is a push gate, so a violation fails the build. Fix
the dependency direction, never the test.

## Consequences

- `GameScreen` mounts (or receives via `:session`) a session, subscribes,
  and updates only from events; commands via taps. Screen assigns keep
  their names (`game` is now the *presented* snapshot, which may lag the
  session by one tumble).
- ScreenCase tests drive the same seams and pump the subscription events
  (`drive/2` helper); scripted outcomes moved from the old ThrowsStub
  draw to the session's `:draw` injection (`Chopaat.Support.ScriptedDice`).
- `scripts/device_acceptance.exs` predicts captures from
  `Session.export/1` + `Session.draw_throw/2` instead of screen-held rng;
  `scripts/device_sanity.exs` is the short session-refactor sanity drive.
- Session lifetime: the pass-and-play screen links its session (dies with
  its only client). LAN/online hosting supervises sessions elsewhere and
  passes the ref — nothing in the session assumes a screen exists.
