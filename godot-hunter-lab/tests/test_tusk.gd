extends SceneTree

const Special = preload("res://scripts/sandbox_special.gd")
const Output = preload("res://tests/result_output.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var captures: Array[String] = []
var metrics: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func step(held: int = 0) -> Dictionary:
	return lab.tick_hunt({"held":held,"mag":0,"direction":0,"bits":0})

func fixture(guard: bool = false) -> void:
	lab.reset_hunt()
	lab.monster.ai_enabled = true
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,500)
	if guard:
		lab.controller.state.yaw = 32768
		lab.controller.state.target = 32768
		lab.controller.state.flags410 |= 8
		lab.controller.force_action(2,3)
	check(lab.monster.begin_special("tusk",lab.controller.state.position),"explicit tusk enters shared readiness")
	var prep: int = 0
	for i in range(180):
		prep += 1 if lab.monster.state.mode == "prepare" else 0
		step(HunterController.R if guard else 0)
		if lab.monster.sandbox_special.kind == "tusk":
			break
	check(prep >= BulldromeController.PREPARE_TICKS and lab.monster.sandbox_special.age == 0,"complete next move prepare18 before tusk charge")

func target_at(point: Vector3, eligible: bool = true) -> Array[Dictionary]:
	return [{"identity":"hunter","generation":1,"eligible":eligible,"volumes":[{"kind":"sphere","a":point,"radius":0.01},{"kind":"sphere","a":point,"radius":0.01}]}]

func producer_checks() -> void:
	var owner = Special.new()
	owner.begin("tusk",Vector3.ZERO,0)
	for i in range(Special.MOVES.tusk.windup):
		check(owner.projectile.is_empty() and owner.contacts(target_at(owner.mouth())).is_empty(),"charge has no damaging projectile")
		owner.tick()
	check(owner.stage == "active" and owner.volume().is_empty(),"projectile is not a laser fixed volume")
	var previous: Vector3 = owner.projectile.position
	owner.tick()
	check(owner.projectile.previous == previous and is_equal_approx(owner.projectile.position.distance_to(previous),0.45),"producer consecutive trajectory/speed")
	var behind: Vector3 = previous-Vector3(0,0,0.40)
	check(not AttackEvents.volumes_intersect({"kind":"capsule","a":owner.projectile.position-Vector3(0,0,0.45),"b":owner.projectile.position+Vector3(0,0,0.45),"radius":0.22},target_at(behind)[0].volumes[0]),"short-range regression point outside current-only geometry")
	check(owner.contacts(target_at(behind,false)).is_empty() and owner.projectile.active,"evade/qualified gate before history")
	check(owner.contacts(target_at(behind)).size() == 1 and not owner.projectile.active,"swept adjacent tick catches short-range crossing once")
	check(owner.contacts(target_at(behind)).is_empty(),"multiple hurtbox and repeated call never double damage")
	owner.begin("tusk",Vector3(0,0,-400),0)
	for i in range(Special.MOVES.tusk.windup):
		owner.tick()
	var max_distance: float = 0.0
	for i in range(Special.MOVES.tusk.active):
		owner.tick()
		owner.contacts([])
		max_distance = maxf(max_distance,float(owner.projectile.get("distance",0.0)))
	check(is_equal_approx(max_distance,Special.MOVES.tusk.range),"exact range800 clamp and cleanup without endpoint overshoot")
	check(owner.stage == "recovery" and owner.projectile.is_empty(),"finite flight TTL and recovery cleanup")
	for i in range(Special.MOVES.tusk.recovery):
		owner.tick()
	check(owner.kind == "","finite recovery24")
	owner.begin("tusk",Vector3(0,0,790),0)
	for i in range(Special.MOVES.tusk.windup):
		owner.tick()
	owner.tick()
	owner.contacts([])
	check(not owner.projectile.active and owner.projectile.position.z <= 9.33,"arena bounds clear without passing boundary")
	owner.begin("tusk",Vector3(0,0,915),0)
	for i in range(Special.MOVES.tusk.windup):
		owner.tick()
	check(owner.projectile.is_empty(),"outward mouth outside arena never spawns projectile")
	owner.reset()
	check(owner.projectile.is_empty() and owner._history.is_empty(),"reset clears owned projectile/history")

