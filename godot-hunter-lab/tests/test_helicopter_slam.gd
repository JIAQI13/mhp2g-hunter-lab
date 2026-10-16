extends SceneTree

const Special = preload("res://scripts/sandbox_special.gd")
const Output = preload("res://tests/result_output.gd")
var lab: Node3D
var checks: int = 0
var failures: Array[String] = []
var captures: Array[String] = []
var stages: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func step(held: int = 0, mag: int = 0, direction: int = 0) -> Dictionary:
	return lab.tick_hunt({"held":held,"mag":mag,"direction":direction,"bits":0})

func fixture(guard: bool = false, wall: bool = false) -> void:
	lab.monster.sandbox_motion_enabled = true
	lab.monster.sandbox_specials_enabled = true
	lab.reset_hunt()
	lab.monster.state.position = Vector3(850,0,850) if wall else Vector3.ZERO
	lab.controller.state.position = Vector3(950,0,950) if wall else Vector3(0,0,320)
	if guard:
		lab.controller.state.flags410 |= 8
		lab.controller.force_action(2,3)
	check(lab.monster.begin_special("slam",lab.controller.state.position),"slam enters current-observation readiness")
	var prep: int = 0
	var max_step: float = 0.0
	for i in range(180):
		var before: Vector3 = lab.monster.state.position
		prep += 1 if lab.monster.state.mode == "prepare" else 0
		step(HunterController.R if guard else 0)
		max_step = maxf(max_step,before.distance_to(lab.monster.state.position))
		if lab.monster.sandbox_special.kind == "slam":
			break
	check(prep >= BulldromeController.PREPARE_TICKS and lab.monster.sandbox_special.age == 0 and lab.monster.state.committed_target == null,"prepare18 and spatially corrected takeoff entry")
	check(max_step <= 18.01 and lab.monster.state.position.y == 0.0,"limited continuous ground readiness; no teleport")

func until_age(age: int, held: int = 0) -> void:
	for i in range(220):
		if lab.monster.sandbox_special.kind == "" or lab.monster.sandbox_special.age >= age:
			break
		step(held)

func target(point: Vector3, eligible: bool = true) -> Array[Dictionary]:
	return [{"identity":"hunter","generation":1,"eligible":eligible,"volumes":[{"kind":"sphere","a":point,"radius":0.01},{"kind":"sphere","a":point,"radius":0.01}]}]

