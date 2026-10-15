extends SceneTree

const AnimatorScript = preload("res://scripts/hunter_animator.gd")
const ControllerScript = preload("res://scripts/hunter_controller.gd")
var animator: HunterAnimator
var controller: HunterController
var checks: Array = []
var failures: Array = []
var ticks: int = 0
var gallery: Array = []

func _initialize() -> void:
	animator = AnimatorScript.new()
	_check("actual animator assets load",animator.load_data())
	if failures.is_empty():
		controller = ControllerScript.new()
		controller.configure(animator)
		_check("initial real idle clip",controller.state.ready and controller.state.primary == 1)
		_run_checks()
	var results: Dictionary = {"engine":Engine.get_version_info().string,"passed":checks.size(),
		"failed":failures.size(),"ticks":ticks,"checks":checks,"failures":failures,"gallery":gallery,
		"source":"tools/hunter_action_reference.py / normal + GS contracts / original 09a99890,09a9bd80,09a86918,09a641c8,09c3d640,08865dcc,08865e8c",
		"original_game_equivalence":false,"visual_qa":"skipped; main agent owns GUI",
		"limitations":["Godot yaw/floor/cosine adaptation, not PSP VFPU", "source attack-window gate and complete spawn notifications implemented; HunterCombat owns separate neutral cube lifetime/geometry/HP sandbox, not original monster equivalence", "danger upstream external snapshot only; map/task/ledge/interrupt unmodeled; exhausted run34 flat-idle adaptation; stamina skill0x18 unmodeled", "GS2/14/15/17/18 forced gallery only; source input unverified"]}
	var output = FileAccess.open("res://tests/controller_test_results.json",FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(results,"\t"))
	print("CONTROLLER TESTS ",checks.size()," passed / ",failures.size()," failed; ",ticks," ticks")
	for failure in failures:
		print("ASSERT FAIL: ",failure)
	quit(0 if failures.is_empty() else 1)

func _check(name: String, condition: bool) -> void:
	if condition:
		checks.append(name)
	else:
		failures.append(name)

func _tick(held: int = 0, magnitude: int = 0, direction: int = 0, bits: int = 0) -> Dictionary:
	ticks += 1
	var result: Dictionary = controller.tick(held,magnitude,direction,bits)
	if result.dispatches > 2 or int(result.flags410) & 4:
		failures.append("REQUEST third dispatch or uncleared flag at tick %d" % ticks)
	if not result.ready:
		failures.append("missing actual animation at tick %d primary %d" % [ticks,result.primary])
	return result

func _run(count: int, held: int = 0, magnitude: int = 0, direction: int = 0) -> void:
	for index in range(count):
		_tick(held,magnitude,direction)

func _idle(limit: int = 450, held: int = 0) -> bool:
	for index in range(limit):
		_tick(held)
		if controller.state.cate == 0 and controller.state.sub == 0:
			return true
	return false

func _draw() -> void:
	controller.reset()
	_run(3,0x1000)
	_check("triangle input selects draw",controller.state.cate == 0 and controller.state.sub == 4)
	_check("draw actual clip end",_idle())
	_check("drawn idle primary1001",controller.is_drawn() and controller.state.primary == 1001)

