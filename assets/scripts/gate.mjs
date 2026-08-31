#!/usr/bin/env node
/**
 * Asset gate — CI-runnable. Every .glb in priv/assets must pass:
 *
 *  1. Khronos glTF-Validator clean (via `gltf-transform validate`,
 *     which wraps the official validator; the standalone npm
 *     `gltf-validator` package ships no CLI executable).
 *  2. Budgets from assets/scripts/budgets.json: triangle count,
 *     material count, texture count, bounding extent.
 *  3. For boards: the node-addressing contract the rules engine uses —
 *     cell_t{track}_l{0..2}_r{1..8}, base_t{track}(_seat_{0..3}),
 *     center_home.
 *  4. The cowrie game-pool manifest (assets/shell_pool.json, built by
 *     shell_pool.mjs): every member exists, its recorded extent matches
 *     the GLB, extents sit in the canonical window, and the pool-wide
 *     max-extent spread is within tolerance (the tumble library bakes
 *     against one canonical proxy — bounds consistency is hard).
 *  5. The tumble library contract (assets/tumble_manifest.json, built by
 *     tumble.py): tumbles.glb carries slot nodes shell_0..shell_6 and
 *     exactly the manifest's animations; every name parses as
 *     throw_k{count}_v{take} with count matching both the manifest field
 *     and the number of aperture-up slots; >= takes_per_outcome takes per
 *     outcome 0..7; durations inside the band; and — the honest-harness
 *     check — the FINAL rotation quaternion of every slot in every
 *     animation is read back out of the GLB binary chunk and re-classified
 *     (glTF local +Y vs world up), which must match the manifest.
 *
 * Budgets/bounds are read straight from the GLB JSON chunk (accessor
 * counts and POSITION min/max), so the gate needs no npm deps beyond
 * npx. Note: bounds ignore node transforms; our exporters bake
 * mesh-level transforms, so this is exact for these assets.
 *
 * Usage:  node assets/scripts/gate.mjs [file.glb ...]
 *         (no args: gates every .glb under priv/assets)
 */

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = join(HERE, "..", "..", "priv", "assets");
const BUDGETS = JSON.parse(readFileSync(join(HERE, "budgets.json"), "utf8"));

