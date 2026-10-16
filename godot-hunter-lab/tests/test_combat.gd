extends SceneTree

const Animator = preload("res://scripts/hunter_animator.gd")
const Controller = preload("res://scripts/hunter_controller.gd")
const Combat = preload("res://scripts/hunter_combat.gd")
const AttackOwner = preload("res://scripts/attack_events.gd")
var animator: HunterAnimator
var controller: HunterController
var combat: Combat
var checks: Array = []
var failures: Array = []
var gallery: Array = []
var default_cube: Array = []
var ticks: int = 0
var lift: float = 0.0

func check(label: String, condition: bool) -> void:
	if condition:
		checks.append(label)
	else:
		failures.append(label)
		print("ASSERT FAIL: ",label)

func _initialize() -> void:
	animator = Animator.new()
	check("real standalone assets load",animator.load_data())
	if not animator.data.is_empty():
		controller = Controller.new()
		controller.configure(animator)
		combat = Combat.new()
		check("combat schema accepted",combat.configure(animator.data.combat))
		_run()
	var result: Dictionary = {"engine":Engine.get_version_info().string,"passed":checks.size(),"failed":failures.size(),"checks":checks,"failures":failures,"simulation_calls":ticks,"gallery":gallery,"default_cube":default_cube,"profiles":animator.data.get("combat",{}).get("neutral_profile",{}),"record_table":animator.data.get("combat",{}).get("records",{}),"shape_tables":animator.data.get("combat",{}).get("shape_tables",{}),"source":animator.data.get("combat",{}).get("sources",{}),"interpretation":{"damage":"binary32 each operation; trunc toward zero; raw100 is NOT displayed attack","lifetime":"S0 state0 countdown no-op then initialized waiting; active [D+1,D+L+1); delay u8 then signed clamp; hard/slow post-consumption extension implemented","geometry":"full animator.world_pose * source points, then .01, lift, actor yaw and position*.01; no visual sword .87 or orthonormalization","dedup":"sandbox living event x target generation; simplification of original target16 ring","respawn":"sandbox90 simulation calls, not render seconds","gallery":"large explicit fixture checks all variants; does NOT claim each variant reaches default small cube","unknown":"original task branches/Hz/VFPU pose commit and full monster feedback/skills/equipment/element/critical/special parts not equivalent; source observations static, no original game run"},"visual_qa":"skipped: nonvisual owner task"}
	var output = FileAccess.open(preload("res://tests/result_output.gd").path("res://tests/combat_test_results.json"),FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(result,"\t"))
	print("COMBAT TESTS ",checks.size()," passed / ",failures.size()," failed; ",ticks," simulation calls")
	quit(0 if failures.is_empty() else 1)

func fresh(large: bool = true) -> void:
	controller.reset()
	combat.reset()
	combat.target_center = Vector3.ZERO if large else Vector3(0,0.9,2.3)
	combat.target_half_size = Vector3(100,100,100) if large else Vector3(0.75,0.9,0.75)
	lift = 0

func step(held: int = 0) -> Dictionary:
	ticks += 1
	var snapshot: Dictionary = controller.tick(held,0,0)
	return {"actor":snapshot,"events":combat.tick(snapshot,animator,lift)}

func spawns(snapshot: Dictionary) -> Array:
	var found: Array = []
	for event in snapshot.events:
		if event.event == "attack_spawn":
			found.append(event)
	return found

func run_action(sub: int, level: int = 0, large: bool = true, charger: bool = false) -> Dictionary:
	fresh(large)
	controller.state.flags410 |= 8
	controller.force_action(1,sub)
	controller.state.level = level
	var notifications: Array = []
	var hit_events: Array = []
	for index in range(500):
		var held: int = Controller.TRIANGLE if charger and controller.state.charge < 90 and controller.state.cate == 1 and Controller.CHARGE.has(controller.state.sub) else 0
		var result: Dictionary = step(held)
		notifications.append_array(spawns(result.actor))
		for event in result.events:
			if event.event == "hit":
				hit_events.append(event)
		if controller.state.cate == 0 and controller.state.sub == 0:
			break
	return {"sub":sub,"level":level,"spawns":notifications,"hits":hit_events,"completed":controller.state.cate == 0 and controller.state.sub == 0}

