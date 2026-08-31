defmodule Chopaat.KhaduTest do
  @moduledoc false

  # Gate / tod / khadu and the finishing rules, including every worked
  # example from RULESET.md verbatim (4 players: gate 54, connector 75,
  # marker 77, home 83).

  use ExUnit.Case, async: true

  alias Chopaat.Game
  alias Chopaat.Support.Craft

  describe "the gate" do
    test "a no-tod pawn cannot pass the active gate, and with a base pawn the roll is just wasted" do
      game = Craft.game() |> Craft.pawns(0, [50, :base, :base, :base]) |> Craft.assigning([7])

      assert Game.legal_actions(game) == [{:waste, 0}]
    end

    test "landing exactly on the gate cell is allowed" do
      game =
        Craft.game()
        |> Craft.pawns(0, [50, :base, :base, :base])
        |> Craft.assigning([4])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 54}
    end

    test "holding a tod deactivates the gate" do
      game =
        Craft.game()
        |> Craft.pawns(0, [50, :base, :base, :base])
        |> Craft.tod(0)
        |> Craft.assigning([7])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 57}
    end

    test "a tod earned mid-turn releases blocked pawns for later rolls of the same turn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [19, 50, :home, :home])
        |> Craft.pawns(1, [72, 1, :base, :base])
        |> Craft.tod(1)
        |> Craft.assigning([2, 7])
        |> Craft.apply!({:assign, 0, 0})

      assert game.tod[0]
      assert {:assign, 0, 1} in Game.legal_actions(game)

      game = Craft.apply!(game, {:assign, 0, 1})
      assert Craft.pos(game, 0, 1) == {:track, 57}
    end
  end

  describe "gate khadu" do
    test "not forced while any pawn can absorb the roll" do
      game = Craft.game() |> Craft.pawns(0, [54, 53, 52, 10]) |> Craft.assigning([7])

      assert Game.legal_actions(game) == [{:assign, 0, 3}]
    end

    test "RULESET example: from 54 a khadu with 30 lands on 12, burning pending dana" do
      game = Craft.game() |> Craft.pawns(0, [54, 53, 52, 51]) |> Craft.assigning([30, 2])

      assert Enum.sort(Game.legal_actions(game)) ==
               for(ix <- 0..3, do: {:khadu, 0, ix})

      game = Craft.apply!(game, {:khadu, 0, 0})

      assert Craft.pawn(game, 0, 0) == %Chopaat.Pawn{pos: {:track, 12}, bypass: false}
      # the pending 2 was burned (dana ane pagdu badi gaya): nothing else moved
      assert Enum.map(1..3, &Craft.pos(game, 0, &1)) == [{:track, 53}, {:track, 52}, {:track, 51}]
      assert {game.turn, game.phase} == {1, :rolling}
    end

    test "a khadu landing at or before the connector leaves a bypass debt" do
      game =
        Craft.game()
        |> Craft.pawns(0, [48, 53, 52, 51])
        |> Craft.assigning([7])
        |> Craft.apply!({:khadu, 0, 0})

      assert Craft.pawn(game, 0, 0) == %Chopaat.Pawn{pos: {:track, 51}, bypass: true}
    end

    test "a khadu landing that captures earns the tod but keeps the penalty" do
      game =
        Craft.game()
        |> Craft.pawns(0, [54, 53, 52, 51])
        |> Craft.pawns(1, [63, 1, :base, :base])
        |> Craft.tod(1)
        |> Craft.assigning([30])
        |> Craft.apply!({:khadu, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 12}
      assert Craft.pos(game, 1, 0) == :base
      assert game.tod[0]
      assert {game.turn, game.phase} == {0, :rolling}
    end
  end

  describe "gate-khadu circulation" do
    test "a circulating no-tod pawn skips the private stretch at the connector" do
      game =
        Craft.game()
        |> Craft.pawns(0, [{70, :bypass}, 5, 6, 7])
        |> Craft.assigning([7])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pawn(game, 0, 0) == %Chopaat.Pawn{pos: {:track, 9}, bypass: false}
    end

    test "from the connector the next step continues at own lane 0 bottom" do
      game =
        Craft.game()
        |> Craft.pawns(0, [{75, :bypass}, 5, 6, 7])
        |> Craft.assigning([], 1)
        |> Craft.apply!({:bonus_step, 0})

      assert Craft.pawn(game, 0, 0) == %Chopaat.Pawn{pos: {:track, 8}, bypass: false}
    end

    test "a tod-holding pawn still owing its bypass skips the stretch once" do
      game =
        Craft.game()
        |> Craft.pawns(0, [{70, :bypass}, 5, 6, 7])
        |> Craft.tod(0)
        |> Craft.assigning([7])
        |> Craft.apply!({:assign, 0, 0})

      assert Craft.pawn(game, 0, 0) == %Chopaat.Pawn{pos: {:track, 9}, bypass: false}
    end
  end

  describe "finishing khadu (RULESET worked examples, verbatim)" do
    test "72 with roll 25 lands on 25" do
      game = finishing(72, [25, 3]) |> Craft.apply!({:khadu, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 25}
    end

    test "76 with roll 25 lands on 29" do
      game = finishing(76, [25, 2]) |> Craft.apply!({:khadu, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 29}
    end

    test "75 with roll 11 lands on 14" do
      game = finishing(75, [11, 4]) |> Craft.apply!({:khadu, 0, 0})

      assert Craft.pos(game, 0, 0) == {:track, 14}
    end
  end

  describe "finishing total-roll accounting (RULESET position-73 examples)" do
    test "from 73 with 7 + 4 pending, only the 7 is offered and it forces the khadu" do
      game = finishing(73, [7, 4])

      assert Game.legal_actions(game) == [{:khadu, 0, 0}]

      game = Craft.apply!(game, {:khadu, 0, 0})
      assert Craft.pos(game, 0, 0) == {:track, 8}
    end

    test "from 73 with 25 + 3 and the bonus step, only the 25 is offered" do
      game = finishing(73, [25, 3], 1)

      assert Game.legal_actions(game) == [{:khadu, 0, 0}]

      game = Craft.apply!(game, {:khadu, 0, 0})
      assert Craft.pos(game, 0, 0) == {:track, 26}
    end

    test "a pawn 25 steps from home with 25 + 3 cannot finish cleanly with the 25" do
      game = finishing(58, [25, 3])

      assert Game.legal_actions(game) == [{:khadu, 0, 0}]
    end

    test "a pawn 28 steps away with 25 + 3 plus the bonus step (total 29) commits khadu" do
      game = finishing(55, [25, 3], 1)

      assert Game.legal_actions(game) == [{:khadu, 0, 0}]
    end

    test "equality is safe: total exactly matching the distance finishes normally" do
      game =
        finishing(55, [25, 3])
        |> Craft.apply!({:assign, 0, 0})
        |> Craft.apply!({:assign, 0, 0})

      assert game.placements == [0]
    end

    test "not forced while the special has an ordinary destination on another pawn" do
      game =
        Craft.game()
        |> Craft.pawns(0, [73, 10, :home, :home])
        |> Craft.tod(0)
        |> Craft.assigning([7, 4])

      assert Enum.sort(Game.legal_actions(game)) == [{:assign, 0, 1}, {:assign, 1, 1}]

      game = Craft.apply!(game, {:assign, 0, 1})
      assert {:assign, 0, 0} in Game.legal_actions(game)
    end

    test "at or past the row-6 marker the overshooting roll is ignored, not a khadu" do
      game =
        Craft.game()
        |> Craft.pawns(0, [77, :home, :home, :home])
        |> Craft.tod(0)
        |> Craft.assigning([30, 2])

      assert Enum.sort(Game.legal_actions(game)) == [{:waste, 0}, {:assign, 1, 0}]
    end

    test "khadu can never be forced while a pawn remains in base — the roll is wasted" do
      game =
        Craft.game()
        |> Craft.pawns(0, [73, :base, :home, :home])
        |> Craft.tod(0)
        |> Craft.assigning([14])

      assert Game.legal_actions(game) == [{:waste, 0}]
    end
  end

  defp finishing(pos, pending, bonus \\ 0) do
    Craft.game()
    |> Craft.pawns(0, [pos, :home, :home, :home])
    |> Craft.tod(0)
    |> Craft.assigning(pending, bonus)
  end
end
