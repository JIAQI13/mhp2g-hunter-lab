extends SceneTree

const Session = preload("res://scripts/hunt_session.gd")
# Test timeout only: this does not change either actor's timing or game balance.
const MAX_SIMULATION_CALLS: int = 18000
const FIRST_ATTEMPT_CALLS: int = 9000

class CountingAnimator extends HunterAnimator:
	var calls: int = 0
	func tick(step: float) -> Dictionary:
		calls += 1
		return super.tick(step)

# Deterministic TEST PLAYER, not a replacement or modification of monster AI.
# It observes the last committed actor state and submits only legal held/stick
# snapshots. HunterController alone derives pressed/released and runs actions.
class TestPlayer extends RefCounted:
	var flank: bool = false
	var pulse: int = 0
	var pulse_ticks: int = 0
	var previous_held: int = 0
	var decision: String = "wait"
	var roll_cooldown: int = 0

	func snapshot(player: HunterController, monster: BulldromeController) -> Dictionary:
		roll_cooldown = maxi(0, roll_cooldown - 1)
		var p: Dictionary = player.state
		var m: Dictionary = monster.state
		var offset: Vector3 = m.position - p.position
		offset.y = 0
		var distance: float = offset.length()
		var direction: int = Session._yaw(p.position, m.position)
		var angle: int = absi(((direction - int(p.yaw) + 32768) & 65535) - 32768)
		var held: int = 0
		var mag: int = 0
		decision = "wait_action"
		if player.is_recovering():
			pulse_ticks = 0
			decision = "normal_hurt_recovery"
		elif pulse_ticks > 0:
			held = pulse
			pulse_ticks -= 1
			decision = "hold_button_for_source_decoder"
		elif p.cate == 1:
			if HunterController.CHARGE.has(int(p.sub)):
				held = HunterController.TRIANGLE if int(p.charge) < 82 else 0
				decision = "charge_to_level3_then_release"
		elif p.cate == 2:
			var safe: bool = m.mode in ["hit", "down", "idle"] or (m.mode == "charge" and int(m.phase) == 3)
			held = 0 if safe else HunterController.R
			decision = "exit_guard_to_counter" if safe else "hold_guard"
		elif p.cate == 0 and int(p.sub) in [0, 1, 3, 73, 36, 44]:
			var safe: bool = m.mode in ["hit", "down", "idle"] or (m.mode == "charge" and int(m.phase) == 3)
			if not player.is_drawn():
				held = _press(HunterController.TRIANGLE)
				decision = "draw_weapon"
			elif safe:
				if distance > 165.0 or angle > 2048:
					mag = 127
					decision = "approach_and_face_counter"
				elif m.mode == "down" and int(m.phase) == 3 and int(m.recovery_ticks) > 110:
					held = _press(HunterController.TRIANGLE)
					decision = "charge_down_opening"
				else:
					held = _press(HunterController.CIRCLE)
					decision = "sweep_counter"
			elif flank and m.mode in ["prepare", "turn_attack"]:
				# Walk tangentially around the live monster; no position writes.
				direction = (direction + 16384) & 65535
				mag = 127
				decision = "lateral_spacing"
			elif flank and m.mode == "charge" and distance < 260 and roll_cooldown == 0 and int(p.stamina) >= 150:
				direction = (direction + 16384) & 65535
				mag = 127
				held = _press(HunterController.CROSS, 1)
				roll_cooldown = 45
				decision = "roll_charge_sideways"
			elif angle > 2048:
				mag = 127
				decision = "face_live_threat_before_guard"
			else:
				held = HunterController.R
				decision = "enter_guard"
				# R alone selects guard when drawn; no fabricated command fields.
		previous_held = held
		return {"held":held, "mag":mag, "direction":direction, "bits":0}

	func _press(button: int, duration: int = 3) -> int:
		# Always release for at least one tick between distinct button presses.
		if previous_held & button:
			return 0
		pulse = button
		pulse_ticks = duration - 1
		return button

var pa: CountingAnimator
var ma: CountingAnimator
var player: HunterController
var monster: BulldromeController
var session: Session
var failures: Array[String] = []
var attempts: Array[Dictionary] = []
var simulation_calls: int = 0
var started: int = 0

