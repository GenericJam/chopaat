defmodule Chopaat.Scene.Orbit do
  @moduledoc """
  Pure per-frame camera-orbit state for the per-turn seat framing
  (bead chopaat-4g7): on a turn handoff the camera orbits the board
  center to the incoming player's seat, so their home arm sits at the
  bottom of the screen — the natural pass-and-play perspective.

  Same shape as `Chopaat.Scene.Move`: no plugin surface beyond ordinary
  IR transforms. The screen ticks (`{:orbit_tick, ref}`), rebuilds the
  scene with `yaw/2` as the camera yaw, and the viewport diff ships one
  camera `set_transform` per frame. Elevation, distance and pitch are
  untouched — only the yaw about the board's vertical axis animates
  (`Chopaat.Scene.rig/2` owns the tuned framing).

  Seats sit every `360 / num_players` degrees (90° for 4p, 60° for 6p),
  seat 0 at the tuned yaw-0 rig; the orbit always takes the shortest arc
  and eases in-out (smoothstep) over ~800 ms.
  """

  @duration_ms 800
  @tick_ms 33

  @enforce_keys [:ref, :from_deg, :delta_deg, :duration_ms, :started_ms]
  defstruct [:ref, :from_deg, :delta_deg, :duration_ms, :started_ms]

  @type t :: %__MODULE__{
          ref: reference(),
          from_deg: float(),
          delta_deg: float(),
          duration_ms: pos_integer(),
          started_ms: integer()
        }

  @doc "The screen's tick interval while an orbit is in flight."
  @spec tick_ms() :: pos_integer()
  def tick_ms, do: @tick_ms

  @doc "The default orbit duration."
  @spec duration_ms() :: pos_integer()
  def duration_ms, do: @duration_ms

  @doc """
  The camera yaw (degrees, `[0, 360)`) framing a seat: seat 0 is the
  tuned rig, seats step counter-clockwise-in-yaw exactly like the home
  ring and the board arms (`sin/cos` of `2π · seat / num_players`).

      iex> Chopaat.Scene.Orbit.seat_yaw(4, 1)
      90.0
      iex> Chopaat.Scene.Orbit.seat_yaw(6, 5)
      300.0
  """
  @spec seat_yaw(pos_integer(), non_neg_integer()) :: float()
  def seat_yaw(num_players, seat), do: normalize(seat * 360.0 / num_players)

  @doc """
  An eased shortest-arc orbit from `from_deg` to `to_deg`, or `nil` when
  the camera is already there (no motion to perform).
  """
  @spec new(number(), number(), integer(), pos_integer()) :: t() | nil
  def new(from_deg, to_deg, started_ms, duration_ms \\ @duration_ms) do
    case shortest_delta(from_deg, to_deg) do
      delta when delta == 0.0 ->
        nil

      delta ->
        %__MODULE__{
          ref: make_ref(),
          from_deg: normalize(from_deg),
          delta_deg: delta,
          duration_ms: duration_ms,
          started_ms: started_ms
        }
    end
  end

  @doc "Whether the orbit has run its full duration at `now_ms`."
  @spec done?(t(), integer()) :: boolean()
  def done?(%__MODULE__{} = orbit, now_ms), do: now_ms - orbit.started_ms >= orbit.duration_ms

  @doc "The orbit's final yaw, normalized to `[0, 360)`."
  @spec target(t()) :: float()
  def target(%__MODULE__{} = orbit), do: normalize(orbit.from_deg + orbit.delta_deg)

  @doc "The eased camera yaw (degrees) at `now_ms` — exact at the endpoints."
  @spec yaw(t(), integer()) :: float()
  def yaw(%__MODULE__{} = orbit, now_ms) do
    t = clamp((now_ms - orbit.started_ms) / orbit.duration_ms)

    cond do
      t <= 0.0 -> orbit.from_deg
      t >= 1.0 -> target(orbit)
      true -> orbit.from_deg + orbit.delta_deg * ease(t)
    end
  end

  # The signed shortest arc from -> to, in (-180.0, 180.0]. A dead 180°
  # (4p seat 0 -> 2) picks +180 deterministically.
  defp shortest_delta(from_deg, to_deg) do
    case normalize(to_deg - from_deg) do
      delta when delta > 180.0 -> delta - 360.0
      delta -> delta
    end
  end

  defp normalize(deg) do
    case :math.fmod(deg, 360.0) do
      neg when neg < 0.0 -> neg + 360.0
      pos -> pos
    end
  end

  defp clamp(t), do: t |> max(0.0) |> min(1.0)

  # Smoothstep: ease-in-out over the whole arc.
  defp ease(t), do: t * t * (3.0 - 2.0 * t)
end
