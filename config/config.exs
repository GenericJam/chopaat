import Config

# Host-side (dev/test) plugin config. On device, Mix config is not loaded;
# Chopaat.MobApp.on_start/0 sets the same values with Application.put_env.
config :mob_scene3d, asset_root: {:chopaat, "priv/assets"}