func _initialize() -> void:
	started = Time.get_ticks_usec()
	pa = CountingAnimator.new()
	ma = CountingAnimator.new()
	_require(pa.load_data() and ma.load_data("res://assets/bulldrome_data.json"), "real exported assets load")
	player = HunterController.new()
	monster = BulldromeController.new()
	player.configure(pa)
	_require(monster.configure(ma), "real monster controller configure")
	pa.tick(0.0)
	var player_lift: float = -minf(pa.world_pose[5].origin.y, pa.world_pose[8].origin.y) * 0.01 + 0.055 if pa.world_pose.size() > 8 else 0.0
	var monster_lift: float = -float(ma.data.get("mesh", {}).get("standing_min_y", 0.0)) * 0.01
	session = Session.new()
	_require(session.configure(player, monster, pa, ma, player_lift, monster_lift), "real paired sourceAPI configure")
	if failures.is_empty():
		_run_attempt(false, FIRST_ATTEMPT_CALLS)
		if session.round_state != "victory" and failures.is_empty():
			# One bounded restart with a different test-player strategy, not a search.
			_run_attempt(true, MAX_SIMULATION_CALLS - simulation_calls)
	var won: bool = session.round_state == "victory" and not monster.state.get("alive", true) and int(monster.state.get("hp", -1)) == 0 and int(player.state.get("hp", 0)) > 0
	_require(won, "normal 1000HP AI round must actually end in living-player victory")
	var results: Dictionary = {
		"engine":Engine.get_version_info().string,
		"success":won and failures.is_empty(), "failures":failures,
		"attempts":attempts,
		"timeout":{"maximum_simulation_calls":MAX_SIMULATION_CALLS, "used":simulation_calls, "policy":"test protection only; at most two rounds; no game timing or balance change"},
		"coverage":{"real_assets":true, "real_controllers":true, "sourceAPI":"HuntSession.configure/reset/tick held/mag/direction/bits", "main_scene":false, "physical_gamepad":false, "synthetic_OS_events":false, "state_edits_during_round":false, "direct_damage_calls":false, "monster_AI":"unchanged real BulldromeController sandbox AI, enabled throughout", "player_bot":"test-only deterministic state-reactive input policy; not monster AI", "original_PSP_equivalence":false, "visual_QA":"skipped: nonvisual sourceAPI test"},
		"performance":{"elapsed_seconds":float(Time.get_ticks_usec()-started)/1000000.0, "godot_static_memory_bytes":OS.get_static_memory_usage(), "godot_static_memory_peak_bytes":OS.get_static_memory_peak_usage(), "cache":"existing imported assets; cold/warm not controlled", "CPU_seconds":"external /usr/bin/time -l; not measured by this script", "peak_process_family_RSS":"external /usr/bin/time -l; not measured by this script", "agent_tokens":"unmeasured; no equivalent before benchmark"},
		"limits":session.limits,
		"interpretation":"Failure establishes only this bounded test player's observed outcome, not that the game cannot be won. No-contact attacks and active evade windows are observations, not proof of a successful dodge."
	}
	var file: FileAccess = FileAccess.open("res://tests/hunt_full_round_results.json", FileAccess.WRITE)
	if file == null:
		_require(false, "result file writable")
	else:
		file.store_string(JSON.stringify(results, "\t"))
		file.close()
	print("HUNT FULL ROUND: success=", won and failures.is_empty(), " calls=", simulation_calls, " hp=", [player.state.get("hp", -1), monster.state.get("hp", -1)], " elapsed=", results.performance.elapsed_seconds)
	quit(0 if won and failures.is_empty() else 1)