func producer_checks() -> void:
	var owner = Special.new()
	owner.begin("slam",Vector3.ZERO,0)
	var lock := Vector3.ZERO
	var max_y: float = 0.0
	var impacts: int = 0
	var high_travel: float = 0.0
	for age in range(1,200):
		var previous: Vector3 = owner.origin
		var yaw: int = owner.yaw
		owner.tick(Vector3(100 if age < 70 else -100,0,180))
		if owner.kind == "":
			check(age == 199,"bounded total199 ticks including all stages")
			break
		stages[owner.stage] = int(stages.get(owner.stage,0))+1
		check(owner.origin.y >= 0 and owner.origin.y <= 5.00001,"actual altitude always within floor..5m")
		check(owner.origin.distance_to(previous) <= 0.50001,"continuous 3D trajectory no jumps")
		var spin: int = ((owner.yaw-yaw+32768)&65535)-32768
		check(absi(spin) <= Special.SLAM.spin_step,"bounded entity yaw for mesh and hurtbox")
		max_y = maxf(max_y,owner.origin.y)
		if owner.stage == "hover":
			high_travel += Vector2(owner.origin.x-previous.x,owner.origin.z-previous.z).length()
		if owner.stage == "ascent":
			check(owner._travel <= Special.SLAM.ascent_budget+0.00001,"ascent reserves finite tracking budget for high hover")
		if owner.age == 99:
			lock = owner.landing_point
		if owner.age >= 99:
			check(owner.landing_point == lock and Vector2(owner.origin.x,owner.origin.z) == Vector2(lock.x,lock.z),"lock point survives moving hunter; descent has no homing")
		if owner.stage == "active":
			impacts += 1
			check(owner.origin.y == 0 and owner.volume().radius == 2.0,"impact only on exact landing floor; ring radius matches capsule")
		else:
			check(owner.contacts(target(owner.origin)).is_empty() and owner.volume().is_empty(),"no takeoff/ascent/hover/descent/recovery damage")
	check(max_y == 5.0 and impacts == 6,"5m real altitude and impact6 ticks")
	check(high_travel > 0.7 and high_travel <= 0.80001,"high-altitude current-observation movement has reserved0.8m budget")
	metrics.high_hover_travel = high_travel
	owner.begin("slam",Vector3.ZERO,0)
	for i in range(133):
		owner.tick(Vector3(0,0,300))
	var point: Vector3 = owner.landing_point+Vector3(0,0.8,0)
	check(owner.contacts(target(point,false)).is_empty(),"evade eligibility checked before history")
	check(owner.contacts(target(point)).size() == 1 and owner.contacts(target(point)).is_empty(),"one contact across hurtboxes and impact frames")
	check(owner.contacts(target(point+Vector3(2.5,0,0))).is_empty(),"outside radius does not hit")
	owner.begin("slam",Vector3(915,0,915),0)
	for i in range(99):
		owner.tick(Vector3(1000,0,1000))
	check(owner._travel <= 2.00001,"finite owner air pursuit budget; arena correction belongs to session")
	owner.cancel()
	var previous: float = owner.origin.y
	for i in range(20):
		owner.tick()
		check(previous-owner.origin.y >= 0 and previous-owner.origin.y <= 0.25001 and owner.volume().is_empty(),"cancelled owner descends continuously without impact")
		previous = owner.origin.y
	check(owner.kind == "" and owner.origin.y == 0 and owner._history.is_empty(),"bounded cancelled flight clears clock/history at ground")

func trajectory_checks() -> void:
	fixture()
	var origin: Vector3 = lab.monster.state.position
	var head_before: Vector3 = lab.hunt._monster_volumes(lab.monster.state)[0].a
	var same_mesh: int = lab.boar_view._instance.get_instance_id()
	for age in range(1,140):
		var previous: Vector3 = lab.monster.state.position
		if age in [35,60]:
			lab.controller.state.position.x += 50
		var result := step()
		var s: Dictionary = lab.monster.sandbox_special.snapshot()
		check(lab.monster.state.position.is_equal_approx(s.origin*100),"entity and trajectory share spatial owner")
		check(lab.boar_view.position.is_equal_approx(s.origin) and is_equal_approx(lab.boar_view.rotation.y,s.yaw*TAU/65536.0),"entire original boar follows actual altitude and yaw")
		check(lab.boar_view._instance.get_instance_id() == same_mesh and lab.monster.state.applied_root_delta == Vector3.ZERO,"same full mesh and no duplicated ground/source root integration")
		if s.origin.y > 0:
			check(not result.space.monster_grounded and not result.space.grounded_body,"actual altitude disables ground-only push blocking")
		check(lab.monster.state.observed_target == lab.controller.state.position,"current observations stay fresh during committed trajectory")
		if age == 75:
			var shape: Dictionary = lab.hunt._monster_volumes(lab.monster.state)[0]
			check(shape.a.y-head_before.y > 4.9,"hurtbox rises with actual entity, not visual-only lift")
			lab.controller.state.position = Vector3(lab.monster.state.position.x,0,lab.monster.state.position.z)
			var p: Vector3 = lab.controller.state.position
			var space: Dictionary = lab.hunt._resolve_space(p,previous)
			check(not space.blocked and lab.controller.state.position == p,"hunter can walk under high boar without remote push")
		if age == 99:
			var locked: Vector3 = s.landing_point
			lab.controller.state.position = (locked+Vector3(3.0,0,0))*100
			metrics.lock_point = [locked.x,locked.y,locked.z]
		if age >= 99:
			check(Vector2(s.origin.x,s.origin.z).is_equal_approx(Vector2(metrics.lock_point[0],metrics.lock_point[2])),"actual moving hunter cannot change locked landing")
	check(lab.hunt.monster_hits == 0 and lab.controller.state.hp == 100,"lateral position fixture outside locked ring avoids slam")
	metrics.trajectory_origin = [origin.x,origin.y,origin.z]

