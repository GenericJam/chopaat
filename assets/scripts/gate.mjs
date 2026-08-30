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

function parseGlbJson(file) {
  const buf = readFileSync(file);
  if (buf.readUInt32LE(0) !== 0x46546c67) throw new Error("not a GLB");
  const jsonLen = buf.readUInt32LE(12);
  if (buf.readUInt32LE(16) !== 0x4e4f534a) throw new Error("first chunk not JSON");
  return JSON.parse(buf.subarray(20, 20 + jsonLen).toString("utf8"));
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

const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : readdirSync(ASSETS).filter((f) => f.endsWith(".glb")).map((f) => join(ASSETS, f));

if (!files.length) {
  console.error("no .glb files found");
  process.exit(1);
}
const ok = files.map(gate).every(Boolean);
process.exit(ok ? 0 : 1);
