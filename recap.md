# Recap — change log

Handoff log for agents and sessions working on this project. **Newest entry at
the top.** Append-only; see `CLAUDE.md` §4 for the format and the rules.

`CLAUDE.md` describes the project as it is now. This file records how it got
there — including the dead ends.

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