func hit_checks() -> void:
	for guard in [false,true]:
		fixture(guard)
		var held: int = HunterController.R if guard else 0
		for i in range(Special.MOVES.tusk.windup-1):
			step(held)
			check(lab.controller.state.hp == 100 and lab.hunt.monster_hits == 0,"full tusk charge harmless")
		var begin := step(held)
		check(begin.events.any(func(e): return e.event == "move_release" and e.move == "tusk"),"launch refreshes tracking intent")
		var seen: bool = false
		for i in range(20):
			var before: int = lab.controller.state.hp
			var result := step(held)
			if result.events.any(func(e): return e.event == "incoming_contact" and e.get("special","") == "tusk"):
				check(lab.controller.state.hp == before,"contact queues incoming without extra HP write")
				check(result.events.any(func(e): return e.event == "incoming_contact" and e.status == ("guarded" if guard else "pending")),"existing guard/pending qualification")
				seen = true
				step(held)
				break
		check(seen and lab.hunt.monster_hits == 1 and lab.controller.state.hp == (97 if guard else 85),"exact one tusk damage15 or existing impact15 guard chip3")
		for i in range(30):
			step(held)
		check(lab.hunt.monster_hits == 1,"no repeat during flight/recovery")
	fixture()
	for i in range(Special.MOVES.tusk.windup):
		step()
	var spawn: Vector3 = lab.monster.sandbox_special.projectile.position
	lab.controller.state.position = spawn*100.0+Vector3(0, -105, 50)
	lab.controller.state.flags410 |= 8
	lab.controller.force_action(0,28)
	step()
	check(lab.controller.state.internal_window > 0 and lab.hunt.monster_hits == 0,"actual hunter roll window rejects tusk")
	for reason in ["death","reset","disable","source","hunter_death"]:
		fixture()
		for i in range(Special.MOVES.tusk.windup+2):
			step()
		check(lab.monster.sandbox_special.projectile.get("active",false),"live projectile before cancellation "+reason)
		match reason:
			"death": lab.monster.take_damage(2000,0)
			"reset": lab.reset_hunt()
			"disable": lab.monster.ai_enabled = false
			"source": lab.monster.sandbox_motion_enabled = false
			"hunter_death": lab.controller.state.hp = 0
		step()
		lab.update_visuals()
		check(lab.monster.sandbox_special.projectile.is_empty() and not lab.tusk_pool[0].visible,"lifecycle projectile/view cleanup "+reason)
		lab.monster.sandbox_motion_enabled = true