func _run_checks() -> void:
	controller.reset()
	_run(30,0,127)
	_check("actual running root movement >0",controller.state.position.length() > 0)
	_check("run selects normal1",controller.state.sub == 1)
	_check("run stop reaches real idle",_idle())
	controller.reset()
	_run(40,0,60,16384)
	_check("slow normal73",controller.state.sub == 73)
	_check("absolute source yaw world+x",controller.state.position.x > 0 and absi(int(controller.state.yaw)-16384) < 2049)
	controller.reset()
	_run(10,0x200,127)
	_check("sprint normal31 / step2.5",controller.state.sub == 31 and controller.state.playback_step == 2.5)
	_check("sprint drain",controller.state.stamina < 750)
	_check("sprint release stops",_idle())
	_draw()
	var first: Dictionary = _tick(0x1000)
	_check("held first tick edge",first.pressed == 0x1000 and first.command_phase == 1)
	var second: Dictionary = _tick(0x1000)
	_check("held second tick no edge",second.pressed == 0 and second.command == 0)
	var third: Dictionary = _tick(0x1000)
	_check("source 1120 recognition third tick",third.command == 2 and third.command_hold == 2 and third.sub == 19)
	_run(5,0x1000)
	_check("held triangle no unlimited buffer",controller.state.command == 0 and controller.state.command_phase == 2)
	_tick()
	_check("release ends hold state",controller.state.command_phase == 0)
	_check("charge released completes",_idle())
	_draw()
	_run(3,0x2000)
	_check("circle source basic sweep0",controller.state.cate == 1 and controller.state.sub == 0)
	_tick()
	_check("sweep primary1406",controller.state.primary == 1406)
	_check("sweep real end",_idle())
	_tick(0x3000)
	_check("simultaneous basic upswing1",controller.state.cate == 1 and controller.state.sub == 1 and controller.state.command == 3)
	_tick()
	_check("upswing primary1407",controller.state.primary == 1407)
	_check("upswing real end",_idle())
	# Source combo window [72,98), circle -> held triangle chooses charge22.
	controller.force_action(1,0)
	for index in range(100):
		if animator.ge(72):
			break
		_tick()
	_check("source sweep GE72 reached",animator.ge(72))
	_run(3,0x1000)
	_check("sweep window triangle combo22",controller.state.cate == 1 and controller.state.sub == 22)
	_check("combo real release completes",_idle())
	controller.force_action(1,0)
	_tick()
	_run(3,0x3000)
	_run(50)
	_check("early combo is not indefinitely buffered",controller.state.sub != 10)
	_idle()
	# Each of the 28 non-empty dispatches uses its distinct concrete source clip.
	var subs: Array = [0,1,2,3,4,5,6,7,8,9,10,11,12,14,15,16,17,18,19,20,21,22,24,25,26,27,28,29]
	var first_clips: Array = [1406,1407,1401,1404,1411,1417,1421,1423,1427,1416,1419,1422,1425,1420,1418,1405,1424,1426,1401,1431,1420,1418,1424,1426,1428,1429,1430,1410]
	var expected_sequences: Array = [[1406,1001],[1407,1001],[1401,1428,1001],[1404,1001],[1411,1001],
		[1417,1406,1001],[1421,1406,1001],[1423,1406,1001],[1427,1406,1001],
		[1416,1407,1001],[1419,1407,1001],[1422,1407,1001],[1425,1407,1001],
		[1420,1401,1428,1001],[1418,1429,1428,1001],[1405,1428,1001],
		[1424,1430,1428,1001],[1426,1401,1428,1001],[1401,1428,1001],
		[1431,1410,1428,1001],[1420,1401,1428,1001],[1418,1429,1428,1001],
		[1424,1430,1428,1001],[1426,1401,1428,1001],[1428,1001],
		[1429,1428,1001],[1430,1428,1001],[1410,1428,1001]]
	for index in range(subs.size()):
		controller.reset()
		controller.state.flags410 |= 8
		_check("GS forced accept %d" % subs[index],controller.force_action(1,subs[index]))
		_tick()
		_check("GS distinct source primary %d" % subs[index],controller.state.primary == first_clips[index])
		var clips: Array = [controller.state.primary]
		var completed: bool = false
		for frame in range(450):
			_tick()
			if not controller.state.primary in clips:
				clips.append(controller.state.primary)
			if controller.state.cate == 0 and controller.state.sub == 0:
				completed = true
				break
		_check("GS end/release %d" % subs[index],completed)
		_check("GS all concrete phases %d" % subs[index],clips == expected_sequences[index])
		gallery.append({"category":1,"sub":subs[index],"primaries":clips,"completed":completed})
	_check("empty GS13/23 reject",not controller.force_action(1,13) and not controller.force_action(1,23))
	var actions: Array = controller.get_actions()
	var dispatch_only: Array = []
	for action in actions:
		if action.category == 1 and action.input_reachability == "unverified dispatch-only gallery":
			dispatch_only.append(action.subaction)
	_check("five input-unverified states explicit",dispatch_only == [2,14,15,17,18])
	for flags in [[false,false],[true,true],[false,true]]:
		controller.focus_d7 = flags[0]
		controller.focus_d8 = flags[1]
		var thresholds: Array = [24,48,64] if flags[0] else [36,72,96] if flags[1] else [30,60,80]
		for index in range(3):
			_check("charge below %s:%d" % [str(flags),thresholds[index]],controller.charge_level(thresholds[index]-1) == index)
			_check("charge at %s:%d" % [str(flags),thresholds[index]],controller.charge_level(thresholds[index]) == index+1)
		controller.reset()
		controller.state.flags410 |= 8
		_run(3,0x1000)
		var maximum: int = 0
		var released: bool = false
		for index in range(300):
			_tick(0x1000)
			maximum = maxi(maximum,int(controller.state.charge))
			if controller.state.sub == 26:
				released = true
				break
		var expected: int = 72 if flags[0] else 108 if flags[1] else 90
		_check("charge auto exact count %d" % expected,released and maximum == expected)
		_check("auto highest level no overcharge downgrade %d" % expected,controller.state.level == 3 and controller.state.attack_scale == 130)
	controller.focus_d7 = false
	controller.focus_d8 = false
	for threshold in [30,60,80]:
		_draw()
		_run(3,0x1000)
		for index in range(200):
			if controller.state.charge == threshold-1:
				break
			_tick(0x1000)
		_tick() # Source phase2 recognizer retains command_hold until next task.
		for index in range(100):
			if controller.state.sub == 26:
				break
			_tick()
		var expected_level: int = 1 if threshold == 30 else 2 if threshold == 60 else 3
		_check("actual input release count%d" % threshold,controller.state.sub == 26 and controller.state.charge == threshold and controller.state.level == expected_level)
		_check("actual release scale%d" % threshold,controller.state.attack_scale == [100,110,120,130][expected_level])
		_check("actual charged clip completes%d" % threshold,_idle())
	_draw()
	_tick(0x4000)
	_tick()
	_check("drawn roll cost75",controller.state.stamina == 675 and controller.state.sub == 28)
	_check("roll real end",_idle())
	controller.state.stamina = 72 # COUNT_BEGIN +2 precedes source input gate.
	_tick(0x4000)
	_check("drawn roll gate74 refused after COUNT",controller.state.sub == 0)
	_tick()
	controller.state.stamina = 73
	_tick(0x4000)
	_tick()
	_check("drawn roll gate75 accepted and cost75",controller.state.sub == 28 and controller.state.stamina == 0)
	controller.reset()
	_tick(0x4000)
	_run(100)
	_check("normal crouch8 loop",controller.state.sub == 8 and controller.state.phase == 2)
	controller.state.stamina = 500
	var request_tick: Dictionary = _tick(0,60)
	_check("REQUEST second dispatch COUNT regen once",request_tick.dispatches == 2 and request_tick.stamina == 502 and request_tick.sub == 59)
	_run(40,0,60)
	_check("crouch walk59",controller.state.sub == 59)
	_run(40,0,127)
	_check("crouch fast61",controller.state.sub == 61)
	_run(40)
	_check("crouch stop60 -> idle29",controller.state.sub == 29)
	_tick(0x4000)
	_check("stand REQUEST dispatch twice",controller.state.sub == 57 and controller.state.dispatches == 2)
	_check("stand real end",_idle())
	controller.reset()
	_tick(1)
	_tick()
	_check("sheathed kick source50",controller.state.sub == 99 and controller.state.primary == 50)
	_check("kick real end",_idle())
	_draw()
	_tick(0x8000)
	_tick()
	_check("square sheath1003",controller.state.primary == 1003 and not controller.is_drawn())
	_check("sheath real end",_idle())
	for sub in [3,12,38,11,1,10,8]:
		controller.reset()
		_check("guard forced accept%d" % sub,controller.force_action(2,sub))
		_tick(0x200)
		_check("guard phase1%d" % sub,controller.state.phase == 1)
		_check("guard release/end%d" % sub,_idle())
	controller.reset()
	controller.force_action(2,3)
	_tick(0x200)
	controller.state.stamina = 74
	_check("guard74 refuses incoming",not controller.guard_incoming(50,32768,true,true))
	controller.state.stamina = 75
	_check("guard75 cost180 clamps0",controller.guard_incoming(50,32768,true,true) and controller.state.stamina == 0 and controller.state.sub == 10)
	var normal_rows: Array = [[0,1,0,0],[1,3,0,127],[3,1004,0,127],[73,49,0,60],
		[36,3,0,127],[4,1002,0,0],[5,1003,0,0],[10,1017,0,0],[15,1003,0,0],
		[28,28,0,0],[37,28,0,0],[45,22,0,0],[49,1013,0,0],[50,1012,0,0],
		[8,7,0,0],[29,8,0,0],[57,9,0,0],[59,10,0,60],[60,8,0,0],[61,37,0,127],
		[44,30,0,0],[63,42,0,0],[31,3,0x200,127],[70,3,0x200,127]]
	for row in normal_rows:
		controller.reset()
		if row[0] == 3:
			controller.state.flags410 |= 8
		_check("normal24 accept%d" % row[0],controller.force_action(0,row[0]))
		_tick(row[2],row[3])
		_check("normal24 concrete source primary%d" % row[0],controller.state.primary == row[1])
	controller.reset()
	controller.state.flags288 = 0xffffffff
	controller.state.flags28c = 0xffffffff
	controller.state.flags410 |= 4
	controller.state.attack_scale = 130
	controller.force_action(1,0)
	_check("SET resets attack scale and flags",controller.state.attack_scale == 100 and controller.state.flags288 == 0x80100 and controller.state.flags28c == 0 and not int(controller.state.flags410)&4)
	controller.reset()
	controller.force_action(1,0)
	_tick()
	controller.state.hit_tag = "bounce"
	_tick()
	_check("bounce source sub3",controller.state.sub == 3 and controller.state.phase == 0)
	_run(3,0x2000)
	var recovered: bool = false
	for index in range(100):
		_tick()
		if controller.state.sub == 16:
			recovered = true
			break
	_check("bounce recovery source16",recovered)
	controller.reset()
	controller.state.hard = 2
	controller.state.stamina = 500
	var frozen: Dictionary = _tick(0x1000)
	_check("hard0 dispatch/frame freeze",frozen.dispatches == 0 and frozen.playback_step == 0 and frozen.stamina == 500)
	controller.state.hard = 0
	controller.state.slow = 2
	_check("slow raw f32 .2",is_equal_approx(_tick().playback_step,0.20000000298023224))
	controller.reset()
	controller.force_action(2,3)
	_tick(0x200)
	var before: int = controller.state.idle_counter
	for index in range(20):
		var next: Dictionary = _tick(0x200)
		_check("COUNT once guard tick%d" % index,next.idle_counter == before+2)
		before = next.idle_counter
	controller.reset()
	var wraps: int = 0
	var last_frame: float = animator.tracks[0].currentframe
	for index in range(400):
		_tick()
		if animator.tracks[0].currentframe < last_frame:
			wraps += 1
		last_frame = animator.tracks[0].currentframe
	_check("real idle loop wraps normally",animator.tracks[0].loop and controller.state.sub == 0 and wraps > 1)
	_tick()
	_check("loop wrap inactive marker resumes",animator.tracks[0].active)
	var snapshot: Dictionary = controller.last_tick.duplicate(true)
	var original_pose: Array = animator.pose.duplicate()
	for index in range(10):
		var unused_pose: Array = animator.world_pose.duplicate()
		_check("render snapshot no tick%d" % index,not unused_pose.is_empty() and controller.last_tick == snapshot and animator.pose == original_pose)
	var returned: Dictionary = _tick()
	returned.position = Vector3(999,999,999)
	_check("tick snapshot independent",controller.state.position != returned.position)
	_check("all REQUEST dispatches<=2 and clear",failures.filter(func(value): return "REQUEST third" in value).is_empty())
	_dive_checks()
	_window_checks()
	_spawn_checks()

