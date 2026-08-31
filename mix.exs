defmodule Chopaat.MixProject do
  use Mix.Project

  def project do
    [
      app: :chopaat,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # On-device BEAM bootstrap (src/chopaat.erl) — the mob adoption shape.
      erlc_paths: ["src"],
      erlc_options: [:debug_info],
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile on every push and
    # the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:mob, "~> 0.7.37"},
      # Path dep until the plugin's animation-playback lane releases; the
      # integration bead (chopaat-hre) pins the hex release. CI clones the
      # public repo and points MOB_SCENE3D_PATH at it.
      {:mob_scene3d, path: System.get_env("MOB_SCENE3D_PATH", "/Users/kevin/code/mob_scene3d")},
      {:mob_dev, "~> 0.6.30", only: :dev, runtime: false},
      {:image, "~> 0.54", only: :dev},
      # mob's native build compiles the sqlite NIF from deps/exqlite
      # unconditionally (every Mob app ships it); the game itself keeps all
      # state in screen assigns.
      {:exqlite, "~> 0.27"},
      # Required by mob_dev's Igniter-based tasks (mob.adopt.native).
      {:igniter, "~> 0.8", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # ex_slop — Credo check that catches AI-generated Elixir patterns.
      # Wired in via .credo.exs as `{ExSlop, []}` in the plugins list.
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
