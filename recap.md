# Recap — change log

Handoff log for agents and sessions working on this project. **Newest entry at
the top.** Append-only; see `CLAUDE.md` §4 for the format and the rules.

`CLAUDE.md` describes the project as it is now. This file records how it got
there — including the dead ends.

## 2026-08-03 23:21 — Death trigger, camera shake, YOU DIED retry screen

The die-and-retry loop finally has a "die". This closes the gap flagged at the
very start of this session: enemies could chase but never hurt anyone.

**Changed:**
- `scenes/Player.tscn` — new `HUD/YouDiedLabel`, centred (anchors preset 8),
  offsets ±300/±100, 42 px red text with an 8 px black outline, hidden at boot.
- `scenes/Player.gd` — new `you_died_label` `@onready` (`camera` already
  existed), `is_dead`, `_shake_intensity`; new `die()`, `_respawn()`,
  `_clear_death()`, `_on_round_reset()`, `_update_camera_shake()`.
  `_physics_process` freezes horizontal movement while dead; `_unhandled_input`
  gains a death branch; `_ready` connects `GameState.round_reset`.
- `scenes/Enemy.gd` — new `KILL_DISTANCE` (1.15) and `_check_contact_kill()`,
  called from `_physics_process` right after `_update_aggro`.
- `CLAUDE.md` — new "Death & Retry" subsection under `Player.tscn`, HUD tree
  line, controls table (F and G now double as retry), §2d contact-kill note.

**Notes:**

**Three placement decisions that are not arbitrary:**
1. The death branch in `_unhandled_input` sits **before** the
   `GameState.is_preparation()` early return. A reset triggered elsewhere can
   flip the phase on the same press, and the retry keys would then fall through
   that return and silently do nothing.
2. The press is **consumed** with `set_input_as_handled()`. `restart_round` (G)
   is also GameState's own reset key during ACTION, so without this one G press
   would run `reset_round()` twice and double-count `attempt`. F is safe either
   way (GameState only acts on it during PREPARATION) but both are consumed for
   consistency. Verified `attempt` increments by exactly 1.
3. Camera shake runs in `_process`, not `_physics_process` — it is purely visual,
   and sampling at the 60 Hz physics tick reads as judder rather than rattle. It
   writes `camera.h_offset`/`v_offset` rather than the transform, so it composes
   with head pitch instead of fighting the look controls for the same property.

Added beyond the spec: `_clear_death()` as shared cleanup, and connecting it to
`round_reset` (the spec asked for the connection; this is the shape of it). It
also zeroes the camera offsets, which `_respawn()` alone would have left wherever
the last shake frame put them if the reset landed mid-shake.

**Mouse look deliberately still works while dead** — the mouse-motion block sits
above the death check, so the player can look around at whatever killed them.
Everything else (fire, reload, interact, weapon slots) is dead.

Contact kill is gated on `State.CHASE`, not proximity alone. A patroller brushing
past has not caught anyone, and killing on proximity would make the hidden-rule
routes lethal to *stand near* rather than lethal to be *seen by* — the opposite
of the intended mechanic.

**Verification:** headless probe (since deleted) on the live scene. Label geometry,
text, alignment, 42 px font, 8 px outline and colour all confirmed, hidden at boot,
and `you_died_label` resolves. `die()` sets the flag, shows the label and sets
shake 0.8; a second `die()` does **not** re-trigger the shake (idempotent).
Horizontal speed is 0.000 while dead despite being set to 15 u/s beforehand.
Camera offsets move (peak 0.319) then decay to exactly 0 with both offsets zeroed.
`_respawn()` from ACTION clears the flag and label, returns to PREPARATION and
increments `attempt` **once** (1 → 2). `reset_round()` on its own — without
`_respawn()` — also clears the death state. Contact kill: PATROL at 0.5 does not
kill, CHASE at 3.0 does not kill, CHASE at 0.9 does.

**A probe gotcha worth recording:** the first run died during PREPARATION, where
`GameState.reset_round()` early-returns, so `attempt` never moved and the test
failed. Not a code bug — contact kill is gated on `is_action_phase`, so death can
only happen in ACTION. Any future test of the retry path must `start_action()`
first.

**Not verified in play.** No windowed run, so how the shake actually feels, and
whether 42 px at ±300 px reads well at the real resolution, are unchecked. Also
unverified: whether an enemy reliably closes to 1.15 in a real chase — the probe
teleported it. Given the direct-pursuit change at 21:51 and RVO clamping, worth
watching that enemies actually make contact rather than hovering just outside.

## 2026-08-03 23:07 — Despawn props and enemies that fall off the bench

**Changed:**
- `scenes/PrepCamera.gd` — new consts `DESPAWN_Y_THRESHOLD` (65.0) and
  `DESPAWN_SWEEP_INTERVAL` (1.0), new `_despawn_timer`, new `_process()` that
  throttles the sweep to once a second, and new `_clean_fallen_props()`.
- `scenes/Enemy.gd` — new `DESPAWN_Y_THRESHOLD` (65.0); `_physics_process()`
  frees the enemy and returns if it is below that, checked before anything else.
- `CLAUDE.md` — §2b documents the prop sweep, §2d the enemy check.

**Notes:**

