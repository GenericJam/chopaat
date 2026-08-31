"""Colorblind verification for the player palettes (bead chopaat-xix).

Two jobs, one method (documented here, referenced by palettes.json):

1. Simulate deuteranopia and protanopia over the pawn contact sheets
   (pawns_4p.png / pawns_6p.png) -> *_deutan.png / *_protan.png.
   Method: decode sRGB -> linear RGB, apply the Machado, Oliveira &
   Fernandes (2009) severity-1.0 CVD matrices (the standard
   physiologically-based simulation; equivalent to what the python
   `colorspacious`/`daltonlens` packages ship), clip, re-encode sRGB.

2. Verify the palettes numerically: re-derive linear RGB from each
   hex (asserting palettes.json's linear_rgba is faithful), then for
   normal vision + both simulated conditions compute all pairwise
   CIE76 deltaE in CIELAB (D65) and the deltaE of every color against
   the dark cloth (board_cloth linear albedo). Asserts min pairwise
   deltaE >= 10 (comfortably distinct at pawn size on the dark board)
   and writes assets/contact_sheets/palette_cvd_report.txt.

Runs under Blender's python (numpy + image IO, pinned toolchain):
  blender --background --python assets/scripts/colorblind_sim.py -- \
      assets/contact_sheets
"""

import json
import os
import sys

import bpy  # noqa: E402
import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# Machado et al. 2009, severity 1.0, linear-RGB in/out
MATRICES = {
    "deutan": np.array([
        [0.367322, 0.860646, -0.227968],
        [0.280085, 0.672501, 0.047413],
        [-0.011820, 0.042940, 0.968881],
    ]),
    "protan": np.array([
        [0.152286, 1.052583, -0.204868],
        [0.114503, 0.786281, 0.099216],
        [-0.003882, -0.048116, 1.051998],
    ]),
}

CLOTH_LINEAR = np.array([0.020, 0.018, 0.016])  # board.py board_cloth
MIN_DELTA_E = 10.0


def srgb_decode(s):
    s = np.clip(s, 0.0, 1.0)
    return np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)


def srgb_encode(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin <= 0.0031308, 12.92 * lin,
                    1.055 * np.power(lin, 1.0 / 2.4) - 0.055)


def linear_to_lab(rgb):
    """Linear sRGB -> CIELAB (D65)."""
    m = np.array([
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ])
    xyz = rgb @ m.T / np.array([0.95047, 1.0, 1.08883])

    def f(t):
        return np.where(t > 0.008856, np.cbrt(t), 7.787 * t + 16.0 / 116.0)

    fx, fy, fz = f(xyz[..., 0]), f(xyz[..., 1]), f(xyz[..., 2])
    return np.stack([116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)], axis=-1)


def delta_e(a, b):
    return float(np.linalg.norm(linear_to_lab(a) - linear_to_lab(b)))


def hex_to_linear(hex_str):
    s = np.array([int(hex_str[i:i + 2], 16) / 255.0 for i in (1, 3, 5)])
    return srgb_decode(s)


def simulate_sheet(path, kind):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    rgba = px.reshape(-1, 4)
    lin = srgb_decode(rgba[:, :3])
    lin = np.clip(lin @ MATRICES[kind].T, 0.0, 1.0)
    rgba[:, :3] = srgb_encode(lin)

    out_path = path.replace(".png", f"_{kind}.png")
    out = bpy.data.images.new("cvd", w, h, alpha=True)
    out.pixels.foreach_set(rgba.astype(np.float32).ravel())
    out.filepath_raw = out_path
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)
    print(f"[cvd] wrote {out_path}")


def verify_palettes(report_path):
    with open(os.path.join(HERE, "..", "palettes.json")) as f:
        palettes = json.load(f)

    lines = ["Palette CVD verification (assets/scripts/colorblind_sim.py)",
             "Machado 2009 severity-1.0 matrices, CIE76 deltaE in CIELAB/D65",
             f"pass threshold: min pairwise deltaE >= {MIN_DELTA_E}", ""]
    for key in ("players_4", "players_6"):
        entries = palettes[key]
        colors = {}
        for e in entries:
            lin = hex_to_linear(e["hex"])
            recorded = np.array(e["linear_rgba"][:3])
            assert np.allclose(lin, recorded, atol=0.002), (
                f"{key}/{e['name']}: linear_rgba {recorded} != hex-derived {lin}"
            )
            colors[e["name"]] = lin
        for kind, mat in (("normal", np.eye(3)),
                          ("deutan", MATRICES["deutan"]),
                          ("protan", MATRICES["protan"])):
            sims = {n: np.clip(c @ mat.T, 0, 1) for n, c in colors.items()}
            names = list(sims)
            worst = None
            for i in range(len(names)):
                for j in range(i + 1, len(names)):
                    de = delta_e(sims[names[i]], sims[names[j]])
                    if worst is None or de < worst[0]:
                        worst = (de, names[i], names[j])
            cloth_min = min(
                (delta_e(c, np.clip(CLOTH_LINEAR @ mat.T, 0, 1)), n)
                for n, c in sims.items()
            )
            lines.append(
                f"{key} {kind:7s}: min pair deltaE {worst[0]:6.1f} "
                f"({worst[1]} vs {worst[2]}); min vs dark cloth "
                f"{cloth_min[0]:6.1f} ({cloth_min[1]})"
            )
            assert worst[0] >= MIN_DELTA_E, (
                f"{key} {kind}: {worst[1]} vs {worst[2]} deltaE {worst[0]:.1f} "
                f"< {MIN_DELTA_E} — palette not colorblind-safe"
            )
        lines.append("")

    with open(report_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"[cvd] wrote {report_path}")


def main(sheets_dir):
    verify_palettes(os.path.join(sheets_dir, "palette_cvd_report.txt"))
    for arms in (4, 6):
        for kind in MATRICES:
            simulate_sheet(os.path.join(sheets_dir, f"pawns_{arms}p.png"), kind)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    main(argv[0] if argv else "assets/contact_sheets")
