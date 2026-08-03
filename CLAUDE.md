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

Config: `project.godot`. Autoloads: `GameSettings` (`scenes/GameSettings.gd`) —
persisted sensitivity/volume; `GameState` (`scenes/GameState.gd`) — the round
phase machine.

### Scene entry points

**`run/main_scene` is `res://scenes/main_menu.tscn`** — the game boots into the
menu, not into the bench. `res://scenes/Main.tscn` is the gameplay scene, reached
from the Start button; it is still perfectly runnable on its own (F6 in the
editor) for testing, and every headless probe in this project loads it directly.

**`scenes/main_menu.tscn`** (script `scenes/Control.gd`) — Start →
`change_scene_to_file("res://scenes/Main.tscn")`; Setting → hides `MainButtons`
and shows the `Setting` panel in place (no scene change), with Exit Setting
reversing it; Credits → `res://scenes/credit_scene.tscn`; Quit →
`get_tree().quit()`.
- **The Start and Setting signals were crossed in the .tscn** — `MainButtons/Start`
  was connected to `_on_setting_pressed` and vice versa — and `Control.gd`'s
  bodies were crossed to match, so the menu worked while every handler did the
  opposite of its name. Both sides are now un-crossed together. If you ever fix
  one side alone the menu silently inverts, which is why this is written down.
- **`credit_scene.tscn` has no way back.** `credit_text.gd/finish_credits()` only
  prints; its `change_scene_to_file` line is commented out and points at
  `res://Scenes/MainMenu.tscn`, which is the wrong case *and* the wrong filename
  (the real path is `res://scenes/main_menu.tscn`). Clicking Credits therefore
  strands the player until they kill the process. Not fixed here because the
  right behaviour — auto-return when the scroll ends, or return on a key press —
  is a design call.

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
- `WaveSpawner` (Node3D + `WaveSpawner.gd`) — the timed wave system. See §2f.
- `CoinSpawner` (Node3D + `CoinSpawner.gd`) — the collectible win condition. See §2g.
- `RoundUI` (CanvasLayer) → `CoinLabel` — top-right "COINS n/10" readout, hidden
  outside ACTION. Separate from the player's own HUD because it is a round-level
  concern, not a first-person one.

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
- **Fallen props are despawned.** `_clean_fallen_props()` runs from `_process`
  once every `DESPAWN_SWEEP_INTERVAL` (1 s) and frees any `draggable` body below
  `DESPAWN_Y_THRESHOLD` (65.0). The drag tool can fling a prop clean off the
  table — deliberate, and measured — and the player or an enemy can shove one
  over the edge; left alone they pile up on the ground geometry 74 units below
  and stay dead weight in the broadphase and in every group scan the minimap, the
  navmesh baker and this sweep itself perform.
  - The threshold is safe by a wide margin, measured on the real scene: the
    tabletop is at y ≈ 73.6, all 522 props sit between **72.37 and 79.02**, and
    the leftover ground geometry is at y = −0.5. The lowest prop clears the
    threshold by 7.37 units, so nothing legitimate is anywhere near it.
  - Order matters in the sweep: if the fallen prop is the one **in hand** it is
    `_drop()`ped first (restoring gravity, the ray exception and the avoidance
    flag, and clearing `_dragged`), and its `_settling` entry is erased, before
    `queue_free()`. Skipping either leaves the tool holding a dead reference or
    `_update_settling` resolving a freed instance id.
  - Guarded with `is_queued_for_deletion()` — a freed node stays in its group
    until the end of the frame, so the next sweep would otherwise free it twice.
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
    ├── GunBar         -- ProgressBar, Stasis Cannon charge; hidden when sword equipped
    ├── Crosshair      -- drawn Control (Crosshair.gd), auto-hides when mouse not captured
    ├── Minimap        -- drawn Control (Minimap.gd), top-left tactical radar
    └── YouDiedLabel   -- centred "YOU DIED" retry prompt, hidden unless dead
