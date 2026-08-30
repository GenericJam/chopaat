# Chopaat Ruleset — the Gujarat variation

Authoritative ruleset for the game, written by the project owner. This ruleset is known as the
**Gujarat variation** and is the engine's default variant (`:gujarat`); the variant-config system
exists so the same engine can host related rulesets in this family. The rules engine is implemented
directly against this document. Anything marked **TBD/confirm** should be resolved by editing this
file directly (not just chat) before the corresponding logic is implemented.

## Players & pieces

- Supported variants are 4 players and 6 players, both free-for-all. The player count is chosen
  after choosing local, online, or LAN play.
- Each player has 4 pawns. All pawns start off-board, in a private base.
- Board/arm numbering is relative to each player: their own home arm is track 0; the other arms are
  tracks 1 through `player count - 1` going counter-clockwise from home.

## Board

- Shape: 4 or 6 equal arms ("tracks") projecting symmetrically from the shared center. Four-player
  games use the traditional cardinal cross; six-player games use six arms spaced 60 degrees apart.
- Center: a shared home base where finished pawns end up. It is a 3x3 square for four players and
  a regular six-sided center for six players.
- Each arm is 3 cells wide x 8 cells long, i.e. 3 parallel lanes, each 8 cells (rows), numbered:
  - **Lane 0** (left) — shared peripheral lane.
  - **Lane 1** (middle) — private home lane, belongs exclusively to the player whose home arm this
    is. Other players' pawns can only *touch* (not climb into) this lane's bottom-most cell, as a
    transit square (see Movement).
  - **Lane 2** (right) — shared peripheral lane.
  - Rows are numbered 1 (top, nearest the center) to 8 (bottom, at the arm's outer end).
- Safe cells (pawn there cannot be captured):
  - On lanes 0 and 2 of every arm: row 5 (i.e. the 4th cell counting in from the arm's outer end).
  - On lane 1 (home lane) of a player's own arm, within their final stretch: row 6 (2nd cell
    entered after crossing into the final stretch, and 6th-from-home) — this is also the
    finishing overshoot threshold (see Finishing).
- **Gate**: located on **lane 2's row 5 safe cell**. In a four-player game it is at relative track
  3 (the last arm before home). In a six-player game it is at relative track 4, two arms before
  home; track 5 remains between the gate arm and the player's home arm. See Gate/Tod/Khadu below.

## Randomizer

- 7 shells, each with an up/down side. Each shell is normally an independent 50/50 up/down flip.
  Assistance is tracked separately for every player. After more than three of that player's turns
  without entering a remaining base pawn, or more than three turns without any legal move, only
  that player's shells become 70% up / 30% down. The applicable drought resets immediately when
  an entry score or legal move becomes available, so subsequent throws return to fair shells; the
  bias never carries into another player's turn.
- Score is determined by how many shells land up:

  | Shells up | Score |
  |-----------|-------|
  | 0         | 7     |
  | 1         | 11    |
  | 2         | 2     |
  | 3         | 3     |
  | 4         | 4     |
  | 5         | 25    |
  | 6         | 30    |
  | 7         | 14    |

- **Extra roll**: rolling 7, 11, 14, 25, or 30 grants another manual shell throw immediately,
  within the same turn. The player performs each granted throw separately; the game never
  auto-generates the rest of the sequence. Each result is its own separate, atomic move (see
  Turn structure for how rolls get assigned to pawns) — they don't automatically sum into one lump
  move.
- **Extra turn**: capturing one or more opposing pawns grants exactly one extra turn for the whole
  turn, regardless of how many pawns or distinct opponents were captured. An extra turn is a normal
  full turn like any other (roll, move any pawn, all the same rules apply, and it can itself grant
  further extra rolls/turns) — the player takes it immediately before play passes to the next
  player.
- **Bonus step**: if a player has zero pawns remaining in their base (all 4 already on the board)
  and rolls 11, 25, or 30, that roll grants a separate +1 bonus step (since the roll isn't needed
  for unlocking a pawn from base). The roll's own step value is still a separate move and can be
  ignored if unplayable; the bonus step remains playable unless the game has already been won.
- **Triple-repeat cancellation**: for a run of N consecutive rolls of the *same score*, only
  `N % 3` of them (the trailing ones in the run) count; the rest are nullified in complete groups
  of 3, along with any bonus steps those nullified rolls would have granted. A 4th, 5th, etc.
  consecutive identical roll does **not** reset the count — cancellation keeps consuming in groups
  of 3 for as long as the run continues (run of 6 → all 6 cancelled; run of 7 → first 6 cancelled,
  7th counts normally).

## Turn structure

- On your turn, manually throw the shells once. After each 7, 11, 14, 25, or 30, manually throw
  again and continue collecting results. The first non-special result ends rolling; only then are
  triple-repeat cancellation and the surviving moves finalized for pawn assignment.
- A pawn leaves base only on a roll of 11, 25, or 30; each such roll unlocks exactly one pawn (not
  more). If a triple-repeat nullifies an 11/25/30, it does not unlock anything.
- **Applying rolls to pawns**: each individual roll (including ones granted by the extra-roll rule)
  is an atomic, indivisible move — its full step count must go to a single pawn, and cannot be
  split across two or more pawns (e.g. a roll of 30 can't be spent as 15 steps on one pawn and 15
  on another; a roll of 7 can't be spent as 4+3 across two pawns). However, **different rolls
  within the same turn are independent** and can each be assigned to a different pawn, or to the
  same pawn repeatedly (in which case that pawn's position moves cumulatively across each move in
  sequence). Example: given rolls 30, 11, 30, 7, 3 in one turn, the player could move a different
  pawn with the 30, another with the 11, another with the 7, the 4th pawn with the second 30, and
  then apply the 3 to any pawn of their choice (reusing one already moved this turn).
- **Bonus steps** (see Randomizer) are not tied to the pawn that earned them — each bonus step is
  its own free-floating single-step move, assignable to any pawn independently of the others. E.g.
  3 bonus steps earned in one turn could all go to the same pawn, or be split one each across 3
  different pawns.

## Movement

- All pawns move counter-clockwise. The full lap from launch to home, for a pawn's own arm as
  "track 0":

  1. **Launch**: start at track 0 lane 1's top-most cell (this is the pawn's start square, and
     doesn't count as a step). Travel down lane 1 to its bottom: **7 cells**.
  2. Cross to track 0 lane 0's bottom, climb to lane 0's top: **8 cells**.
  3. Cross into track 1's lane 2 top.
  4. For every foreign track in turn (tracks 1 through `player count - 1`): lane 2 top→bottom
     (**8 cells**) → cross to that track's
     lane 1 bottom cell, touching it as a transit square without climbing into it (**1 cell**) →
     cross to that track's lane 0 bottom→top (**8 cells**) → cross into the next track's lane 2
     top. Each foreign track contributes 17 cells.
  5. Returning to track 0: lane 2 top→bottom (**8 cells**) → cross into track 0's own lane 1
     bottom (**1 cell** — this time the pawn *can* climb, since it's their own home lane) → climb
     lane 1's bottom→top through the 7-cell final stretch (**7 cells**) → take one final step from
     the top square into the off-board center homebase (**1 cell**).

  Total finish distance from launch entry to homebase is `17 * player count + 15`: **83 cells**
  for four players and **117 cells** for six. The final on-board positions are respectively 82
  and 116.

- A pawn cannot make a normal (non-default) move if: it's still in base, the destination cell is
  blocked by a protected opponent pawn/group, the roll would move it past the gate while the gate is
  active (2/3/4 can never pass a gate; 7/11/14/25/30 can), or the roll would overshoot home.
  Depending on where the pawn is, an unplayable roll may either force a khadu/default or simply be
  ignored; see Gate / Tod / Khadu and Finishing below.

## Overshoot / Khadu (general rule)

Khadu isn't triggered by a fixed precondition like "all 4 pawns sitting at the gate." It's governed
by one abstract rule that applies identically at the gate and at the finish:

- A roll must go to some pawn if *any* pawn has a legal, non-default use for it — unlocking a new
  pawn from base, or moving any pawn on the board normally without hitting a gate or overshooting
  a finish. The player has full freedom to choose which of their pawns to move with a roll, exactly
  like normal Ludo, as long as the move is legal.
- **Khadu can never be forced while the player still has a pawn in base.** Having a pawn left in
  reserve means the player hasn't fully committed to the board yet, so an otherwise-unplayable roll
  is simply ignored (wasted) instead of forcing any pawn into a khadu — even if that base pawn
  couldn't itself use this particular roll (e.g. the roll isn't 11/25/30, so it can't unlock
  anything). Only once **all 4** pawns have left base does khadu become possible at all.
- Once no pawns remain in base, a khadu is forced when **every one** of a player's pawns is unable
  to legally absorb the current roll — e.g. some blocked by or crossing an active gate, some
  overshooting at a finish,
  and/or some already home. A pawn that has already reached home counts as permanently unable to
  absorb anything.
- When a khadu is forced and more than one of the player's pawns qualifies (e.g. 2 blocked at/by the
  gate and 1 overshooting at the finish, with the 4th also unable to move), the **player chooses**
  which one commits the khadu.
- **Khadu is, by definition, a wraparound: it can never be a shortcut through the finish path.**
  Both the gate and finishing versions reverse 4 cells from the pawn's actual position and then
  continue forward by the full roll value. Gate khadu keeps no-tod pawns circulating until tod is
  earned, skipping the homebase/private-lane passage if that khadu path reaches home. Finishing
  khadu uses its own coordinate transform, described below, to skip the private middle-lane tiles
  and continue around the same cycle.
- The landing-cell math for a khadu differs depending on *where* it's committed — see Gate / Tod /
  Khadu and Finishing below for the two specific cases.

- Committing either a gate khadu or finishing khadu immediately burns every still-pending lower
  roll (`2`, `3`, and `4`, traditionally called **dana**) and every pending bonus step
  (traditionally called **pagdu**). Those moves cannot be assigned afterward. This is called
  **dana ane pagdu badi gaya**.

## Gate / Tod / Khadu

- Every player starts with their gate **active** (blocking). A pawn cannot pass the gate at all
  while it's active, regardless of roll.
- Capturing **any** opponent pawn earns a **tod** (a.k.a. "break") — a single yes/no flag per
  player (not tracked per-opponent). While a player holds a tod, their gate is deactivated and
  their pawns pass through normally.
- If **all 4** of a player's pawns are simultaneously off the board (captured/in base) at once,
  their tod is lost and their gate reactivates. Exception: if at least one of their pawns has
  already reached home, losing the other 3 does **not** remove the tod (not all pieces are "dead"
  — a home pawn counts as safe).
- **Gate khadu (default)**: per the general Overshoot / Khadu rule above, this is only forced when
  none of a player's 4 pawns can legally absorb the current roll — in practice this typically means
  all 4 would cross or are already jammed at the active gate without a tod, or a no-tod pawn before
  the bottom of the player's own middle lane would otherwise overshoot toward home (since a pawn in
  base or moving freely elsewhere would otherwise absorb the roll instead). When forced, and a roll
  of 7,
  11, 14, 25, or 30 comes up, the player picks **one** blocked pawn to default past the gate — the
  others remain blocked. The landing cell for that one pawn: take the pawn's current position `x`,
  reverse 4 cells, then continue forward from there by the full roll value (not just the
  overshoot). In engine coordinates, start with `target = x - 4 + roll`; if the target passes the
  bottom middle-lane connector, add 15 before applying modulo the variant's home position. The
  connector/home pairs are 75/83 for four players and 109/117 for six. The pawn therefore never
  enters the private final stretch during the khadu move; it skips that passage and continues
  around the board cycle. The
  freed pawn remains in gate-khadu circulation on later turns too: it may land on the bottom-most
  square of its own middle lane, but its next step skips the private final stretch and continues
  at the bottom of its own lane 0. This persists until a tod is captured. Without a tod, the pawn
  will jam at the same gate again once it circles back.