func _run() -> void:
	var ids: Array = [1,2,3,4,5,91,92,93]
	var scales: Array = [100,100,100,100,100,110,120,130]
	var damages: Array = [46,36,48,2,2,71,96,143]
	for i in range(ids.size()):
		check("neutral damage record%d scale%d =%d" % [ids[i],scales[i],damages[i]],combat.damage_for(ids[i],scales[i]) == damages[i])
	check("no rounding71.5",combat.damage_for(91,110) == 71)
	check("unknown record produces no damage",combat.damage_for(999) == 0)
	var malformed: Dictionary = animator.data.combat.duplicate(true)
	malformed.shapes["0"][0].kind = 2
	check("unknown kind fails configure",not combat.configure(malformed) and combat.damage_for(2) == 0)
	malformed = animator.data.combat.duplicate(true)
	malformed.shape_tables["0"].terminated = false
	check("unterminated shape table rejected",not combat.configure(malformed))
	malformed = animator.data.combat.duplicate(true)
	malformed.shape_tables["0"].supported_geometry = false
	check("unsupported selector status rejected",not combat.configure(malformed))
	malformed = animator.data.combat.duplicate(true)
	malformed.shapes["0"][0].point_a[0] = 1e100
	check("non binary32 point fails before Vector3 allocation",not combat.configure(malformed))
	malformed = animator.data.combat.duplicate(true)
	malformed.shapes["0"][0].bone = 125
	check("control geometry not guessed",not combat.configure(malformed))
	malformed = animator.data.combat.duplicate(true)
	malformed.records["2"].delay_byte = 1.5
	check("fractional raw byte rejected",not combat.configure(malformed))
	malformed = animator.data.combat.duplicate(true)
	malformed.neutral_profile.raw_attack = 480
	check("UI attack cannot silently replace raw100",not combat.configure(malformed))
	check("restore actual combat",combat.configure(animator.data.combat))
	var subs: Array = [0,1,2,3,4,5,6,7,8,9,10,11,12,14,15,16,17,18,19,20,21,22,24,25,26,27,28,29]
	for sub in subs:
		var result: Dictionary = run_action(sub,0,true,Controller.CHARGE.has(sub))
		var record: int = 2 if Controller.SWEEP.has(sub) else 1 if Controller.UPS.has(sub) else 4 if sub == 4 else 93 if Controller.CHARGE.has(sub) and not sub in [20,24] else 3
		check("GS%d real gallery completes" % sub,result.completed)
		if sub == 3:
			check("bounce gallery has no spawn/no damage",result.spawns.is_empty() and result.hits.is_empty())
		else:
			check("GS%d exactly one producer spawn correct record%d" % [sub,record],result.spawns.size() == 1 and result.spawns[0].record == record)
			check("GS%d large fixture exactly one hit" % sub,result.hits.size() == 1)
			if result.hits.size() == 1:
				var spawn: Dictionary = result.spawns[0]
				check("GS%d creation fields and frozen scale" % sub,spawn.has("start") and spawn.has("blend_count") and spawn.has("attack_id") and result.hits[0].attack_scale == spawn.attack_scale and result.hits[0].attack_id == spawn.attack_id)
				check("GS%d damage agrees source record/level" % sub,result.hits[0].damage == combat.damage_for(record,130 if record == 93 else 100))
		gallery.append(result)
	for sub in [26,27,28,29]:
		for level in range(4):
			var result: Dictionary = run_action(sub,level)
			check("release%d level%d record/scale production" % [sub,level],result.spawns.size() == 1 and result.spawns[0].record == [3,91,92,93][level] and result.spawns[0].attack_scale == [100,110,120,130][level])
			check("release%d level%d hits once correct damage" % [sub,level],result.hits.size() == 1 and result.hits[0].damage == [48,71,96,143][level])
	for sub in [0,26]:
		for level in (range(4) if sub == 26 else range(1)):
			var result: Dictionary = run_action(sub,level,false)
			default_cube.append(result)
			check("default cube real sweep/release%d level%d hits" % [sub,level],result.hits.size() == 1)
	var kick: Dictionary = run_action(99)
	check("sheathed99 record5 not4 and damage2",kick.spawns.size() == 1 and kick.spawns[0].record == 5 and kick.hits.size() == 1 and kick.hits[0].damage == 2)
	fresh()
	var select_records: Array = []
	for i in range(40):
		var result: Dictionary = step(Controller.SELECT if i == 0 else 0)
		select_records.append_array(spawns(result.actor))
	check("real sheathed SELECT produces record5 damage2 without drawing",select_records.size() == 1 and select_records[0].record == 5 and combat.hits == 1 and combat.last_damage == 2 and not controller.is_drawn())
	for category in [0,2]:
		for sub in (Controller.NORMAL if category == 0 else Controller.GUARD):
			fresh()
			controller.force_action(category,sub)
			var count: int = 0
			for index in range(100):
				count += spawns(step(Controller.R if category == 2 else 0).actor).size()
			check("nonattack%d/%d no manufactured damage" % [category,sub],count == 0 and combat.hits == 0)
	_spatial_checks()
	_lifetime_checks()
	_target_checks()
	_input_checks()

