defmodule Chopaat.SetupTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Chopaat.Setup

  doctest Chopaat.Setup

  test "draws 7 distinct shells from the owner-ruled pool, deterministically per seed" do
    setup = Setup.new(4, seed: 99)

    assert Enum.count(setup.shells) == 7
    assert Enum.uniq(setup.shells) == setup.shells
    assert Enum.all?(setup.shells, &(&1 in Setup.pool()))
    assert setup.shells == Setup.new(4, seed: 99).shells
    refute setup.shells == Setup.new(4, seed: 100).shells
  end

  test "the pool is the a/c families minus a2 (bead chopaat-cbr ruling)" do
    assert Setup.pool() == ~w(cowrie_a1 cowrie_a3 cowrie_a4 cowrie_a5 cowrie_a6 cowrie_a7
                              cowrie_c1 cowrie_c2 cowrie_c3 cowrie_c4 cowrie_c5 cowrie_c6)
  end

  test "reshuffle draws a fresh set under a new seed" do
    setup = Setup.new(6, seed: 1)
    reshuffled = Setup.reshuffle(setup)

    refute reshuffled.seed == setup.seed
    assert Enum.count(reshuffled.shells) == 7
  end

  test "players get default names, distinct colors, and custom names stick" do
    setup = Setup.new(6, names: ["Asha"])

    assert Setup.player(setup, 0).name == "Asha"
    assert Setup.player(setup, 1).name == "Player 2"
    assert setup.players |> Enum.map(& &1.color) |> Enum.uniq() |> length() == 6

    renamed = Setup.rename(setup, 1, "Bhavin")
    assert Setup.player(renamed, 1).name == "Bhavin"
  end

  test "player counts outside the variant are refused" do
    assert_raise MatchError, fn -> Setup.new(5) end
  end
end
