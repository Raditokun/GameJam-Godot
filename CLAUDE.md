# CLAUDE.md

Persistent memory for this project. Read this before making changes; update it
whenever a core feature, scene, weapon, or key binding is added or changed
(see **AI Workflow Rules** below).

## 1. Project Overview

**Macro-Tactics: The Workbench Defense** — a game jam entry on the theme
**"Order in Disorder"**. Godot 4.7 (mono/C#-enabled, GDScript throughout).

A hybrid of sandbox tower defense and FPS, set on a cluttered crafting
workbench seen from a miniature's perspective. The player creates **Order** (a
hand-built maze of clutter) to survive **Disorder** (enemy swarms), while
reverse-engineering the hidden **Order** behind the enemies' seemingly chaotic
movement.

### Core loop (die & retry sandbox)

1. **Preparation Phase — creating Order.** No enemies, battle clock not
   running. The player freely drags, drops and rotates physical scraps (EVA
   foam, 3D-printing rejects, rulers) anywhere on the bench — **no grid, no
   snapping, no placement rules** — to build a maze and form choke points.
2. **Action Phase — surviving Disorder.** The player locks the layout in with a
   keybind, FPS mechanics come online, and swarms flood the table.
3. **Reset Phase.** On death or failure the match snaps straight back to
   Preparation with **the layout left untouched**, so a losing maze can be
   tweaked and retried in seconds.

### The "Order in Disorder" twist (enemy AI — NOT YET IMPLEMENTED)

Enemies do not use ordinary pathfinding. They obey strict hidden rules the
player must deduce by watching (e.g. always steer toward blue objects; always
turn right on hitting a wall). **Aggro mechanic:** an enemy with direct
line-of-sight to the player abandons its rule entirely and rushes them — so a
badly exposed firing position turns the player's structured maze back into
chaos.

Underneath sits a Source-engine (Counter-Strike) style movement controller —
ground/air acceleration, bunny-hopping, air-strafing, crouch — and a two-weapon
combat kit (hitscan pistol, melee sword).

Config: `project.godot`. Main scene: `res://scenes/Main.tscn`. Autoloads:
`GameSettings` (`scenes/GameSettings.gd`) — persisted sensitivity/volume;
`GameState` (`scenes/GameState.gd`) — the round phase machine.

## 1b. Phase System

`scenes/GameState.gd`, autoloaded as **`GameState`**. Everything asks it what
phase the round is in rather than wiring node paths between scenes.
- `Phase.PREPARATION` / `Phase.ACTION`, `is_preparation()`, `is_action()`.
- `start_action()` (F) locks the layout in; `reset_round()` (G, and later death
  / a breached defense) returns to Preparation and increments `attempt`.
  **Enter** (`toggle_action_phase`) flips whichever way the round currently is —
  a test shortcut for bouncing in and out of the fight on one key.
- Signals `phase_changed(new_phase)` and `round_reset`.
- `process_mode = PROCESS_MODE_ALWAYS` so the phase keys work regardless of
  what else is swallowing input.
- Resetting deliberately does **not** move the obstacles — keeping the layout
  is the entire point of the retry loop. It does return the player to the
  spawn pose captured in `Player._ready()`.

`Player.gd` listens for `phase_changed`: PREPARATION holsters both weapons and
drops any carried prop (empty hands = "the click moves furniture now"), ACTION
hands the previously selected slot back. `Player._unhandled_input()` returns
early during PREPARATION, so click / wheel / reach all belong to BuildMode.

## 2. Current Scene & Node Architecture

### `scenes/Main.tscn`
- `WorldEnvironment` — procedural sky, tonemap.
- `DirectionalLight3D` — shadows enabled.
- `Floor` (CSGBox3D, ~110×1×50) + `Ramp` + `Stair0`–`5` — leftover movement-test
  geometry on the ground, well away from the bench.
- `meja` — instance of `meja.tscn` scaled ~74.8×, **the workbench itself**. It
  carries a `freeze = true` instance override: at that scale it is the play
  surface, not a prop, and an unfrozen 25 kg body under the player's feet slides
  around and gets shoved by them. **Tabletop surface sits at y ≈ 73.635**, and
  the scale carries a slight tilt, so the surface drifts ~0.15 across the bench.
- `PrepCamera` (Camera3D + `PrepCamera.gd`) with a `MouseRay` (RayCast3D) child
  — the Preparation Phase tactical view. See §2b.
- **~500 converted props** — the maze-building clutter (crates, furniture, food,
  ore, tunnel pieces…), all direct children of the root. Each is a
  `RigidBody3D` in groups `draggable` + `navmesh_source` with a `Model` child,
  a box `CollisionShape3D` and a `NavigationObstacle3D`, produced by the bulk
  converter in §2e. **They are frozen** (`FREEZE_MODE_KINEMATIC`) and their
  obstacle avoidance is off; `PrepCamera` thaws and un-mutes exactly the one
  being dragged. See §2e for the measurements behind both decisions.