func walk_escape_checks() -> void:
	fixture()
	until_age(99)
	var point: Vector3 = lab.monster.sandbox_special.landing_point*100
	var start: Vector3 = lab.controller.state.position
	check(Vector2(start.x-point.x,start.z-point.z).length() < 200,"actual hunter starts inside locked warning ring")
	for i in range(34):
		step(0,127,0)
		check(lab.monster.state.committed_target.is_equal_approx(point),"real movement input cannot retarget locked descent")
	var distance: float = Vector2(lab.controller.state.position.x-point.x,lab.controller.state.position.z-point.z).length()
	check(distance > 240 and lab.controller.state.hp == 100 and lab.hunt.monster_hits == 0,"actual ground locomotion walks out during fixed warning/drop, no position injection")
	metrics.walk_escape = {"ticks":34,"distance_from_lock":distance,"travel":start.distance_to(lab.controller.state.position)}

func airborne_hit_checks() -> void:
	fixture()
	until_age(75)
	# Elevated hunter fixture tests actual 3D attack eligibility, not terrain support.
	lab.controller.state.floor_height = 500.0
	lab.controller.state.position = lab.monster.state.position+Vector3(0,0,350)
	lab.controller.state.yaw = 32768
	lab.controller.state.target = 32768
	lab.controller.state.flags410 |= 8
	check(lab.controller.force_action(1,0),"elevated actual greatsword fixture starts attack")
	var hp: int = lab.monster.state.hp
	for i in range(30):
		step()
	check(lab.monster.state.position.y > 0 and lab.monster.state.hp < hp and lab.hunt.hunter_hits > 0,"actual airborne hurtbox can receive hunter attack via session; no full-flight invincibility")
	lab.controller.state.floor_height = 0.0

func impact_checks() -> void:
	for guard in [false,true]:
		fixture(guard)
		var held: int = HunterController.R if guard else 0
		until_age(99,held)
		var point: Vector3 = lab.monster.sandbox_special.landing_point*100
		lab.controller.state.position = point+Vector3(0,0,160)
		lab.controller.state.yaw = 32768
		lab.controller.state.target = 32768
		until_age(132,held)
		check(lab.hunt.monster_hits == 0 and lab.controller.state.hp == 100,"full aerial path harmless until exact impact")
		var contact := step(held)
		check(contact.events.any(func(e): return e.event == "incoming_contact" and e.get("special","") == "slam" and e.status == ("guarded" if guard else "pending")),"existing guard or incoming queue at landing")
		check(lab.controller.state.hp == 100 and lab.monster.state.position.y == 0,"session is sole pending HP producer, landing once")
		step(held)
		check(lab.controller.state.hp == (94 if guard else 75) and lab.hunt.monster_hits == 1,"one damage25 or original guard chip6")
		until_age(139,held)
		check(lab.hunt.monster_hits == 1 and lab.monster.sandbox_special.stage == "recovery","no repeated impact and clear punishable recovery")
	fixture()
	until_age(99)
	var landing: Vector3 = lab.monster.sandbox_special.landing_point*100
	lab.controller.state.position = landing+Vector3(0,0,350)
	until_age(139)
	lab.controller.state.position = landing+Vector3(0,0,135)
	lab.controller.state.flags410 |= 8
	lab.controller.state.yaw = 32768
	lab.controller.state.target = 32768
	check(lab.controller.force_action(1,0),"greatsword slash ready after sidestepping impact")
	var hp: int = lab.monster.state.hp
	for i in range(30):
		step()
	check(lab.monster.state.hp < hp and lab.hunt.hunter_hits > 0,"real greatsword attack punishes grounded recovery")
	fixture()
	until_age(99)
	lab.controller.state.position = lab.monster.sandbox_special.landing_point*100+Vector3(0,0,160)
	until_age(131)
	lab.controller.state.flags410 |= 8
	lab.controller.force_action(0,28)
	step()
	step()
	check(lab.controller.state.internal_window > 0 and lab.hunt.monster_hits == 0,"actual roll collision window rejects impact")
	fixture(false,true)
	for i in range(132):
		var result := step()
		var point: Vector3 = lab.monster.state.position
		check(absf(point.x) <= 915.001 and absf(point.z) <= 915.001,"session keeps ascending/high/locked/descending boar within arena")
		check(lab.monster.sandbox_special.origin.is_equal_approx(point*0.01),"session arena-corrected flight pose feeds owning trajectory")
		if point.y > 0:
			check(not result.space.grounded_body,"near-wall air never applies 2D body constraints")
	var fixed: Vector3 = lab.monster.sandbox_special.landing_point*100
	lab.controller.state.position = fixed+Vector3(40,0,40)
	var result := step()
	check(result.space.grounded_body and result.space.distance >= 124.999 and lab.monster.state.position.is_equal_approx(fixed),"near-corner landing anchors boar; hunter/wall correction cannot move lock point")
	check(absf(lab.controller.state.position.x) <= 960.001 and absf(lab.controller.state.position.z) <= 960.001,"landing hunter remains in bounded arena")

