extends SceneTree

const Boar = preload("res://scripts/bulldrome_controller.gd")
const Events = preload("res://scripts/attack_events.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func target(yaw: int) -> Vector3:
	return Vector3(0,0,500).rotated(Vector3.UP,yaw*TAU/65536.0)

func difference(to: int, from: int) -> int:
	return ((to-from+32768)&65535)-32768

func fixture() -> void:
	lab.reset_hunt()
	lab.monster.sandbox_specials_enabled = false
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,500)

func tick(point: Vector3) -> Dictionary:
	return lab.monster.tick({"position":point,"hp":100,"alive":true}).state

func step() -> Dictionary:
	return lab.hunt.tick({"held":0,"mag":0,"direction":0,"bits":0})

func angle_checks() -> void:
	for pair in [[0,0x3000],[0,0x6000],[0,0x8000],[0,0xa000],[0,0xd000],[65000,500],[500,65000],[0,0],[0,1]]:
		fixture()
		lab.monster.state.yaw = pair[0]
		lab.monster._begin_attack(target(pair[1]),"turn_attack")
		var locked: int = lab.monster.state.turn_target_yaw
		var delta: int = difference(locked,pair[0])
		var rotation: int = 0
		var spawns: int = 0
		for age in range(1,Boar.TURN_TICKS+1):
			var old_yaw: int = lab.monster.state.yaw
			var state := tick(target((pair[1]+22000)&65535))
			var change: int = difference(state.yaw,old_yaw)
			rotation += change
			spawns += state.events.filter(func(e): return e.event == "attack_spawn").size()
			check(absi(change) <= ceili(float(absi(delta))/Boar.TURN_TICKS) and (change == 0 or signi(change) == signi(delta)),"bounded shortest path; no snap/overshoot")
			check(state.turn_target_yaw == locked,"moving target cannot alter committed turn")
			check(state.mode == ("move_recovery" if age == Boar.TURN_TICKS else "turn_attack"),"exact15 damaging turn duration")
		check(rotation == delta and lab.monster.state.yaw == locked and spawns == 1,"single accurate turn, no quadrant loops")
		check(lab.monster.state.cooldown_ticks == Boar.MOVE_RECOVERY_TICKS.turn_attack and lab.monster.state.blend == 6,"explicit movable recovery, local blend only")
		check(lab.monster.state.events.any(func(e): return e.event == "attack_end"),"producer explicitly ends old attack")

func lifetime_checks() -> void:
	fixture()
	var owner := Events.new()
	check(owner.configure(lab.monster_animator.data.combat,"shell24"),"real record/timegate owner")
	var record: Dictionary = owner.read_record(2)
	check(record.delay_byte == 0 and record.duration_byte >> 1 == 122,"source lifetime requires explicit cancellation")
	lab.monster._begin_attack(target(16384),"turn_attack")
	var targets: Array[Dictionary] = [{"identity":"hunter","generation":1,"eligible":true,"volumes":[{"kind":"sphere","a":Vector3.ZERO,"radius":1000.0}]}]
	var hits: int = 0
	for age in range(1,16):
		var state := tick(target(16384))
		hits += owner.tick(state,lab.monster_animator,lab.boar_view.lift,targets).size()
		if age == 1:
			check(hits == 0 and owner.snapshot().attacks[0].state == 1,"spawn only initializes S0")
		if age == 2:
			check(hits == 1 and owner.snapshot().attacks[0].state == 2,"next tick activates once")
	check(hits == 1 and owner.snapshot().attacks.is_empty(),"turn end removes old event and deduplicates damage")
	lab.monster._begin_attack(target(16384),"turn_attack")
	var state := tick(target(16384))
	owner.tick(state,lab.monster_animator,lab.boar_view.lift,targets)
	var notification: Dictionary = state.events[0].duplicate()
	state.events = [{"event":"attack_end","attack_id":state.attack_id}]
	targets[0].generation = 2
	check(owner.tick(state,lab.monster_animator,lab.boar_view.lift,targets).is_empty() and owner.snapshot().attacks.is_empty(),"explicit end precedes same-clip eligible contact")
	state.events = [notification]
	check(owner.tick(state,lab.monster_animator,lab.boar_view.lift,targets).is_empty() and owner.snapshot().attacks.is_empty(),"monotonic identity prevents respawn replay")
	for interruption in ["hurt","death","disabled","player_dead","restart"]:
		fixture()
		lab.monster._begin_attack(target(16384),"turn_attack")
		step()
		check(not lab.hunt.monster_attack_events.snapshot().attacks.is_empty(),"session receives actual turn spawn")
		if interruption == "restart":
			lab.reset_hunt()
		else:
			if interruption == "hurt":
				lab.monster.take_damage(120,0)
			elif interruption == "death":
				lab.monster.take_damage(1000,0)
			elif interruption == "disabled":
				lab.monster.ai_enabled = false
			else:
				lab.controller.state.hp = 0
			step()
		check(lab.hunt.monster_attack_events.snapshot().attacks.is_empty() and lab.monster.state.turn_ticks == 0,"interruption clears turn: "+interruption)
		lab.reset_hunt()
		check(lab.monster.state.alive and lab.monster.state.mode == "idle" and lab.monster.state.turn_ticks == 0,"reopen does not resume turn")

func source_checks() -> void:
	fixture()
	lab.monster.sandbox_motion_enabled = false
	for angle in [0x3000,0x6000,0xa000,0xd000]:
		lab.monster.reset(Vector3.ZERO)
		lab.monster._begin_attack(target(angle),"turn_attack")
		var direction: int = -1 if angle >= 32768 else 1
		tick(target(angle))
		check(lab.monster.state.yaw == (direction*230)&65535,"source first phase yaw230")
		while lab.monster.state.phase != 3:
			tick(target(angle))
		var frames: int = 0
		while lab.monster.state.mode == "turn_attack" and frames < 200:
			var old: int = lab.monster.state.yaw
			var in_window: bool = lab.monster_animator.ge(142) and not lab.monster_animator.ge(164)
			tick(target(angle))
			if in_window:
				check(difference(lab.monster.state.yaw,old) == direction*(2350 if angle in [0x6000,0xa000] else 860),"source late window retained")
			frames += 1
		check(lab.monster.state.mode == "idle" and lab.monster.state.cooldown_ticks == 30,"source full END and cooldown retained")
	lab.monster.sandbox_motion_enabled = true

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	angle_checks()
	lifetime_checks()
	source_checks()
	print("TURN PACING: ",checks," checks / ",failures.size()," failed; no API; reacquire/combo/walk coverage owned by test_release_tracking and test_tactics_continuity")
	quit(0 if failures.is_empty() else 1)