- `bowl_dirty2` — the original drag-and-drop test object, deliberately left
  **fully dynamic** (unfrozen) as the reference the props were tuned against. A
  `RigidBody3D` (mass 3, friction 0.55, bounce 0.1, `continuous_cd`) in the
  `draggable` group, holding
  the gltf as a `Model` child plus a `CollisionShape3D` (CylinderShape3D,
  r 7.887 × h 4.9815, offset +2.49 y). **The scale lives on the `Model` child,
  not on the body** — the mesh is 0.95 × 0.3 × 0.95 at 16.605×, and putting that
  scale on the physics body itself makes for a scaled collider, which Jolt
  handles badly. The body stays at scale 1 and the shape is sized in world units.
- `Player` — instance of `Player.tscn`, above the bench.
- `Navigation` (NavigationRegion3D + `NavBaker.gd`) with its `NavSurface` child,
  `EnemyGoal` (Marker3D, group `enemy_goal`) and an `Enemy` instance — the
  pathfinding prototype. See §2d.

Obstacle scripting (`Obstacle.gd`, `BuildMode.gd`, §2c) still exists but has no
nodes in `Main.tscn` right now — the block layout was reverted while the drag
mechanic is prototyped on the bowl alone.

### 2b. Preparation Phase Camera & Drag Tool

`scenes/PrepCamera.gd` on `Main.tscn/PrepCamera`. A high, steeply-angled
tactical view of the bench, plus the mouse drag-and-drop tool that goes with it.
- Authored at **75° below horizontal**, 125.6 units above the tabletop, aimed
  exactly at the tabletop centre (50.5, 73.6, -4.6). Distance ~130 frames the
  whole bench.
- **Owns the camera and the cursor while in PREPARATION**: `make_current()` plus
  `MOUSE_MODE_VISIBLE`; on lock-in it drops whatever is held, calls
  `clear_current()` and re-captures the mouse for the first-person controller.
  The initial `MOUSE_MODE_VISIBLE` is applied via `call_deferred` because
  `Player._ready()` captures the mouse and this has to win regardless of ready
  order.
- Picking uses `project_ray_origin()`/`project_ray_normal()` from the cursor to
  aim the `MouseRay` RayCast3D each physics frame (the node has `enabled = false`
  — it is driven by hand, not by its own -Z). `target_position` is local, so the
  world direction is converted with `to_local()` — this node is pitched 75°.
- Hold LMB to drag, release to drop; the wheel spins the held object.
- **The drag is entirely physics-based — nothing writes `global_position` or
  `global_rotation`.** A spring-damper force pulls the body's centre toward the
  target, and it is applied **at the point the cursor grabbed** via
  `apply_force(force, arm)`. Because that point is offset from the centre of
  mass, the same force that moves the object also torques it, so a fast drag
  makes it lean and swing on its own — the engine derives the tilt, not the
  script. `apply_central_force()` would slide it around perfectly flat.
  - The error steers the **centre**, not the grab point: measuring to the grab
    point buries a rim-grabbed object by however far the rim sits above its
    origin.
  - `tilt_arm` clamps the lever arm. At this world scale the raw grab offset is
    several metres and the honest torque flips the bowl end over end (measured
    175° before clamping); 0.6 keeps the lean proportional and settleable.
  - `_upright_torque_for()` adds the restoring torque that turns a one-off lean
    into a pendulum, and gravity is switched off while held so the spring is not
    fighting a permanent sag. Gravity and all accumulated momentum come back on
    release, so a flung object really is flung (measured: released at 209 u/s,
    flew 62 units further before landing — and yes, you can fling it clean off
    the bench).
- Tunables: `spring_stiffness` (120), `spring_damping` (14 — critical is ~22, so
  it is deliberately underdamped to leave overshoot), `max_pull` (25, without
  which a distant grab produces a colossal force spike), `hover_height` (3),
  `tilt_arm` (0.6), `upright_torque` (40), `upright_damping` (9),
  `spin_impulse` (45). Measured feel at these values: a fast drag peaks at
  ~38° of lean and settles back toward level once the cursor stops.
- While dragging, the held body is added to the ray's **exceptions** rather than
  having its collision switched off: the exclusion takes effect immediately,
  where a `collision_layer` change has to be deferred and leaves a frame where
  the object blocks its own placement ray.
- `_lowest_point()` measures how far a body's lowest collision point sits below
  its origin (via `shape.get_debug_mesh().get_aabb()`, which works for every
  shape type) so the object rests ON the surface instead of sinking into it.
- Draggables are found by **group** (`draggable`), not node path — tagging more
  clutter is all that is needed to extend this past the bowl. They must be
  `RigidBody3D`; the spring has nothing to push on otherwise.
- **Grabbing thaws, releasing re-freezes.** Converted props sit frozen so 500 of
  them cost nothing; `_try_grab()` sets `freeze = false` (a frozen body ignores
  the carry spring entirely) and `_drop()` does **not** freeze on the spot —
  that would stop a thrown prop dead in mid-air. Released props go into
  `_settling`, and `_update_settling()` freezes each one after it has held still
  (under `refreeze_speed` 1.5) for `refreeze_delay` 0.4 s, or unconditionally
  after `refreeze_timeout` 4 s. The timeout is not optional: a cone-ish hull
  like a christmas tree creeps along the bench's slight tilt at just above the
  rest threshold forever, and one prop left awake is the per-frame cost that
  freezing everything was meant to remove. `_was_frozen` records how the prop
  was found, so the always-dynamic bowl is handed back unfrozen.
  Settling runs before the `current` check, so a prop thrown just before lock-in
  still finishes and freezes itself.