func cancellation_checks() -> void:
	for reason in ["hit","down","death","disable","specials_disable","source","hunter_death","reset","mode"]:
		fixture()
		until_age(90)
		var before: Vector3 = lab.monster.state.position
		match reason:
			"hit": lab.monster.take_damage(120,0)
			"down": lab.monster.take_damage(250,0)
			"death": lab.monster.take_damage(2000,0)
			"disable": lab.monster.ai_enabled = false
			"specials_disable": lab.monster.sandbox_specials_enabled = false
			"source": lab.monster.sandbox_motion_enabled = false
			"hunter_death": lab.controller.state.hp = 0
			"reset": lab.reset_hunt()
			"mode": lab.set_hunt_mode(false)
		if reason in ["reset","mode"]:
			check(lab.monster.state.position.y == 0 and lab.monster.sandbox_special.kind == "","explicit round/mode reset may reposition to ground")
		else:
			step()
			check(lab.monster.state.position.y > 0 and is_equal_approx(before.y-lab.monster.state.position.y,25.0),"no cancellation teleport from5m: "+reason)
			for i in range(19):
				var y: float = lab.monster.state.position.y
				step()
				check(lab.monster.state.position.y >= 0 and y-lab.monster.state.position.y <= 25.001,"continuous safe descent: "+reason)
			check(lab.monster.state.position.y == 0 and lab.monster.sandbox_special.kind == "" and lab.hunt.monster_hits == 0,"ground landing cleanup without damaging impact: "+reason)
		lab.update_visuals()
		check(not lab.slam_warning.visible and not lab.slam_impact.visible and not lab.slam_spin.visible,"bounded visual cleanup: "+reason)
		if reason in ["hit","down","death"]:
			var result := step()
			check(result.events.any(func(e): return e.event == "monster_reaction"),"queued reaction begins only after reaching floor: "+reason)
		lab.set_hunt_mode(true)

func phase_cancel_checks() -> void:
	for age in [24,50,99,128,133,140]:
		for reason in ["hit","disable"]:
			fixture()
			until_age(age)
			var y: float = lab.monster.state.position.y
			var hits: int = lab.hunt.monster_hits
			if reason == "hit":
				lab.monster.take_damage(120,0)
			else:
				lab.monster.ai_enabled = false
			var cancellation: Dictionary = step()
			if y > 0:
				check(cancellation.events.any(func(e): return e.event == "move_cancelled" and e.move == "slam"),"one explicit continuous-landing cancellation event")
				check(y-lab.monster.state.position.y <= 25.001 and lab.monster.state.position.y >= 0,"phase cancellation does not teleport: "+str(age))
				for i in range(20):
					if lab.monster.sandbox_special.kind == "":
						break
					step()
			check(lab.monster.sandbox_special.kind == "" and lab.hunt.monster_hits == hits,"cancel windup/ascent/locked/descent/impact/recovery without additional impact: "+str(age))
			lab.update_visuals()
			check(not lab.slam_spin.visible and not lab.slam_warning.visible and not lab.slam_impact.visible,"phase cancellation visual cleanup: "+str(age))