- Once a tod is captured, **all** pawns currently jammed at the gate are released immediately (not
  just one at a time).
- If the gate-khadu landing itself captures an opponent and earns a tod, that tod releases the
  player's other pawns but does not cancel the committing pawn's khadu penalty. If its khadu move
  landed before or on the bottom middle-lane connector, that pawn must still bypass the private
  final stretch once and continue around the outer track. If the khadu move already crossed that
  connector and wrapped, the bypass has already happened and the pawn is already traversing its
  required outer lap.
- If a pawn that defaulted through the gate circles all the way back around without the player
  ever capturing a tod, it jams at the gate again alongside whichever other pawns are there; once
  all 4 are jammed together again, another gate khadu becomes possible.

## Capturing

- A pawn is captured when an opposing pawn's move lands it exactly on the same cell — whether that
  landing comes from a single roll (e.g. an 11 lands exactly on an opponent) or from a sequence of
  rolls applied to the same pawn across the turn (e.g. an 11 then later a 30 applied to the same
  pawn, whose cumulative position now lands exactly on an opponent). Passing over or falling short
  of an opponent's cell — without landing exactly on it — never captures. That is you may just pass a piece, but you will only overlap when your total rolls stop exactly as the cell of another player's.
- A captured pawn is sent back to base — it needs a fresh 11, 25, or 30 roll to re-enter, same as
  any pawn starting from base.