function budgetFor(file) {
  const name = basename(file);
  if (BUDGETS[name]) return BUDGETS[name];
  for (const [pattern, budget] of Object.entries(BUDGETS)) {
    if (!pattern.includes("*")) continue;
    const re = new RegExp(
      "^" + pattern.split("*").map((p) => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$"
    );
    if (re.test(name)) return budget;
  }
  return null;
}

function parseGlb(file) {
  const buf = readFileSync(file);
  if (buf.readUInt32LE(0) !== 0x46546c67) throw new Error("not a GLB");
  const jsonLen = buf.readUInt32LE(12);
  if (buf.readUInt32LE(16) !== 0x4e4f534a) throw new Error("first chunk not JSON");
  const json = JSON.parse(buf.subarray(20, 20 + jsonLen).toString("utf8"));
  let bin = null;
  const binStart = 20 + jsonLen;
  if (binStart + 8 <= buf.length && buf.readUInt32LE(binStart + 4) === 0x004e4942)
    bin = buf.subarray(binStart + 8, binStart + 8 + buf.readUInt32LE(binStart));
  return { json, bin };
}

function parseGlbJson(file) {
  return parseGlb(file).json;
}

/** Float32 values of accessor #idx (tightly packed or default-stride). */
function accessorFloats(gltf, bin, idx) {
  const acc = gltf.accessors[idx];
  if (acc.componentType !== 5126) throw new Error(`accessor ${idx}: not float32`);
  const comps = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[acc.type];
  const view = gltf.bufferViews[acc.bufferView];
  const start = (view.byteOffset ?? 0) + (acc.byteOffset ?? 0);
  const out = new Float32Array(acc.count * comps);
  const stride = view.byteStride ?? comps * 4;
  for (let i = 0; i < acc.count; i++)
    for (let c = 0; c < comps; c++)
      out[i * comps + c] = bin.readFloatLE(start + i * stride + c * 4);
  return { values: out, comps, count: acc.count };
}

function inspect(gltf) {
  let tris = 0;
  const mins = [Infinity, Infinity, Infinity];
  const maxs = [-Infinity, -Infinity, -Infinity];
  for (const mesh of gltf.meshes ?? []) {
    for (const prim of mesh.primitives ?? []) {
      const mode = prim.mode ?? 4;
      const count =
        prim.indices !== undefined
          ? gltf.accessors[prim.indices].count
          : gltf.accessors[prim.attributes.POSITION].count;
      if (mode === 4) tris += count / 3;
      const pos = gltf.accessors[prim.attributes.POSITION];
      for (let i = 0; i < 3; i++) {
        mins[i] = Math.min(mins[i], pos.min[i]);
        maxs[i] = Math.max(maxs[i], pos.max[i]);
      }
    }
  }
  const extent = Math.max(...maxs.map((m, i) => m - mins[i]));
  return {
    tris,
    materials: (gltf.materials ?? []).length,
    textures: (gltf.textures ?? []).length,
    extent,
    nodeNames: new Set((gltf.nodes ?? []).map((n) => n.name)),
  };
}

function requiredBoardNodes(arms) {
  const names = ["center_home"];
  for (let t = 0; t < arms; t++) {
    names.push(`base_t${t}`);
    for (let s = 0; s < 4; s++) names.push(`base_t${t}_seat_${s}`);
    for (let l = 0; l < 3; l++)
      for (let r = 1; r <= 8; r++) names.push(`cell_t${t}_l${l}_r${r}`);
  }
  return names;
}

function gate(file) {
  const failures = [];

  // 1. official validator (errors fail; warnings/infos reported only)
  try {
    execFileSync("npx", ["--yes", "@gltf-transform/cli", "validate", file], {
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (err) {
    failures.push(`validator: ${err.stdout?.toString().slice(0, 400) ?? err.message}`);
  }

  // 2. budgets
  const budget = budgetFor(file);
  const info = inspect(parseGlbJson(file));
  if (!budget) {
    failures.push("no budget entry in budgets.json — every asset needs one");
  } else {
    if (budget.maxTris !== undefined && info.tris > budget.maxTris)
      failures.push(`tris ${info.tris} > max ${budget.maxTris}`);
    if (budget.minTris !== undefined && info.tris < budget.minTris)
      failures.push(`tris ${info.tris} < min ${budget.minTris}`);
    if (budget.maxMaterials !== undefined && info.materials > budget.maxMaterials)
      failures.push(`materials ${info.materials} > max ${budget.maxMaterials}`);
    if (budget.maxTextures !== undefined && info.textures > budget.maxTextures)
      failures.push(`textures ${info.textures} > max ${budget.maxTextures}`);
    if (budget.maxExtent !== undefined && info.extent > budget.maxExtent)
      failures.push(`extent ${info.extent.toFixed(3)}m > max ${budget.maxExtent}m`);

    // 3. board addressing contract
    if (budget.nodeContract) {
      const missing = requiredBoardNodes(budget.nodeContract.arms).filter(
        (n) => !info.nodeNames.has(n)
      );
      if (missing.length)
        failures.push(`missing addressing nodes: ${missing.slice(0, 5).join(", ")}${missing.length > 5 ? ` (+${missing.length - 5} more)` : ""}`);
    }
  }

  const label = `${basename(file)} — ${info.tris} tris, ${info.materials} mats, ${info.textures} tex, ${info.extent.toFixed(3)}m`;
  if (failures.length) {
    console.error(`FAIL ${label}`);
    for (const f of failures) console.error(`     ${f}`);
    return false;
  }
  console.log(`PASS ${label}`);
  return true;
}

function gateManifest() {
  const path = join(HERE, "..", "shell_pool.json");
  const failures = [];
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    console.error(`FAIL shell_pool.json — ${err.message}`);
    return false;
  }

  const extents = [];
  for (const [name, member] of Object.entries(manifest.members ?? {})) {
    let info;
    try {
      info = inspect(parseGlbJson(join(ASSETS, `${name}.glb`)));
    } catch (err) {
      failures.push(`${name}: missing/unreadable GLB (${err.message})`);
      continue;
    }
    if (Math.abs(info.extent - member.extent_m) > 1e-5)
      failures.push(
        `${name}: manifest extent ${member.extent_m}m != GLB ${info.extent.toFixed(6)}m (stale manifest — rerun shell_pool.mjs)`
      );
    const { min_extent_m, max_extent_m } = manifest.bounds;
    const EPS = 1e-5; // GLB accessors are float32; targets sit ON the window edges
    if (info.extent < min_extent_m - EPS || info.extent > max_extent_m + EPS)
      failures.push(
        `${name}: extent ${info.extent.toFixed(6)}m outside canonical window [${min_extent_m}, ${max_extent_m}]`
      );
    extents.push(info.extent);
  }
  const spread = extents.length ? Math.max(...extents) - Math.min(...extents) : 0;
  if (spread > manifest.bounds.max_spread_m)
    failures.push(
      `pool extent spread ${spread.toFixed(6)}m > tolerance ${manifest.bounds.max_spread_m}m`
    );

  const label = `shell_pool.json — ${extents.length} members, extent spread ${spread.toFixed(6)}m`;
  if (failures.length) {
    console.error(`FAIL ${label}`);
    for (const f of failures) console.error(`     ${f}`);
    return false;
  }
  console.log(`PASS ${label}`);
  return true;
}

function gateTumbles() {
  const path = join(HERE, "..", "tumble_manifest.json");
  const failures = [];
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    console.error(`FAIL tumble_manifest.json — ${err.message}`);
    return false;
  }
  let glb;
  try {
    glb = parseGlb(join(ASSETS, "tumbles.glb"));
  } catch (err) {
    console.error(`FAIL tumbles.glb — ${err.message}`);
    return false;
  }
  const { json: gltf, bin } = glb;

  // slot nodes
  const nodeIdx = new Map((gltf.nodes ?? []).map((n, i) => [n.name, i]));
  for (const slot of manifest.slots)
    if (!nodeIdx.has(slot)) failures.push(`missing slot node ${slot}`);

  // animation set == manifest set
  const glbAnims = new Map((gltf.animations ?? []).map((a) => [a.name, a]));
  for (const name of Object.keys(manifest.animations))
    if (!glbAnims.has(name)) failures.push(`manifest animation ${name} missing from GLB`);
  for (const name of glbAnims.keys())
    if (!manifest.animations[name]) failures.push(`GLB animation ${name} missing from manifest`);

  const [minDur, maxDur] = manifest.duration_band_s;
  const tol = manifest.up_axis_tolerance;
  const perOutcome = new Map();
  for (const [name, meta] of Object.entries(manifest.animations)) {
    const m = /^throw_k([0-7])_v(\d+)$/.exec(name);
    if (!m) {
      failures.push(`${name}: bad animation name`);
      continue;
    }
    const k = Number(m[1]);
    const upCount = meta.aperture_up.filter(Boolean).length;
    if (meta.count !== k) failures.push(`${name}: manifest count ${meta.count} != name k${k}`);
    if (upCount !== k) failures.push(`${name}: ${upCount} aperture-up slots != name k${k}`);
    if (Number(m[2]) !== meta.take) failures.push(`${name}: manifest take ${meta.take} != name v${m[2]}`);
    perOutcome.set(k, (perOutcome.get(k) ?? 0) + 1);

    const anim = glbAnims.get(name);
    if (!anim) continue;

    // duration inside the band, and matching the manifest
    let tMin = Infinity;
    let tMax = -Infinity;
    for (const s of anim.samplers) {
      tMin = Math.min(tMin, gltf.accessors[s.input].min[0]);
      tMax = Math.max(tMax, gltf.accessors[s.input].max[0]);
    }
    const dur = tMax - tMin;
    if (dur < minDur - 0.02 || dur > maxDur + 0.02)
      failures.push(`${name}: duration ${dur.toFixed(3)}s outside band [${minDur}, ${maxDur}]`);
    if (Math.abs(dur - meta.duration_s) > 0.02)
      failures.push(`${name}: GLB duration ${dur.toFixed(3)}s != manifest ${meta.duration_s}s`);

    // every slot animated, and the FINAL quaternion re-classifies to the
    // manifest orientation (aperture-up = local +Y points world-down)
    manifest.slots.forEach((slot, i) => {
      const node = nodeIdx.get(slot);
      const rot = anim.channels.find(
        (c) => c.target.node === node && c.target.path === "rotation"
      );
      const trans = anim.channels.find(
        (c) => c.target.node === node && c.target.path === "translation"
      );
      if (!rot || !trans) {
        failures.push(`${name}: ${slot} missing rotation/translation channel`);
        return;
      }
      const { values, count } = accessorFloats(gltf, bin, anim.samplers[rot.sampler].output);
      const [x, y, z, w] = values.subarray((count - 1) * 4, count * 4);
      // world-Y of the node's local +Y axis, from the quaternion directly
      const upY = 1 - 2 * (x * x + z * z);
      const up = upY <= -tol ? true : upY >= tol ? false : null;
      if (up === null) failures.push(`${name}: ${slot} final pose ambiguous (upY ${upY.toFixed(3)})`);
      else if (up !== meta.aperture_up[i])
        failures.push(
          `${name}: ${slot} GLB final pose ${up ? "aperture" : "dome"}-up != manifest ${meta.aperture_up[i] ? "aperture" : "dome"}-up`
        );
    });
  }
  for (let k = 0; k <= 7; k++)
    if ((perOutcome.get(k) ?? 0) < manifest.takes_per_outcome)
      failures.push(`outcome ${k}: only ${perOutcome.get(k) ?? 0} takes < ${manifest.takes_per_outcome}`);

  const label = `tumble_manifest.json — ${glbAnims.size} animations, outcomes 0..7`;
  if (failures.length) {
    console.error(`FAIL ${label}`);
    for (const f of failures) console.error(`     ${f}`);
    return false;
  }
  console.log(`PASS ${label}`);
  return true;
}

const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : readdirSync(ASSETS).filter((f) => f.endsWith(".glb")).map((f) => join(ASSETS, f));

if (!files.length) {
  console.error("no .glb files found");
  process.exit(1);
}
const filesOk = files.map(gate).every(Boolean);
const manifestOk = gateManifest();
const tumblesOk = gateTumbles();
process.exit(filesOk && manifestOk && tumblesOk ? 0 : 1);