func _spatial_checks() -> void:
	for fixture in [Vector3(1000,0,0),Vector3(0,0.9,-5)]:
		fresh(false)
		combat.target_center = fixture
		controller.state.flags410 |= 8
		controller.force_action(1,0)
		for i in range(70):
			step()
		check("real empty swing/wrong target direction " + str(fixture),combat.hits == 0)
	fresh(false)
	controller.state.yaw = 32768
	controller.state.target = 32768
	controller.state.flags410 |= 8
	controller.force_action(1,26)
	for i in range(45):
		step()
	check("opposite actor yaw misses default cube",combat.hits == 0)
	var low := Vector3(-1,-1,-1)
	var high := Vector3(1,1,1)
	check("capsule expanded-AABB corner false positive rejected",AttackOwner.segment_box_distance_squared(Vector3(1.4,1.4,-0.5),Vector3(1.4,1.4,0.5),low,high) > 0.5*0.5)
	check("capsule exact tangent included",is_equal_approx(AttackOwner.segment_box_distance_squared(Vector3(1.5,0,-2),Vector3(1.5,0,2),low,high),0.25))
	check("sphere corner exact distance",is_equal_approx(AttackOwner.segment_box_distance_squared(Vector3(2,2,2),Vector3(2,2,2),low,high),3.0))
	check("segment crossing AABB zero",AttackOwner.segment_box_distance_squared(Vector3(-3,0,0),Vector3(3,0,0),low,high) == 0)
	var bone := Transform3D(Basis(Vector3(2,0,0),Vector3(0,3,0),Vector3(0,0,4)),Vector3(10,20,30))
	var actor: Dictionary = {"yaw":16384,"position":Vector3(100,200,300)}
	var point: Vector3 = AttackOwner.world_point(bone * Vector3(1,2,3),actor,0.5)
	check("full nonorthogonal bone basis/units/lift/yaw/actor translation",point.is_equal_approx(Vector3(1.42,2.76,2.88)))

func fixture_spawn(record: int = 3, blend: int = 0, start: int = 0) -> Dictionary:
	fresh()
	controller.state.flags410 |= 8
	controller.force_action(1,26)
	var result: Dictionary = step()
	var spawn: Dictionary = spawns(result.actor)[0].duplicate(true)
	spawn.record = record
	spawn.blend_count = blend
	spawn.start = start
	combat.reset()
	var snapshot: Dictionary = result.actor.duplicate(true)
	snapshot.events = [spawn]
	combat.tick(snapshot,animator,0)
	return snapshot

func isolated_step(snapshot: Dictionary) -> Array[Dictionary]:
	ticks += 1
	snapshot.events = []
	animator.tick(0)
	return combat.tick(snapshot,animator,0)