- **Grabbing also switches that prop's RVO avoidance on, and release switches it
  off** — see the cost measurement in §2e.
- Other tunables: `drag_group`, `pick_distance` (900), `refreeze_speed`,
  `refreeze_delay`.

### `scenes/Player.tscn` (`CharacterBody3D`, script `Player.gd`)
```
Player (CharacterBody3D)
├── CollisionShape3D / MeshInstance3D   (capsule; resized at runtime for crouch)
├── Head (Node3D)                       -- pitch pivot, eye height
│   └── Camera3D                        -- yaw is on Player root, pitch on Head
│       ├── RayCast3D                   -- shared aim ray, target 100m forward
│       ├── Pistol  (instance of Pistol.tscn, Slot 1)
│       └── Sword   (instance of sword.tscn, Slot 2)
├── BuildMode (Node3D, BuildMode.gd)  -- Preparation-phase obstacle dragging
├── jump (AudioStreamPlayer3D)
└── HUD (CanvasLayer)
    ├── StatsLabel     -- velocity/pos/angle/bhop-gain debug readout
    ├── PhaseLabel     -- current phase, attempt number and that phase's keys
    ├── AmmoLabel      -- pistol ammo, hidden when sword equipped
    ├── Crosshair      -- drawn Control (Crosshair.gd), auto-hides when mouse not captured
    └── SettingsMenu   (instance of SettingsMenu.tscn) -- Esc pause/settings overlay
```

**Movement/bhop tunables** (`Player.gd`, all `@export`):
`mouse_sensitivity`, `pitch_limit_deg`, `max_speed` (7.0), `walk_speed` (3.5),
`ground_accel`, `friction`, `stop_speed`, `air_accel`, `air_cap` (0.8 — the
air-strafe target-speed clamp), `jump_velocity`, `gravity`, `auto_bhop`,
`crouch_speed`, `crouch_height`, `crouch_eye`, `crouch_transition_speed`,
`units_per_metre` (debug HUD only).

**Prop tunables** (`Player.gd`, `@export_group("Props")`): `push_force` (120 —
see the friction gotcha in §5 before lowering it), `carry_range` (3.0),
`carry_distance` (2.6), `carry_stiffness` (12.0), `carry_max_speed` (12.0),
`carry_break_distance` (3.0), `throw_speed` (9.0).