**I checked the threshold against the real scene before enabling it**, since this
deletes props unconditionally and a bad number would quietly eat the maze. All
522 props sit between y **72.37 and 79.02**, the tabletop is at ~73.6, and the
leftover ground geometry is at −0.5. The lowest prop clears 65.0 by 7.37 units,
so the dead band is wide and nothing legitimate is near it. Player was at 73.06
and the enemy at 73.20.

Three ordering details in `_clean_fallen_props()` that are not in the spec but
matter:
- If the fallen prop is the one **in hand**, `_drop()` runs first — it restores
  gravity, removes the ray exception, turns avoidance back off and clears
  `_dragged`. Freeing it out from under the drag would leave the tool holding a
  dead reference. (The spec did have this one.)
- Its `_settling` entry is erased too, or `_update_settling()` spends frames
  resolving an instance id that no longer exists.
- The `is_queued_for_deletion()` guard is load-bearing, not defensive: a freed
  node stays in its group until the end of the frame, so the next sweep would
  free it a second time.

The enemy check sits **above** the phase gate in `_physics_process`, so it fires
during PREPARATION as well as ACTION. Tested both.

`PrepCamera` had no `_process` before this — everything lived in
`_physics_process`. Added one as specced; the sweep does not need physics timing.

**Verification:** headless probe (since deleted) against the live 522-prop scene.
A sweep with nothing fallen deletes nothing (522 → 522). Three props moved to
y=10 → 519, all three confirmed freed. A second sweep does not double-free. A
prop dropped while held clears `_dragged` and its settling entry. A fresh enemy
survives on the bench, is freed when moved to y=20 with `is_action_phase` true,
and is also freed with `is_action_phase` false.

**A probe bug worth recording** since it will bite anyone testing against
Main.tscn: my first attempt reached for the scene's hand-placed
`Navigation/Enemy` and got null, because `WaveSpawner._physics_process()` →
`clear_enemies()` had already freed it during the startup PREPARATION frame —
the same behaviour that ate the Enemy during the 22:31 scene rebuild. The null
deref aborted `_initialize()` before `quit()`, so the SceneTree ran forever and
the run had to be killed. Test enemy behaviour with a **freshly instantiated**
Enemy, not the one in the scene.

**Not verified in play.** No windowed run: whether one second of latency reads
well (a prop visibly resting in mid-air below the table for up to a second before
vanishing) is unchecked. If it looks wrong, lower `DESPAWN_SWEEP_INTERVAL` — the
sweep is cheap, it is one group scan.

Also unaddressed, and worth deciding on: **props are freed permanently, but
`GameState.reset_round()` deliberately does not restore the layout** (keeping the
maze is the point of the retry loop). So a prop knocked off the bench is gone for
the rest of the session, and the player cannot rebuild that part of their maze.
That may be the intended consequence — it makes the edge a real hazard — but it
is a design call nobody has made explicitly.

## 2026-08-03 22:44 — Minimap performance: throttled redraw + fast shape bounds

**Changed:**
- `scenes/Minimap.gd` — new `_redraw_timer` and `REDRAW_INTERVAL` const (0.05 s /
  20 Hz); `_process()` throttles `queue_redraw()` instead of calling it every
  frame. `_shape_footprint()` now calls a new `_shape_bounds()` that reads shape
  parameters directly instead of `shape.get_debug_mesh().get_aabb()`.
- `CLAUDE.md` — Minimap section documents both optimisations with the measured
  numbers; new §5 gotcha about `get_debug_mesh()` not being a getter.

**Notes:**

**One task item was already done.** Early distance filtering in `_draw_props()`
was already implemented exactly as specified when the Minimap was written at
20:44 — the `dx*dx + dz*dz > range_squared` check already sat above `_to_radar()`,
`_prop_extents()` and `draw_colored_polygon()`. No change was needed; leaving this
note so nobody goes looking for a diff that does not exist.

**What was actually causing the drops.** Measured on the live bench, and the
steady-state cost turned out not to be the problem: only **7 of 522** props are
inside the 30 m radar radius, and a warm-cache scan costs 0.25 ms per redraw.
That is 1.5% of a 16.7 ms frame — real, worth removing, but not something you
would notice.

The actual culprit was the **cold** footprint measurement.
`shape.get_debug_mesh()` builds an entire debug mesh just to read extents, and
the multi-convex rebuild at 22:31 had just taken props from 1 hull each to up to
8 — so the first frame a prop entered radar range paid for up to 8 mesh builds.
Because the cache fills lazily as the player moves, that cost arrived as
intermittent hitches all through a round rather than once at load, which is
exactly what "FPS drops" describes. So this change is partly cleaning up after
22:31, which made the pre-existing weakness much worse.

**Measured, over all 522 props on the real bench:**

| | old (`get_debug_mesh`) | new (parameter read) |
|---|---|---|
| cold pass over every prop | 103.0 ms | **5.1 ms** (20.1× faster) |

Correctness checked, not assumed: the two implementations were run side by side
over all 522 props and agreed to a worst relative difference of **0.0001**, with
zero mismatches above 2%.

Steady-state scan: 0.252 ms per redraw → at 60 Hz that was ~15.1 ms of CPU per
second, now ~5.0 ms at 20 Hz.

Added beyond the spec: the spec's `_shape_bounds` handled Box and ConvexPolygon
and `continue`d on everything else. I also handled Sphere, Cylinder and Capsule —
they are one-liners, and without them the always-dynamic `bowl_dirty2` (a
CylinderShape3D) would silently fall through to being sized by its visual mesh
instead of its collider.

