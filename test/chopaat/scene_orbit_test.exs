defmodule Chopaat.Scene.OrbitTest do
  @moduledoc false

  use ExUnit.Case, async: true

  doctest Chopaat.Scene.Orbit

  alias Chopaat.Scene.Orbit

  describe "seat_yaw/2" do
    test "4p seats sit every 90°, 6p every 60°, seat 0 at the tuned rig" do
      assert Enum.map(0..3, &Orbit.seat_yaw(4, &1)) == [0.0, 90.0, 180.0, 270.0]
      assert Enum.map(0..5, &Orbit.seat_yaw(6, &1)) == [0.0, 60.0, 120.0, 180.0, 240.0, 300.0]
    end

    test "matches the home-ring/base-arm angle convention (2π · seat / n)" do
      # The scene places player p's ring pawns at angle 2π·p/n via
      # sin/cos — the seat yaw is the same angle in degrees, so the
      # camera at that yaw puts the seat's arm at the bottom of frame.
      for {players, seat} <- [{4, 1}, {4, 3}, {6, 2}, {6, 5}] do
        assert Orbit.seat_yaw(players, seat) == seat * 360.0 / players
      end
    end
  end

  describe "new/4" do
    test "no motion when the camera already frames the seat" do
      assert Orbit.new(90.0, 90.0, 0) == nil
      assert Orbit.new(360.0, 0.0, 0) == nil
    end

    test "takes the shortest arc in either direction" do
      # 4p seat 3 -> seat 0: +90° across the wrap, never -270°.
      assert %Orbit{delta_deg: 90.0} = Orbit.new(270.0, 0.0, 0)
      # And back: -90°.
      assert %Orbit{delta_deg: -90.0} = Orbit.new(0.0, 270.0, 0)
      # 6p neighbor: ±60°.
      assert %Orbit{delta_deg: 60.0} = Orbit.new(300.0, 0.0, 0)
      assert %Orbit{delta_deg: -60.0} = Orbit.new(60.0, 0.0, 0)
    end

    test "a dead 180° (4p opposite seat) picks +180 deterministically" do
      assert %Orbit{delta_deg: 180.0} = Orbit.new(0.0, 180.0, 0)
      assert %Orbit{delta_deg: 180.0} = Orbit.new(180.0, 0.0, 0)
    end

    test "a mid-orbit re-aim starts from the interrupted yaw" do
      assert %Orbit{from_deg: 45.0, delta_deg: 135.0} = Orbit.new(45.0, 180.0, 0)
    end
  end

  describe "yaw/2 and done?/2" do
    test "endpoints are exact — the tuned rig poses, no roundoff drift" do
      orbit = Orbit.new(270.0, 0.0, 1_000, 800)

      assert Orbit.yaw(orbit, 1_000) == 270.0
      assert Orbit.yaw(orbit, 900) == 270.0
      assert Orbit.yaw(orbit, 1_800) == 0.0
      assert Orbit.yaw(orbit, 5_000) == 0.0
      assert Orbit.target(orbit) == 0.0

      refute Orbit.done?(orbit, 1_799)
      assert Orbit.done?(orbit, 1_800)
    end

    test "eases in and out: smoothstep across the whole arc" do
      orbit = Orbit.new(0.0, 90.0, 0, 800)

      # Smoothstep: f(1/4) = 5/32, f(1/2) = 1/2, f(3/4) = 27/32.
      assert_in_delta Orbit.yaw(orbit, 200), 90.0 * 5 / 32, 1.0e-9
      assert_in_delta Orbit.yaw(orbit, 400), 45.0, 1.0e-9
      assert_in_delta Orbit.yaw(orbit, 600), 90.0 * 27 / 32, 1.0e-9

      # Slower than linear near the ends, monotone throughout.
      yaws = for ms <- 0..800//50, do: Orbit.yaw(orbit, ms)
      assert yaws == Enum.sort(yaws)
    end

    test "eases along a negative arc too" do
      orbit = Orbit.new(0.0, 270.0, 0, 800)

      assert_in_delta Orbit.yaw(orbit, 400), -45.0, 1.0e-9
      assert Orbit.target(orbit) == 270.0
    end
  end
end
