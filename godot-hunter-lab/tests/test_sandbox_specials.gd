extends SceneTree

const Special = preload("res://scripts/sandbox_special.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var capture_mode: bool = false
var frame_us: Array = []
var captures: Array[String] = []

func _initialize() -> void:
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func step(held: int = 0) -> Dictionary:
	var before: int = lab.hunt.ticks
	var result: Dictionary = lab.tick_hunt({"held":held,"mag":0,"direction":0,"bits":0})
	check(lab.hunt.ticks == before+1 and lab.controller.state.ticks == lab.monster.state.ticks,"paired source owners")
	return result

func fixture(move: String, guard: bool = false) -> void:
	lab.reset_hunt()
	lab.monster.ai_enabled = true
	lab.controller.state.position = Vector3(0,0,300 if move == "laser" else 190)
	lab.controller.state.yaw = 32768 if guard else 0
	lab.controller.state.target = lab.controller.state.yaw
	lab.monster.state.position = Vector3.ZERO
	if guard:
		lab.controller.state.flags410 |= 8
		lab.controller.force_action(2,3)
	check(lab.monster.begin_special(move,lab.controller.state.position),"special entry "+move)

func capture(name: String) -> void:
	if not capture_mode:
		return
	lab.update_visuals()
	if name.begins_with("laser"):
		lab.camera.position = Vector3(10,9,13)
		lab.camera.look_at(Vector3(0,0.8,4))
	await process_frame
	RenderingServer.force_draw(false)
	var path: String = "res://screenshots/specials/"+name+".png"
	var image := root.get_texture().get_image()
	check(not image.is_empty() and image.save_png(path) == OK,"GPU capture "+name)
	captures.append(ProjectSettings.globalize_path(path))

func geometry_checks() -> void:
	var owner = Special.new()
	check(not owner.begin("unknown",Vector3.ZERO,0),"unknown move rejected")
	for move in ["laser","stink"]:
		owner.begin(move,Vector3.ZERO,0)
		var shape: Dictionary = owner.volume()
		var point: Vector3 = (shape.a+shape.b)*0.5 if move == "laser" else shape.a
		var targets: Array[Dictionary] = [{"identity":"hunter","generation":1,"eligible":true,"volumes":[{"kind":"sphere","a":point,"radius":0.1},{"kind":"sphere","a":point,"radius":0.1}]}]
		for i in range(Special.MOVES[move].windup):
			check(owner.contacts(targets).is_empty(),"no unannounced damage "+move)
			owner.tick()
		check(owner.stage == "active","exact activation "+move)
		check(owner.contacts(targets).size() == 1,"multiple body volumes consume once "+move)
		check(owner.contacts(targets).is_empty(),"repeated active calls deduplicate "+move)
		targets[0].generation = 2
		check(owner.contacts(targets).size() == 1,"generation identity distinct "+move)
		for i in range(Special.MOVES[move].active):
			owner.tick()
		check(owner.stage == "recovery" and owner.contacts(targets).is_empty(),"finite active / recovery harmless "+move)
		for i in range(Special.MOVES[move].recovery):
			owner.tick()
		check(owner.kind == "","finite recovery "+move)
	owner.begin("laser",Vector3.ZERO,0)
	for i in range(Special.MOVES.laser.windup):
		owner.tick()
	var ray: Dictionary = owner.volume()
	for point in [ray.a-Vector3(0,0,1),ray.b+Vector3(0,0,1),ray.a+Vector3(2,0,0)]:
		var targets: Array[Dictionary] = [{"identity":"outside","generation":1,"eligible":true,"volumes":[{"kind":"sphere","a":point,"radius":0.1}]}]
		check(owner.contacts(targets).is_empty(),"finite capsule rejects side / behind / beyond")
	var edge: Array[Dictionary] = [{"identity":"edge","generation":1,"eligible":false,"volumes":[{"kind":"sphere","a":ray.a+Vector3(0.4,0,0),"radius":0.1}]}]
	check(owner.contacts(edge).is_empty(),"evade gate precedes geometry history")
	edge[0].eligible = true
	check(owner.contacts(edge).size() == 1,"grazing capsule boundary and no evade history consumption")

func integration_checks() -> void:
	for move in ["laser","stink"]:
		fixture(move)
		var fixed: Dictionary = lab.monster.sandbox_special.snapshot()
		for i in range(Special.MOVES[move].windup-1):
			var result := step()
			check(not result.events.any(func(e): return e.event == "incoming_contact") and lab.controller.state.hp == 100,"full telegraph harmless "+move)
		await capture(move+"_windup")
		var contact := step()
		check(contact.events.filter(func(e): return e.event == "incoming_contact" and e.get("special","") == move).size() == 1,"active geometry contact "+move)
		check(lab.controller.state.hp == 100,"session queues not double HP consumption "+move)
		var state: Dictionary = lab.monster.sandbox_special.snapshot()
		check(state.yaw == fixed.yaw and state.origin == fixed.origin and state.volume == fixed.volume,"fixed orientation and geometry "+move)
		await capture(move+"_active")
		var unchanged: Dictionary = lab.monster.sandbox_special.snapshot()
		var hp: int = lab.controller.state.hp
		for i in range(20):
			lab.update_visuals()
		check(lab.monster.sandbox_special.snapshot() == unchanged and lab.controller.state.hp == hp,"render cannot consume attack clock or HP "+move)
		var damage := step()
		check(damage.events.filter(func(e): return e.event == "player_damage").size() == 1 and lab.controller.state.hp == 100-Special.MOVES[move].damage,"next tick one HP consumer "+move)
		check(damage.events.any(func(e): return e.event == "player_damage" and e.incoming_source.get("special","") == move),"special provenance retained "+move)
		for i in range(Special.MOVES[move].active+Special.MOVES[move].recovery-1):
			step()
		check(lab.monster.sandbox_special.kind == "" and lab.hunt.monster_hits == 1 and lab.controller.state.hp == 100-Special.MOVES[move].damage,"finite move / no repeated HP "+move)
		fixture(move,true)
		for i in range(Special.MOVES[move].windup):
			step(HunterController.R)
		check(lab.hunt.events.any(func(e): return e.event == "incoming_contact" and e.status == "guarded"),"existing defense qualification "+move)
		step(HunterController.R)
		check(lab.controller.state.hp == (95 if move == "laser" else 100),"existing chip rule "+move)
		fixture(move)
		for i in range(Special.MOVES[move].windup-1):
			step()
		lab.controller.state.flags410 |= 8
		lab.controller.force_action(0,28)
		step()
		check(lab.controller.state.internal_window > 0 and lab.hunt.monster_hits == 0,"real roll window rejects special "+move)
		var old_id: int = lab.monster.sandbox_special.attack_id
		lab.reset_hunt()
		check(lab.monster.sandbox_special.kind == "" and not lab.hunt._incoming_queued,"restart clears clock/history/pending")
		fixture(move)
		check(lab.monster.sandbox_special.attack_id > old_id,"monotonic special identity across restart")
		lab.monster.take_damage(120,0)
		step()
		check(lab.monster.sandbox_special.kind == "" and lab.monster.state.mode == "hit","reaction cancels special "+move)
		fixture(move)
		lab.monster.take_damage(2000,0)
		step()
		check(lab.monster.sandbox_special.kind == "" and lab.hunt.round_state == "victory" and lab.hunt.monster_hits == 0,"death cancels special before contact "+move)
		fixture(move)
		lab.monster.ai_enabled = false
		step()
		check(lab.monster.sandbox_special.kind == "","disabled AI cancels special")
		fixture(move)
		var fixed_shape: Dictionary = lab.monster.sandbox_special.volume()
		lab.controller.state.position.x = 450
		for i in range(Special.MOVES[move].windup+Special.MOVES[move].active):
			step()
		check(lab.hunt.monster_hits == 0 and lab.controller.state.hp == 100 and lab.monster.sandbox_special.volume() == fixed_shape,"leave warning area: miss, no homing "+move)
	lab.reset_hunt()
	lab.monster.ai_enabled = true
	var seen: Array = []
	for i in range(2000):
		var result := step()
		for event in result.events:
			if event.event == "sandbox_special_begin":
				seen.append(event.special)
		if lab.hunt.round_state != "running":
			break
	check(seen.has("laser") and seen.has("stink"),"unmodified default spawn and stationary input naturally reaches both moves")
	print("NATURAL SPECIAL ROUND ticks=",lab.hunt.ticks," hp=",lab.controller.state.hp," moves=",seen," outcome=",lab.hunt.round_state)
	for decision in [2,3]:
		lab.reset_hunt()
		lab.monster.ai_enabled = true
		lab.monster._sandbox_decision = decision
		lab.monster.state.mode = "prepare"
		lab.monster.state.prepare_ticks = 1
		step()
		check(lab.monster.sandbox_special.kind == ("laser" if decision == 2 else "stink"),"sandbox decision reaches move")

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	lab.distance = 11
	lab.elevation = 0.55
	lab.orbit = 1.1
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/specials"))
	geometry_checks()
	await integration_checks()
	if capture_mode:
		lab.reset_hunt()
		lab.monster.ai_enabled = false
		lab.set_process(true)
		lab.set_physics_process(true)
		for i in range(20):
			await process_frame
		var before: int = Time.get_ticks_usec()
		for i in range(180):
			await process_frame
			var now: int = Time.get_ticks_usec()
			frame_us.append(now-before)
			before = now
		frame_us.sort()
		print("GPU FRAME us median=",frame_us[90]," p95=",frame_us[171]," max=",frame_us[-1]," adapter=",RenderingServer.get_video_adapter_name())
	print("SANDBOX SPECIALS: ",checks," checks / ",failures.size()," failed; captures=",captures)
	quit(0 if failures.is_empty() else 1)