**Not verified in play.** No windowed run — `_draw()` does not execute headless,
so the on-screen result of the 20 Hz throttle (whether the radar reads as smooth
while the player turns) is unchecked. If it looks steppy while turning, lower
`REDRAW_INTERVAL`; the expensive part is fixed independently of the rate.

## 2026-08-03 22:31 — Multi-convex prop colliders (V-HACD) + full scene rebuild

**Changed:**
- `tools/PropConverter.gd` — `build_collision_shapes()` now decomposes each mesh
  into multiple convex hulls instead of taking one hull per mesh. New
  `_decompose()` and `_named_shape()` helpers; new consts
  `DECOMPOSE_MAX_CONCAVITY` (0.01), `DECOMPOSE_MAX_HULLS` (8), `MIN_HULL_POINTS`
  (4). Degenerate meshes now fall back to their **own** tight AABB box per mesh,
  rather than the whole prop falling back only when every mesh failed.
  `_box_size_of()` → `_shape_count_of()` since most props no longer have a box.
- `tools/rebuild_prop_colliders.gd` — **new tool.** Re-runs the shape builder
  over already-converted props. Needed because `convert_scene()` skips anything
  in the `draggable` group, so re-running the converter over Main.tscn is a
  no-op. `--sample=N` dry-runs a projection, `--save` writes.
- `scenes/Main.tscn` — **rebuilt.** 569 → 1804 collision shapes across 521 props;
  290 props now have compound colliders. File 1.53 MB → 2.82 MB.
- `CLAUDE.md` — §2e rewritten for multi-convex generation, the settings, the API
  constraint, the cost measurements and the new tool; two new §5 gotchas.

**Notes:**

**Two API facts that shaped the implementation:**
1. `Mesh.convex_decompose()` is **not exposed to GDScript** in Godot 4.7 — I
   checked the method list directly. The only route is
   `MeshInstance3D.create_multiple_convex_collisions()`, which works by adding a
   StaticBody3D *child* to the node it is called on. `_decompose()` runs it on a
   throwaway clone; calling it on the real model node would have parented a
   StaticBody3D full of colliders inside all 521 props.
2. `MeshConvexDecompositionSettings.max_concavity` defaults to **1.0**, which
   accepts a single hull for any shape — the "decomposition" would have been
   bit-identical to the old single-hull code, at 200 ms per prop, and would have
   looked like it worked. Swept it on a synthetic table (slab + 4 legs):
   1.0 → 1 hull, 0.1 → 4, 0.01 → 6, 0.001 → 6. Settled on 0.01.
   `max_convex_hulls` was identical at 8 and 32, so 8.

**A destructive mistake I made and caught — read this before writing any tool
that saves Main.tscn.** My first rebuild ran the scene for a frame to get valid
global transforms, then packed it. That let the game's own scripts edit the scene
on the way out: `WaveSpawner._physics_process()` calls `clear_enemies()`, which
adopts the hand-placed `Enemy` instance and `queue_free()`s it. The saved
Main.tscn came out with the Enemy **silently missing** — 526 instances became 525
and nothing errored. Caught it by diffing the instance-node name sets against
`git show HEAD:scenes/Main.tscn`. Reverted with `git checkout`, restructured the
tool to `await process_frame` **before** adding the scene and then do everything
in that same frame with no further await, and added a hard assert that nothing is
`is_queued_for_deletion()` before saving. Second run came out clean. Gotcha added
to §5.

**Verification of the rebuilt scene** (against `git show HEAD:scenes/Main.tscn`):
node instances 526 → 526, **identical name set**; all key nodes present (Enemy,
meja, bowl_dirty2, Player, Navigation, WaveSpawner, CoinSpawner, PrepCamera);
522 NavigationObstacle3D preserved; 525 group assignments preserved; meja's
`freeze = true` instance override survived; no `WaveTimer` leaked into the file
(it has no owner, so pack() skips it). Spot-checked `table_round_A2`: 3+ hulls
with Model instance, obstacle outline, mass, freeze and damping all intact.

**Converter verification:** synthetic table (slab + 4 legs, 3× scale, rotated)
produced **6 shapes** where a single hull gives 1; a point in the hollow under
the tabletop is confirmed **not** inside any hull; collider span came out
12.19 × 9.14 confirming the 3× model scale is correctly carried into body space
while the body stays at scale 1. A degenerate flat plane still gets a collider.

**Performance, measured rather than assumed** — this was my main worry, since 3×
the shapes on a scene documented as sitting at budget could have been fatal.
Benchmarked both scenes headless, 240 samples after 60 warm-up frames:

| | shapes | mean | median | p95 | max |
|---|---|---|---|---|---|
| before | 579 | 3.12 ms | 3.12 | 4.45 | 5.66 |
| after | 1814 | **2.80 ms** | 2.78 | **2.91** | **2.91** |

It got *faster* and much more stable. The props are frozen and asleep, so extra
hulls cost broadphase and memory, not narrowphase — and the tighter hulls seem to
remove spurious contacts that caused the old variance. Conversion itself is slow
(~200 ms/prop, ~110 s total) but that is a one-off tool cost.