func plan_checks() -> void:
	lab.monster.sandbox_motion_enabled = true
	lab.monster.sandbox_specials_enabled = true
	lab.reset_hunt()
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,320)
	var plan := {"plan":[{"tactic":"observe","move":"slam"},{"tactic":"approach","move":"laser"}]}
	check(BulldromeController.MOVE_MENU.size() == 6 and LlmTactics.parse_plan(JSON.stringify(plan)).ok and LlmTactics.PROMPT.contains("laser, stink, tusk, slam") and not LlmTactics.PROMPT.contains("|slam"),"six-move allowlist/prompt accepts bounded slam plan")
	check(lab.llm.observe(lab.hunt).legal_moves.keys() == BulldromeController.MOVE_MENU.keys() and lab.llm.observe(lab.hunt).slam_ready,"six-move source menu/observation readiness")
	lab.llm.pending = true
	lab.llm._started = Time.get_ticks_msec()
	lab.monster.llm_pending = true
	var body: PackedByteArray = JSON.stringify({"choices":[{"message":{"content":JSON.stringify(plan)}}]}).to_utf8_buffer()
	lab.llm._completed(HTTPRequest.RESULT_SUCCESS,200,[],body,lab.llm.decision_id,lab.hunt.round_generation)
	check(lab.monster.llm_plan == plan.plan,"offline completion-boundary mock installs slam; no key/network")
	var begun: Array = []
	var locked: bool = false
	for i in range(520):
		if locked:
			lab.controller.state.position = Vector3(330,0,380)
		var result := step()
		for event in result.events:
			if event.event == "sandbox_special_begin":
				begun.append(event.special)
			if event.event == "slam_lock":
				locked = true
		if begun.size() == 2:
			break
	check(begun == ["slam","laser"] and locked,"accepted ordered continuation through full slam recovery and next readiness")
	metrics.accepted_moves = begun
	var log_file := FileAccess.open(lab.llm.log_path,FileAccess.READ)
	var logged_lock: bool = false
	while log_file != null and not log_file.eof_reached():
		var line: String = log_file.get_line()
		if line.is_empty():
			continue
		var value: Variant = JSON.parse_string(line)
		if value is Dictionary and value.get("event","") == "slam_lock" and value.get("decision_source","") == "llm":
			logged_lock = true
	check(logged_lock,"local execution log retains actual slam lock and accepted source")
	fixture()
	until_age(199)
	check(not lab.monster.slam_available() and not lab.monster.begin_special("slam",lab.controller.state.position),"360-tick launch frequency gate survives completion")
	lab.monster.accept_llm_plan(plan.plan)
	check(lab.monster.llm_plan.is_empty(),"LLM cannot bypass unavailable slam frequency")
	lab.llm.pending = true
	lab.llm._started = Time.get_ticks_msec()
	lab.monster.llm_pending = true
	lab.llm._completed(HTTPRequest.RESULT_SUCCESS,200,[],body,lab.llm.decision_id,lab.hunt.round_generation)
	check(lab.llm.choice == "规则" and lab.llm.status.contains("拒绝") and lab.monster.llm_plan.is_empty(),"completion adapter cannot falsely report unavailable plan accepted")
	var policy = SandboxTactics.new()
	var fresh: int = 0
	var repeated: int = 0
	for seed in range(128):
		policy.reset()
		policy.rng.seed = seed
		fresh += 1 if policy.choose(320,0,"charging_weapon",true,BulldromeController.LLM_RANGES).move == "slam" else 0
		policy.selected("slam")
		policy.rng.seed = seed
		repeated += 1 if policy.choose(320,0,"charging_weapon",true,BulldromeController.LLM_RANGES).move == "slam" else 0
		check(policy.choose(320,0,"charging_weapon",true,BulldromeController.LLM_RANGES,false).move != "slam","fallback honors frequency availability")
	check(fresh > repeated and fresh > 0,"situational default weights and history reduce sky repetition")
	metrics.policy = {"seeds":128,"fresh_slam":fresh,"after_slam":repeated}
	lab.reset_hunt()
	lab.monster.state.position = Vector3.ZERO
	lab.controller.state.position = Vector3(0,0,320)
	for seed in range(128):
		lab.monster.tactics.rng.seed = seed
		if lab.monster.tactics.choose(320,0,"locomotion_or_idle",true,BulldromeController.LLM_RANGES).move == "slam":
			lab.monster.tactics.rng.seed = seed
			break
	for i in range(180):
		step()
		if lab.monster.sandbox_special.kind == "slam":
			break
	check(lab.monster.sandbox_special.kind == "slam" and lab.monster.decision_source == "fallback","actual default game encounters slam without LLM/explicit move")
	metrics.default_tick = lab.hunt.ticks

