defmodule Chopaat.BotTest do
  @moduledoc false

  # The bot decision contract over crafted public observations: bots see
  # Session.observe/1 + legal_actions/2 and nothing else; the heuristic
  # honors the bead's ladder (captures > entering > advancing > safe
  # stops), avoids parking before an active gate, and picks the
  # least-bad khadu.

  use ExUnit.Case, async: true

  alias Chopaat.Bot
  alias Chopaat.RNG
  alias Chopaat.Session
  alias Chopaat.Support.Craft
  alias Chopaat.Support.Fixtures

  # An observation + legal list for a crafted game state, via a real
  # session — exactly the client surface a bot gets.
  defp observe(game) do
    {:ok, session} = Session.start_link(game: game, rng_seed: 7)
    obs = Session.observe(session)
    legal = Session.legal_actions(session, game.turn)
    :ok = GenServer.stop(session)
    {obs, legal}
  end

  defp choose(bot, game) do
    {obs, legal} = observe(game)
    assert legal != []
    {action, _rng} = bot.choose(obs, legal, RNG.new(1))
    {action, legal}
  end

  describe "Bot.Random" do
    test "always picks a member of the legal list, reproducibly per seed" do
      {obs, legal} = observe(Fixtures.simple_move([4, 2]))

      {action, _rng} = Chopaat.Bot.Random.choose(obs, legal, RNG.new(42))
      assert action in legal

      {again, _rng} = Chopaat.Bot.Random.choose(obs, legal, RNG.new(42))
      assert again == action
    end
  end

  describe "Bot.Heuristic ladder" do
    test "prefers the capture over any other move" do
      # Player 0 at 33 and 20; a 2 from 33 captures player 1's pawn.
      game =
        Craft.game()
        |> Craft.pawns(0, [33, 20, :base, :base])
        |> Craft.pawns(1, [18, 1, :base, :base])
        |> Craft.assigning([2])

      {action, legal} = choose(Chopaat.Bot.Heuristic, game)

      assert {:assign, 0, 1} in legal
      assert action == {:assign, 0, 0}
    end

    test "prefers entering from base over advancing" do
      game =
        Craft.game()
        |> Craft.pawns(0, [20, :base, :base, :base])
        |> Craft.assigning([11])

      {action, _legal} = choose(Chopaat.Bot.Heuristic, game)

      # Pawn 0 could advance by 11; the heuristic unlocks a base pawn.
      assert {:assign, 0, ix} = action
      assert ix in [1, 2, 3]
    end

    test "advances the leader when nothing captures or enters" do
      game =
        Craft.game()
        |> Craft.pawns(0, [30, 10, :base, :base])
        |> Craft.assigning([3])

      {action, legal} = choose(Chopaat.Bot.Heuristic, game)

      assert {:assign, 0, 1} in legal
      assert action == {:assign, 0, 0}
    end

    test "prefers a safe-cell stop over a slightly longer advance" do
      # Pawn 0 can stop on the lane-0 row-5 safe cell (lap 11); pawn 1
      # advances marginally further but lands unprotected.
      game =
        Craft.game()
        |> Craft.pawns(0, [8, 10, :base, :base])
        |> Craft.assigning([3])

      {action, _legal} = choose(Chopaat.Bot.Heuristic, game)

      assert action == {:assign, 0, 0}
    end

    test "avoids parking just before its active gate (4p gate at 54)" do
      # A 3 moves pawn 0 (49 -> 52, inside the gate shadow) or pawn 1
      # (30 -> 33, open track). Parking at 52 invites a jam.
      game =
        Craft.game()
        |> Craft.pawns(0, [49, 30, :base, :base])
        |> Craft.assigning([3])

      {action, legal} = choose(Chopaat.Bot.Heuristic, game)

      assert {:assign, 0, 0} in legal
      assert action == {:assign, 0, 1}
    end

    test "khadu choice is the least-bad pawn (keeps the most progress)" do
      # All four jammed at the gate; the khadu landing is x - 4 + 7, so
      # the most advanced pawn (54 -> 57) loses the least.
      {action, legal} = choose(Chopaat.Bot.Heuristic, Fixtures.gate_jam([7]))

      assert Enum.all?(legal, &match?({:khadu, _i, _ix}, &1))
      assert action == {:khadu, 0, 0}
    end

    test "a capturing khadu outranks a longer non-capturing one" do
      # Pawn 0's khadu lands on 57; pawn 1's lands on 56 where an enemy
      # sits (player 2's lap 22 shares player 0's lap 56 cell: absolute
      # cell t3_l0_r2). The capture (and its tod) wins.
      game =
        Craft.game()
        |> Craft.pawns(0, [54, 53, 52, 51])
        |> Craft.pawns(2, [22, :base, :base, :base])
        |> Craft.assigning([7])

      {obs, legal} = observe(game)
      assert {:khadu, _i, _ix} = capturing = Enum.find(legal, &Bot.captures?(obs, &1))
      {action, _rng} = Chopaat.Bot.Heuristic.choose(obs, legal, RNG.new(1))
      assert action == capturing
    end
  end

  describe "Bot observation helpers" do
    test "landing arithmetic matches the session's public facts" do
      {obs, _legal} = observe(Fixtures.simple_move([4]))

      assert Bot.landing(obs, {:assign, 0, 0}) == {:track, 24}
      assert Bot.me(obs).seat == 0
      assert Bot.pawn(obs, 0).track == 20
    end

    test "entry and home landings are named" do
      game =
        Craft.game()
        |> Craft.tod(0)
        |> Craft.pawns(0, [79, :base, :base, :base])
        |> Craft.assigning([4, 11])

      {obs, legal} = observe(game)

      assert {:assign, 0, 0} in legal
      assert Bot.landing(obs, {:assign, 0, 0}) == :home
      assert Bot.landing(obs, {:assign, 1, 1}) == :entry
    end

    test "wrap-mode landing skips the private passage without a tod" do
      # No tod: past the connector (75) the pawn wraps with the +15 skip.
      game =
        Craft.game()
        # Gate is at 54: position 60 is already past it (crafted), and a
        # 30 from 60 crosses the connector -> wraps.
        |> Craft.pawns(0, [60, :base, :base, :base])
        |> Craft.assigning([30])

      {obs, legal} = observe(game)

      assert {:assign, 0, 0} in legal
      assert Bot.landing(obs, {:assign, 0, 0}) == {:track, rem(60 + 30 + 15, 83)}
    end
  end
end