func _dive_checks() -> void:
	# 保留原 319 断言，新增用真实动画和按键走完整飞扑链。
	_check("normal27 library keeps GS28",ControllerScript.NORMAL.size() == 27 and ControllerScript.PLANS[28][0][0] == 1430)
	var names: Array = []
	for action in controller.get_actions():
		if action.category == 0 and action.subaction in [32,68,69]:
			names.append(action.name)
	_check("danger dive recovery named gallery",names == ["危险跑","飞扑","危险跑恢复"])
	for angle in [0x2000,0x2001,0xdfff,0xe000,0xffff,0x10000+0x2001]:
		controller.reset()
		controller.danger_enabled = true
		controller.danger_yaw = angle
		var selected: Dictionary = _tick(ControllerScript.R,127)
		var qualified: bool = ((angle+0x2000) & 65535) > 0x4000
		_check("danger unsigned angle boundary%d" % angle,selected.sub == (32 if qualified else 31) and bool(int(selected.flags111c)&0x100))
		_run(2,ControllerScript.R,127)
		_tick(ControllerScript.R|ControllerScript.CROSS,127)
		_check("danger angle CROSS eligibility%d" % angle,controller.state.sub == (68 if qualified else 28))
	controller.danger_enabled = false
	controller.reset()
	controller.state.flags111c = 0x1100
	_run(3,ControllerScript.R,127)
	_tick(ControllerScript.R|ControllerScript.CROSS,127)
	_check("no danger snapshot clears bit preserves others and rolls",controller.state.sub == 28 and int(controller.state.flags111c)&0x1000 and not int(controller.state.flags111c)&0x100)
	controller.danger_enabled = true
	controller.danger_yaw = 32768
	controller.reset()
	controller.state.flags410 |= 8
	_run(3,ControllerScript.R,127)
	_tick(ControllerScript.R|ControllerScript.CROSS,127)
	_check("drawn danger never selects dive",controller.is_drawn() and not (controller.state.cate == 0 and controller.state.sub in [32,68,69]))
	for stamina in [74,75,76,77]:
		controller.reset()
		_run(2,ControllerScript.R,127)
		controller.state.stamina = stamina
		_tick(ControllerScript.R|ControllerScript.CROSS,127)
		_check("danger post-cost low stamina exits first%d" % stamina,controller.state.sub == 0 and controller.state.internal_window == 0)
	controller.reset()
	_run(2,ControllerScript.R,127)
	controller.state.stamina = 78
	_tick(ControllerScript.R|ControllerScript.CROSS,127)
	_check("danger post-cost76 accepts deferred dive",controller.state.sub == 68 and controller.state.phase == 0 and controller.state.stamina == 76)
	controller.reset()
	_run(2,ControllerScript.R,127)
	controller.danger_enabled = false
	var exited: Dictionary = _tick(ControllerScript.R|ControllerScript.CROSS,127)
	_check("danger lost before CROSS exits via70 never dives",exited.sub == 28 and exited.primary == 3 and exited.dispatches == 2 and exited.events.any(func(event): return event.event == "request" and event.sub == 70))
	controller.danger_enabled = true
	for recovery_held in [0,ControllerScript.R]:
		controller.reset()
		controller.evasion_skill_a1 = true
		controller.evasion_skill_a2 = true
		controller.state.yaw = 16384
		controller.state.target = 16384
		controller.danger_yaw = 49152
		var entry: Dictionary = _tick(ControllerScript.R,127,16384)
		_check("input SET32 defers initialization%d" % recovery_held,entry.sub == 32 and entry.phase == 0 and entry.primary == 1 and entry.dispatches == 1)
		entry = _tick(ControllerScript.R,127,16384)
		_check("danger run38 initialization%d" % recovery_held,entry.sub == 32 and entry.phase == 1 and entry.primary == 38)
		var before: Vector3 = controller.state.position
		var running: Dictionary = _tick(ControllerScript.R,127,16384)
		_check("danger local extra1.5 once plus root%d" % recovery_held,is_equal_approx(running.position.x-before.x,running.root_delta.x+1.5) and running.stamina == 748)
		var requested: Dictionary = _tick(ControllerScript.R|ControllerScript.CROSS,127,16384)
		_check("SET68 next tick no window or cost75%d" % recovery_held,requested.sub == 68 and requested.phase == 0 and requested.primary == 38 and requested.internal_window == 0 and requested.stamina == 746 and requested.dispatches == 1)
		var initialized: Dictionary = _tick(recovery_held)
		_check("dive46 mode2 cost75 raw window3%d" % recovery_held,initialized.phase == 1 and initialized.primary == 46 and initialized.air280 == 2 and initialized.stamina == 671 and initialized.internal_window == 3 and initialized.events.any(func(event): return event.event == "animation" and event.blend_argument == 4))
		var protected: bool = true
		for index in range(100):
			if controller.state.phase == 2:
				break
			before = controller.state.position
			var next: Dictionary = _tick(recovery_held)
			protected = protected and next.internal_window == 3
			if next.phase == 2:
				_check("takeoff47 adds100 preserves air root%d" % recovery_held,is_equal_approx(next.position.y-before.y,100+next.root_delta.y) and next.primary == 47 and next.air280 == 2)
		_check("dive prep refresh protection%d" % recovery_held,protected and controller.state.phase == 2)
		_check("takeoff world+x velocity acceleration%d" % recovery_held,controller.state.velocity.is_equal_approx(Vector3(16,3,0)) and controller.state.acceleration == Vector3(0,-0.75,0))
		var integrals: int = 0
		for index in range(40):
			if controller.state.phase != 2:
				break
			before = controller.state.position
			var old_velocity: Vector3 = controller.state.velocity
			var airborne: Dictionary = _tick(recovery_held)
			integrals += 1
			var expected_velocity: Vector3 = old_velocity+Vector3(0,-0.75,0)
			_check("dive discrete v then p%d:%d" % [recovery_held,index],airborne.velocity.is_equal_approx(expected_velocity) and is_equal_approx(airborne.position.x-before.x,expected_velocity.x+airborne.root_delta.x) and (airborne.phase == 3 or is_equal_approx(airborne.position.y-before.y,expected_velocity.y+airborne.root_delta.y)) and airborne.internal_window == 3)
		_check("flat landing after21 integrals48%d" % recovery_held,integrals == 21 and controller.state.phase == 3 and controller.state.primary == 48 and controller.state.air280 == 0 and controller.state.position.y == 0 and controller.state.velocity.y == -12.75)
		var landing_velocity: Vector3 = controller.state.velocity
		var landing: Dictionary = _tick(recovery_held)
		_check("landing active window2 no integration%d" % recovery_held,landing.internal_window == 2 and landing.velocity == landing_velocity)
		for index in range(100):
			if animator.ge(30):
				break
			_tick(recovery_held)
		_check("landing real GE30 holds remaining2%d" % recovery_held,animator.ge(30) and controller.state.internal_window == 2)
		var tail: Dictionary = _tick(recovery_held)
		_check("GE30 first call window1%d" % recovery_held,tail.internal_window == 1 and not controller.attack_collision_allowed())
		tail = _tick(recovery_held)
		_check("GE30 second call window0%d" % recovery_held,tail.internal_window == 0 and controller.attack_collision_allowed())
		var end: Dictionary = {}
		for index in range(200):
			if animator.animation_ended():
				controller.state.internal_window = -9 # 验证结束显式清零，而非只等自然耗尽。
			end = _tick(recovery_held)
			if end.sub != 68:
				break
		_check("dive finish REQUEST initializes recovery once%d" % recovery_held,end.sub == (69 if recovery_held else 44) and end.primary == (38 if recovery_held else 30) and end.dispatches == 2 and end.internal_window == 0 and end.events.any(func(event): return event.event == "animation" and event.blend_argument == 4))
		if recovery_held:
			var stopped: Dictionary = _tick()
			_check("69 restores real stop44",stopped.sub == 44 and stopped.primary == 30 and stopped.dispatches == 2)
		_check("dive recovery reaches actual idle%d" % recovery_held,_idle())
	controller.reset()
	_check("reset physical state preserves external configuration",controller.state.velocity == Vector3.ZERO and controller.state.acceleration == Vector3.ZERO and controller.state.floor_height == 0 and controller.danger_enabled and controller.evasion_skill_a1 and controller.evasion_skill_a2)
	controller.danger_enabled = false
	controller.evasion_skill_a1 = false
	controller.evasion_skill_a2 = false