- A pawn cannot be captured while it shares a cell with another pawn of the same player (2+
  same-owner pawns on one cell block capture and also block opponents from landing there).
- A pawn cannot be captured while on a safe cell, and opponents cannot land on an occupied safe cell.

## Finishing

- The home-lane final stretch (see Movement, step 5) has a safe-cell/overshoot-threshold marker at
  row 6 (2nd cell entered after crossing into the stretch, 6th-from-home).
- **Any on-track pawn before the row-6 marker can commit a finishing khadu** if a roll would
  overshoot past home and, per the general Overshoot / Khadu rule, no other pawn can legally absorb
  the roll instead — this includes a pawn still out on the peripheral track, not just one already
  inside its own 7-cell final stretch. Even far from home, the raw arithmetic
  (`position + roll`) can exceed the home value simply because the whole lap shares one continuous
  position scale, and that pawn is just as legitimately "stuck" as one deep in its final approach.
  The **landing** is what differs by how far along the pawn already was — see below — never the
  eligibility itself.
- **Total-roll accounting is decided before assignment**: while a pawn is still below the row-6
  marker, add **every** still-pending roll and bonus step in the turn. That total must be equal to
  or below the pawn's remaining distance home. If it exceeds the distance, and a pending special
  roll (`7`, `11`, `14`, `25`, or `30`) has no ordinary destination on another pawn, a finishing
  khadu is forced immediately from the pawn's current position. The player cannot first spend a
  lower roll or bonus step to carry that pawn to/through the safe marker; those options are hidden
  and rejected until the special roll commits the khadu. Only the special roll is offered as the
  committing roll. Pending `2`/`3`/`4` rolls and bonus steps still count toward the overshoot total,
  then burn when the khadu is committed. Examples: from position 73 (10 steps from home), `7 + 4 =
  11`, so only the 7 is offered and it forces khadu; from the same position, `25 + 3` (plus the
  bonus step earned by 25) likewise offers only 25. A pawn 25 steps from home with `25 + 3` cannot
  take the 3 first or finish cleanly with 25. A pawn 28 steps away with `25 + 3` plus the bonus step
  has a total of 29 and also commits khadu. Equality is safe: if the total exactly matches the
  remaining distance, the rolls can finish the pawn normally. A pawn already at/past row 6 remains
  safe from finishing khadu, as described below.