func accepted_checks() -> void:
	lab.reset_hunt()
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,500)
	lab.llm.bind_round(lab.hunt)
	var plan := {"plan":[{"tactic":"observe","move":"tusk"},{"tactic":"approach","move":"laser"}]}
	var parsed: Dictionary = LlmTactics.parse_plan(JSON.stringify(plan))
	check(parsed.ok and lab.llm.observe(lab.hunt).legal_moves.keys() == BulldromeController.MOVE_MENU.keys() and lab.llm.observe(lab.hunt).legal_moves.tusk.range_m == 7.5 and LlmTactics.PROMPT.contains("laser, stink, tusk, slam") and not LlmTactics.PROMPT.contains("|tusk"),"producer menu drives LLM allowlist/prompt/observation")
	var bad := LlmTactics.parse_plan('{"plan":[{"tactic":"observe","move":"tusk","damage":99}]}')
	check(not bad.ok,"tusk plan cannot edit damage")
	lab.llm.pending = true
	lab.monster.llm_pending = true
	var body := JSON.stringify({"choices":[{"message":{"content":JSON.stringify(plan)}}]}).to_utf8_buffer()
	# Inject at actual completion boundary: no socket, key, relay or live model.
	lab.llm._completed(HTTPRequest.RESULT_SUCCESS,200,[],body,lab.llm.decision_id,lab.hunt.round_generation)
	check(lab.monster.llm_plan == plan.plan and lab.llm.choice.contains("tusk"),"offline mock accepted completion installs tusk plan and display")
	var begun: Array = []
	var released: bool = false
	var prep: int = 0
	var cooldown_motion: float = 0.0
	for i in range(350):
		if released:
			lab.controller.state.position = Vector3(320,0,550)
		var before: Vector3 = lab.monster.state.position
		var result := step()
		prep += 1 if lab.monster.state.mode == "prepare" else 0
		for event in result.events:
			if event.event == "sandbox_special_begin":
				begun.append(event.special)
			if event.event == "move_release" and event.move == "tusk":
				released = true
		if released and lab.monster.state.mode == "special" and lab.monster.sandbox_special.kind == "tusk":
			check(lab.monster.state.observed_target == lab.controller.state.position,"inflight tracking intent observes moving target")
		if lab.monster.state.mode == "move_recovery":
			cooldown_motion += before.distance_to(lab.monster.state.position)
		if begun.size() == 2:
			break
	check(begun == ["tusk","laser"] and prep >= 36 and cooldown_motion > 0,"accepted order, required recovery, immediate reposition and full next prep")
	var file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	var logged: bool = false
	while file != null and not file.eof_reached():
		var line: String = file.get_line()
		if line.is_empty():
			continue
		var event: Variant = JSON.parse_string(line)
		if event is Dictionary and event.get("event","") == "move_commit" and event.get("move","") == "tusk" and event.get("decision_source","") == "llm":
			logged = true
	check(logged,"actual local execution log retains accepted tusk plan, no HTTP inferred")
	metrics.accepted = {"begun":begun,"prepare_ticks":prep,"cooldown_distance":cooldown_motion,"mock":"completion callback only; no network/no key/live unverified"}
	lab.reset_hunt()
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,500)
	var found: bool = false
	for seed in range(128):
		lab.monster.tactics.rng.seed = seed
		if lab.monster.tactics.choose(500,0,"locomotion_or_idle",true,lab.monster.LLM_RANGES).move == "tusk":
			lab.monster.tactics.rng.seed = seed
			found = true
			break
	check(found,"bounded seed search covers situational default tusk")
	for i in range(180):
		step()
		if lab.monster.sandbox_special.kind == "tusk":
			break
	check(lab.monster.sandbox_special.kind == "tusk" and lab.monster.decision_source == "fallback","actual default policy executes tusk, not special-only display")
	metrics.default_tick = lab.hunt.ticks
	var policy = SandboxTactics.new()
	var fresh: int = 0
	var repeated: int = 0
	var inappropriate: int = 0
	for seed in range(128):
		policy.reset()
		policy.rng.seed = seed
		fresh += 1 if policy.choose(500,0,"locomotion_or_idle",true,lab.monster.LLM_RANGES).move == "tusk" else 0
		policy.selected("tusk")
		policy.rng.seed = seed
		repeated += 1 if policy.choose(500,0,"locomotion_or_idle",true,lab.monster.LLM_RANGES).move in ["tusk","laser"] else 0
		for context in [[190,0,"locomotion_or_idle"],[500,22000,"locomotion_or_idle"],[500,0,"evading"]]:
			inappropriate += 1 if policy.choose(context[0],context[1],context[2],true,lab.monster.LLM_RANGES).move == "tusk" else 0
	check(fresh > repeated and inappropriate == 0,"matched seeds reduce consecutive ranged spam; no pointblank/side/evade tusk selection")
	metrics.policy = {"seeds":128,"fresh_tusk":fresh,"after_tusk_ranged":repeated,"inappropriate_tusk":inappropriate}