└── SettingsMenu       (instance of SettingsMenu.tscn) -- Esc pause/settings overlay
```

(`SettingsMenu` is a child of the Player root, **not** of `HUD` — it brings its
own CanvasLayer.)

### Death & Retry

The "die" half of the die-and-retry loop, which until now had no trigger at all.

- **`Enemy._check_contact_kill()`** calls `Player.die()` when a **chasing** enemy
  gets within `KILL_DISTANCE` (1.15) of the player. Both capsules are radius 0.4
  so they physically stop ~0.8 apart and can never close further; 1.15 fires
  reliably on contact with slack for the tilted bench. Routed through
  `has_method("die")`, so the enemy never depends on the player's concrete type.
- **Gated on CHASE, not proximity.** A patroller brushing past on its way
  somewhere else has not caught anyone. Killing on proximity alone would make the
  hidden-rule routes lethal to *stand near* rather than lethal to be *seen by* —
  the opposite of the mechanic.
- **`Player.die()`** is idempotent (`if is_dead: return`), so a whole swarm
  arriving on the same frame kills once and does not re-trigger the shake. It
  sets `_shake_intensity` to 0.8, shows `HUD/YouDiedLabel`, and drops any carried
  prop — a prop still on the carry spring would otherwise keep being steered by a
  corpse.
- **While dead**, `_physics_process` zeroes horizontal velocity and returns early
  (gravity and `move_and_slide()` still run so the body stays settled), and
  `_unhandled_input` returns after the death block so a corpse cannot shoot,
  reload or grab props. **Mouse look deliberately still works** — that block sits
  above the death check, so the player can look around at what killed them.
- **Camera shake** runs in `_process`, not `_physics_process`: it is purely
  visual, and sampling it at the 60 Hz physics tick reads as a judder rather than
  a rattle. It writes the camera's `h_offset`/`v_offset` rather than its
  transform, so it composes with the head's pitch instead of fighting the look
  controls for the same property. Decays at `delta * 2.0`, so ~0.4 s from 0.8.
- **Retry on F or G.** The death branch sits **before** the
  `GameState.is_preparation()` early return, because a reset triggered elsewhere
  can flip the phase on the same press and the retry keys would then fall through
  and do nothing. The press is **consumed** with `set_input_as_handled()`:
  `restart_round` (G) is also GameState's own reset key during ACTION, and
  letting both fire would run `reset_round()` twice and double-count `attempt`.
- **`round_reset` is connected as well as `_respawn()` calling it.** Anything
  that resets the round — G straight through GameState, a future breached-defence
  trigger — must clear the death screen, or the player ends up alive and mobile
  behind a "YOU DIED" overlay. `_clear_death()` is the shared cleanup.
- Note `GameState.reset_round()` early-returns if already in PREPARATION, so
  dying there would not reset anything. That never happens in practice: contact
  kill is gated on the enemy's `is_action_phase`.

**`scenes/Minimap.gd`** — the top-left radar, a 160 × 160 `Control` at
`HUD/Minimap`, offset (20, 20). Everything is painted in `_draw()` (with
`_process` calling `queue_redraw()`) rather than built from child nodes: the
contents change every frame and most of them are off-radar at any moment.
- Shows the maze as blocky grey rectangles at their real footprint and angle, the
  swarm as red dots, and the player as a green arrow fixed at the centre pointing
  up. `radar_radius_meters` (30) of world maps onto `radar_pixel_radius` (70) px.
- **It exists because of the aggro mechanic.** Enemies only chase what they can
  see, so without a radar the only way to find out where the swarm is would be to
  step out from cover and look — which is precisely the mistake that gets the
  player killed. The radar lets them gather that information without breaking
  line of sight.
- `rotate_with_player` (true) turns the disc so the player's facing is always up.
  The projection takes the player's forward as **-Z**, matching the capsule and
  the enemies, and negates the forward component because screen Y grows downward.
  Prop rectangles rotate by `player_yaw - prop_yaw`, not the other way round.
- Contacts are found by group — `enemy_group` ("enemies", matching
  `WaveSpawner`), `prop_group` ("draggable"), `player_group` ("player") — so
  runtime-spawned enemies appear with no wiring. Enemy dots are skipped when
  `is_queued_for_deletion()`, or a just-cleared wave keeps painting for a frame.
- **Redraw is throttled to `REDRAW_INTERVAL` (0.05 s / 20 Hz)**, not queued every
  frame. A redraw walks the whole `draggable` group, and `get_nodes_in_group()`
  allocates a fresh Array of all 522 props on every call. Measured 0.25 ms per
  redraw on the live bench, so 60 Hz was spending ~15 ms of CPU per second on a
  160 px widget; 20 Hz is a third of that and no staleness is visible at this
  world scale.
- **Prop footprints are measured once and cached** by instance id. Only the
  transform is re-read, which is what a dragged prop changes. Falls back to
  visual bounds, then to a 2 × 2 m block.
- **`_shape_bounds()` reads shape parameters directly — never
  `get_debug_mesh()`.** That call builds an entire debug MESH just to read a
  shape's extents. It was tolerable when each prop had one hull; after the
  multi-convex rebuild (§2e) props carry up to 8, so the first frame a prop
  entered radar range paid for up to 8 mesh builds. Measured over all 522 props:
  **103 ms → 5.1 ms, a 20× speedup**, with the footprints agreeing to a worst
  relative difference of 0.0001. Because the cache fills lazily as props come
  into range, that cold cost used to arrive as intermittent hitches all through a
  round, not just at load — which is what made the radar feel like an FPS drop.
  Box, ConvexPolygon, Sphere, Cylinder and Capsule are all handled; anything else
  returns a zero AABB and falls through to the visual bounds.
- Only **7 of 522** props sit inside the 30 m radar radius on the current bench,
  so the per-frame drawing is trivial — the cost was always the full-group scan
  and the cold measurement, which is what the two fixes above target.
- `mouse_filter = 2` (IGNORE) in the scene. Load-bearing: the radar sits over the
  top-left corner of the screen, and a Control that accepts input there would
  swallow clicks meant for the PREPARATION drag tool.

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

**Slot 1 — Stasis Cannon** (`scenes/Pistol.tscn`, script `Pistol.gd` — node and
files still carry the "Pistol" name from when it was one)
- **One shot every `cooldown_time` (25 s), and it slows rather than kills.** The
  cooldown is the design, not a balance knob: at 25 s the shot is a resource, not
  a weapon. It cannot fight a swarm, only buy time against the one enemy about to
  reach the player, or hold a choke point open long enough to get through it.
  Firing at the wrong moment leaves the player with nothing for 25 s — which is
  what keeps the maze the real answer to the swarm and the cannon just the
  escape hatch.
- Hitscan: fires via the shared `Head/Camera3D/RayCast3D`, resolved with
  `force_raycast_update()` at the moment of firing (not last physics tick).
- Fires on the `fire` action from `_unhandled_input`, gated on `equipped` and
  `_cooldown_timer == 0.0`.
- Spawns a fading unshaded white beam (`_spawn_tracer`) from the muzzle to the
  hit point (or ray's max range if nothing hit); parented to the current scene
  (not the weapon) so it stays put in the world. Tunables: `tracer_lifetime`
  (0.25s), `tracer_thickness`, `tracer_color`, `tracer_draw_on_top`.
- On a hit, `_apply_impact` offers the collider `apply_slow(slow_factor,
  slow_duration)` (0.4 / 5.0), then `take_damage` and `apply_hit` — **all three
  through `has_method()`**, so the weapon knows nothing about the enemy type and
  shooting plain geometry stays a no-op. Enemies have no health system, so only
  the slow currently does anything to them.
- `cooldown_bar` (exported `ProgressBar` ref → HUD/GunBar) shows charge as
  `(1 - timer/cooldown_time) * 100` — a meter **filling back up**, which reads as
  "ready?" far better than a countdown draining away. `_ready()` forces the bar's
  range to 0–100 rather than trusting the scene, since the value is a percentage.
- The cooldown ticks in `_physics_process` whether or not the weapon is equipped,
  so switching to the sword is not a way to dodge it.
- **Important:** the `Pistol` node in `Player.tscn` must declare
  `node_paths=PackedStringArray("ray", "cooldown_bar")` in its `[node]` header or
  these exported NodePaths silently resolve to `null` (see §5 below).
- Ammo, magazines and the reload animation were **removed** in the overhaul — a
  weapon that fires once every 25 s has nothing to reload. `fire_cooldown` went
  with them, being wholly subsumed by the 25 s timer. The `reload` input action
  is still defined in `project.godot` but is now bound to nothing.
- **No fire animation.** The reload dip/tilt tween was the weapon's only movement
  and went with the reload system, so the cannon currently fires with no recoil
  or visual kick at all. Worth adding.

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
red) with a `NavigationAgent3D` (avoidance on, agent radius 0.5).
- **The agent radius tracks the capsule, not the clutter.** It was 1.2 against a
  0.4 capsule, which inflated every enemy's RVO footprint to three times its real
  size and made the swarm refuse gaps between props it physically fits through.
  0.5 keeps a hair of margin over 0.4 without inventing collisions.
- `target_desired_distance` is **driven from the script per state**, not left at
  the authored value — see `_apply_arrive_tuning()` and the arrival gotcha in §5.
  Scene default 0.5; `path_desired_distance` 0.8.
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
- `DetectionArea` (Area3D, sphere **r 250**, layer 0 / mask 1) reports the player
  — found by the `player` group, which `Player.tscn`'s root now carries. 250 is
  **bench-wide**: the table is ~220 units end to end, so proximity is no longer a
  real gate and line of sight is doing all the work. That is the intent — clutter
  is meant to be the only thing hiding the player, not distance. `SightRay`
  reaches the same 250.
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

**Chasing bypasses the navmesh entirely.** `_line_of_sight_fallback()` overrides
the path-following velocity with a direct horizontal vector at the player
whenever a chasing enemy is further than `chase_arrive_distance` (0.5) away —
i.e. essentially the whole chase. **Pathfinding now governs PATROL only.**

That reads like giving up on navigation, and it is, on purpose. The props' carve
outlines fragment the bench into ~27 disconnected navmesh regions (§2e), so for
most of the table there is *no route at all* from an enemy to the player: the
agent takes a path to the nearest reachable point, reports
`is_navigation_finished()` while still far away, and stops dead. That is the
"enemies freeze at a distance" symptom. Driving straight at the player is the
only thing that crosses a fragmented mesh, and the steering layers that run after
it — `_corner_slide()` off the feelers, then `_unstick()` — are what keep it from
walking face-first into the clutter. **If the navmesh fragmentation is ever
fixed** (fewer props, or smaller carve outlines) this is worth revisiting, since
real pathfinding around the maze would be better AI than a beeline.

Note this no longer gates on line of sight, so during the `aggro_memory` (2 s)
tail after the player breaks cover, the enemy keeps charging their last known
position. Skipped inside `MIN_CHARGE_OFFSET` (0.2), where normalising the offset
just makes the enemy spin.

`_apply_arrive_tuning()` still sets `agent.target_desired_distance` from the
state — `chase_arrive_distance` (0.5) chasing, `patrol_arrive_distance` (2.0)
patrolling — called on every aggro flip **and** from `_apply_phase()`, which sets
the state directly without going through `_update_aggro()`. It matters for patrol
and it is what `chase_arrive_distance` means as the direct-pursuit threshold.

**Corner-slide assist and unstuck recovery.** Three steering layers run in a
fixed order at the end of `_physics_process`, each taking the previous one's
`desired` velocity and handing on a new one:
`_line_of_sight_fallback()` → `_corner_slide()` → `_unstick()`. The order is
load-bearing: the two assists run **last** so they steer whatever the enemy
actually decided to do, whether that is following the path or charging the
player.

- **Feelers.** `FeelerLeft` / `FeelerRight` are RayCast3Ds at knee height (y 0.4),
  splayed out from ±0.3 to ±0.8 over 1.0 forward, mask 1. Navmesh paths cut
  corners and RVO only knows about *other agents*, so the capsule scrapes prop
  edges it was routed past; the angled feelers see the edge before the body
  reaches it. Both take `add_exception(self)` in `_ready()` — they start inside
  the capsule's own radius, and without it the enemy reads its own body as the
  corner and steers in circles.
- **`_corner_slide()`** deflects by `global_transform.basis.x` (the enemy's right)
  scaled by `CORNER_SLIDE_STRENGTH` (0.75), then renormalises to speed — so it is
  a blend weight, not an absolute, and can never overpower the direction the agent
  wants. A left hit pushes right and vice versa. **Fires only when exactly one
  feeler is blocked:** both blocked is a dead end, not a corner, and deflecting
  there just picks which wall to grind against — that case belongs to `_unstick`.
  Measured: straight-ahead (0, 0, −8) with only the left feeler blocked becomes
  (4.8, 0, −6.4), a ~37° bend at unchanged speed.
- **`_unstick()`** throws a random lateral dodge once `_stuck_time` passes
  `UNSTICK_STUCK_TIME` (0.6 s), and forces `_since_repath = 999.0` — the route it
  was on leads into the thing it is wedged against, so the same path would walk it
  straight back in.

**`_unstick()` deliberately does not zero `_stuck_time`**, using its own
`UNSTICK_COOLDOWN` (0.4 s) to avoid dodging every frame. Zeroing the shared
counter every 0.6 s would cap it below `stuck_timeout` (1.5 s) permanently, which
silently kills `_advance_patrol()`'s waypoint give-up — the only thing that
rescues a route valid on the navmesh but impassable to the capsule — and would
strand the enemy dodging in place at a waypoint it can never reach. Leaving the
counter climbing means a dodge that works clears it naturally through `_drive()`,
and one that does not still escalates to abandoning the waypoint.

**Known issue:** the feelers' mask 1 also sees **other enemies and the player**,
which are on layer 1. A dense swarm will therefore corner-slide off its own
members. That may read as natural crowd flow or as jitter — give the feelers a
dedicated mask if it looks wrong.

**Contact kill.** `_check_contact_kill()` runs each physics frame and calls
`Player.die()` once a **chasing** enemy is within `KILL_DISTANCE` (1.15). See
"Death & Retry" under `Player.tscn` for the whole loop.

**Falling off the bench.** The first thing `_physics_process` does is free the
enemy if it is below `DESPAWN_Y_THRESHOLD` (65.0, matching `PrepCamera`'s
threshold for props). It sits **above the phase gate deliberately** — an enemy
knocked off during either phase can never path back onto the table, so left alone
it falls forever while still counting against `max_live_enemies` and still being
painted on the radar from somewhere the player cannot reach.

**Stasis (`apply_slow`).** `apply_slow(factor, duration)` scales the enemy to
`factor` of its speed for `duration` seconds; `_current_speed()` applies it, so it
slows patrol, chase and the direct charge alike. Defaults come from
`default_slow_factor` (0.4) and `default_slow_duration` (5.0). Called by the
Stasis Cannon purely through `has_method()`, so the weapon has no dependency on
the enemy type. **A fresh hit replaces the current stasis rather than stacking** —
two shots must not compound into a near-total freeze, and re-arming the full
duration is what a player expects from re-applying a debuff. `is_slowed()` and
`slow_remaining()` are there for a future HUD tell or a shader tint.
- Tunables: `move_speed` (8.0), `chase_speed_scale` (1.35), `turn_speed`,
  `gravity`, `default_slow_factor` (0.4), `default_slow_duration` (5.0),
  `goal_group`, `goal_position`, `arrive_distance`,
  `waypoint_timeout`, `repath_interval` (0.4), `player_group`,
  `aggro_range` (250.0 — fallback only; `_ready()` reads the DetectionArea
  sphere), `eye_height`, `target_height`, `aggro_memory`,
  `chase_repath_interval`, `chase_arrive_distance` (0.5 — doubles as the
  direct-pursuit threshold), `patrol_arrive_distance`.

**Performance risk, unmeasured.** Going from r 45 to r 250 makes each enemy's
`DetectionArea` cover the whole bench, and its mask is 1 — the same layer the
~500 props sit on. At `max_live_enemies` (120) that is on the order of 60,000
area-overlap pairs the broadphase has to maintain, plus a 250-unit `SightRay`
cast per enemy per frame instead of a 45-unit one. The scene was already sitting
exactly on the 16.7 ms budget (§2e), so **this wants profiling with a full wave
before it is trusted.** The clean fix if it does bite is to put the player on a
dedicated collision layer and narrow the DetectionArea mask to only that, so the
props stop being tested at all.

**Known issue, not yet fixed:** `_ready()` sets `agent.max_speed = move_speed`,
but a chasing enemy asks for `move_speed * chase_speed_scale`. With avoidance on
the RVO simulation clamps the returned velocity to `max_speed`, so the chase
speed boost is silently discarded and a charging enemy moves at patrol pace.
`agent.max_speed = move_speed * chase_speed_scale` fixes it, at the cost of
making enemies faster — a feel change, so it is left as a decision.

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
then drops back to PATROL. **These were measured at the old r 45 detection range**
— the "out of range" cases no longer exist at r 250, where only cover denies
aggro.

Measured (250 m aggro): sightline is clear at 200 units on an empty bench and
denied at 200 units with a wall on the line, so range genuinely stopped being the
gate and cover still is. Direct pursuit returns full speed at 100 units and at
2 units, passes the input straight through inside `MIN_CHARGE_OFFSET`, and leaves
PATROL untouched.

### 2f. Wave Spawning (`scenes/WaveSpawner.gd`)

`Main.tscn/WaveSpawner`, a Node3D. Owns every enemy on the board and is driven entirely
off `GameState` — no node paths into the round logic.

**The maths.** Wave 1 is `first_wave_size` (5) enemies the instant ACTION begins; every
`wave_interval` (45 s) another wave arrives carrying `enemies_per_wave` (1) more than the
last, so 0:45 = 6, 1:30 = 7, 2:15 = 8. `max_live_enemies` (120) caps the board so a long
round cannot melt the frame budget.

**Phase integration.** Only `phase_changed` is connected, **not** `round_reset` —
`GameState.reset_round()` emits both, and clearing twice double-reports through
`enemies_cleared`. Entering PREPARATION stops the timer, rewinds the wave counter to 0
and `queue_free()`s every enemy. `clear_enemies()` skips nodes already
`is_queued_for_deletion()`, since a freed node stays in its group until the end of the
frame.

**Spawn points are generated, not placed.** The ring is built from the bounds of
`area_path` — which defaults to `Navigation/NavSurface`, the tabletop. It is deliberately
**not** `Floor`: that is a 292 × 224 slab at y = −0.5, ground geometry ~74 units *below*
the bench, and spawning on its perimeter drops enemies onto the floor under the table.
`fallback_area_path` points at `Floor` only as a last resort. `_area_bounds()` reads a
box collision shape, then a `CSGBox3D.size`, then a `VisualInstance3D` AABB, so it works
against any of the three.

Every candidate is snapped with `NavigationServer3D.map_get_closest_point()` and dropped
if the snap moved it more than `navmesh_tolerance` (2.5) — i.e. it landed inside a prop
or off the walkable area. With `perimeter_inset` 8 and `perimeter_spacing` 6 that yields
**106 valid points** on the current bench. `_ground()` then raycasts each spawn down onto
the actual tabletop, because the navmesh bakes ~0.4 above the surface and the bench is
slightly tilted, so a fixed height would either bury the capsule or drop it from mid-air.

**Safe zone.** `_pick_point()` re-rolls up to `max_spawn_attempts` (24) until the point is
at least `min_player_distance` (10 m) from the player, then falls back to the furthest
candidate available so a player standing in the middle of the ring still gets a wave
rather than nothing. Measured: 400 rolls with the player parked at the bench corner gave
a closest spawn of 14.4 m.

Enemies are positioned **before** `add_child()`: `Enemy._ready()` captures its own spawn
transform to return to on a reset, so adding first and moving after records the wrong
pose. Hand-placed enemies already in the scene are adopted into `enemy_group` by
behaviour (`has_method("is_chasing")`), not node path, so the reset owns them too.

Signals `wave_started(wave, count)` and `enemies_cleared(count)` are there for a HUD.
Helpers: `current_wave()`, `next_wave_size()`, `spawn_point_count()`.

### 2g. Coins & the Win Condition (`scenes/Coin.tscn`, `scenes/CoinSpawner.gd`)

**`Coin.tscn`** — an `Area3D` (layer 0 / mask 1, so it senses the player and can never
push them) wrapping `coin_gold.gltf` at 1.2×, stood on edge and spinning. Children:
`Model`, a 4 m `SphereShape3D` trigger, a white `OmniLight3D` (`Glow`), and a billboarded
`Label3D` (`Prompt`, "Press E") that is hidden until the player is inside the area.

Walking over a coin does nothing — collection is deliberate. `Coin.gd` reads the key in
**`_input`, not `_unhandled_input`**, and calls `set_input_as_handled()`. That ordering is
load-bearing: `Player._unhandled_input()` binds the same `interact` action to prop
pickup, so without consuming the event first one press would both collect the coin and
grab a prop. Handling it in `_input` makes the outcome deterministic rather than
dependent on tree order. Emits `collected(coin)`, then frees itself.

**`CoinSpawner.gd`** places `coin_count` (10) coins on ACTION and owns the counter.

Every candidate clears **two independent checks**, because either alone is insufficient:
1. it snaps onto the navmesh within `navmesh_tolerance` (the player can path to it), and
2. a `clearance_radius` (0.8) sphere at `clearance_height` (1.0) above the grounded point
   touches nothing on layer 1. The sphere sits *above* the floor deliberately, so the
   tabletop never registers and only real obstructions do.
The navmesh check alone is not enough — carve outlines are 2D footprints, so a spot can
be walkable and still sit under overhanging geometry.

**Distance bands are cut by DISTANCE, not by index.** Slicing the sorted candidate list
into equal-sized index slices sounds equivalent but is not: candidates cluster wherever
the bench is open, so a sparse near-region stretches band 0 across a huge range and the
"nearest" coin landed 68 m away. Slicing the distance span instead gives an even ladder.
Measured with `sample_spacing` 4.0: 611 candidates, nearest coin 15.9 m, ladder
16 / 57 / 65 / 104 / 118 / 143 / 158 / 177 / 199 / 229 m, 0 coins buried in geometry.
`sample_spacing` matters a lot — at 7.0 only 173 candidates survive and the nearest coin
is 48 m, because the cluttered corner the player starts in has no legal spot nearby.

Candidates are rebuilt on **every** ACTION, since the player has just rearranged the maze
and last round's list may now be buried. They are deliberately **not** built on the first
synchronised physics frame: the map reports itself synchronised a frame or two before
NavBaker's region is actually registered in it, so a build that early finds nothing and
warns.

Signals `coin_collected(collected, total)` and `all_coins_collected` are the hooks for a
win screen. `all_coins_collected` currently has no listener — winning is not wired yet.

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
- **Each mesh is MULTI-CONVEX decomposed (V-HACD), not reduced to one hull.** A
  single hull is by definition convex, so it fills in every hollow: a table
  becomes a solid block from floor to tabletop and the space underneath — which
  the player should be able to get into and an enemy should path through — stops
  existing. Decomposition keeps the slab and the legs separate. Hulls are still
  kept per-mesh on top of that, so a multi-part prop's compound collider follows
  its parts *and* its concavities. Current bench: **521 props carrying 1804
  hulls**, 290 of them compound (was 569 single hulls).
- **Both decomposition settings matter and the defaults are useless.**
  `MeshConvexDecompositionSettings.max_concavity` defaults to **1.0**, which is
  fully permissive — the decomposer accepts one hull for any shape and the result
  is bit-identical to `create_convex_shape()`. Measured on a synthetic table
  (slab + 4 legs): 1.0 → 1 hull; 0.1 → 4; **0.01 → 6** (slab and legs resolved,
  hollow preserved); 0.001 → 6 (no gain, just slower). `DECOMPOSE_MAX_CONCAVITY`
  is 0.01. `max_convex_hulls` measured identical at 8 and 32, so
  `DECOMPOSE_MAX_HULLS` is 8 — the cheap end of the plateau.
- **`Mesh.convex_decompose()` is not exposed to GDScript in Godot 4.7.** The only
  route is `MeshInstance3D.create_multiple_convex_collisions()`, which works by
  adding a **StaticBody3D child** to the instance it is called on. `_decompose()`
  therefore runs it against a throwaway clone and harvests the shapes — calling
  it on the real model node would leave a StaticBody3D full of colliders parented
  inside every prop in the scene. The shapes are refcounted Resources, so they
  outlive the clone.
- Decomposition returns points in **mesh** space, exactly as
  `create_convex_shape()` did. The body is always scale 1 while the model keeps
  the authored scale, so every point is transformed into body space — skip that
  and each hull comes out at 1/scale of its real size.
- A mesh whose hulls all come back under 4 points is not a solid; that **mesh**
  falls back to its own tight AABB box, rather than being dropped from the
  compound collider and leaving a hole in the prop.
- **Cost, measured on the real bench, in both directions:**
  - *Conversion* is slow — ~200 ms per prop, ~110 s for all 521. That is a
    one-off tool cost, not a runtime one.
  - *Runtime physics did **not** regress*, despite 3.17× the shapes: headless
    physics time went **3.12 → 2.80 ms/frame mean** and got far more stable
    (p95 4.45 → 2.91, max 5.66 → 2.91). The props are frozen and asleep, so the
    extra hulls cost broadphase and memory rather than narrowphase — and the
    tighter hulls appear to remove spurious contacts that caused the old variance.
- **`tools/rebuild_prop_colliders.gd`** re-runs the shape builder over props that
  are **already** converted. `PropConverter.convert_scene()` cannot do this: it
  skips anything already in the `draggable` group, so re-running it over a
  converted scene is a no-op. Headless, `--sample=N` to dry-run a projection,
  `--save` to write. It refuses to save if the scene lost a node (see §5).
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
  scene as **text**, rewriting only the `transform`/`radius`/`height`/`vertices`
  lines, so unique_ids and instance overrides survive untouched.

  The tool now does two things. It **untilts** each obstacle (local basis =
  `body.global_basis.inverse()`), because NavigationObstacle3D only supports Y
  rotation — that cleared all 522 editor warnings. With the frame square to the
  world it writes the outline as the **2D convex hull of every collision point
  projected onto world XZ**, which is tighter than any AABB and correct for a
  prop at any angle. Falls back to the hull's bounding rectangle past
  `MAX_HULL_POINTS` (10) so bake cost stays bounded.

  **Measured consequence, worth knowing:** with outlines finally accurate, the
  props' true footprints total ~33,600 sq units on a 29,256 sq unit bench. The
  walkable navmesh is therefore fragmented into **27 disconnected regions** (largest
  75 sampled cells spanning x 50..150, next 60, then a tail of pockets). Wave-spawned
  enemies patrol normally — measured 4 of 5 moving, mean 17.2 units in 6 s — but
  there is no route across the whole bench, and no navigation setting changes that
  (`agent_radius` 1.5 → 0.4 gives an identical 11/252). It is a level-content limit:
  522 props is more clutter than the table has room for.

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
| `lock_in` | F | Preparation → Action. Locks the layout in. **While dead: retry** |
| `restart_round` | G | Action → Preparation. Keeps the layout, resets the player and the enemy. **While dead: retry** (the press is consumed so the reset runs once) |
| `toggle_action_phase` | Enter | Flips whichever phase is current — test shortcut |
| `move_forward` / `move_back` | W / S | |
| `move_left` / `move_right` | A / D | |
| `jump` | Space | Held for auto-bhop when `auto_bhop = true` |
| `crouch` | C / Ctrl | |
| `walk` | Shift | Slows to `walk_speed`; overridden by crouch if both held |
| `slot_1` | 1 | Equip Stasis Cannon |
| `slot_2` | 2 | Equip Sword |
| `slot_next` | Mouse wheel down | Action: cycle weapon forward. Preparation: rotate held object |
| `slot_prev` | Mouse wheel up | Action: cycle weapon backward. Preparation: rotate held object |
| `fire` | Left Click | Preparation: hold to drag a `draggable` object under the cursor. Stasis Cannon: fire (25 s cooldown). Sword: melee swing. Carrying: throw the prop |
| `interact` | E | Collect a coin when in range (consumes the press), otherwise pick up / put down the prop under the crosshair |
| `reload` | R | **Unused** — still defined in `project.godot`, but the Stasis Cannon has no reload |
| `ui_cancel` | Esc | Opens/closes SettingsMenu; pauses the tree while open |

## 4. AI Workflow Rules

**Whenever a new core feature, scene, weapon, or key binding is added or
modified, automatically update this `CLAUDE.md` file with concise notes before
considering the task complete.** Keep entries factual and current — prefer
editing the relevant section above over appending a changelog. `CLAUDE.md`
describes the project as it is **now**; the history of how it got there lives in
`recap.md` (below).

**Whenever you change any file in this project, append an entry to `recap.md` in
the repo root before considering the task complete.** It is the handoff log that
other agents and sessions read to find out what moved since they last looked, so
it must be written even for small changes and even when `CLAUDE.md` did not need
updating.

- **Newest entry goes at the TOP**, directly under the file's heading, so a
  reader sees the latest state first without scrolling.
- Timestamp every entry `YYYY-MM-DD HH:MM` in **local time**. Get it from the
  system (`Get-Date -Format "yyyy-MM-dd HH:mm"`) — never estimate it, and never
  reuse the timestamp of an earlier entry.
- One entry per task, not per file edit. Entry format:

```markdown
## YYYY-MM-DD HH:MM — <short title of the task>

