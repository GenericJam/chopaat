defmodule Chopaat.MachinePlay do
  @moduledoc """
  The machine-playable game protocol (bead chopaat-85o): the documented,
  versioned interface an LLM — or any external agent — plays the game
  through. A thin, STABLE facade over `Chopaat.Session`: no game logic
  lives here, only the wire shape of the session's public surface.

  Everything is JSON-serializable in both directions:

    * server → client (`observe/1`, `act/3` returns, `encode_event/1`)
      is plain data — maps, lists, numbers, strings, booleans, `nil`,
      and whitelisted atoms that encode canonically (the stdlib `JSON`
      module round-trips it, proven in the test suite).
    * client → server (`act/3` actions) is the post-JSON-decode shape:
      string-keyed maps with string/integer values. `legal_actions/2`
      returns actions in exactly this wire shape, so a client picks one
      and sends it back verbatim.

  The protocol is transport-agnostic by design (owner ruling: possible,
  not built): the same maps ride Erlang dist today
  (`scripts/machine_client.exs` is the acceptance proof) and can ride
  HTTP or MCP later without redesign — there is deliberately no server
  here.

  Stability policy (the protocol versions independently of the app):
  within a major protocol version the wire surface is append-only. New
  state fields, action types, event types, or error reasons may be added
  (minor bump); nothing is renamed, removed, or retyped without a major
  bump. Clients must ignore unknown fields and unknown event types.

  `describe/0` returns the whole contract — action grammar, state
  schema, event vocabulary, errors — as data, so an agent can be handed
  the protocol without reading this codebase. The prose companion is
  `guides/machine-play.md`, written for an agent reader.

  Khadu stays explicit at the wire level exactly as at the session API:
  the destructive commit is its own action type, `"confirm_khadu"` — the
  name is the confirmation. A khadu can never be committed by a generic
  `"assign"`.
  """

  alias Chopaat.Rules
  alias Chopaat.Session

  @protocol_version "1.0.0"

  @typedoc "A wire action: a string-keyed, JSON-decoded map."
  @type wire_action :: %{required(String.t()) => String.t() | non_neg_integer()}

  @typedoc "A wire event: an atom-keyed map that `:json.encode/1` accepts."
  @type wire_event :: map()

  @type error ::
          :bad_action
          | :not_your_turn
          | :wrong_phase
          | :invalid_event
          | :illegal_action
          | :game_over

  # ── the protocol surface ───────────────────────────────────────────────────

  @doc "The protocol version (semver; append-only within a major)."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  The full public state of the game as JSON-serializable plain data —
  the schema is in `describe/0` under `"state"`.
  """
  @spec observe(Session.session()) :: map()
  def observe(session), do: Session.observe(session)

  @doc """
  The wire actions `act/3` accepts for `seat` right now: `[]` off-turn
  or after the game finished; `[%{"type" => "throw"}]` in the rolling
  phase; the encoded assignment actions in the assigning phase. A client
  picks one and sends it back verbatim.
  """
  @spec legal_actions(Session.session(), Session.seat()) :: [wire_action()]
  def legal_actions(session, seat) do
    case observe(session) do
      %{phase: :rolling, turn: ^seat} ->
        [encode_action(:throw)]

      %{phase: :assigning, turn: ^seat} ->
        session |> Session.legal_actions(seat) |> Enum.map(&encode_action/1)

      _off_turn_or_finished ->
        []
    end
  end

  @doc """
  Submits one wire action for `seat` and returns the resulting events,
  encoded (`{:ok, [wire_event]}`), or a documented error reason. This is
  the only mutating entry point; it translates the wire grammar to the
  session commands (`"throw"` → `Session.throw/2`, `"confirm_khadu"` →
  `Session.confirm_khadu/3`, everything else → `Session.assign/3`).
  """
  @spec act(Session.session(), Session.seat(), wire_action()) ::
          {:ok, [wire_event()]} | {:error, error()}
  def act(session, seat, action) do
    with {:ok, term} <- decode_action(action),
         {:ok, events} <- dispatch(session, seat, term) do
      {:ok, Enum.map(events, &encode_event/1)}
    end
  end

  @doc """
  Subscribes `pid` (default: the caller) to the session's event stream —
  `{:chopaat_session, session_pid, seq, event}` messages, `seq` strictly
  increasing. Convert each `event` with `encode_event/1` to put it on a
  JSON wire; `act/3` returns the same events already encoded.
  """
  @spec subscribe(Session.session(), pid()) :: :ok
  def subscribe(session, pid \\ self()), do: Session.subscribe(session, pid)

  @doc "Removes `pid` (default: the caller) from the subscriber set."
  @spec unsubscribe(Session.session(), pid()) :: :ok
  def unsubscribe(session, pid \\ self()), do: Session.unsubscribe(session, pid)

  # ── the action grammar, both directions ─────────────────────────────────────

  @doc "A session action term (or `:throw`) as its wire shape."
  @spec encode_action(:throw | Rules.action()) :: wire_action()
  def encode_action(:throw), do: %{"type" => "throw"}

  def encode_action({:assign, i, ix}) do
    %{"type" => "assign", "roll_index" => i, "pawn" => ix}
  end

  def encode_action({:bonus_step, ix}), do: %{"type" => "bonus_step", "pawn" => ix}

  def encode_action({:khadu, i, ix}) do
    %{"type" => "confirm_khadu", "roll_index" => i, "pawn" => ix}
  end

  def encode_action({:waste, i}), do: %{"type" => "waste", "roll_index" => i}

  def encode_action(:waste_bonus), do: %{"type" => "waste_bonus"}

  @doc """
  A wire action back to the session's term grammar. Unknown types or
  missing/mistyped fields are `{:error, :bad_action}`; unknown *extra*
  fields are ignored (append-only stability policy).
  """
  @spec decode_action(term()) :: {:ok, :throw | Rules.action()} | {:error, :bad_action}
  def decode_action(%{"type" => "throw"}), do: {:ok, :throw}

  def decode_action(%{"type" => "assign", "roll_index" => i, "pawn" => ix})
      when is_integer(i) and is_integer(ix) do
    {:ok, {:assign, i, ix}}
  end

  def decode_action(%{"type" => "bonus_step", "pawn" => ix}) when is_integer(ix) do
    {:ok, {:bonus_step, ix}}
  end

  def decode_action(%{"type" => "confirm_khadu", "roll_index" => i, "pawn" => ix})
      when is_integer(i) and is_integer(ix) do
    {:ok, {:khadu, i, ix}}
  end

  def decode_action(%{"type" => "waste", "roll_index" => i}) when is_integer(i) do
    {:ok, {:waste, i}}
  end

  def decode_action(%{"type" => "waste_bonus"}), do: {:ok, :waste_bonus}

  def decode_action(_undecodable), do: {:error, :bad_action}

  @doc """
  A session event as a JSON-encodable map: the payload plus an `:event`
  name, with any embedded action term converted to its wire shape.
  """
  @spec encode_event(Session.event()) :: wire_event()
  def encode_event({name, payload}) do
    payload
    |> Map.new(fn
      {:action, action} -> {:action, encode_action(action)}
      pair -> pair
    end)
    |> Map.put(:event, name)
  end

  defp dispatch(session, seat, :throw), do: Session.throw(session, seat)

  defp dispatch(session, seat, {:khadu, _i, _ix} = term) do
    Session.confirm_khadu(session, seat, term)
  end

  defp dispatch(session, seat, term), do: Session.assign(session, seat, term)

  # ── describe/0: the contract as data ────────────────────────────────────────

  @actions [
    %{
      "type" => "throw",
      "params" => %{},
      "phase" => "rolling",
      "semantics" =>
        "Throw the seven shells. The server draws the configuration and " <>
          "applies it; a special score (7/11/14/25/30) keeps the phase at " <>
          "rolling (throw again), the first non-special score finalizes the " <>
          "turn's rolls into pending and moves to assigning."
    },
    %{
      "type" => "assign",
      "params" => %{"roll_index" => "index into pending", "pawn" => "own pawn index 0..3"},
      "phase" => "assigning",
      "semantics" =>
        "Spend pending[roll_index] on one pawn, atomically: unlock it from " <>
          "base (entry scores 11/25/30 only) or move it forward by the " <>
          "roll's full value."
    },
    %{
      "type" => "bonus_step",
      "params" => %{"pawn" => "own pawn index 0..3"},
      "phase" => "assigning",
      "semantics" => "Spend one free-floating +1 step on any on-track pawn."
    },
    %{
      "type" => "confirm_khadu",
      "params" => %{"roll_index" => "index into pending", "pawn" => "own pawn index 0..3"},
      "phase" => "assigning",
      "semantics" =>
        "Explicitly commit a forced khadu: the pawn reverses 4 cells, then " <>
          "runs forward by the roll's full value, skipping the private final " <>
          "stretch; every other pending 2/3/4 roll and every bonus step burns " <>
          "(dana ane pagdu badi gaya). Offered only when forced; when offered, " <>
          "khadu actions are the ONLY legal actions. The action name is the " <>
          "confirmation — a khadu can never be committed via assign."
    },
    %{
      "type" => "waste",
      "params" => %{"roll_index" => "index into pending"},
      "phase" => "assigning",
      "semantics" => "Discard pending[roll_index]; offered only when it has no use."
    },
    %{
      "type" => "waste_bonus",
      "params" => %{},
      "phase" => "assigning",
      "semantics" => "Discard one bonus step; offered only when no pawn can take a step."
    }
  ]

  @position_schema %{
    "state" => "base | track | home",
    "track" => "lap position 0..board.home-1 when state=track, else null",
    "cell" =>
      "render/occupancy key: cell_t{track}_l{lane}_r{row} when on track, " <>
        "center_home when home, null in base"
  }

  @pawn_schema Map.merge(@position_schema, %{
                 "pawn" => "this pawn's index (the value action params name)",
                 "bypass" =>
                   "true while the pawn owes one skip of the private final " <>
                     "stretch from a gate khadu",
                 "tipped" => "true inside the private final stretch (about to finish)",
                 "jammed" =>
                   "true when the owner's gate is active and even the smallest " <>
                     "score would cross it — the pawn cannot move until a tod is earned"
               })

  @state_schema %{
    "seq" => "server event sequence number, strictly increasing",
    "variant" => "ruleset name (gujarat)",
    "num_players" => "4 or 6",
    "turn" => "seat to act, 0..num_players-1",
    "phase" => "rolling | assigning | finished",
    "rolls" => "scores collected so far this turn (rolling phase)",
    "pending" =>
      "surviving scores awaiting assignment, after triple-repeat " <>
        "cancellation; roll_index in actions indexes THIS list",
    "bonus_steps" => "free-floating +1 steps remaining this turn",
    "captured_this_turn" => "true grants an extra turn when the turn ends",
    "placements" => "seats in finishing order (complete once phase=finished)",
    "board" => %{
      "arms" => "arm count (= num_players)",
      "home" => "lap position that finishes a pawn (83 for 4p, 117 for 6p)",
      "connector" => "last shared lap position before the private final stretch",
      "gate" => "lap position of each seat's gate cell",
      "marker" => "the row-6 safe marker; at/past it a pawn is safe from finishing khadu",
      "khadu_skip" => "positions skipped when a wrap bypasses the private stretch (15)"
    },
    "seats" => %{
      "seat" => "seat index",
      "name" => "display name",
      "color" => "cosmetic color name",
      "tod" => "true once the seat captured and holds the tod (gate open)",
      "gate" => "active | open (open iff tod)",
      "assisted" => "true when the drought bias applies to this seat's shells",
      "drought" => %{"entry" => "turns without an entry", "move" => "turns without a move"},
      "pawns" => @pawn_schema
    },
    "occupancy" => "map of cell name => [%{seat, pawn}] for every on-track pawn"
  }

  @event_schema %{
    "game_started" => "new game: variant, num_players, turn",
    "throw_result" =>
      "seat, shells (up-booleans), up_count, score, special, entry, " <>
        "cosmetic (presentation-only), phase, rolls, pending, bonus_steps",
    "moved" =>
      "seat, pawn, action (wire shape), roll (score or \"bonus\"), " <>
        "from/to/path as positions",
    "captured" => "seat, victim_seat, victim_pawn, cell, tod_earned, victim_tod_lost",
    "khadu" => "seat, pawn, roll, burned: %{dana: [scores], pagdu: count}",
    "wasted" => "seat, roll (score or \"bonus\")",
    "turn_passed" => "seat, next_seat, extra_turn",
    "placement" => "seat, rank",
    "game_over" => "placements, loser"
  }

  @errors %{
    "bad_action" => "the action map did not decode (unknown type or missing field)",
    "not_your_turn" => "the seat is not the current turn",
    "wrong_phase" => "throw outside the rolling phase",
    "invalid_event" => "an assignment action outside the assigning phase",
    "illegal_action" => "a well-formed action not in legal_actions",
    "game_over" => "the game already finished"
  }

  @doc """
  The whole protocol contract as JSON-serializable data: version, flow,
  action grammar, state schema, event vocabulary, and error reasons.
  Serve this to an agent as its instruction set; the prose companion is
  `guides/machine-play.md`.
  """
  @spec describe() :: map()
  def describe do
    %{
      "protocol" => "chopaat.machine_play",
      "version" => @protocol_version,
      "stability" =>
        "Append-only within a major version: fields, action types, event " <>
          "types, and error reasons may be added; none are renamed, removed, " <>
          "or retyped without a major bump. Ignore unknown fields and events.",
      "flow" => [
        "Call legal_actions(session, seat); when it is empty you are not to act.",
        "Pick exactly one returned action and send it back verbatim via act/3.",
        "Repeat until observe(session).phase == finished.",
        "Events stream to subscribers and return from every act call."
      ],
      "commands" => %{
        "observe" => "observe(session) -> the full public state (see state)",
        "legal_actions" => "legal_actions(session, seat) -> [action] in wire shape",
        "act" => "act(session, seat, action) -> {ok, [event]} | {error, reason}",
        "subscribe" =>
          "subscribe(session, pid) -> ok; delivers " <>
            "{chopaat_session, pid, seq, event}; encode_event/1 puts one on a JSON wire"
      },
      "actions" => @actions,
      "state" => @state_schema,
      "events" => @event_schema,
      "errors" => @errors
    }
  end
end