func _window_checks() -> void:
	for value in [0,1,-1,-32768]:
		controller.reset()
		controller.state.internal_window = value
		_check("attack collision exact zero%d" % value,controller.attack_collision_allowed() == (value == 0))
		_tick()
		_check("window s16 nonzero countdown%d" % value,controller.state.internal_window == (0 if value == 0 else ControllerScript._s16(value-1)))
	controller.reset()
	controller.state.internal_window = -32768
	controller.state.hard = 2
	_tick()
	_check("hard33c freezes window signed countdown",controller.state.internal_window == -32768 and controller.state.dispatches == 0)
	controller.state.hard = 0
	controller.state.slow = 2
	_tick()
	_check("slow is not hard freeze window",controller.state.internal_window == 32767)
	controller.reset()
	controller.force_action(0,29)
	_tick()
	controller.state.internal_window = 6
	var doubled: Dictionary = _tick(0,60)
	_check("window decrements once across double dispatch",doubled.dispatches == 2 and doubled.internal_window == 5)
	for sub in [28,37,45,49,50]:
		for skills in [[false,false],[true,false],[false,true],[true,true]]:
			controller.reset()
			controller.evasion_skill_a1 = skills[0]
			controller.evasion_skill_a2 = skills[1]
			controller.evade_rank = 2
			controller.force_action(0,sub)
			var roll: Dictionary = _tick()
			var expected: int = (16 if sub == 37 else 6)+(6 if skills[1] else 4 if skills[0] else 0)
			_check("roll window base and skill priority%d:%s" % [sub,str(skills)],roll.internal_window == expected and roll.stamina == 712)
	controller.evade_rank = 0
	controller.evasion_skill_a1 = false
	controller.evasion_skill_a2 = false
	# 使用真实 clip48 的 blend 起点验证 GE30 的资格门，而非伪 Animator。
	controller.reset()
	controller.force_action(0,68)
	controller.state.phase = 3
	controller._anim(48,4,30)
	controller.state.internal_window = 3
	_check("landing frame30 blend base3 not GE qualified",animator.tracks[0].blend_remaining == 3 and not animator.ge(30))
	_tick()
	_check("landing blend gate still refreshes2",controller.state.internal_window == 2)
	controller.reset()
	controller.state.floor_height = 12.0
	controller.state.position = Vector3(0,99,0)
	_tick()
	_check("nonair cached floor adaptation only",controller.state.position.y == 12.0)
	for sub in [32,68,69]:
		controller.reset()
		_check("explicit new normal action accepted%d" % sub,controller.force_action(0,sub))