func _require(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		print("ASSERT FAIL: ", label)

func _point(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _run_attempt(flank: bool, budget: int) -> void:
	session.reset()
	_require(player.state.hp == 100 and monster.state.hp == 1000 and monster.state.hp_max == 1000 and player.state.hp_max == 100, "default full HP at reset")
	_require(player.state.position == Vector3(0, 0, 250) and monster.state.position == Vector3(0, 0, -350), "unchanged default session spawns")
	_require(monster.ai_enabled and not player.infinite_stamina, "normal AI and finite stamina")
	# Reset already faces both actors toward each other at their legal spawns.
	var bot: TestPlayer = TestPlayer.new()
	bot.flank = flank
	var attempt: Dictionary = {"strategy":"lateral_spacing_and_sweep" if flank else "guard_and_counter", "initial":{"hp":[player.state.hp, monster.state.hp], "positions":[_point(player.state.position), _point(monster.state.position)], "yaws":[player.state.yaw, monster.state.yaw], "AI":monster.ai_enabled, "stamina":player.state.stamina}, "events":[], "phase_curve":[], "counts":{"incoming_attacks":0, "incoming_contacts":0, "guarded_contacts":0, "player_guards":0, "player_damage":0, "monster_hits":0, "monster_damage":0, "evade_window_ticks":0, "roll_entries":0, "charge_entries":0}, "inputs":[]}
	var signature: String = ""
	var previous_action: Array = [int(player.state.cate), int(player.state.sub)]
	var last_input: Dictionary = {}
	var outgoing_ids: Dictionary = {}
	var incoming_ids: Dictionary = {}
	var contact_ids: Dictionary = {}
	var prior_hp: Array = [100, 1000]
	var hp_losses: Array = [0, 0]
	var begin: int = Time.get_ticks_usec()
	for index in range(budget):
		if not failures.is_empty() or session.round_state != "running":
			break
		var snapshot: Dictionary = bot.snapshot(player, monster)
		if snapshot != last_input:
			attempt.inputs.append({"tick":session.ticks + 1, "snapshot":snapshot.duplicate(), "decision":bot.decision})
			last_input = snapshot.duplicate()
		var pc: int = pa.calls
		var mc: int = ma.calls
		var result: Dictionary = session.tick(snapshot)
		simulation_calls += 1
		if result.has("error") or not result.get("ready", false):
			_require(false, "sourceAPI semantic error: " + str(result.get("error", "not ready")))
			break
		_require(pa.calls == pc+1 and ma.calls == mc+1, "one sample per actor per tick")
		_require(player.state.ready and monster.state.ready, "actor animations remain ready")
		_require(monster.ai_enabled and not player.infinite_stamina, "AI and finite stamina remain unchanged")
		_require(not result.space.grounded_body or float(result.space.distance) >= 124.999, "real spatial owner separation")
		var applied: Array = [0, 0]
		for event in result.events:
			var name: String = event.event
			if name in ["missing_animation", "incoming_not_ready"]:
				_require(false, "unsupported/missing source semantics: " + str(event))
			if name == "attack_spawn" and event.actor == "bulldrome":
				attempt.counts.incoming_attacks += 1
				incoming_ids[str(event.attack_id)] = true
			elif name == "incoming_contact":
				attempt.counts.incoming_contacts += 1
				contact_ids[str(event.attack_id)] = true
				if event.status == "guarded":
					attempt.counts.guarded_contacts += 1
				_require(event.status in ["guarded", "pending"], "valid ground contact queue status")
			elif name == "player_guard":
				attempt.counts.player_guards += 1
			elif name == "player_damage":
				attempt.counts.player_damage += int(event.applied_damage)
				applied[0] += int(event.applied_damage)
				_require(event.has("incoming_source"), "incoming damage keeps real attack provenance")
			elif name == "monster_damage":
				var identity: String = "%s/%s" % [event.attack_id, event.target_generation]
				_require(not outgoing_ids.has(identity), "one outgoing hit per attack identity/generation")
				outgoing_ids[identity] = true
				attempt.counts.monster_hits += 1
				attempt.counts.monster_damage += int(event.applied_damage)
				applied[1] += int(event.applied_damage)
				_require(event.has("source") and int(event.damage) > 0, "outgoing damage has real source record")
			if name in ["attack_spawn", "monster_damage", "incoming_contact", "player_damage", "player_guard", "player_dead", "round_end", "monster_reaction", "monster_rage"]:
				var copy: Dictionary = event.duplicate(true)
				copy.tick = session.ticks
				attempt.events.append(copy)
		if not player.attack_collision_allowed():
			attempt.counts.evade_window_ticks += 1
		var action: Array = [int(player.state.cate), int(player.state.sub)]
		if action != previous_action:
			if action[0] == 0 and action[1] in [28, 37, 45]:
				attempt.counts.roll_entries += 1
			if action[0] == 1 and HunterController.CHARGE.has(action[1]):
				attempt.counts.charge_entries += 1
		previous_action = action
		var hp: Array = [int(player.state.hp), int(monster.state.hp)]
		_require(prior_hp[0]-hp[0] == applied[0] and prior_hp[1]-hp[1] == applied[1], "all HP losses accounted by source damage events")
		hp_losses[0] += applied[0]
		hp_losses[1] += applied[1]
		prior_hp = hp
		var next: String = "%s/%d/%d/%d/%s/%s/%d" % [session.round_state, player.state.cate, player.state.sub, player.state.phase, player.state.recovery, monster.state.mode, monster.state.phase]
		if signature != next or session.ticks % 30 == 0 or applied[0] > 0 or applied[1] > 0:
			attempt.phase_curve.append({"tick":session.ticks, "state":next, "hp":hp, "stamina":player.state.stamina, "distance":result.space.distance, "positions":[_point(player.state.position), _point(monster.state.position)], "yaws":[player.state.yaw, monster.state.yaw], "frames":[player.state.frames, monster.state.frames], "charge":player.state.charge, "evade_window":player.state.internal_window, "decision":bot.decision})
			signature = next
	attempt["final"] = {"round":session.round_state, "hp":[player.state.hp, monster.state.hp], "ticks":session.ticks, "stamina":player.state.stamina, "hunter_hits":session.hunter_hits, "monster_hits":session.monster_hits, "total_monster_damage":session.total_monster_damage, "HP_losses":hp_losses, "timeout":session.round_state == "running", "elapsed_seconds":float(Time.get_ticks_usec()-begin)/1000000.0}
	attempt.counts["attacks_without_observed_contact"] = incoming_ids.size() - contact_ids.size()
	attempts.append(attempt)
	print("ATTEMPT ", attempt.strategy, " ", attempt.final, " counts=", attempt.counts)
	_require(session.hunter_hits == int(attempt.counts.monster_hits) and session.total_monster_damage == hp_losses[1], "session outgoing totals match full-round evidence")
	if session.round_state == "victory":
		_require(hp_losses[1] == 1000 and hp_losses[0] < 100 and attempt.events.any(func(e): return e.event == "round_end" and e.outcome == "victory"), "complete 1000HP kill and real victory event")