func capture(name: String, detail: bool = false) -> void:
	if not "--capture" in OS.get_cmdline_user_args():
		return
	lab.update_visuals()
	if detail:
		lab.hud.get_parent().visible = false
		lab.camera.position = Vector3(8,6,9)
		lab.camera.look_at(Vector3(0,2.5,1))
	await process_frame
	RenderingServer.force_draw(false)
	var path: String = "res://screenshots/helicopter_slam_20261015/"+name+".png"
	check(root.get_texture().get_image().save_png(path) == OK,"actual GPU screenshot "+name)
	captures.append(ProjectSettings.globalize_path(path))
	lab.hud.get_parent().visible = true

func view_checks() -> void:
	fixture()
	until_age(24)
	await capture("windup_tick24")
	until_age(50)
	await capture("ascent_tick50",true)
	until_age(75)
	lab.panel.visible = true
	lab.update_visuals()
	var framed: bool = true
	for surface in lab.boar_view.vertices:
		for point in surface:
			framed = framed and lab.camera.is_position_in_frustum(lab.boar_view._instance.to_global(point))
	check(framed,"default player camera with menu frames full boar at5m; no forced orbit/fov")
	await capture("default_high_tick75")
	lab.panel.visible = false
	await capture("high_tick75",true)
	until_age(99)
	lab.controller.state.position = lab.monster.sandbox_special.landing_point*100+Vector3(300,0,0)
	await capture("locked_tick99")
	await capture("locked_detail_tick99",true)
	var snapshot: Dictionary = lab.monster.sandbox_special.snapshot()
	var hp: int = lab.controller.state.hp
	for i in range(5):
		lab.update_visuals()
	check(lab.monster.sandbox_special.snapshot() == snapshot and lab.controller.state.hp == hp,"render never consumes flight clock/position/history/HP")
	until_age(128)
	await capture("descent_tick128",true)
	until_age(133)
	await capture("impact_tick133",true)
	until_age(140)
	await capture("recovery_tick140")
	until_age(199)
	lab.update_visuals()
	check(not lab.slam_warning.visible and not lab.slam_impact.visible and not lab.slam_shadow.visible,"expiry hides all owned effects with zero particles/nodes accumulated")

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots/helicopter_slam_20261015"))
	producer_checks()
	trajectory_checks()
	walk_escape_checks()
	airborne_hit_checks()
	impact_checks()
	cancellation_checks()
	phase_cancel_checks()
	plan_checks()
	await view_checks()
	metrics.merge({"parameters":Special.SLAM,"stages":stages,"checks":checks,"failures":failures,"captures":captures,"adapter":RenderingServer.get_video_adapter_name()})
	var file := FileAccess.open(Output.path("res://tests/helicopter_slam_results.json"),FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(metrics,"\t"))
	print("HELICOPTER SLAM: ",checks," checks / ",failures.size()," failed; adapter=",metrics.adapter," captures=",captures)
	quit(0 if failures.is_empty() else 1)
