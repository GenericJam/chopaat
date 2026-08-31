# Formalizing RULESET.md (Gujarat variation) in the rules engine

The engine implements `RULESET.md` directly; it is the acceptance oracle and
every worked example in it is an example-based test (`test/chopaat/`).
Formalizing prose into total functions surfaced a handful of points the text
does not fully determine. Per RULESET.md's own contract, these get resolved
by **editing RULESET.md**, not chat; until then the engine implements the
interpretations below. None of them changes the module structure — each is a
localized rule in `Chopaat.Rules`.

## Interpretations implemented (owner: please confirm or correct)

1. **Finishing-khadu `+15` is conditional on passing the connector.** The
   text gives `(x - 4 + roll + 15) % homePosition` unconditionally, but when
   `x - 4 + roll` does not reach the bottom middle-lane connector the literal
   formula can land the pawn *inside* the private final stretch (e.g. `x=60,
   roll 7 → 78`), contradicting "khadu … can never be a shortcut through the
   finish path" and "ignore the middle-lane tiles during this finish-khadu
   wrap". Implemented: add the 15-cell skip only when `x - 4 + roll` passes
   the connector — identical in form to the gate-khadu formula, and matching
   all four worked examples (`72+25→25`, `76+25→29`, `54+30→12`, `75+11→14`),
   each of which does pass the connector.

2. **Unlocking consumes the whole roll.** An 11/25/30 spent on entry places
   the pawn on the launch square (position 0) and is fully used; the pawn
   does not also advance by the roll's value. Inferred from "the roll isn't
   needed for unlocking" (bonus-step rationale) and "start at … the pawn's
   start square, and doesn't count as a step".

3. **A forced khadu preempts the whole assignment.** When a khadu trigger
   holds, the only offered actions are the qualifying khadu commits — the
   player cannot first spend still-pending `2/3/4` rolls or bonus steps on
   *other* pawns to rescue them from the burn. Grounded in "a finishing
   khadu is forced **immediately**", "**only** the special roll is offered as
   the committing roll", and "pending 2/3/4 rolls and bonus steps still count
   toward the overshoot total, **then burn**" (the burn would be vacuous if
   the pending rolls could be drained first). Applied to gate khadu as well
   for consistency — confirm especially this case.

4. **Bonus steps are fixed at roll finalization.** All rolls precede
   assignment, so base-emptiness for the bonus rule is evaluated when the
   rolling phase ends (equivalently: at each roll — the base cannot change
   during rolling). An unlock later in the same turn does not retroactively
   grant a bonus for an earlier-rolled 11/25/30 of that turn.

5. **The endangered-pawn freeze is total.** While a pawn below the row-6
   marker has remaining distance smaller than the sum of all pending rolls
   and bonus steps (and a special is pending, and no pawns remain in base),
   that pawn can receive *nothing* — not just "no move that carries it
   to/through the safe marker" — until the khadu commits or the pending
   total drops to/below its distance. With a pawn still in base the freeze
   does not apply at all (khadu is impossible there and unplayable rolls are
   simply wasted).

6. **A khadu with a blocked landing is not offered.** If a qualifying
   khadu's landing cell is illegal (occupied safe cell, or a 2+ enemy
   stack), that (roll, pawn) option is dropped; if no qualifying khadu
   landing is legal the roll is wasted. RULESET.md does not address this.

7. **"7/11/14/25/30 can pass a gate" means *via khadu only*.** Reconciled
   with "a pawn cannot pass the gate at all while it's active, regardless of
   roll": normal moves never pass an active gate; a special roll passes it
   only as the gate-khadu default.

8. **An extra turn earned in the turn a player finishes is forfeited** — the
   finisher leaves the rotation immediately.

9. **Player choice over forced khadus.** With several qualifying
   (special roll, pawn) pairs, the player picks which pair commits.

10. **No-tod circulation is automatic movement arithmetic.** A pawn whose
    owner holds no tod (and any pawn still owing its bypass debt) wraps at
    the connector on *normal* moves: `(x + roll + 15) mod home` — "its next
    step skips the private final stretch and continues at the bottom of its
    own lane 0". Such pawns can therefore never overshoot home, so they are
    never candidates for a finishing khadu.

## Consequences the formalization makes explicit

- **A player cannot finish any pawn without capturing at least once**: the
  own gate is active until a tod is earned, and no-tod pawns skip the final
  stretch even after a gate khadu. The mass simulations confirm every
  finisher captures (`captures >= players - 1` in every completed game).
- Every turn's roll sequence ends with a `2`, `3`, or `4` (all other scores
  chain), so the surviving pending list is never empty.
- Since the score table has no `1`, a pawn exactly 1 step from home can only
  finish with a bonus step.

## Deferred (representational room only)

- `Variant.gandi` (mad pawn) and `Variant.teams` (2v2) exist as
  always-false flags; no logic implemented, per the owner's deferral.

## Where the drought assistance lives

The 70/30 shell bias is **not** in the rules: `Chopaat.Game` maintains
per-player drought counters and turn facts (entry available / legal move
available, reset mid-turn per RULESET.md) and exposes `assisted?/2`;
`Chopaat.RNG.draw/3` takes the up-probability. The session layer (or the
test simulator, which exercises this path) connects the two.