**Worth doing next, not done here:** the NavigationObstacle3D carve outlines were
**not** refitted. They were fitted to the old single hulls, and the union of
decomposed hulls is a subset of the single hull, so every outline is now equal to
or *larger* than the prop's true footprint. That is the safe direction (never a
sliver of floor inside a solid) but it means the bench is over-carved. Running
`tools/refit_carve_outlines.gd` would tighten them, and given that carve
over-reach is exactly what fragmented the navmesh into 27 disconnected regions —
the thing that forced chase to bypass pathfinding at 21:51 — that could
meaningfully open the bench back up. Say the word and I will run it.

**Not verified in play.** No windowed run: whether the under-table spaces are
actually usable by the player, and whether any prop now has a collider gap, are
unchecked.

## 2026-08-03 21:51 — Bench-wide aggro (250 m) + chase now bypasses the navmesh

**Changed:**
- `scenes/Enemy.tscn` — `DetectionArea` SphereShape3D radius 45 → 250;
  `SightRay.target_position` (0,0,−45) → (0,0,−250).
- `scenes/Enemy.gd` — `aggro_range` export 45.0 → 250.0. `_ready()` unchanged: it
  already adopts the radius off the DetectionArea sphere, so the editor value
  stays the single source of truth and now yields 250 automatically (verified by
  deliberately mis-setting the export to 1.0 and watching `_ready()` overwrite
  it). `_line_of_sight_fallback()` rewritten to the new rule: chase directly when
  `agent.is_navigation_finished()` **or** distance > `chase_arrive_distance`.
- `CLAUDE.md` — §2d DetectionArea/SightRay/aggro_range updated; the "Closing the
  last few metres" section replaced with "Chasing bypasses the navmesh entirely";
  tunables list updated; old aggro measurements marked as taken at r 45 and new
  ones added.

**Notes:**

**The big one: chase no longer uses pathfinding at all.** `chase_arrive_distance`
is 0.5, so "distance > 0.5" is true for essentially the entire chase — the
navmesh path is overridden every frame and the enemy beelines. Pathfinding now
governs PATROL only.

I want to be explicit that this is a real architectural change, not a tuning
tweak, because it is easy to read the diff as small. It is nevertheless the right
call **given the current level content**: §2e records that the props' carve
outlines fragment the bench into ~27 disconnected navmesh regions with no route
across it, so a chasing enemy usually cannot path to the player at all — it gets
a path to the nearest reachable point, reports `is_navigation_finished()` far
away, and stops. That IS the "distant patrol freezing" symptom. A beeline is the
only thing that crosses a fragmented mesh, and the feelers/unstuck layers added
at 21:40 are what stop it grinding into props. **If the fragmentation is ever
fixed (fewer props, or tighter carve outlines), revisit this** — real pathfinding
around the maze is better AI than a straight line.

Second behaviour change: the spec's condition drops the line-of-sight gate that
21:40 added, so during the `aggro_memory` (2 s) tail after the player breaks
cover the enemy keeps charging their last known position. Bounded at 2 s, so it
reads as momentum rather than wallhacking.

`direct_charge_distance` (4.0) was **removed** — the new condition does not
reference it, so it was left completely unread. Same treatment as `fire_cooldown`
in the 21:15 entry: a dead export that appears to govern charging is worse than
no export. Nothing overrode it in any .tscn. `_sees_player` is now written but
not read; kept deliberately as the hook for a HUD "they can see you" tell, and
its doc comment says so.

**PERFORMANCE RISK — unmeasured, please profile before trusting.** r 250 makes
every enemy's DetectionArea cover the whole bench, and its mask is 1, which is
the layer the ~500 props sit on. At `max_live_enemies` 120 that is on the order
of 60,000 area-overlap pairs for the broadphase to maintain, plus a 250-unit
SightRay cast per enemy per frame instead of 45. §2e records the scene already
sitting **exactly** on the 16.7 ms budget, so there may be no headroom for this.
I could not measure it here — it needs a real wave on the real bench, not a
headless two-node probe. If it does bite, the clean fix is to put the player on a
dedicated collision layer and narrow the DetectionArea mask to only that, so the
props stop being tested at all.

**Verification:** headless probe (since deleted). Sphere radius 250, SightRay
target (0,0,−250), `aggro_range` 250 both as export default and as adopted from
the shape at `_ready()`; `direct_charge_distance` confirmed absent. Direct
pursuit returns full speed (10.8, the chase speed) at 100 units and at 2 units,
passes the input through unchanged inside `MIN_CHARGE_OFFSET`, and leaves PATROL
input untouched. Line of sight at 200 units: true on a clear bench, false with a
wall on the line — so range really has stopped being the gate and cover still is.

**Not verified in play, and not profiled.** See the performance risk above; that
is the main open question on this change.

## 2026-08-03 21:40 — Enemy feelers, corner-slide assist, unstuck recovery

**Changed:**
- `scenes/Enemy.tscn` — new `FeelerLeft` and `FeelerRight` RayCast3Ds at knee
  height (±0.3, 0.4, 0) splaying to (±0.8, 0, −1.0), mask 1, `enabled` left at
  default true so they self-update each physics frame.
- `scenes/Enemy.gd` — `feeler_left` / `feeler_right` via `get_node_or_null`;
  three new consts (`CORNER_SLIDE_STRENGTH` 0.75, `UNSTICK_STUCK_TIME` 0.6,
  `UNSTICK_COOLDOWN` 0.4); `_dodge_cooldown` var reset in `_apply_phase`.
  The old inline direct-charge block became `_line_of_sight_fallback()`, plus new
  `_corner_slide()` and `_unstick()`. `_physics_process` now pipes the desired
  velocity through all three in that order. `direct_charge_distance` 3.0 → 4.0.