**Changed:**
- `path/to/file.gd` — what changed and why, in one line.

**Notes:** anything the next agent needs: new tunables, things deliberately left
undone, verification that was or was not run. Omit the line if there is nothing.
```

- Record what was actually done, including work that failed or was reverted.
  A recap that only lists successes is worse than no recap — the next agent will
  redo the dead end.
- Never rewrite or delete existing entries; the log is append-only.

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
- **`Shape3D.get_debug_mesh()` builds a whole mesh just to answer a question
  about extents.** It is the convenient way to size any shape type, and it is
  fine once — but it is not a getter, and calling it per shape per prop costs
  real milliseconds. Measured across the bench's 522 props: 103 ms via
  `get_debug_mesh().get_aabb()` against 5.1 ms reading `size` / `points` /
  `radius` directly, for answers identical to 4 decimal places. Anything that
  measures shapes in bulk should read the parameters.
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
  purely to compare against. Note a node added to the tree *during*
  `SceneTree._initialize()` is also not yet inside it — `await process_frame`
  once before adding anything, or every transform you read is identity.
- **Instantiating `Main.tscn` in a tool and letting one frame process lets the
  game's own scripts edit the scene you are about to save.** `WaveSpawner`
  adopts any hand-placed enemy into `enemies` and `_physics_process` →
  `clear_enemies()` `queue_free()`s it, so a rebuild tool that awaits a frame and
  then `pack()`s writes out a `Main.tscn` with the `Enemy` instance **silently
  missing** — 526 instances become 525 and nothing errors. Do the work and pack
  in the same frame the scene is added, and assert nothing is
  `is_queued_for_deletion()` before saving.
- **`NavigationObstacle3D` carves the navmesh with `vertices`, not `radius`.**
  `radius` only feeds RVO avoidance. With `affect_navigation_mesh = true` but an
  empty `vertices` outline, the bake completes cleanly and produces a mesh with
  no hole in it — no error, no warning, and the agent happily paths straight
  through the obstacle.
- **`NavigationObstacle3D` only supports rotation around Y, and it inherits its
  parent's basis.** Every prop on the bench sits at some angle, so all 522 obstacles
  raised a configuration warning — even a 0.3° tilt trips it, and one prop was at 175°.
  Worse than the warning: the outline is then measured in a tilted frame, so a prop lying
  on its side carved its *height* instead of its width. Give the obstacle a local basis of
  `parent.global_basis.inverse()` so its global basis is identity, then write the outline
  in world axes.
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
- **A navigation map query before its first synchronisation fails outright.** It does not
  return a poor answer, it errors with "query failed because it was made before first map
  synchronization" and hands back a default — so `map_get_closest_point()` answers
  `Vector3.ZERO` and any validation built on it silently passes everything. `_ready()` is
  far too early, and **one physics frame is not enough either**. Poll
  `NavigationServer3D.map_get_iteration_id(map)` until it is non-zero; that is the only
  reliable ready signal.
- **A `queue_free()`d node stays in its groups until the end of the frame.** Anything that
  clears by group and reports a count will re-count the same nodes if it runs twice in one
  frame. Guard with `is_queued_for_deletion()`. Relatedly, `GameState.reset_round()` emits
  **both** `round_reset` and `phase_changed` — connecting a clear-out to both runs it twice.
- **`is_navigation_finished()` does not mean "arrived".** It means the agent has
  run out of path. When a target is unreachable the agent gets a path to the
  closest reachable point, so it reports finished while still far away. Anything
  that treats it as arrival will silently skip work; anything that waits for
  arrival will hang until its timeout.
- **`target_desired_distance` is a hard stop, not a tolerance.** The agent
  reports `is_navigation_finished()` the instant it is within that radius, so any
  body-sized value makes a chaser park exactly that far from the player and never
  touch them — it looks like the enemy losing its nerve, not like a tuning
  number. It was 2.5 here, i.e. enemies halted 2.5 m out. A pursuer needs it
  small (0.5) and a patroller wants it loose, so drive it from the state rather
  than authoring one value in the scene. Note this cuts velocity to zero *before*
  contact, which is why the final approach has to be driven off-path.
- **`NavigationAgent3D.radius` is the RVO footprint and is independent of the
  collision shape.** Setting it larger than the body — 1.2 against a 0.4 capsule
  here — makes avoidance treat each agent as three times its real width, so a
  swarm refuses gaps its members physically fit through and jams in corridors
  that look wide open. Keep it just over the capsule radius.
- **`NavigationAgent3D.max_speed` clamps the velocity avoidance hands back.** A
  speed multiplier applied to the desired velocity (a chase boost, say) is
  silently thrown away if the product exceeds `max_speed`, so the enemy moves at
  the clamp with no error and the multiplier looks like it does nothing.
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
