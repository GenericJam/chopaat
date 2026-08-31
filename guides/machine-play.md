# Machine Play — the Chopaat game protocol

**Protocol:** `chopaat.machine_play` · **Version:** 1.0.0 · **Module:** `Chopaat.MachinePlay`

This document is written for an agent. If you can call three functions and
read JSON, you can play Chopaat legally after reading only this page. The
same contract is available *as data* from `describe/0`, so a runtime can
hand you the grammar and schema without handing you this prose.

Contents:

1. [The game in one paragraph](#the-game-in-one-paragraph)
2. [Joining and transports](#joining-and-transports)
3. [The calls](#the-calls)
4. [The state you observe, field by field](#the-state-you-observe-field-by-field)
5. [The action grammar](#the-action-grammar)
6. [How a turn works: two phases](#how-a-turn-works-two-phases)
7. [Gate, tod, and khadu](#gate-tod-and-khadu)
8. [Finishing and placements](#finishing-and-placements)
9. [Events](#events)
10. [Errors](#errors)
11. [Worked examples (real transcripts)](#worked-examples-real-transcripts)
12. [Stability policy](#stability-policy)

## The game in one paragraph

Chopaat (Gujarat variation, `RULESET.md` is the authoritative ruleset) is a
cross-and-circle race for 4 or 6 seats. Each seat has 4 pawns that start
off-board in a *base*, enter on special scores, run one counter-clockwise
lap on a shared per-seat coordinate scale (`0..board.home`), and finish by
landing on `board.home` exactly. Seven two-sided shells are the randomizer.
Landing exactly on a lone enemy pawn *captures* it (back to its base) and
earns you a *tod*, which opens your *gate* — a cell your pawns cannot
otherwise pass. A seat finishes when all 4 pawns are home; the last
unfinished seat loses.

**You never need to derive legality.** `legal_actions/2` returns every
action the server will accept, and only those; pick one and send it back
verbatim. The rest of this document tells you what you are choosing
between.

## Joining and transports

The game is hosted by a `Chopaat.Session` process; this protocol is a
stable facade over it. There is no server — the protocol is
transport-agnostic plain data, and today it rides Erlang distribution
(HTTP/MCP hosting is possible later without redesign, deliberately not
built):

- **In-BEAM**: call `Chopaat.MachinePlay` directly with the session pid or
  registered name.
- **Over dist** (an external agent): connect a plain node — no game code
  loaded locally — and call
  `:rpc.call(host, Chopaat.MachinePlay, fun, args)`. The reference client
  is `scripts/machine_client.exs`; run it from the repo root with
  `mise exec -- elixir scripts/machine_client.exs` (it spawns its own host
  and plays a full seeded game).

There is no join handshake: whoever holds the session ref may command any
seat (the trust model of a pass-and-play device). The server enforces only
that commands come for the seat whose turn it is. Seats are integers
`0..num_players-1`.

All data crossing the boundary is JSON-shaped. Server → client values are
maps with atom keys and whitelisted atom values that the standard `JSON`
encoder maps canonically (atoms become strings, `nil` becomes `null`).
Client → server actions are string-keyed maps exactly as `legal_actions`
returned them — after a JSON round trip if you like; the server accepts
the post-decode shape.

## The calls

| call | returns |
| --- | --- |
| `protocol_version()` | `"1.0.0"` |
| `describe()` | this contract as data: action grammar, state schema, events, errors |
| `observe(session)` | the full public state (schema below) |
| `legal_actions(session, seat)` | the wire actions `act` will accept for `seat` *right now*; `[]` when it is not your moment |
| `act(session, seat, action)` | `{:ok, [event, ...]}` or `{:error, reason}` |
| `subscribe(session, pid)` / `unsubscribe(session, pid)` | event stream as `{:chopaat_session, session_pid, seq, event}` messages; `encode_event/1` puts one on a JSON wire |

A minimal correct player is a loop:

```
loop:
  state = observe(session)
  if state.phase == "finished": stop
  if state.turn != my_seat: wait (poll or subscribe), repeat
  legal = legal_actions(session, my_seat)   # never [] on your turn
  act(session, my_seat, choose_one_of(legal))
  repeat
```

Every accepted `act` also broadcasts the same events to subscribers with a
strictly increasing `seq`, so you may drive from the stream instead of
polling. `observe().seq` tells you which events a snapshot already
includes.

## The state you observe, field by field

Top level:

| field | meaning |
| --- | --- |
| `seq` | server event sequence number, strictly increasing |
| `variant` | ruleset name; `"gujarat"` |
| `num_players` | `4` or `6` |
| `turn` | the seat to act |
| `phase` | `"rolling"` \| `"assigning"` \| `"finished"` |
| `rolls` | scores collected so far *this turn* (rolling phase; already-final turns show the full list until the turn ends) |
| `pending` | the surviving scores awaiting assignment, **after** triple-repeat cancellation. `roll_index` in actions indexes this list. Consumed entries are removed, so indexes shift after every action — always re-fetch `legal_actions`. |
| `bonus_steps` | free-floating `+1` steps remaining this turn |
| `captured_this_turn` | `true` means the turn will end with an extra turn for the same seat |
| `placements` | seats in finishing order; complete exactly when `phase == "finished"` (the last entry is the loser) |
| `board` | static geometry facts (below) |
| `seats` | one entry per seat (below) |
| `occupancy` | map of cell name → list of `{seat, pawn}` for every on-track pawn. Cell names are shared across seats: two pawns on the same name are on the same physical cell. |

`board` (constant for a given game):

| field | 4p value | meaning |
| --- | --- | --- |
| `arms` | 4 | arm count (= `num_players`) |
| `home` | 83 | the lap position that finishes a pawn (117 in 6p) |
| `connector` | 75 | last shared lap position before the private final stretch (109 in 6p) |
| `gate` | 54 | lap position of each seat's gate cell (relative to that seat) |
| `marker` | 77 | the row-6 marker; a pawn at/past it is safe from finishing khadu |
| `khadu_skip` | 15 | positions skipped when a wrap bypasses the private stretch |

Each entry of `seats`:

| field | meaning |
| --- | --- |
| `seat` | seat index |
| `name`, `color` | cosmetic |
| `tod` | `true` once this seat holds a tod (has captured; gate open) |
| `gate` | `"active"` \| `"open"` — `"open"` iff `tod` |
| `assisted` | `true` when the anti-drought shell bias currently applies to this seat |
| `drought` | `{entry, move}` — turns without an entry / without any legal move |
| `pawns` | four pawn entries (below) |

Each pawn:

| field | meaning |
| --- | --- |
| `pawn` | index `0..3` — the value action params name |
| `state` | `"base"` \| `"track"` \| `"home"` |
| `track` | lap position `0..home-1` when on track, else `null`. Positions are **relative to the owning seat**; use `cell`/`occupancy` to compare across seats. |
| `cell` | `"cell_t{track}_l{lane}_r{row}"` on track, `"center_home"` when home, `null` in base — the shared physical-cell key |
| `bypass` | `true` while the pawn owes one skip of the private final stretch from a gate khadu |
| `tipped` | `true` inside the private final stretch (past `connector`; about to finish) |
| `jammed` | `true` when the owner's gate is active and even the smallest possible score would cross it — this pawn cannot move at all until a tod is earned |

## The action grammar

Actions are string-keyed maps with a `"type"`. `legal_actions` returns
them fully instantiated — send one back verbatim. Unknown extra fields are
ignored; unknown types or missing fields are rejected as `bad_action`.

| action | params | phase | meaning |
| --- | --- | --- | --- |
| `{"type":"throw"}` | — | rolling | throw the seven shells (server draws the result) |
| `{"type":"assign","roll_index":i,"pawn":p}` | i into `pending`, p own pawn | assigning | spend `pending[i]` on pawn `p`, atomically: unlock from base (entry scores only) or move forward by the score's full value |
| `{"type":"bonus_step","pawn":p}` | | assigning | spend one free-floating `+1` step on an on-track pawn |
| `{"type":"confirm_khadu","roll_index":i,"pawn":p}` | | assigning | explicitly commit a forced khadu (see below) — the action name is the confirmation; `assign` can never commit one |
| `{"type":"waste","roll_index":i}` | | assigning | discard `pending[i]`; offered only when it has no use *right now* |
| `{"type":"waste_bonus"}` | — | assigning | discard one bonus step; offered only when no pawn can take a step |

## How a turn works: two phases

### Phase 1 — collection (`phase == "rolling"`)

The only action is `throw`. The server draws the shell configuration and
scores it by the up-count:

| shells up | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| score | 7 | 11 | 2 | 3 | 4 | 25 | 30 | 14 |

Scores **7, 11, 14, 25, 30** are *special*: the phase stays `rolling` and
you must throw again, collecting results. The first non-special score
(2/3/4) ends collection. Then, in one step:

- **Triple-repeat cancellation**: within each run of consecutive identical
  scores, complete groups of 3 are nullified; only `run_length % 3`
  trailing rolls survive.
- The survivors become `pending`.
- **Bonus steps**: if you had *zero* pawns in base when collection ended,
  each surviving 11/25/30 also grants one free-floating `+1` step
  (`bonus_steps`).

The phase becomes `assigning`.

### Phase 2 — assignment (`phase == "assigning"`)

Each entry of `pending` is one **atomic** move: its full value goes to a
single pawn — never split. Different rolls are independent: each may go to
a different pawn or pile onto the same pawn sequentially. Bonus steps are
not tied to the roll that earned them — each is its own `+1` move for any
pawn.

Rules the legal list already enforces for you:

- A pawn leaves base only on an *entry* score (11/25/30); one roll unlocks
  exactly one pawn, onto lap position 0.
- A move is illegal if it would cross this seat's **active gate** (only
  specials could numerically reach past it, and they may not while the
  gate is active), overshoot home (landing must be exact), or land on a
  *protected* cell — a safe cell holding any enemy, or any cell holding 2+
  same-owner enemy pawns.
- Landing exactly on a lone enemy on a non-safe cell **captures** it.
- **Legality is recomputed after every action** — a roll useless now may
  become usable after an unlock or another move (and vice versa), so
  re-fetch `legal_actions` every time. `waste` offers appear only for
  currently-unusable rolls; wasting early what could be used later is
  legal but yours to regret.

The turn ends when `pending` is empty and `bonus_steps` is 0. If you
captured this turn you get exactly one extra full turn (`turn_passed` with
`extra_turn: true`); otherwise play passes left.

## Gate, tod, and khadu

- Every seat's **gate** starts *active* at lap `board.gate` (their own
  coordinate scale). No pawn of that seat may pass it while active.
- Capturing any enemy pawn earns the seat a **tod** — one boolean flag —
  which opens the gate for all of its pawns immediately.
- The tod is **lost** if all 4 of the seat's pawns are simultaneously
  off-board in base again — unless at least one pawn already reached home.
- While a seat has no tod, its pawns *wrap*: they skip the private final
  stretch (add `khadu_skip`, modulo `home`, whenever a move passes
  `connector`) and keep circulating. A pawn with `bypass: true` owes one
  more such skip even after the tod arrives.

**Khadu** is the forced default when a special roll has no legal use:

- Never possible while you still have any pawn in base (the roll is simply
  wasted instead).
- Forced when a pending **special** roll (7/11/14/25/30) has no ordinary
  use on *any* pawn, and some pawn is either blocked at/by the active gate
  or endangered by finishing accounting (see below). When forced,
  `legal_actions` returns **only** `confirm_khadu` actions — one per
  qualifying pawn; you choose which pawn commits.
- The landing: reverse 4 cells from the pawn's position, then run forward
  by the roll's full value; if the path passes `connector`, add
  `khadu_skip` modulo `home` (a khadu is a wraparound — never a shortcut
  home). In coordinates: `target = x - 4 + roll`, plus
  `(+ khadu_skip) % home` when it passed the connector.
- **The burn** (*dana ane pagdu badi gaya*): committing a khadu destroys
  every still-pending 2/3/4 roll (*dana*) and every bonus step (*pagdu*).
  The `khadu` event itemizes what burned.
- **Confirmation is required**: the destructive commit is its own action
  type. Sending `assign` for the same roll/pawn returns
  `illegal_action` — there is no accidental khadu.

**Finishing accounting** (why a far-from-home pawn can be forced): while a
pawn is below the `marker`, sum *all* pending rolls and bonus steps; if
the total exceeds its remaining distance home and a pending special has no
ordinary destination elsewhere, the khadu is forced immediately — you may
not spend the small rolls first to sneak the pawn to safety (those options
simply do not appear in `legal_actions`). Equality is safe. A pawn at or
past the `marker` never commits a finishing khadu; an overshooting roll is
wasted instead.

## Finishing and placements

A pawn finishes by landing on `home` exactly (`state: "home"`,
`cell: "center_home"`). When a seat's 4th pawn lands home, the seat takes
the next `placement` rank and leaves the rotation. The game ends when only
one seat remains unfinished: `phase == "finished"`, `placements` complete,
last place is the loser (`game_over.loser`).

## Events

Every accepted `act` returns the events it produced (encoded); subscribers
receive the same events. Fields, by `event`:

| event | payload |
| --- | --- |
| `game_started` | `variant, num_players, turn` — a fresh game (rematch) |
| `throw_result` | `seat, shells (up-booleans), up_count, score, special, entry, cosmetic, phase, rolls, pending, bonus_steps` — `cosmetic` is presentation-only randomness; ignore it |
| `moved` | `seat, pawn, action (wire shape), roll (score or "bonus"), from, to, path` — positions as `{state, track, cell}` |
| `captured` | `seat, victim_seat, victim_pawn, cell, tod_earned, victim_tod_lost` |
| `khadu` | `seat, pawn, roll, burned: {dana: [scores], pagdu: count}` |
| `wasted` | `seat, roll (score or "bonus")` |
| `turn_passed` | `seat, next_seat, extra_turn` |
| `placement` | `seat, rank` |
| `game_over` | `placements, loser` |

## Errors

`act` returns `{:error, reason}` (the reason JSON-encodes as a string):

| reason | meaning |
| --- | --- |
| `bad_action` | the action map did not decode (unknown type / missing field) |
| `not_your_turn` | the seat is not `observe().turn` |
| `wrong_phase` | `throw` outside the rolling phase |
| `invalid_event` | an assignment action outside the assigning phase |
| `illegal_action` | well-formed but not in `legal_actions` (including `assign` where a khadu is forced) |
| `game_over` | the game already finished |

## Worked examples (real transcripts)

### A sample opening over Erlang dist (entry, a normal move, a waste)

Verbatim from `scripts/machine_client.exs` (seed 85), an external node
with no game code loaded. Seat 0 throws an 11 (special — throw again),
then a 3; the 11 unlocks pawn 1 from base, the 3 — unusable while all
pawns were based, hence the `waste` offer — becomes usable after the
unlock and moves the same pawn on:

```
>> legal_actions(seat 0)
<< [{"type":"throw"}]
>> act(seat 0, {"type":"throw"})
<< [{"bonus_steps":0,"cosmetic":3366169601,"entry":true,"event":"throw_result","pending":[],
    "phase":"rolling","rolls":[11],"score":11,"seat":0,
    "shells":[false,false,false,false,true,false,false],"special":true,"up_count":1}]

>> legal_actions(seat 0)
<< [{"type":"throw"}]
>> act(seat 0, {"type":"throw"})
<< [{"bonus_steps":0,"cosmetic":1899431973,"entry":false,"event":"throw_result","pending":[11,3],
    "phase":"assigning","rolls":[11,3],"score":3,"seat":0,
    "shells":[false,false,true,true,true,false,false],"special":false,"up_count":3}]

>> legal_actions(seat 0)
<< [{"pawn":0,"roll_index":0,"type":"assign"},{"pawn":1,"roll_index":0,"type":"assign"},
    {"pawn":2,"roll_index":0,"type":"assign"},{"pawn":3,"roll_index":0,"type":"assign"},
    {"roll_index":1,"type":"waste"}]
>> act(seat 0, {"pawn":1,"roll_index":0,"type":"assign"})
<< [{"action":{"pawn":1,"roll_index":0,"type":"assign"},"event":"moved",
    "from":{"cell":null,"state":"base","track":null},
    "path":[{"cell":"cell_t0_l1_r1","state":"track","track":0}],
    "pawn":1,"roll":11,"seat":0,"to":{"cell":"cell_t0_l1_r1","state":"track","track":0}}]

>> legal_actions(seat 0)
<< [{"pawn":1,"roll_index":0,"type":"assign"}]
>> act(seat 0, {"pawn":1,"roll_index":0,"type":"assign"})
<< [{"action":{"pawn":1,"roll_index":0,"type":"assign"},"event":"moved",
    "from":{"cell":"cell_t0_l1_r1","state":"track","track":0},
    "path":[{"cell":"cell_t0_l1_r2","state":"track","track":1},
            {"cell":"cell_t0_l1_r3","state":"track","track":2},
            {"cell":"cell_t0_l1_r4","state":"track","track":3}],
    "pawn":1,"roll":3,"seat":0,"to":{"cell":"cell_t0_l1_r4","state":"track","track":3}},
   {"event":"turn_passed","extra_turn":false,"next_seat":1,"seat":0}]

>> legal_actions(seat 1)
<< [{"type":"throw"}]
>> act(seat 1, {"type":"throw"})
<< [{"bonus_steps":0,"cosmetic":1609702606,"entry":false,"event":"throw_result","pending":[3],
    "phase":"assigning","rolls":[3],"score":3,"seat":1,
    "shells":[true,true,true,false,false,false,false],"special":false,"up_count":3}]

>> legal_actions(seat 1)
<< [{"roll_index":0,"type":"waste"}]
>> act(seat 1, {"roll_index":0,"type":"waste"})
<< [{"event":"wasted","roll":3,"seat":1},
    {"event":"turn_passed","extra_turn":false,"next_seat":2,"seat":1}]
```

Note the two moves onto pawn 1 accumulate — atomic rolls, freely stacked
on one pawn — and note the `roll_index` for the 3 shifted from 1 to 0
after the 11 was consumed.

### A capture, granting a tod and an extra turn

Seat 0's pawn at lap 33 spends a 2, landing exactly on seat 1's lone pawn
(same physical cell `cell_t2_l2_r3`):

```
>> legal_actions(seat 0)
<< [{"pawn":0,"roll_index":0,"type":"assign"}]
>> act(seat 0, {"pawn":0,"roll_index":0,"type":"assign"})
<< [{"action":{"pawn":0,"roll_index":0,"type":"assign"},"event":"moved",
    "from":{"cell":"cell_t2_l2_r1","state":"track","track":33},
    "path":[{"cell":"cell_t2_l2_r2","state":"track","track":34},
            {"cell":"cell_t2_l2_r3","state":"track","track":35}],
    "pawn":0,"roll":2,"seat":0,"to":{"cell":"cell_t2_l2_r3","state":"track","track":35}},
   {"cell":"cell_t2_l2_r3","event":"captured","seat":0,"tod_earned":true,
    "victim_pawn":0,"victim_seat":1,"victim_tod_lost":false},
   {"event":"turn_passed","extra_turn":true,"next_seat":0,"seat":0}]

>> legal_actions(seat 0)      # the extra turn: seat 0 rolls again
<< [{"type":"throw"}]
```

### A forced khadu (and the refused assign)

All four of seat 0's pawns sit jammed behind the active gate at lap 54;
pending is `[7, 2, 3]` with one bonus step. The 7 is special and has no
ordinary use, so ONLY `confirm_khadu` actions are legal; committing with
pawn 0 reverses 4 (54 → 50), runs the full 7 forward (→ 57, past the
gate), and burns the 2, the 3, and the bonus step:

```
>> legal_actions(seat 0)
<< [{"pawn":0,"roll_index":0,"type":"confirm_khadu"},
    {"pawn":1,"roll_index":0,"type":"confirm_khadu"},
    {"pawn":2,"roll_index":0,"type":"confirm_khadu"},
    {"pawn":3,"roll_index":0,"type":"confirm_khadu"}]

>> act(seat 0, {"pawn":0,"roll_index":0,"type":"assign"})
<< {:error, :illegal_action}                # no accidental khadu, ever

>> act(seat 0, {"pawn":0,"roll_index":0,"type":"confirm_khadu"})
<< [{"action":{"pawn":0,"roll_index":0,"type":"confirm_khadu"},"event":"moved",
    "from":{"cell":"cell_t3_l2_r5","state":"track","track":54},
    "path":[{"cell":"cell_t3_l2_r4","state":"track","track":53},
            {"cell":"cell_t3_l2_r3","state":"track","track":52},
            {"cell":"cell_t3_l2_r2","state":"track","track":51},
            {"cell":"cell_t3_l2_r1","state":"track","track":50},
            {"cell":"cell_t3_l2_r2","state":"track","track":51},
            {"cell":"cell_t3_l2_r3","state":"track","track":52},
            {"cell":"cell_t3_l2_r4","state":"track","track":53},
            {"cell":"cell_t3_l2_r5","state":"track","track":54},
            {"cell":"cell_t3_l2_r6","state":"track","track":55},
            {"cell":"cell_t3_l2_r7","state":"track","track":56},
            {"cell":"cell_t3_l2_r8","state":"track","track":57}],
    "pawn":0,"roll":7,"seat":0,"to":{"cell":"cell_t3_l2_r8","state":"track","track":57}},
   {"burned":{"dana":[2,3],"pagdu":1},"event":"khadu","pawn":0,"roll":7,"seat":0},
   {"event":"turn_passed","extra_turn":false,"next_seat":1,"seat":0}]
```

## Stability policy

Within a major protocol version the wire surface is **append-only**: new
state fields, action types, event types, and error reasons may be added
(minor bump); nothing is renamed, removed, or retyped without a major
bump. Ignore unknown fields and unknown event types. `describe()["version"]`
is the source of truth at runtime.