- `CLAUDE.md` — §2d gains a "Corner-slide assist and unstuck recovery" section;
  the "Closing the last few metres" bullet rewritten for the new LoS rule and the
  4.0 range.

**Notes:**

**One deliberate deviation from the spec, and it matters.** The spec said
`_unstick` should `reset _stuck_time = 0.0`. It does **not** — it uses its own
`UNSTICK_COOLDOWN` (0.4 s) instead. Reason: `_stuck_time` is shared with
`_advance_patrol()`, which abandons a waypoint at `stuck_timeout` (1.5 s). Zeroing
it every 0.6 s caps it below 1.5 s *permanently*, so that give-up could never fire
again — and it is the only thing that rescues a path which is valid on the navmesh
but impassable to the capsule (the measured 19.7 s → 1.5 s freeze fix from the
original pathfinding work). The enemy would dodge in place forever at a waypoint
it can never reach. With a cooldown instead: a dodge that works clears the counter
naturally via `_drive`, and one that does not still escalates to abandoning the
waypoint. Probe asserts `_stuck_time` survives the dodge and that
`stuck_timeout` > `UNSTICK_STUCK_TIME`. Easy to switch to the literal reset if
you disagree — one line.

**Behaviour change worth noticing:** the LoS fallback now requires line of sight
in **both** branches, where the previous version let "ran out of path" charge
without it. So an enemy that loses its path but cannot see the player no longer
beelines at a remembered position through the clutter. This is what the spec asked
for and I think it is right, but it does make chasers give up more readily in a
dense maze.

Ordering inside `_physics_process` is load-bearing: path velocity →
`_line_of_sight_fallback` → `_corner_slide` → `_unstick`. The two assists run last
so they steer whatever the enemy actually chose to do, path-following or charging.

Added beyond the spec: `add_exception(self)` on both feelers in `_ready()`. Their
origins at ±0.3 sit inside the 0.4-radius capsule, so without it the enemy reads
its own body as the corner ahead and steers in circles. Verified the exception
holds.

**Known issue, flagged not fixed.** Feeler mask 1 also sees other enemies and the
player — everything is on layer 1. A dense swarm will corner-slide off its own
members, which may read as natural crowd flow or as jitter. Same class of issue
the reverted JumpRay had. Documented in §2d.

**Verification:** headless probe (since deleted). Both feelers present with exact
transforms, targets and mask; `direct_charge_distance` 4.0; all three methods
present. Live test on a floor with a wall placed to block only the left feeler:
left hit true / right hit false, self-exception held (collider was the wall),
and `_corner_slide((0,0,−8))` returned **(4.8, 0, −6.4)** — steered right, a ~37°
bend, speed preserved at exactly 8.0. Idle input passes through untouched.
Unstuck: no dodge below threshold; at `_stuck_time` 0.7 it returned a
lateral-dominant vector, forced `_since_repath` > 900, left `_stuck_time` at 0.7,
and suppressed an immediate second dodge via the cooldown.

**Not verified in play.** No windowed run and no test with multiple enemies, so
crowd behaviour — the main risk given the mask-1 issue above — is unmeasured.

## 2026-08-03 21:15 — Pistol overhauled into the 25 s Stasis Cannon

The Pistol is now a single-shot slow weapon on a 25-second cooldown with a blue
charge bar. Scene/script filenames still say "Pistol" — only the behaviour
changed.

**Changed:**
- `scenes/Enemy.gd` — new `@export_group("Debuffs")` with `default_slow_factor`
  (0.4) and `default_slow_duration` (5.0); `_slow_timer` / `_slow_factor` vars;
  `apply_slow(factor, duration)`; timer decrement in `_physics_process`;
  `_current_speed()` multiplies by `_slow_factor` while the timer runs. Also
  added `is_slowed()` / `slow_remaining()` as hooks for a future HUD tell.
- `scenes/Pistol.gd` — removed `magazine_size`, `magazine_count`,
  `infinite_ammo`, `reload_time`, `_reloading`, `ammo_label`, `_bullets`,
  `_mags`, `_update_ammo_label()`, `_reload()`, `_on_reload_finished()`.
  Added `cooldown_time` (25.0), `slow_factor` (0.4), `slow_duration` (5.0),
  `cooldown_bar: ProgressBar`, `_cooldown_timer`. Fire input moved from
  `_process` polling to `_unhandled_input`. `_apply_impact()` now offers
  `apply_slow` before `take_damage` / `apply_hit`, all via `has_method()`.
- `scenes/Player.tscn` — `AmmoLabel` removed; new `GunBar` ProgressBar at
  bottom-right (anchors preset 3, offsets −220/−50/−20/−20, `show_percentage`
  off, `theme_override_styles/fill` → new `StyleBoxFlat` sub-resource with
  `bg_color` `Color(0.2, 0.65, 1, 1)`). Pistol node header updated to
  `node_paths=PackedStringArray("ray", "cooldown_bar")` with
  `cooldown_bar = NodePath("../../../HUD/GunBar")`.
- `CLAUDE.md` — Pistol section rewritten as "Slot 1 — Stasis Cannon"; HUD tree
  line `AmmoLabel` → `GunBar`; §2d gains a "Stasis (`apply_slow`)" paragraph and
  the two new tunables; §3 controls table updated (`slot_1` label, `fire` row,
  and `reload` marked unused).

