defmodule Chopaat.Scene.Move do
  @moduledoc """
  Pure per-frame interpolation state for one pawn's animated move — the
  chopaat-hre pick-to-move performance. The rules already decided the
  landing; this only *performs* it: an eased hop per traversed cell
  (smoothstep horizontal lerp + a sine lift), with the pawn's rotation
  nlerped start→end across the whole move (so a khadu out of the final
  stretch stands the tipped pawn back upright in motion, and a pawn
  entering the stretch tips over as it lands).

  No plugin surface beyond ordinary IR transforms: the screen ticks
  (`{:move_tick, ref}`), rebuilds the scene with `transform/2` as a
  per-entity override, and the viewport diff ships one `set_transform` per
  frame. The final tick drops the override and the settled scene pose (with
  stack fan-out, tip, home ring) is the landing by construction.
  """

  alias Mob.Scene3d.IR.Transform

  @ms_per_cell 120
  @min_ms 250
  @max_ms 2_000
  # Peak lift of each per-cell hop, meters (pawn is ~22 mm tall).
  @hop 0.012
  @tick_ms 33

  @enforce_keys [:entity_id, :ref, :points, :from_rotation, :to_rotation, :duration_ms]
  defstruct [:entity_id, :ref, :points, :from_rotation, :to_rotation, :duration_ms, :started_ms]

  @type t :: %__MODULE__{
          entity_id: String.t(),
          ref: reference(),
          points: [{float(), float(), float()}],
          from_rotation: Transform.quat(),
          to_rotation: Transform.quat(),
          duration_ms: pos_integer(),
          started_ms: integer()
        }

  @doc "The screen's tick interval while a move is in flight."
  @spec tick_ms() :: pos_integer()
  def tick_ms, do: @tick_ms

  @doc """
  A move from the pawn's current scene pose to its settled pose, hopping
  through `waypoints` (world positions of the traversed cells, landing
  last — the landing waypoint is replaced by `to`'s exact pose position so
  stack fan-out and tip lift land where the scene will settle).
  """
  @spec new(String.t(), Transform.t(), Transform.t(), [{number(), number(), number()}], integer()) ::
          t()
  def new(entity_id, %Transform{} = from, %Transform{} = to, waypoints, started_ms) do
    through = if waypoints == [], do: [], else: Enum.drop(waypoints, -1)
    points = [from.position | through] ++ [to.position]
    cells = length(points) - 1

    %__MODULE__{
      entity_id: entity_id,
      ref: make_ref(),
      points: points,
      from_rotation: from.rotation,
      to_rotation: to.rotation,
      duration_ms: (cells * @ms_per_cell) |> max(@min_ms) |> min(@max_ms),
      started_ms: started_ms
    }
  end

  @doc "Whether the move has run its full duration at `now_ms`."
  @spec done?(t(), integer()) :: boolean()
  def done?(%__MODULE__{} = move, now_ms), do: now_ms - move.started_ms >= move.duration_ms

  @doc "The pawn's interpolated transform at `now_ms`."
  @spec transform(t(), integer()) :: Transform.t()
  def transform(%__MODULE__{} = move, now_ms) do
    t = clamp((now_ms - move.started_ms) / move.duration_ms)

    cond do
      # Exact endpoints — no float-roundoff drift on the poses that matter
      # (the start pose the scene held, the settled pose it will hold).
      t <= 0.0 -> %Transform{position: hd(move.points), rotation: move.from_rotation}
      t >= 1.0 -> %Transform{position: List.last(move.points), rotation: move.to_rotation}
      true -> interpolate(move, t)
    end
  end

  defp interpolate(move, t) do
    segments = length(move.points) - 1
    scaled = t * segments
    segment = min(trunc(scaled), segments - 1)
    u = ease(scaled - segment)

    {ax, ay, az} = Enum.at(move.points, segment)
    {bx, by, bz} = Enum.at(move.points, segment + 1)
    lift = @hop * :math.sin(:math.pi() * u)

    %Transform{
      position: {lerp(ax, bx, u), lerp(ay, by, u) + lift, lerp(az, bz, u)},
      rotation: nlerp(move.from_rotation, move.to_rotation, t)
    }
  end

  defp clamp(t), do: t |> max(0.0) |> min(1.0)

  # Smoothstep: eases each cell hop in and out.
  defp ease(u), do: u * u * (3.0 - 2.0 * u)

  defp lerp(a, b, u), do: a + (b - a) * u

  # Normalized lerp along the shorter arc — ample for the ≤90° pawn
  # reorientations here (tip over / stand upright).
  defp nlerp({ax, ay, az, aw}, {bx, by, bz, bw}, t) do
    dot = ax * bx + ay * by + az * bz + aw * bw
    sign = if dot < 0, do: -1.0, else: 1.0

    x = lerp(ax, bx * sign, t)
    y = lerp(ay, by * sign, t)
    z = lerp(az, bz * sign, t)
    w = lerp(aw, bw * sign, t)

    norm = :math.sqrt(x * x + y * y + z * z + w * w)
    {x / norm, y / norm, z / norm, w / norm}
  end
end