func _lifetime_checks() -> void:
	for tuple in [[0,0,17],[1,0,18],[1,8,14],[0,10,12],[0,32,1],[0,300,123],[-101,0,18],[101,0,18],[0,65536,17],[0,256,0]]:
		var snapshot: Dictionary = fixture_spawn(3,tuple[0],tuple[1])
		check("initial delay C remainder/u8/signed B%d S%d" % [tuple[0],tuple[1]],combat.attack_events.snapshot().attacks[0].delay == tuple[2] and combat.hits == 0)
		var active: Array = []
		for index in range(tuple[2]+7):
			isolated_step(snapshot)
			if not combat.attack_events.snapshot().attacks.is_empty() and combat.attack_events.snapshot().attacks[0].state == 2:
				active.append(index+1)
		check("lifetime exact [D+1,D+L+1) B%d S%d" % [tuple[0],tuple[1]],active == [tuple[2]+1,tuple[2]+2,tuple[2]+3,tuple[2]+4,tuple[2]+5])
		check("one event three shapes hits once B%d S%d" % [tuple[0],tuple[1]],combat.hits == 1)
	var snapshot: Dictionary = fixture_spawn()
	for i in range(18):
		isolated_step(snapshot)
	animator.set_animation(1428,0,0)
	for i in range(4):
		isolated_step(snapshot)
	check("same animation reset retains creation identity and dedup",combat.hits == 1)
	snapshot = fixture_spawn()
	snapshot.primary = 1406
	isolated_step(snapshot)
	check("changed animation retires old attack",combat.attack_events.snapshot().attacks.is_empty() and combat.hits == 0)
	snapshot = fixture_spawn()
	combat.target_center = Vector3(1000,0,0)
	for i in range(21):
		isolated_step(snapshot)
	isolated_step(snapshot)
	check("last decrement duration0 still active",combat.attack_events.snapshot().attacks[0].state == 2 and combat.attack_events.snapshot().attacks[0].duration == 0)
	combat.target_center = Vector3.ZERO
	# Above last active call missed; next old0 must disable, not produce damage.
	isolated_step(snapshot)
	check("old duration0 disables before collision",combat.hits == 0 and combat.attack_events.snapshot().attacks.is_empty())
	snapshot = fixture_spawn()
	combat.target_center = Vector3(1000,0,0)
	for i in range(21):
		isolated_step(snapshot)
	var before: int = combat.hits
	combat.target_center = Vector3.ZERO
	isolated_step(snapshot)
	check("last duration1 to0 call collision eligible",combat.hits == before+1 and combat.attack_events.snapshot().attacks[0].duration == 0)
	snapshot = fixture_spawn()
	snapshot.hard = 1
	isolated_step(snapshot)
	check("hard does not freeze startup and extends future lifetime",combat.attack_events.snapshot().attacks[0].delay == 16 and combat.attack_events.snapshot().attacks[0].duration == 6)
	snapshot.hard = 0
	snapshot.slow = 1
	isolated_step(snapshot)
	check("slow post-consumption nonzero extends",combat.attack_events.snapshot().attacks[0].duration == 7)
	snapshot.slow = 0
	isolated_step(snapshot)
	check("last slow1 consumed0 does not extend",combat.attack_events.snapshot().attacks[0].duration == 7)
	snapshot = fixture_spawn(91)
	snapshot.attack_scale = 130 # Actor后续状态不是攻击创建快照。
	for i in range(18):
		isolated_step(snapshot)
	check("combat never guesses scale from current actor",combat.last_damage == 65)
	snapshot = fixture_spawn()
	var identity: int = combat.attack_events.snapshot().attacks[0].attack_id
	snapshot.events = [{"event":"attack_spawn","record":3,"primary":1428,"start":0,"blend_count":0,"attack_scale":100,"attack_id":identity}]
	combat.tick(snapshot,animator,0)
	check("replayed production identity cannot manufacture a second attack",combat.attack_events.snapshot().attacks.size() == 1)
	snapshot.events = [{"event":"attack_spawn","record":3,"primary":1428}]
	combat.tick(snapshot,animator,0)
	check("incomplete legacy notification does not guess identity or scale",combat.attack_events.snapshot().attacks.size() == 1)
	var zero_delay: Dictionary = animator.data.combat.duplicate(true)
	zero_delay.records["3"].delay_byte = 0
	var owner := AttackOwner.new()
	check("raw delay0 bypasses B/S adjustment",owner.configure(zero_delay) and owner.initial_delay(3,99,300) == 0)