**Notes:**

**Three consequences of the spec worth knowing, all deliberate:**
1. **`fire_cooldown` was removed too**, though it was not on the removal list. A
   0.15 s gate is entirely subsumed by a 25 s one, and leaving both would leave a
   reader guessing which governs. Nothing overrode it in either .tscn. Say the
   word if you want it back.
2. **The weapon now has no fire animation at all.** The dip/tilt tween belonged
   to the reload system, which the spec removed, and `reload_dip` /
   `reload_tilt_deg` / `_rest_position` / `_rest_rotation` went with it. A 25 s
   cannon firing with zero visual kick will feel weak — recoil is worth adding,
   but inventing one was outside the ask.
3. **The `reload` action (R) is now bound to nothing.** Left defined in
   `project.godot` rather than removed, since editing that file needs an editor
   reload to take effect (§5) and an orphan action is harmless.

Fire input moved to `_unhandled_input` as specced, from `_process` polling. Safe
against the existing conflicts: `Player._unhandled_input` also reads `fire` (to
throw a carried prop) and `PrepCamera` uses it for dragging, but weapons are
holstered — `equipped == false` — in both of those states, so the gate at the top
of the handler resolves it. The event is deliberately **not** consumed, to keep
the change behaviourally minimal.

**Verification:** headless probe (since deleted). `AmmoLabel` gone; `GunBar`
present with the exact offsets, anchors all 1.0, `show_percentage` false, and
fill `bg_color` (0.2, 0.65, 1, 1). `cooldown_bar` **resolved to the real node**,
confirming the `node_paths` marker is right — this is the silent-null trap from
§5, so it was checked explicitly rather than assumed. All five removed properties
confirmed absent. Enemy: patrol speed 8.0 → 3.2 and chase 10.8 → 4.32 (both
exactly 0.4×), speed restored on expiry, and a double hit leaves factor 0.4 and
not 0.16 — i.e. replace, not stack.

Also confirmed GDScript accepts **member variables as default argument values**
(`apply_slow()` with no args resolved to 0.4 / 5.0 from the exports). That was
the one uncertain construct here; it works, so the exports are genuinely the
defaults rather than dead config.

**Not verified in play.** No windowed run: the bar's on-screen appearance, and
whether 25 s feels right, are unchecked. Also note the cannon's `damage` (15) is
still inert against enemies — there is no health system, so the slow is the only
thing a shot actually does to them.

## 2026-08-03 21:06 — REVERTED the 20:59 jump work

User did not like the jump changes. Everything from the 20:59 entry below is
undone. **That entry is left in place deliberately** — this log is append-only,
and a reverted experiment is exactly the kind of thing the next agent needs to
know was already tried. Do not re-implement it without asking.

**Changed:**
- `scenes/Player.gd` — `jump_velocity` back to 6.5 (peak ~1.06 m), original doc
  comment restored.
- `scenes/Enemy.tscn` — `JumpRay` node removed.
- `scenes/Enemy.gd` — removed the `jump_velocity` export, the `jump_ray`
  `@onready`, `_jump_cooldown`, the three `JUMP_*` consts, `_try_jump()` and its
  call site, the cooldown decrement in `_physics_process`, the
  `jump_ray.add_exception(self)` in `_ready()`, and the `_apply_phase` reset.
- `CLAUDE.md` — the "Hopping obstacles" subsection, the `JumpRay` known-issue
  note, and both tunable-list edits reverted to their prior wording.

**Scope:** only the 20:59 jump work. The chase/arrival fixes (20:05), the 45 s
wave interval (20:31) and the Minimap (20:44) were all left in place, and were
explicitly re-checked after the revert.

**Verification:** grepped the whole tree for `jump_ray|JumpRay|_jump_cooldown|
_try_jump|JUMP_` — no hits outside this log. Headless probe (since deleted)
confirmed both scenes still load and both scripts still compile;
`Player.jump_velocity` is 6.5; `JumpRay` is gone and `_try_jump` no longer
exists; and the earlier work survived untouched — agent `radius` 0.5,
`target_desired_distance` 0.5, `path_desired_distance` 0.8,
`direct_charge_distance` 3.0, `_apply_arrive_tuning` present, `HUD/Minimap`
present, `wave_interval` 45.0.

## 2026-08-03 20:59 — Higher player jump + enemies can now hop obstacles

**Changed:**
- `scenes/Player.gd` — `jump_velocity` 6.5 → 8.5. Peak height is
  `v^2 / (2 * gravity)`, so against gravity 20 that is 1.06 m → 1.81 m. Doc
  comment updated to match.