- When forced, the pawn commits a **khadu (default)**:
  - Take the pawn's current position `x`, reverse 4 cells, then continue forward by the full roll
    value.
  - Ignore the middle-lane tiles during this finish-khadu wrap: 8 tiles on the way in and 7 on the
    way out, for a total skip of 15.
  - In engine coordinates, the landing is `(x - 4 + roll + 15) % homePosition`, where
    `homePosition` is 83 for four players and 117 for six.
  - Examples: `72, roll 25 -> 25`; `76, roll 25 -> 29`; `54, roll 30 -> 12`;
    `75, roll 11 -> 14`.
  - This is a severe penalty: the pawn must then re-traverse most of the remaining lap before it
    can attempt to finish again.
  - Visual note (for the future Unity/rendering layer, not the rules engine itself): a pawn in the
    final stretch is shown tipped on its side to mark it's about to finish. If it commits a khadu
    from there, it must be flipped back to its normal upright orientation, since it's no longer in
    the final stretch.
- If the pawn is at the row-6 marker or already past it (closer to home), and no pawn can legally
  absorb an overshooting roll, the roll is ignored instead of forcing a khadu. Bonus steps from
  qualifying 11/25/30 rolls still count as separate +1 moves unless an exact roll has already won
  the game.
- Placement condition: players finish in chronological order as soon as all 4 of their pawns are
  home and then leave turn rotation. The game terminates when all but one player have finished;
  the remaining unfinished player receives the final placement and is the loser. Thus a
  four-player game ends after the third finisher and a six-player game after the fifth.

## Deferred / out of scope for now

- Team/partner play (2v2).
- **The mad pawn (gandi)**: once a player finishes a pawn (especially early), they may choose to
  send it back onto the board as a "mad pawn" / gandi:
  - Mad pawns travel **clockwise** (opposite of normal play). Gate rules still apply to them.
  - A mad pawn can capture pawns on safe cells, and can capture a whole stack of same-owner pawns
    grouped on one cell (normally protected) — up to all 4 at once.
  - A mad pawn that gets captured is not obliged to return to base.
  - A mad pawn is placed upside-down on the board, visually.
  - House-rule variant: an even stronger mad pawn can enter other players' private home lanes and
    capture pawns there too.
  - Thematically: mad pawns represent saints/ascetics, who move opposite the world's normal
    direction and are exempt from most worldly (game) rules.
