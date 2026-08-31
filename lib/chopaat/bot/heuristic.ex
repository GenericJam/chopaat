defmodule Chopaat.Bot.Heuristic do
  @moduledoc """
  Tier 2 (the menu's Bot · normal): a ranking heuristic over the public
  observation, per the bead's priority ladder —

    captures > entering > advancing (prefer the leader) > safe stops

  plus two penalty rules: avoid parking just before an active gate (a
  pawn stopped within dana reach of its gate is about to jam), and when
  a khadu is forced choose the least-bad pawn (the commit whose landing
  keeps the most progress; captures on the khadu landing break ties
  upward — a khadu that earns the tod is the best of a bad turn).

  Deterministic: ties resolve to the first action in the session's legal
  order, so a heuristic seat's play is a pure function of the observation
  (the RNG state threads through untouched). Legality is the session's
  guarantee — this module only ranks what it was offered.
  """

  @behaviour Chopaat.Bot

  alias Chopaat.Bot

  # Priority weights: each rung dominates everything below it (advance
  # contributes at most ~100, safe +60, so capture/entry/home can never
  # be outranked by accumulation).
  @capture 1_000
  @entry 500
  @home 400
  @safe 60
  @advance_scale 100
  @gate_parking -150
  @waste -1_000
  @khadu -2_000

  # Parking closer than this to an active gate invites a jam: any dana
  # (2/3/4) fails to cross and strands the pawn.
  @gate_shadow 3

  @impl Chopaat.Bot
  def choose(obs, [_ | _] = legal, rng) do
    {Enum.max_by(legal, &score(obs, &1)), rng}
  end

  defp score(_obs, {:waste, _i}), do: @waste
  defp score(_obs, :waste_bonus), do: @waste - 1

  # Forced khadu: all offered actions are khadus (they preempt). Least-bad
  # = the landing that keeps the most lap progress; a capturing khadu
  # (earning the tod) outranks every non-capturing one.
  defp score(obs, {:khadu, _i, _ix} = action) do
    {:track, x} = Bot.landing(obs, action)
    @khadu + capture_bonus(obs, action) + x
  end

  defp score(obs, action) do
    case Bot.landing(obs, action) do
      :entry -> @entry
      :home -> @home
      {:track, x} -> capture_bonus(obs, action) + track_score(obs, x)
    end
  end

  defp capture_bonus(obs, action) do
    case Bot.captures?(obs, action) do
      true -> @capture
      false -> 0
    end
  end

  defp track_score(obs, x) do
    advance = div(x * @advance_scale, obs.board.home)
    advance + safe_bonus(obs, x) + gate_penalty(obs, x)
  end

  defp safe_bonus(obs, x) do
    case Bot.safe?(obs, x) do
      true -> @safe
      false -> 0
    end
  end

  defp gate_penalty(obs, x) do
    gate = obs.board.gate

    case not Bot.me(obs).tod and x <= gate and gate - x <= @gate_shadow do
      true -> @gate_parking
      false -> 0
    end
  end
end
