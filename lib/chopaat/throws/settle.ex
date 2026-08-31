defmodule Chopaat.Throws.Settle do
  @moduledoc """
  The post-settle honesty check (AGENTS.md: rules first, animation performs
  the answer — then *assert* the performance matched).

  Given a `Mob.Scene3d.scene/1` readback map, classify every tumble slot's
  settled orientation with exactly the rule `tumble.py` baked and `gate.mjs`
  re-verifies: a slot is aperture-up iff its local +Y axis in world space
  has a world-Y component ≤ −0.7 (dome-up ⇔ ≥ +0.7; anything between is
  ambiguous and fails the check). The local +Y axis is column 1 of the
  node's column-major world matrix, which the readback exposes per named
  glTF node (`"nodes"` on the tumbles entity — the k0/k4/k7 contract
  verified upstream on three devices).

  A mismatch is a wire/applier/asset bug by construction — the caller logs
  it loudly and **trusts the rules**, never the visual.
  """

  alias Chopaat.Throws.Manifest

  @slots 7

  @typedoc "One slot's classified settled orientation."
  @type orientation :: :aperture_up | :dome_up | {:ambiguous, float()}

  @doc """
  Asserts the seven slot orientations in a scene readback against the
  manifest's per-slot array for `animation_name`.

  Returns `:ok`, `{:mismatch, report}` (per-slot expected vs observed with
  the raw world-Y components), or `{:error, reason}` when the readback has
  no usable tumbles node map (readback failure, not a settled-wrong throw).
  """
  @spec verify(map(), String.t()) :: :ok | {:mismatch, map()} | {:error, term()}
  def verify(scene, animation_name) when is_map(scene) do
    with {:ok, nodes} <- tumble_nodes(scene) do
      expected = Manifest.aperture_up(animation_name)
      observed = Enum.map(0..(@slots - 1), &classify(Map.get(nodes, "shell_#{&1}")))

      case Enum.zip(expected, observed) |> Enum.all?(&match?/1) do
        true ->
          :ok

        false ->
          {:mismatch, %{animation: animation_name, expected: expected, observed: observed}}
      end
    end
  end

  @doc """
  Classifies one slot node's column-major world matrix (16 floats).
  """
  @spec classify([number()] | term()) :: orientation() | {:error, term()}
  def classify([_, _, _, _, yx, yy, yz, _, _, _, _, _, _, _, _, _]) do
    up_y = yy / :math.sqrt(yx * yx + yy * yy + yz * yz)
    tolerance = Manifest.up_axis_tolerance()

    cond do
      up_y <= -tolerance -> :aperture_up
      up_y >= tolerance -> :dome_up
      true -> {:ambiguous, up_y}
    end
  end

  def classify(other), do: {:error, {:bad_node_matrix, other}}

  defp match?({true, :aperture_up}), do: true
  defp match?({false, :dome_up}), do: true
  defp match?(_pair), do: false

  defp tumble_nodes(scene) do
    case get_in(scene, ["entities", "tumbles", "nodes"]) do
      %{} = nodes -> {:ok, nodes}
      other -> {:error, {:no_tumble_nodes, other}}
    end
  end
end