func _spawn_checks() -> void:
	var previous_id: int = 0
	for level in range(4):
		controller.reset()
		controller.force_action(1,26)
		controller.state.level = level
		var result: Dictionary = _tick()
		var notifications: Array = result.events.filter(func(event): return event.event == "attack_spawn")
		_check("release production one notification level%d" % level,notifications.size() == 1)
		if notifications.size() == 1:
			var spawn: Dictionary = notifications[0]
			_check("spawn retains old event/record/primary keys level%d" % level,spawn.event == "attack_spawn" and spawn.record == [3,91,92,93][level] and spawn.primary == 1428 and spawn.has("combat"))
			_check("release scale committed before notification level%d" % level,spawn.attack_scale == [100,110,120,130][level] and spawn.attack_scale == result.attack_scale)
			_check("spawn carries setter start and stored half blend level%d" % level,spawn.start == 0 and spawn.blend_count == 1 and result.blend == 1)
			_check("creation identity monotonic across resets level%d" % level,spawn.attack_id > previous_id)
			previous_id = spawn.attack_id
		controller._anim(1428,0,0)
		_check("same animation reset not new attack level%d" % level,controller._attack_id == previous_id)
	for sub in [4,99]:
		controller.reset()
		controller.force_action(1,sub)
		var result: Dictionary = _tick()
		var notifications: Array = result.events.filter(func(event): return event.event == "attack_spawn")
		_check("short attack%d correct record/bone selector producer" % sub,notifications.size() == 1 and notifications[0].record == (4 if sub == 4 else 5) and notifications[0].primary == (1411 if sub == 4 else 50) and notifications[0].attack_scale == 100)
	controller.reset()