- `scenes/Enemy.tscn` — new `JumpRay` (RayCast3D) child at `Vector3(0, 0.4, 0)`
  (knee height), `target_position` `Vector3(0, 0, -1.2)` (forward, since -Z is
  the capsule's forward), `collision_mask` 1. Left `enabled` at its default true
  so it self-updates each physics frame — unlike `SightRay`, which is aimed by
  hand and so must stay disabled.
- `scenes/Enemy.gd` — new `@export var jump_velocity := 8.5` (deliberately the
  same reach the player has), `@onready var jump_ray` via `get_node_or_null` with
  null guards throughout, `var _jump_cooldown`, and `_try_jump(desired)`.
  Triggers on any of: JumpRay colliding, `_stuck_time > 0.2`, or next path point
  more than 0.3 above the enemy. Gated on `is_on_floor()`, on actually wanting to
  move, and on a 0.6 s cooldown. Cooldown decrements at the top of
  `_physics_process` and resets in `_apply_phase`.
- `CLAUDE.md` — Player movement tunables now carry the 8.5 value and the height
  formula; §2d gains a "Hopping obstacles" subsection and `jump_velocity` in the
  tunables list.

**Notes:**

Placement of `_try_jump()` matters: it runs **after** the desired horizontal
velocity is computed but **before** the handoff to avoidance. It writes only
`velocity.y`, and `_drive()` overwrites x/z while leaving y untouched, so the hop
survives whichever route the horizontal velocity takes — direct drive or the
`velocity_computed` callback. Also note the gravity block at the top of
`_physics_process` zeroes `velocity.y` while grounded, so the jump write has to
come after it, which it does.

Three magic numbers were made named consts (`JUMP_COOLDOWN` 0.6,
`JUMP_STUCK_THRESHOLD` 0.2, `JUMP_STEP_HEIGHT` 0.3) rather than exports, to keep
the export list exactly as specced.

Added beyond the spec: `jump_ray.add_exception(self)` in `_ready()`. The ray
origin at y 0.4 sits **inside** the capsule (which spans y 0..1.8), so without it
the enemy can report its own body as the obstacle ahead and hop forever. Verified
the exception takes effect.

**Known issue, flagged not fixed.** `JumpRay`'s mask 1 also sees other enemies
and the player — everything is on collision layer 1. A tightly packed swarm will
hop against itself, and a chasing enemy will hop on approach to the player. Fix
is a dedicated mask or excluding the enemy layer, but that is a feel call and the
spec pinned mask 1. Documented in §2d as a known issue.

**Verification:** headless probe (since deleted). Confirmed both `jump_velocity`
values are 8.5 and both peaks compute to 1.81 m (player and enemy match exactly);
`JumpRay` present with position (0, 0.4, 0), target (0, 0, -1.2), mask 1;
`_try_jump` and all three consts present. Then drove a live enemy standalone
(`is_action_phase` forced on) into a 0.8 m kerb on a test floor: JumpRay saw the
kerb, the self-exception held (collider was the kerb, not the enemy), and over 90
frames the capsule rose **1.879 m** off its resting height — i.e. it really
jumped and cleared the obstacle, not just twitched.

**Not verified in play.** No windowed run, so how the jump feels for the player
at 8.5, and whether the swarm's hopping reads well in a real crowd on the bench,
are both unchecked.

## 2026-08-03 20:44 — New Minimap radar HUD element

**Changed:**
- `scenes/Minimap.gd` — **new.** A `Control` that paints a top-left tactical
  radar in `_draw()`: dark disc, green border ring + faint crosshair/half-range
  grid, props as rotated grey rectangles at their real footprint, enemies as red
  dots, player as a green arrow at centre pointing up. `_process()` calls
  `queue_redraw()`. Exports: `radar_radius_meters` (30), `radar_pixel_radius`
  (70), `enemy_group`/`prop_group`/`player_group`, `rotate_with_player` (true).
- `scenes/Player.tscn` — added `HUD/Minimap` (Control, `layout_mode = 3`, offsets
  20/20 → 180/180 = 160×160) with the script attached, plus the `7_minimap`
  ext_resource. Inserted **before** the `SettingsMenu` node so it draws under the
  pause overlay.
- `CLAUDE.md` — §2 `Player.tscn` tree gains the Minimap line and a full component
  description. Also corrected the tree diagram, which showed `SettingsMenu` as a
  child of `HUD`; it is actually a child of the Player root.

**Notes:**

`enemy_group` defaults to `"enemies"` to match `WaveSpawner.gd:25` — checked
rather than assumed, since nothing else in the project uses that group name.

Two things I added that were not in the spec, both to avoid known traps:
- `mouse_filter = 2` (IGNORE) on the node. Without it the 160×160 Control sits
  over the top-left corner eating clicks, and the PREPARATION drag tool would go
  dead in that region of the screen.
- Prop footprints are measured once and **cached** by instance id.
  `shape.get_debug_mesh()` rebuilds geometry and there are ~500 draggables;
  measuring per frame inside `_draw()` would have been the most expensive thing
  on the HUD by a wide margin. Only the transform is re-read each frame.

**Verification:** headless probe (since deleted) confirmed `Player.tscn` loads
with `HUD/Minimap` present, script compiled, size 160×160 at offset (20, 20),
`mouse_filter` 2, and all six exports at their defaults. Radar projection checked
against hand-computed expectations — 10 m ahead draws straight up, 10 m right
draws right, 10 m behind draws down, and both hold after a 90° player yaw
(confirming `rotate_with_player`). Footprint measurement returned exact
half-extents (2, 3) for a 4×6 box and fell back to the 2×2 default for geometry-
less input. The probe also caught a real latent bug: `_visual_footprint()` called
`global_transform` on a node possibly outside the tree, which errors and silently
returns identity — guarded now.

**Not verified visually.** No windowed run was done, so the actual on-screen
appearance — colours, scale legibility, whether 30 m is a useful range on a
220-unit bench — is unchecked. Also unresolved by design: the radar stays visible
during PREPARATION, when `PrepCamera` owns the view and the player is not really
in the world. It may want hiding on `phase_changed`, but that was not specified
so it was left alone.

## 2026-08-03 20:31 — Wave interval tightened 60 s → 45 s

**Changed:**
- `scenes/WaveSpawner.gd` — `@export var wave_interval` 60.0 → 45.0. Nothing else
  needed touching: both `_ready()` and `_start_waves()` read the export into
  `_timer.wait_time` via `maxf(wave_interval, 1.0)`, so the new value is picked
  up on the next round start.
- `CLAUDE.md` — §2f now says `wave_interval` (45 s). Also reworked that
  paragraph's example, which was written around the old 60 s value and read
  "minute 1 = 6, minute 2 = 7"; it is now "0:45 = 6, 1:30 = 7, 2:15 = 8", which
  is the same rule stated against the clock rather than against minutes.

**Notes:** Ramp is now noticeably steeper — wave N arrives a third sooner, so the
board reaches `max_live_enemies` (120) correspondingly earlier in a long round.
Not play-tested; no verification run was done for this change.

## 2026-08-03 20:05 — Enemies now close to contact instead of stopping short

Chasing enemies halted ~2.5 m from the player and stood there, and the swarm
jammed in prop gaps it physically fits through. Two independent causes, both on
the `NavigationAgent3D`.

**Changed:**
- `scenes/Enemy.tscn` — `NavigationAgent3D`: `radius` 1.2 → 0.5 (was 3× the 0.4
  capsule, so RVO false-blocked in narrow gaps), `target_desired_distance`
  2.5 → 0.5, `path_desired_distance` 1.5 → 0.8.
- `scenes/Enemy.gd` — new `_apply_arrive_tuning()` sets
  `agent.target_desired_distance` from the state: `chase_arrive_distance` (0.5)
  chasing, `patrol_arrive_distance` (2.0) patrolling. Called on every aggro flip
  in `_update_aggro()` **and** from both branches of `_apply_phase()`, which sets
  state directly and would otherwise leave the tolerance stale after a round
  reset.
- `scenes/Enemy.gd` — `_physics_process()` now overrides the path-following
  velocity with a direct horizontal vector at the player when `state == CHASE`
  and either the agent reports navigation finished, or it is within
  `direct_charge_distance` (3.0) with line of sight. Guarded by new const
  `MIN_CHARGE_OFFSET` (0.2) so a near-zero offset is not normalised into a spin.
- `scenes/Enemy.gd` — new `_sees_player`, cached by `_update_aggro()`. The charge
  check reuses it instead of calling `has_line_of_sight()` again, which forces a
  raycast per call; at `max_live_enemies` 120 that second cast is real budget.
- `scenes/Enemy.gd` — three new exports under the Aggro group:
  `chase_arrive_distance`, `patrol_arrive_distance`, `direct_charge_distance`.
- `CLAUDE.md` — §2d rewritten for the above; four new §5 gotchas
  (`target_desired_distance` is a hard stop not a tolerance; agent `radius` is
  independent of the collision shape; `max_speed` clamps the avoidance result;
  plus the corrected agent radius). Also corrected §2d's stale `move_speed` (25)
  → the actual default 8.0, and `chase_speed_scale` 1.25 → 1.35.

**Notes:**

**Found but deliberately NOT fixed — needs your call.** `Enemy._ready()` does
`agent.max_speed = move_speed` (8.0), but a chaser asks for
`move_speed * chase_speed_scale` (10.8). With avoidance on, RVO clamps the
returned velocity to `max_speed`, so **the chase speed boost has never actually
applied** — charging enemies move at patrol pace. One-line fix is
`agent.max_speed = move_speed * chase_speed_scale`, but it makes enemies
genuinely faster, which is a feel change mid-jam. Documented in §2d as a known
issue.

**Verification:** ran a throwaway `SceneTree` probe (headless, since deleted)
that loaded `Enemy.tscn` and read back the values — confirmed `radius` 0.5,
`target_desired_distance` 0.5, `path_desired_distance` 0.8 against capsule radius
0.4, and that `Enemy.gd` compiles with all three new exports and
`_apply_arrive_tuning()` present. **Not verified in play** — no in-game run was
done, so the actual contact behaviour and the RVO change in tight gaps are
unmeasured. Worth a look before trusting the numbers.

Note `godot` is not on PATH; the binary is at
`D:\downloads\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe`.
`--check-only --script res://scenes/Enemy.gd` gives a **false** failure
("Identifier not found: GameState") because it compiles the script in isolation
without autoloads — load the scene from a probe instead.

## 2026-08-03 19:58 — Added the recap.md handoff-log rule

**Changed:**
- `CLAUDE.md` — §4 AI Workflow Rules now requires appending an entry to
  `recap.md` on every file change, with format, local-time timestamp rule, and
  newest-at-top ordering. Clarified the division of labour: `CLAUDE.md` is the
  current-state doc, `recap.md` is the history.
- `recap.md` — created, with this entry.

**Notes:** No game code was touched. Open threads noted while reading the
project, none acted on: `CoinSpawner.all_coins_collected` is emitted but has no
listener (winning does nothing); there is no health system at all, so enemies
cannot hurt the player and the player cannot kill them — the "die & retry" loop
has no death trigger; the hidden-rule "Order in Disorder" enemy AI is still
unimplemented (patrol + aggro prototype stands in for it).