Weapon slot switching lives in `Player.gd`: `weapons: Array[Node3D]` =
`[Pistol, Sword]`, `equip(slot)` sets exactly one weapon's `equipped = true`
(which drives that weapon's own `visible` and input-processing gate).

### Weapon System

**Slot 1 — Pistol** (`scenes/Pistol.tscn`, script `Pistol.gd`)
- Hitscan: fires via the shared `Head/Camera3D/RayCast3D`, resolved with
  `force_raycast_update()` at the moment of firing (not last physics tick).
- Fires on the `fire` action, gated by `fire_cooldown` (0.15s) and `equipped`.
- Spawns a fading unshaded white beam (`_spawn_tracer`) from the muzzle to the
  hit point (or ray's max range if nothing hit); parented to the current scene
  (not the weapon) so it stays put in the world. Tunables: `tracer_lifetime`
  (0.25s), `tracer_thickness`, `tracer_color`, `tracer_draw_on_top`.
- Ammo: `magazine_size` (15), `magazine_count` (7), `infinite_ammo` (true by
  default — counters display but never drop). Reload (`reload` action) plays a
  tween dip/tilt over `reload_time` (1.0s) and blocks firing meanwhile.
- `ammo_label` (exported `Label` ref → HUD/AmmoLabel) shows `"N / mag \n MAGS m"`.
- **Important:** the `Pistol` node in `Player.tscn` must declare
  `node_paths=PackedStringArray("ray", "ammo_label")` in its `[node]` header or
  these exported NodePaths silently resolve to `null` (see §5 below).

**Slot 2 — Sword** (`scenes/sword.tscn`, script `Sword.gd`, wraps a `.blend`
katana model in `3DModels/`)
- Melee: reuses the **camera's** RayCast3D (not a locally-aimed one — the
  Sword node is rotated ~84° on Y in the scene, so its own -Z does not point
  forward), clipped to `melee_range` (2.75m) via an explicit distance check
  since the shared ray reaches 100m for the pistol.
- Attacks on `fire`, gated by `attack_cooldown` (0.5s) and `equipped`.
- On a connecting hit, calls `take_damage(damage)` (40.0) on the collider if it
  has that method, and emits `hit_target(collider, point)`.
- No baked animation — slash is procedural: a `Tween` swings `rotation`/
  `position` out to a peak offset over `slash_time` (0.1s, quad ease-out), then
  eases back to the authored idle pose over `return_time` (0.2s, sine in-out).
  Peak offsets (`slash_rotation_deg`, `slash_offset`) are tuned for visible
  travel across the screen — small offsets read as an in-place twist, not a
  slash. In-flight tweens are killed before a new swing starts so spamming
  attacks can't strand the blade off-pose.
- Also needs `node_paths=PackedStringArray("ray")` on its `[node]` entry in
  `Player.tscn`.

### 2d. Navigation & the Enemy Prototype

Two independent layers handle the clutter, covering different moments:
**navmesh carving** re-routes the path once an object is put down, and
**agent avoidance (RVO)** steers around it in real time while it is still being
dragged and the mesh has not caught up.

**`Main.tscn/Navigation`** — `NavigationRegion3D` running `scenes/NavBaker.gd`.
- Bake source is **`NavSurface`**, a `StaticBody3D` (collision layer 512,
  mask 0) with a 212 × 2 × 138 box whose top face sits exactly on the tabletop.
  A dedicated layer nothing else masks means it never collides with anything —
  it exists only to be baked.
- The NavigationMesh uses `parsed_geometry_type = STATIC_COLLIDERS` with
  `geometry_collision_mask = 512`. Parsing **colliders, not mesh instances**, is
  required for runtime re-baking: Godot warns that pulling visual meshes back
  off the GPU each bake blocks rendering.
- `source_geometry_mode = GROUPS_WITH_CHILDREN` on group `navmesh_source`.
  **Not `GROUPS_EXPLICIT`** — explicit mode visits only the exact grouped nodes
  and never their children, so the bowl's `NavigationObstacle3D` child was
  invisible to the parser and nothing was ever carved.
- `NavBaker.gd` watches every body in the `draggable` group and re-bakes once a
  moved body has been still for `settle_time` (0.25 s), floored to one bake per
  `min_interval` (0.5 s). Debounced deliberately — a bake is far too expensive
  per-frame during a drag, and re-cutting for a position about to change again
  is wasted work. First bake is synchronous so the enemy has a path on frame 1;
  later ones are threaded. Tunables: `watch_group`, `move_threshold` (1.5),
  `settle_time`, `min_interval`. Emits `navmesh_rebaked`.

**`bowl_dirty2/NavigationObstacle3D`** — carves the bowl out of the navmesh.
- **The carve uses the `vertices` outline, NOT `radius`.** `radius` drives RVO
  avoidance only; leaving `vertices` empty bakes a mesh with no hole in it and
  looks exactly like carving is broken. It is set to a 10-unit octagon.
- `affect_navigation_mesh` + `carve_navigation_mesh` both on.
- The bowl is in group `navmesh_source` so the parser reaches this child. Its
  own collider is on layer 1 and therefore filtered out by the bake mask, so it
  contributes an obstacle without contributing walkable floor.

**`scenes/Enemy.tscn` / `Enemy.gd`** — `CharacterBody3D` capsule (r 0.4, h 1.8,
red) with a `NavigationAgent3D` (avoidance on, agent radius 1.2).
- **Patrols a looping circuit** — every Node3D in the `enemy_goal` group is a
  stop, walked in tree order, wrapping at the end so it never runs out of
  somewhere to be. With a single marker the enemy's own spawn point is added as
  the second stop, so one marker still yields a there-and-back loop rather than
  a dead end; add a second marker and the circuit becomes those two (the
  implicit spawn stop drops out). Group lookup rather than an exported node
  reference — see the `node_paths` gotcha in §5.
- The route is rebuilt as it is walked, so a marker dragged to a new spot is
  followed without restarting the round.
- A stop counts as reached within `arrive_distance` (4.0), compared on the
  horizontal plane only — the markers sit on the tabletop while the capsule's
  origin rides at its feet, and that height gap should not stop it counting as
  arrived. On arrival the repath wait is skipped so the next leg starts on the
  very next frame and there is no visible pause at a corner.
- `waypoint_timeout` (20 s) gives up on a stop and moves to the next one, so a
  waypoint walled in by the player's clutter cannot stall the patrol forever.
- **Two faster give-up paths, because 20 s of standing still reads in-game as the
  enemy hitting an invisible wall.** `_advance_patrol` also abandons a waypoint
  when either (a) the agent reports `is_navigation_finished()` while still
  further than `arrive_distance` away — the path exists but stops short — or
  (b) `_stuck_time` exceeds `stuck_timeout` (1.5 s), meaning it kept asking to
  move and covered no ground. (b) is the only signal that catches a path which is
  valid on the navmesh but runs through something the capsule cannot physically
  pass; `_drive` measures actual displacement rather than `velocity`, since
  `move_and_slide()` reports a healthy velocity for a capsule wedged in a corner.
  `unreachable_grace` (0.75 s) stops the freshly-set-target frames, where
  navigation briefly reports finished, from cycling waypoints instantly.
  Measured on the sealed bench: longest freeze 19.7 s → 1.5 s, ground covered in
  45 s 50 → 140 units.
- With avoidance on, the desired velocity goes to `agent.velocity` and the move
  happens in the `velocity_computed` callback. Both the arrived and moving cases
  funnel through the same call so `move_and_slide()` runs **exactly once** per
  physics frame.
- This is a pathfinding/aggro testbed, not the shipping enemy — the patrol leg
  stands in for the hidden "Order in Disorder" rule the real ones will follow.

**Phase gating.** `is_action_phase` mirrors `GameState` (the global manager owns
the real phase; the flag is kept local so the enemy can be driven standalone in
tests). The whole of `_physics_process` is gated on it: during PREPARATION the
enemy neither moves nor looks, and entering PREPARATION resets it to PATROL and
returns it to its spawn transform, so every retry runs from the same setup.

**Aggro — the "Order in Disorder" twist.** Two conditions, both required:
- `DetectionArea` (Area3D, sphere r 45, layer 0 / mask 1) reports the player —
  found by the `player` group, which `Player.tscn`'s root now carries.
- `SightRay` (RayCast3D at `eye_height` 1.5) reaches the player's chest
  unblocked. Anything else the ray hits first — the bowl, a wall — denies aggro.
  **Standing behind clutter is therefore cover even at point-blank range**,
  which is the entire point of the mechanic.

`has_line_of_sight()` also range-checks explicitly instead of trusting Area3D
membership: enter/exit resolves once per physics frame, so a player who leaves
is still "inside" for one frame — and since the ray is aimed at them *wherever
they are*, that single frame was enough to aggro clean across the bench. The
range is read off the DetectionArea's sphere in `_ready()`, so the radius
visible in the editor is the one the logic uses (`aggro_range` is only a
fallback).

On aggro the enemy abandons the goal marker and re-points the agent at the
player every `chase_repath_interval` (0.2 s), moving at `chase_speed_scale`
(1.25×). Losing sight does not drop it instantly — `aggro_memory` (2 s) keeps
the chase alive, without which the state flickers every time the player clips an
obstacle edge. Emits `aggro_changed(chasing)`; `is_chasing()` reports state.
- Tunables: `move_speed` (25), `chase_speed_scale`, `turn_speed`, `gravity`,
  `goal_group`, `goal_position`, `arrive_distance`, `waypoint_timeout`,
  `repath_interval` (0.4), `player_group`, `aggro_range`, `eye_height`,
  `target_height`, `aggro_memory`, `chase_repath_interval`.

Measured (navigation): 169 units of bench, clear run arrives in 370 frames dead
straight (0.0 lateral stray); with the bowl parked mid-path it arrives in 386
frames, detours 11.2 units sideways, and never gets closer than 11.1 units to
the bowl centre (the bowl's own radius is 7.9).

Measured (patrol loop): 40 s of patrol covers 1000 units at a sustained
25 u/s with 5 direction reversals, a longest stall of 0.00 s, and the enemy
still moving at the end. After an aggro detour the circuit resumes on its own.

Measured (aggro): inert in PREPARATION with the player 8 units away (0.00 units
moved); patrols to the goal when the player is out of range; player 30 units
away with the bowl on the sightline gives `line_of_sight=false` and the ray
reports hitting `bowl_dirty2`, so it keeps patrolling; move the bowl aside and
it switches to CHASE, retargets onto the player and closes 20.6 → 2.4 units in
1.5 s; teleport the player away and it holds the chase through `aggro_memory`
then drops back to PATROL.

### 2e. Bulk Prop Conversion (`tools/`)

`tools/BulkPropSetup.gd` (an `EditorScript`, run with **File → Run** in the
script editor) wraps `tools/PropConverter.gd`, which holds the logic. The split
exists because **`EditorScript` refuses to instantiate outside the editor**, so
putting the logic there would make the whole conversion impossible to test
headlessly; `PropConverter` is a plain `RefCounted` a probe can drive.

Turns every raw prop node dropped into `Main.tscn` into a `bowl_dirty2` clone:

```
PropName (RigidBody3D)   groups: draggable, navmesh_source, scale 1
├── Model                the original node, keeps the authored scale
├── CollisionShape3D     ConvexPolygonShape3D hull, one per mesh
├── CollisionShape3D2    (multi-part props get a compound collider)
└── NavigationObstacle3D footprint-rectangle carve outline + height
```

- **Colliders are convex hulls, not boxes.** An axis-aligned box around
  something irregular — a christmas tree, a rack, a pile of bars — is a huge
  invisible barrier blocking the player and the enemy metres from anything they
  can see. Measured against the old boxes, a hull reaches **30–37% closer** on a
  christmas tree, 14% on a fridge, 8% on a streetlight. Convex specifically, not
  concave/trimesh: a trimesh collider is static-only and illegal on a moving
  RigidBody3D.
- Each MeshInstance3D gets its own hull, so a multi-part prop follows its shape
  instead of one hull swallowing the gaps between parts. 503 props currently
  carry 550 hulls at ~29 points each.
- `create_convex_shape(true, true)` returns points in **mesh** space. The body
  is always scale 1 while the model keeps the authored scale, so every point is
  transformed into body space — skip that and each hull comes out at 1/scale of
  its real size.
- A mesh that yields fewer than 4 hull points is not a solid; those fall back to
  the AABB box rather than leaving the prop with no collider.
- **The navmesh carve outline is the prop's footprint RECTANGLE, in body space** —
  not a circle, and not an octagon. Both alternatives were measured on the real
  bench and both break, in opposite directions:
  - *Circle* (`max(size.x, size.z) * 0.5`, the original) is fine on a crate but
    ruinous on anything long and thin. `banner_triple_white2` is 1.8 units thick
    and 17 long, so it carved a **16.6-unit-wide disc** — a ring of invisible
    wall metres out from a prop you can see straight past. Across 503 props that
    totalled 29,466 sq units of carve on a 29,256 sq unit bench, splitting the
    navmesh into islands: only **24 of 252** sampled cells were reachable from
    the enemy spawn and the goal was 165 units short of reachable.
  - *Octagon inscribed in the footprint* fixes the over-carve (216/252 reachable)
    but cuts the corners, leaving walkable slivers **inside** solid props — the
    agent then paths into `wall_sloped2` and grinds against it.
  - The rectangle is exactly what the collision shapes occupy, so it can neither
    invent phantom wall nor leave floor inside a solid. It rotates with the body,
    so a dragged prop still carves its true footprint.
  `tools/refit_carve_outlines.gd` repairs outlines already saved in `Main.tscn`
  (run it after changing the outline shape; `--check` dry-runs). It edits the
  scene as **text**, rewriting only the `radius`/`vertices` lines, so unique_ids
  and instance overrides survive untouched.

- Candidates are chosen **by type, not name** — anything already a
  `CollisionObject3D`, or a `CSGShape3D` / `Camera3D` / `Light3D` / `Marker3D` /
  `NavigationRegion3D` / `WorldEnvironment`, is skipped. That covers Player,
  Enemy, meja, bowl_dirty2, PrepCamera, EnemyGoal, Navigation, Floor, Ramp and
  the stairs without hard-coding a single one. Re-running is safe.
- The AABB is measured in the **body's** frame, not world space, so a rotated
  prop gets a tight box instead of one inflated by its own rotation.
- `mass = volume * DENSITY` clamped to [0.5, 60], with DENSITY calibrated so the
  bowl's box lands on the 3.0 that was hand-tuned for it. Big props hit the
  clamp — that is deliberate, it keeps the solver sane.
- Child nodes are **named explicitly**: `add_child()` on an unnamed node
  generates the `@CollisionShape3D@12` form, which is unreadable in the tree and
  unfindable by `get_node()`.
- Nodes only survive a save if the scene root `owner`s them; recursion stops at
  an instance boundary, since instanced scenes own their own internals.

**Two settings are performance-critical, both measured on the real 500-prop
bench (60 fps budget is 16.7 ms per physics frame):**

| Configuration | ms/frame |
|---|---|
| Dynamic props, obstacle avoidance on | 63.7 |
| Frozen props, avoidance on | 34.8 |
| Frozen props, **avoidance off** | **16.7** |

- **Freeze.** 500 free rigid bodies resting on the bench never actually sleep —
  250 stayed awake indefinitely with only 3 genuinely moving. Frozen, all of
  them sleep. Continuous CD turned out to be irrelevant either way (63.70 vs
  62.96), so the churn was contact resolution, not CCD.
- **Obstacle avoidance off.** Every `NavigationObstacle3D` with
  `avoidance_enabled` joins the RVO simulation every frame; 500 of them cost
  more than all the rest of the physics combined. Carving is what actually
  routes the enemy, so avoidance is only needed for the single prop mid-drag —
  `PrepCamera` toggles it per grab.

Measured on the live scene: 503 props, 502 on convex hulls (550 hulls), 502
frozen, 503 fully structured; 16.68 ms/frame; navmesh re-bake 30 ms producing
1818 polygons; the enemy still finds a 25-corner route across the cluttered
bench; and a full drag cycle on a christmas tree thaws it, hauls it, then
re-freezes it 0.5 s after release.

**Known rough edge:** tall thin props (christmas trees, streetlights) tip a long
way while dragged — a tighter hull is also a narrower one, so they tip more
easily than they did on their old boxes. The restoring torque scales with mass
but not with the body's actual inertia, which under-corrects tall shapes. Raise
`upright_torque` or lower `tilt_arm` on `PrepCamera` if it reads badly.

### 2c. Obstacles & the First-Person Build Tool

*(Scripts are live; no obstacle nodes are in `Main.tscn` at the moment — the
drag mechanic is being prototyped through `PrepCamera.gd` on the bowl instead.)*

**`scenes/Obstacle.gd`** (`class_name Obstacle extends RigidBody3D`) — a piece
of bench clutter the player repositions.
- `freeze = true` + `freeze_mode = FREEZE_MODE_KINEMATIC`, forced in `_ready()`.
  Frozen so enemies and bullets can never shove a wall out of the maze the
  player built; *kinematic* freeze specifically, because that is what makes
  writing the transform every frame legal — a statically frozen body ignores it.
- Joins the `obstacles` group in `_ready()`, so the enemy AI and spawners can
  read the current layout with no node paths.
- `set_highlighted(on)` tints via emission on a **per-instance duplicate** of
  the shared material — highlighting the shared one lights up all nine.
- `grab()` zeroes `collision_layer`/`collision_mask` (deferred — collision state
  cannot change mid-physics-resolution) so a held piece flies through clutter;
  `release(layer, mask)` restores the exact values captured at grab time.
- `base_offset()` / `radius()` read the collision box, not the mesh, so a
  placement seats on the surface the enemies actually collide with.

**`scenes/BuildMode.gd`** — a `Node3D` child of Player that owns the drag tool.
Reads its own input like the weapons do, and is completely inert outside
PREPARATION (locking in mid-drag force-drops the piece first).
- Camera reached by `get_node("../Head/Camera3D")`, **not** an exported
  NodePath — see the `node_paths` gotcha in §5.
- LMB grabs the highlighted obstacle, LMB again drops it; the piece rides the
  crosshair, easing in at `follow_speed` so it reads as having weight.
- Aiming at a **vertical** face (normal·UP < 0.7) drops the piece to the surface
  underneath the aim point instead of leaving it clinging halfway up the wall.
- Held pieces are forced upright and only yaw — a tipped wall is a ramp, and
  enemies would walk over the maze.
- Tunables: `build_reach` (45 — the bench is enormous at miniature scale),
  `rotate_step_deg` (15), `follow_speed` (18), `grab_debounce` (0.12).

### Physics Props

**`scenes/Prop.gd`** (`class_name Prop extends RigidBody3D`) — the shared script
for anything the player can shove, hit and carry. Weapons and the player find
props by type/`has_method()`, never by node path, so adding a prop is just this
script on a RigidBody3D with collision shapes.
- `apply_hit(point, direction, force)` — knocks the prop; the lever arm is
  clamped to `hit_torque_arm` (0.4 m) so a whack on a table corner can't apply
  metres of leverage and spin it through the floor.
- `take_damage(amount)` — exists only so `Sword.gd`'s `has_method` probe routes
  hits here; there is no health system yet.
- `carried_by` — set by the player. Zeroes `gravity_scale` and `can_sleep`
  while held (a sleeping body ignores the carry spring's velocity writes) and
  restores both on release.

**`scenes/meja.tscn`** — a KayKit kitchen table (3.0 × 1.0 × 2.0 m) as a
`RigidBody3D` + `Prop.gd`. Mass 25, friction 0.6, `continuous_cd` on. Collision
is five hand-fitted boxes measured off the mesh: a 3 × 0.2 × 2 tabletop at
y = 0.9, and four 0.19 m legs at (±1.35, 0.4, ±0.85). The model child must
**not** have `top_level = true` (the FBX instance ships with it) — that makes
the visual ignore the body's transform, so the collision moves and the table
appears to stay put.

**Player-side prop handling** (`Player.gd`):
- `_push_bodies(approach, delta)` — runs after `move_and_slide()`, shoving any
  RigidBody3D the capsule slid against. It takes the *pre-move* velocity, since
  `move_and_slide()` has already slid `velocity` along the contact by then.
  Horizontal-only, scaled by closing speed, applied at the contact point so
  corner hits spin the prop.
- `pick_up_prop()` / `drop_prop()` / `throw_prop()` and `_update_carry(delta)` —
  the held prop is steered by writing `linear_velocity` toward a point in front
  of the camera, not by reparenting, so it keeps colliding with the world
  instead of being shoved through it. The hold point pulls in short of any wall
  ahead, a collision exception with the player stops the prop grinding on the
  capsule, and the prop is dropped if it ends up `carry_break_distance` from the
  hold point (wedged behind geometry).
- Carrying holsters **both** weapons and restores the previous slot on release;
  while carrying, `fire` throws the prop instead of shooting, and reaching for
  any weapon slot drops it first.
- `Pistol.gd` (`damage` 15, `impact_force` 12) and `Sword.gd` (`damage` 40,
  `knockback` 60) both route hits through `apply_hit`/`take_damage`.

## 3. Controls & Key Bindings

Several bindings do double duty: in PREPARATION the click and wheel drive the
build tool, in ACTION they drive the weapons.

| Action | Input | Notes |
|---|---|---|
| `lock_in` | F | Preparation → Action. Locks the layout in |
| `restart_round` | G | Action → Preparation. Keeps the layout, resets the player and the enemy |
| `toggle_action_phase` | Enter | Flips whichever phase is current — test shortcut |
| `move_forward` / `move_back` | W / S | |
| `move_left` / `move_right` | A / D | |
| `jump` | Space | Held for auto-bhop when `auto_bhop = true` |
| `crouch` | C / Ctrl | |
| `walk` | Shift | Slows to `walk_speed`; overridden by crouch if both held |
| `slot_1` | 1 | Equip Pistol |
| `slot_2` | 2 | Equip Sword |
| `slot_next` | Mouse wheel down | Action: cycle weapon forward. Preparation: rotate held object |
| `slot_prev` | Mouse wheel up | Action: cycle weapon backward. Preparation: rotate held object |
| `fire` | Left Click | Preparation: hold to drag a `draggable` object under the cursor. Pistol: shoot. Sword: melee swing. Carrying: throw the prop |
| `interact` | E | Pick up the prop under the crosshair / put it down |
| `reload` | R | Pistol only |
| `ui_cancel` | Esc | Opens/closes SettingsMenu; pauses the tree while open |

## 4. AI Workflow Rules

**Whenever a new core feature, scene, weapon, or key binding is added or
modified, automatically update this `CLAUDE.md` file with concise notes before
considering the task complete.** Keep entries factual and current — prefer
editing the relevant section above over appending a changelog.

## 5. Known Gotchas (learned the hard way — see project memory for more)

- **Hand-edited `.tscn` node references silently break.** Any `[node]` that
  assigns an `@export var x: SomeNodeType` (not a plain `NodePath`) must list
  that property name in `node_paths=PackedStringArray(...)` on the same
  `[node]` line, or Godot stores a raw `NodePath` that never resolves — the
  property stays `null` with no error or warning. Always grep a hand-edited
  `.tscn` for `= NodePath(` and confirm the owning `[node]` header has the
  marker.
- **Editing `project.godot` (autoloads, input actions) while the editor has
  the project open does not take effect until you Project → Reload Current
  Project.** A running editor session keeps its own in-memory copy; a fresh
  engine/CLI run reads the file fine, which can make a bug look fixed in
  headless verification while the open editor still errors.
- **A per-frame impulse smaller than static friction moves a rigid body by
  exactly nothing.** Pushing a prop with repeated small impulses only works if
  each one beats `friction * mass * gravity * delta`; below that the solver
  absorbs all of them and the prop never budges no matter how long you push.
  The 25 kg / 0.6-friction table needs > ~2.5 N-s per frame. Worse, the player
  then jams against what is effectively a wall, and stepping away can release
  the stored contact energy as a 100+ m/s ejection. If a prop ignores you and
  then lurches when you back off, raise `push_force` — don't chase it as a
  collision bug.
- **A `cross(UP)` restoring torque parks an object upside down.** The classic
  "roll this body back level" torque, `body.global_basis.y.cross(Vector3.UP)`,
  has length `sin(lean)` — which is zero at 180° as well as at 0°. A body that
  gets flipped fully inverted therefore sits in a *stable* equilibrium and stays
  there forever, looking like the righting code is broken. Normalise the axis
  and scale it by the lean **angle** instead, and special-case the exactly
  inverted pose (any horizontal axis will start it falling back).
- **`Mesh.create_convex_shape()` returns points in MESH space.** If the physics
  body is unscaled and the model child carries the scale (which is the pattern
  here, because Jolt handles scaled colliders badly), every hull point must be
  transformed into the body's space or the collider comes out at 1/scale — a
  collider far too small, silently, with no error.
- **`NavigationObstacle3D.avoidance_enabled` is on by default and is not free.**
  Every enabled obstacle joins the RVO simulation each frame whether or not any
  agent is near it. At 500 obstacles that measured 34.8 ms/frame against a
  16.7 ms budget — more than everything else in the scene put together. Leave it
  off for static clutter and switch it on only for something actually moving.
- **Hundreds of resting `RigidBody3D`s never go to sleep.** 500 props settled on
  the bench left ~250 permanently awake with only 3 actually moving, at 63 ms a
  frame. If props are meant to stay put, freeze them (`FREEZE_MODE_KINEMATIC`)
  and thaw individually — do not rely on sleep to save you.
- **`global_transform` on a node that was instantiated but never added to the
  tree** errors with `Condition "!is_inside_tree()" is true` and silently
  returns identity. Read `transform` instead when inspecting a scene loaded
  purely to compare against.
- **`NavigationObstacle3D` carves the navmesh with `vertices`, not `radius`.**
  `radius` only feeds RVO avoidance. With `affect_navigation_mesh = true` but an
  empty `vertices` outline, the bake completes cleanly and produces a mesh with
  no hole in it — no error, no warning, and the agent happily paths straight
  through the obstacle.
- **A navmesh carve outline that is not the prop's real footprint is an invisible
  wall.** Sizing the outline off a single radius (`max(x, z) * 0.5`) turns every
  long thin prop into a disc of unwalkable floor many units wider than the thing
  you can see, and hundreds of them merge into barriers that seal the bench into
  islands. Symptom: an enemy walks to a spot with nothing visible, stops dead,
  waits out `waypoint_timeout`, then turns around. Diagnose it by flood-filling
  the bench with the agent's own capsule and comparing that against
  `NavigationServer3D.map_get_path()` — if the physical fill connects but the
  navmesh does not, the carve is the culprit. **Also check the opposite failure:**
  an outline *smaller* than the prop leaves walkable slivers inside solid
  geometry and the agent jams against a wall it was told to walk through.
- **`is_navigation_finished()` does not mean "arrived".** It means the agent has
  run out of path. When a target is unreachable the agent gets a path to the
  closest reachable point, so it reports finished while still far away. Anything
  that treats it as arrival will silently skip work; anything that waits for
  arrival will hang until its timeout.
- **`SOURCE_GEOMETRY_GROUPS_EXPLICIT` does not visit children.** A navmesh bake
  in explicit mode parses only the exact nodes in the group, so an obstacle or
  collider parented under a grouped node is silently skipped. Use
  `GROUPS_WITH_CHILDREN` when the thing to parse is a child.
- **Bake from colliders, not mesh instances, if you re-bake at runtime.**
  `PARSED_GEOMETRY_MESH_INSTANCES` reads geometry back off the GPU and Godot
  warns that it blocks rendering. `PARSED_GEOMETRY_STATIC_COLLIDERS` plus a
  dedicated collision layer for the bake surface avoids it entirely.
- **In a hand-written `.tscn`, the 12-number `Transform3D(...)` sets basis
  ROWS, not columns.** Writing the columns gives you the transpose — for a
  rotation that is the inverse, so a camera pitched to look down at the table
  ends up aiming at the sky.
- **`linear_velocity` does not reflect an `apply_impulse()` until the next
  physics step.** Reading it back on the same frame always shows the old value,
  which makes a working throw or shove look like a no-op in a probe.
- **`Input.mouse_mode` is stubbed under `--headless`** (always reads back
  `VISIBLE`) — anything gated on `MOUSE_MODE_CAPTURED` (crosshair visibility,
  look input) needs a windowed run (`--resolution WxH`, no `--headless`) to
  verify for real.
