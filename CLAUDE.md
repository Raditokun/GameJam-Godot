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
- `meja` — instance of `meja.tscn` scaled ~14.8×, **the workbench itself**. It
  carries a `freeze = true` instance override: at that scale it is the play
  surface, not a prop, and an unfrozen 25 kg body under the player's feet slides
  around and gets shoved by them.
- `Obstacle1`–`9` — the draggable clutter, sitting on the tabletop (surface is
  y ≈ 13.691). Each is a `RigidBody3D` + `Obstacle.gd` with a `MeshInstance3D`
  (BoxMesh) and a `CollisionShape3D` (BoxShape3D), sharing six size variants.
  Converted from the old `JumpBlock` CSGBox3D nodes, which had no node-level
  physics body and so could not be grabbed or scripted.
- `Player` — instance of `Player.tscn`, standing on the bench.

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

### Obstacles & the Build Tool (Preparation Phase)

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
| `restart_round` | G | Action → Preparation. Keeps the layout, resets the player |
| `move_forward` / `move_back` | W / S | |
| `move_left` / `move_right` | A / D | |
| `jump` | Space | Held for auto-bhop when `auto_bhop = true` |
| `crouch` | C / Ctrl | |
| `walk` | Shift | Slows to `walk_speed`; overridden by crouch if both held |
| `slot_1` | 1 | Equip Pistol |
| `slot_2` | 2 | Equip Sword |
| `slot_next` | Mouse wheel down | Action: cycle weapon forward. Preparation: rotate held obstacle |
| `slot_prev` | Mouse wheel up | Action: cycle weapon backward. Preparation: rotate held obstacle |
| `fire` | Left Click | Preparation: grab / place obstacle. Pistol: shoot. Sword: melee swing. Carrying: throw the prop |
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
- **`linear_velocity` does not reflect an `apply_impulse()` until the next
  physics step.** Reading it back on the same frame always shows the old value,
  which makes a working throw or shove look like a no-op in a probe.
- **`Input.mouse_mode` is stubbed under `--headless`** (always reads back
  `VISIBLE`) — anything gated on `MOUSE_MODE_CAPTURED` (crosshair visibility,
  look input) needs a windowed run (`--resolution WxH`, no `--headless`) to
  verify for real.