func _target_checks() -> void:
	var snapshot: Dictionary = fixture_spawn()
	combat.target_hp = 10
	var lethal: Array = []
	for i in range(18):
		lethal = isolated_step(snapshot)
	check("hit payload and broken ordered events",lethal.size() == 2 and lethal[0].event == "hit" and lethal[0].damage == 48 and lethal[0].applied_damage == 10 and lethal[0].hp == 0 and lethal[0].position is Vector3 and lethal[0].has("part") and lethal[1].event == "broken" and lethal[1].target_generation == lethal[0].target_generation)
	check("lethal hit damage48 but applied10",combat.last_damage == 48 and combat.total_damage == 10 and combat.target_hp == 0 and not combat.target_alive and combat.respawn_remaining == 90)
	var before: int = combat.hits
	for i in range(89):
		isolated_step(snapshot)
	check("dead target no damage and not early respawn",combat.hits == before and not combat.target_alive and combat.respawn_remaining == 1)
	var events: Array = isolated_step(snapshot)
	check("90 simulation calls respawn new generation",combat.target_alive and combat.target_hp == 500 and combat.target_generation == 1 and events.size() == 1 and events[0].event == "respawned")
	check("expired old attack cannot hit respawned target",combat.hits == before)
	snapshot = fixture_spawn()
	for i in range(18):
		isolated_step(snapshot)
	before = combat.hits
	for i in range(2):
		isolated_step(snapshot)
	check("same generation dedup",combat.hits == before)
	combat.target_generation += 1
	isolated_step(snapshot)
	check("different target generation permits still-live event",combat.hits == before+1)
	var duration: int = combat.attack_events.snapshot().attacks[0].duration
	var hp: int = combat.target_hp
	for i in range(100):
		# Render-only consumers may inspect properties, never call combat.tick.
		var ignored: int = combat.target_hp + combat.respawn_remaining
		if ignored < 0:
			failures.append("invalid fixture")
	check("render reads do not advance combat",combat.attack_events.snapshot().attacks[0].duration == duration and combat.target_hp == hp)
	combat.reset()
	check("reset only combat state/config survives",combat.hits == 0 and combat.total_damage == 0 and combat.damage_for(2) == 36)

func _input_checks() -> void:
	fresh(false)
	# Actual draw then circle input, not direct fabricated attack state.
	for i in range(3):
		step(Controller.TRIANGLE)
	for i in range(100):
		step()
		if controller.state.cate == 0 and controller.state.sub == 0:
			break
	check("draw animation no attack",combat.hits == 0)
	for i in range(3):
		step(Controller.CIRCLE)
	for i in range(60):
		step()
	check("real circle entry default cube hits once",combat.hits == 1 and combat.last_damage == 36)
	for flags in [[false,false],[true,false],[false,true]]:
		controller.focus_d7 = flags[0]
		controller.focus_d8 = flags[1]
		var result: Dictionary = run_action(26,1)
		check("focus only timing not neutral damage " + str(flags),result.hits.size() == 1 and result.hits[0].damage == 71)
	controller.focus_d7 = false
	controller.focus_d8 = false
	for level in range(4):
		fresh(false)
		for i in range(3):
			step(Controller.TRIANGLE)
		for i in range(100):
			step()
			if controller.state.cate == 0 and controller.state.sub == 0:
				break
		for i in range(3):
			step(Controller.TRIANGLE)
		var count: int = [0,30,60,80][level]
		for i in range(200):
			if controller.state.charge >= count:
				break
			step(Controller.TRIANGLE)
		check("actual triangle held charge%d startup no hit" % level,combat.hits == 0)
		var notifications: Array = []
		var observed_hits: Array = []
		for i in range(200):
			var result: Dictionary = step()
			notifications.append_array(spawns(result.actor))
			for event in result.events:
				if event.event == "hit":
					observed_hits.append(event)
			if controller.state.cate == 0 and controller.state.sub == 0:
				break
		check("actual triangle entry charge%d release record/scale" % level,notifications.size() == 1 and notifications[0].record == [3,91,92,93][level] and notifications[0].attack_scale == [100,110,120,130][level])
		check("actual triangle entry charge%d default cube damage" % level,observed_hits.size() == 1 and observed_hits[0].damage == [48,71,96,143][level])
		default_cube.append({"entry":"real triangle hold/release","level":level,"spawns":notifications,"hits":observed_hits})
	fresh()
	controller.force_action(1,26)
	step()
	for i in range(17):
		step()
	check("release real startup cannot hit even giant fixture",combat.hits == 0)
	step()
	step()
	check("release after startup hits",combat.hits == 1)
