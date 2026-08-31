#!/usr/bin/env node
/**
 * shell_pool.mjs — regenerate assets/shell_pool.json, the machine-readable
 * cowrie game-pool manifest the tumble/runtime lanes consume.
 *
 * Pool membership is the OWNER RULING recorded in bead chopaat-cbr:
 * a- and c-family variants only (a2 excluded); a2 and the b-series stay
 * in priv/assets as generator references but are NOT in the game pool
 * (7 shells per throw are drawn from this pool, set varied per game).
 *
 * Bounds are measured straight from each GLB's POSITION accessors
 * (exporters bake mesh transforms, so accessor min/max is exact) and the
 * pool-wide max-extent spread is recorded. The tumble library
 * (chopaat-5gx) bakes motion against one canonical proxy, so bounds
 * consistency across the pool is a hard requirement — gate.mjs enforces
 * the window and spread tolerance recorded here.
 *
 * Usage: node assets/scripts/shell_pool.mjs
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = join(HERE, "..", "..", "priv", "assets");
const MANIFEST = join(HERE, "..", "shell_pool.json");

// Owner ruling (bead chopaat-cbr): a/c families, a2 and b-series dropped.
const POOL = [
  "cowrie_a1", "cowrie_a3", "cowrie_a4", "cowrie_a5", "cowrie_a6",
  "cowrie_a7", "cowrie_c1", "cowrie_c2", "cowrie_c3", "cowrie_c4",
  "cowrie_c5", "cowrie_c6",
];

const BOUNDS = {
  min_extent_m: 0.023,
  max_extent_m: 0.024,
  max_spread_m: 0.0015,
};

function parseGlbJson(file) {
  const buf = readFileSync(file);
  if (buf.readUInt32LE(0) !== 0x46546c67) throw new Error("not a GLB");
  const jsonLen = buf.readUInt32LE(12);
  if (buf.readUInt32LE(16) !== 0x4e4f534a) throw new Error("first chunk not JSON");
  return JSON.parse(buf.subarray(20, 20 + jsonLen).toString("utf8"));
}

function dims(file) {
  const gltf = parseGlbJson(file);
  const mins = [Infinity, Infinity, Infinity];
  const maxs = [-Infinity, -Infinity, -Infinity];
  for (const mesh of gltf.meshes ?? []) {
    for (const prim of mesh.primitives ?? []) {
      const pos = gltf.accessors[prim.attributes.POSITION];
      for (let i = 0; i < 3; i++) {
        mins[i] = Math.min(mins[i], pos.min[i]);
        maxs[i] = Math.max(maxs[i], pos.max[i]);
      }
    }
  }
  return maxs.map((m, i) => m - mins[i]);
}

const round6 = (x) => Number(x.toFixed(6));

const members = {};
for (const name of POOL) {
  const d = dims(join(ASSETS, `${name}.glb`));
  members[name] = {
    file: `priv/assets/${name}.glb`,
    dims_m: d.map(round6),
    extent_m: round6(Math.max(...d)),
  };
}

const extents = Object.values(members).map((m) => m.extent_m);
const spread = round6(Math.max(...extents) - Math.min(...extents));

const manifest = {
  version: 2,
  ruling: "chopaat-cbr owner ruling: pool = a/c families minus a2; b-series and a2 kept as generator references only",
  bounds: { ...BOUNDS, measured_spread_m: spread },
  members,
};

writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
console.log(
  `[shell_pool] wrote ${MANIFEST}: ${POOL.length} members, extent spread ${spread}m`
);