func capture(name: String) -> void:
	if not "--capture" in OS.get_cmdline_user_args():
		return
	lab.update_visuals()
	var special: Dictionary = lab.monster.sandbox_special.snapshot()
	var forward := Vector3(0,0,1).rotated(Vector3.UP,special.yaw*TAU/65536.0)
	var center: Vector3 = special.mouth+forward*1.5
	lab.camera.position = center+Vector3(3.8,3.0,4.5)
	lab.camera.look_at(center)
	if name.begins_with("detail"):
		center = special.projectile.position
		lab.camera.position = center+Vector3(-2.0,1.0,1.6)
		lab.camera.look_at(center)
		lab.hud.get_parent().visible = false
	await process_frame
	RenderingServer.force_draw(false)
	var path: String = "res://screenshots/tusk_20261015/"+name+".png"
	check(root.get_texture().get_image().save_png(path) == OK,"GPU capture "+name)
	captures.append(ProjectSettings.globalize_path(path))
	lab.hud.get_parent().visible = true

func view_checks() -> void:
	fixture()
	var id: int = lab.tusk_pool[0].get_instance_id()
	var mesh_id: int = lab.tusk_pool[0].mesh.get_instance_id()
	check(lab.tusk_pool.size() == Special.MOVES.tusk.count,"finite preallocated mesh pool")
	var max_radius: float = 0.0
	var max_extent: float = 0.0
	var points: PackedVector3Array = lab.tusk_pool[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for point in points:
		max_radius = maxf(max_radius,Vector2(point.x,point.y).length())
		max_extent = maxf(max_extent,absf(point.z))
	check(is_equal_approx(max_extent,Special.MOVES.tusk.half_length) and is_equal_approx(max_radius,Special.MOVES.tusk.radius),"capsule bounds exactly match visible fang envelope including curved tip")
	for i in range(24):
		step()
	await capture("charge_tick24")
	for i in range(6):
		step()
	lab.controller.state.position.x = 400
	await capture("launch_tick30")
	var fixed_yaw: int = lab.monster.sandbox_special.yaw
	for i in range(8):
		var previous: Vector3 = lab.monster.sandbox_special.projectile.position
		step()
		var snapshot: Dictionary = lab.monster.sandbox_special.snapshot()
		check(lab.monster.state.applied_root_delta == Vector3.ZERO and lab.monster.state.approach_delta == Vector3.ZERO,"tusk flight does not integrate extra root or walk")
		var hp: int = lab.controller.state.hp
		for render in range(5):
			lab.update_visuals()
		check(lab.monster.sandbox_special.snapshot() == snapshot and lab.controller.state.hp == hp,"render cannot advance position/age/history/HP")
		check(snapshot.yaw == fixed_yaw and snapshot.projectile.previous == previous and is_equal_approx(snapshot.projectile.position.distance_to(previous),0.45),"visible continuous trajectory without homing")
		check(lab.tusk_pool[0].get_instance_id() == id and lab.tusk_pool[0].mesh.get_instance_id() == mesh_id and lab.tusk_pool[0].position == snapshot.projectile.position,"same visible projectile mesh follows producer")
		if i in [3,7]:
			await capture("flight_tick"+str(31+i))
		if i == 3:
			await capture("detail_flight_tick34")
	check(lab.hunt.monster_hits == 0,"lateral motion avoids locked tooth")
	metrics.geometry = {"radius":0.22,"half_length":0.45,"mesh_vertices":lab.tusk_pool[0].mesh.surface_get_array_len(0),"pool_count":lab.tusk_pool.size(),"inflight_ticks_checked":8}

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/tusk_20261015"))
	producer_checks()
	hit_checks()
	accepted_checks()
	await view_checks()
	metrics.move = Special.MOVES.tusk
	metrics.adapter = RenderingServer.get_video_adapter_name()
	metrics.checks = checks
	metrics.failures = failures
	metrics.captures = captures
	var file := FileAccess.open(Output.path("res://tests/tusk_results.json"),FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(metrics,"\t"))
	print("TUSK: ",checks," checks / ",failures.size()," failed; adapter=",metrics.adapter,"; captures=",captures)
	quit(0 if failures.is_empty() else 1)
