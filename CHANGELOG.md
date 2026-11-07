# Changelog

## Unreleased
- Lot entrances: a lot's `entrances` metadata (`front`/`back`/`left`/`right`) swaps the street edge on those sides for `GridCityLayout.street_entrance_edge` / `avenue_entrance_edge` (driveways). Unset variants fall back to the plain edge.
- Opt-in batching: `GridCityLayout.batch_meshes` / `batch_chunk` merge repeated static meshes into per-chunk MultiMeshes at bake time (`GridCityBatcher`). Off by default: it cuts draw calls but loses per-prop culling, so measure before enabling (it made a Forward+ city slower).

## 1.0.0 — 2026-10-10
- First release: GridCityLayout (district map, superblocks, barriers, avenues, pools, cell overrides, markers), GridCityBuilder (lots, street edges, kerb corners, junction props, navigation lanes, box colliders, deterministic per-cell seeding), GridCityGenerator (Inspector Bake / Clear, optional build on ready), GridCityPropSlot, GridCityMap street queries, headless bake CLI, placeholder starter kit and demo.
