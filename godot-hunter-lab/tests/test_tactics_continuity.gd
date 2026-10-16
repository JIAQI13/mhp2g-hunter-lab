extends SceneTree

const Output = preload("res://tests/result_output.gd")
const Tactics = preload("res://scripts/llm_tactics.gd")
const Policy = preload("res://scripts/sandbox_tactics.gd")
var lab: Node3D
var rows: Array[Dictionary] = []
var checks: int = 0
var failures: Array[String] = []
var peaks: Dictionary = {}
var previous: Dictionary = {}
var capture_mode: bool = false
var diagnose: bool = false
var ground_height := Vector2(INF,-INF)
var pose_bound: float = 0.0
var screenshots: Array[String] = []

func _initialize() -> void:
	capture_mode = "--capture" in OS.get_cmdline_user_args()
	diagnose = "--diagnose" in OS.get_cmdline_user_args()
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error("ASSERT FAIL: "+label)

func vector(point: Vector3) -> Array:
	return [point.x,point.y,point.z]

func calibrate() -> void:
	var animator := HunterAnimator.new()
	check(animator.load_data("res://assets/bulldrome_data.json"),"real pose calibration")
	var minimum: Array[Vector3] = []
	var maximum: Array[Vector3] = []
	for bone in animator.world_pose:
		minimum.append(Vector3(INF,INF,INF))
		maximum.append(Vector3(-INF,-INF,-INF))
	for clip in [1001,lab.monster.WALK_CLIP]:
		var end: int = int(animator.data.clips[str(clip)+":0"].end)
		for frame in range(end+1):
			animator.set_animation(clip,0,frame)
			animator.tick(0)
			ground_height.x = minf(ground_height.x,animator.world_pose[2].origin.y*0.01)
			ground_height.y = maxf(ground_height.y,animator.world_pose[2].origin.y*0.01)
			for i in range(minimum.size()):
				var point: Vector3 = animator.world_pose[i].origin*0.01
				minimum[i] = minimum[i].min(point)
				maximum[i] = maximum[i].max(point)
	for i in range(minimum.size()):
		pose_bound = maxf(pose_bound,minimum[i].distance_to(maximum[i]))
	print("CALIBRATION grounded body2=",ground_height," all-frame bone envelope diameter=",pose_bound,"m; float/skin tolerance=0.00003m (existing 93-pose goldens)")

func sample(scenario: String, age: int, space: Dictionary) -> void:
	var m: Dictionary = lab.monster.state
	var a = lab.monster_animator
	var view = lab.boar_view
	var root_point: Vector3 = view.to_global(a.world_pose[1].origin*0.01+Vector3(0,view.lift,0))
	var body_point: Vector3 = view.to_global(a.world_pose[2].origin*0.01+Vector3(0,view.lift,0))
	var head_point: Vector3 = view.to_global(a.world_pose[11].origin*0.01+Vector3(0,view.lift,0))
	var volume: Dictionary = lab.monster.sandbox_special.volume()
	var row: Dictionary = {"scenario":scenario,"tick":age,"mode":m.mode,"primary":m.primary,"frame":a.tracks[0].currentframe,"blend":a.tracks[0].blend_remaining,"entity":vector(m.position*0.01),"view":vector(view.global_position),"root1":vector(root_point),"body2":vector(body_point),"head11":vector(head_point),"yaw":m.yaw,"instance":view.get_instance_id(),"mesh_instance":view._instance.get_instance_id(),"special_center":vector(volume.a) if not volume.is_empty() else null,"decision_source":lab.monster.decision_source,"tracking_stage":m.tracking_stage,"observed_target":str(m.observed_target),"committed_target":str(m.committed_target)}
	var grounded: bool = m.primary in [1001,lab.monster.WALK_CLIP] and (a.tracks[0].blend_remaining == 0 or a.tracks[0].old_clip in ["1001:0",str(lab.monster.WALK_CLIP)+":0"])
	row.grounded = grounded
	row.slam = lab.monster.sandbox_special.kind == "slam"
	var local: Array = []
	var world: Array = []
	for bone in a.world_pose:
		local.append(bone.origin*0.01)
		world.append(view.to_global(bone.origin*0.01+Vector3(0,view.lift,0)))
	if not previous.is_empty():
		var entity_step: float = (m.position*0.01-previous.entity_point).length()
		var pose_step: float = 0.0
		var world_step: float = 0.0
		for i in range(local.size()):
			pose_step = maxf(pose_step,local[i].distance_to(previous.local[i]))
			world_step = maxf(world_step,world[i].distance_to(previous.world[i]))
		var head_step: float = head_point.distance_to(previous.head_point)
		row.entity_step = entity_step
		row.pose_step = pose_step
		row.world_pose_step = world_step
		row.head_step = head_step
		peaks[scenario].entity = maxf(peaks[scenario].entity,entity_step)
		peaks[scenario].pose = maxf(peaks[scenario].pose,pose_step)
		peaks[scenario].world_pose = maxf(peaks[scenario].world_pose,world_step)
		peaks[scenario].head = maxf(peaks[scenario].head,head_step)
		if diagnose and (m.mode != previous.mode or pose_step > pose_bound):
			print("TRACE ",row)
		check(view.get_instance_id() == previous.instance and view._instance.get_instance_id() == previous.mesh_instance,"same boar and mesh instance; never respawn")
		if not row.slam and not previous.slam and m.mode not in ["charge","hit","down","dying","dead"] and previous.mode not in ["charge","hit","down","dying","dead"]:
			check(entity_step <= lab.monster.APPROACH_SPEED*0.01+0.00003,"physical walk <=18 units/tick")
		if grounded and previous.grounded:
			check(pose_step <= pose_bound+0.00003,"all-bone local continuity inside measured grounded envelope")
			check(local[2].y >= ground_height.x-0.00003 and local[2].y <= ground_height.y+0.00003,"body root does not enter underground source clip")
			var yaw_delta: int = ((int(m.yaw)-int(previous.yaw)+32768)&65535)-32768
			var radius: float = 0.0
			for point in previous.local:
				radius = maxf(radius,Vector2(point.x,point.z).length())
			check(world_step <= entity_step+pose_step+2*radius*absf(sin(yaw_delta*PI/65536.0))+0.00003,"world-pose drift explained by actual pose, yaw and translation")
		if not volume.is_empty() and previous.get("volume",{}) != {}:
			check(volume == previous.volume,"committed special geometry fixed through active/recovery")
	check(view.global_position.is_equal_approx(m.position*0.01),"view synchronized at pose submission, not deferred until UI render")
	check(a.pose[1].origin == Vector3.ZERO,"only source extraction root1 translation removed; no all-root suppression")
	check((not space.grounded_body or space.distance >= 124.999) and absf(m.position.x) <= 915.001 and absf(m.position.z) <= 915.001,"real collision/wall constraints")
	var mesh_error: float = 0.0
	for s in range(view._surfaces.size()):
		var surface: Dictionary = view._surfaces[s]
		for index in [0,surface.vertices.size()/2,surface.vertices.size()-1]:
			var expected := Vector3.ZERO
			for influence in surface.vertices[index]:
				expected += (a.world_pose[influence.bone]*influence.local_bind)*float(influence.weight)*0.01
			mesh_error = maxf(mesh_error,view.vertices[s][index].distance_to(expected))
	check(mesh_error <= 0.00003,"render skin uses same sampled pose")
	previous = row.duplicate(true)
	previous.local = local
	previous.world = world
	previous.entity_point = m.position*0.01
	previous.head_point = head_point
	previous.volume = volume
	rows.append(row)

func capture(name: String) -> void:
	await process_frame
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	var directory: String = Output.path("user://tactics_continuity/unused.json").get_base_dir()
	var path: String = directory.path_join(name+".png")
	check(not image.is_empty() and image.save_png(path) == OK,"GPU capture "+name)
	screenshots.append(ProjectSettings.globalize_path(path))

func chain(scenario: String, point: Vector3, position: Vector3, plan: Array, seed: int = 7) -> void:
	lab.reset_hunt()
	lab.monster.state.position = position
	lab.controller.state.position = point
	lab.monster.tactics.rng.seed = seed
	lab.llm.advance(lab.hunt,true)
	if not plan.is_empty():
		check(Tactics.parse_plan(JSON.stringify({"plan":plan})).ok,"selected plan references legal tactics and moves")
		lab.monster.accept_llm_plan(plan)
		lab.llm.status = "离线selected回归夹具 · 未调用真实模型"
		lab.llm.choice = " → ".join(plan.map(func(step): return step.tactic+"/"+step.move))
	lab.update_visuals()
	previous = {}
	peaks[scenario] = {"entity":0.0,"pose":0.0,"world_pose":0.0,"head":0.0}
	var captured: Dictionary = {}
	var selected: Array[String] = []
	var begun: Array[String] = []
	var finished: int = 0
	var prior_mode: String = "idle"
	for i in range(800 if plan.is_empty() else 420):
		var report: Dictionary = lab.tick_hunt({"held":0,"mag":0,"direction":0,"bits":0})
		if not plan.is_empty():
			check(lab.monster.state.primary in [1001,lab.monster.WALK_CLIP],"selected special/maneuver chain uses grounded producer clips only")
		# Assert before update_visuals, so a stale view owner cannot be hidden by rendering.
		sample(scenario,i,report.space)
		lab.update_visuals()
		for event in report.events:
			if event.event == "decision_selected":
				selected.append(event.move)
				check(event.decision_source == ("fallback" if plan.is_empty() else "llm"),"executor never substitutes fallback for valid model step")
			if event.event == "sandbox_special_begin":
				begun.append(event.special)
		if report.events.any(func(event): return event.event == "move_finished") and prior_mode == "special":
			finished += 1
		prior_mode = lab.monster.state.mode
		var special = lab.monster.sandbox_special
		var key: String = special.kind+"_"+special.stage if special.kind != "" else str(lab.monster.state.mode)
		if capture_mode and scenario == "selected" and (key not in captured or i in range(165,223) or i in [107,137,250,295,325,326]):
			captured[key] = true
			await capture(scenario+"_%03d_" % i+key)
		if not plan.is_empty() and finished == plan.size():
			break
		if plan.is_empty() and lab.hunt.round_state != "running":
			break
	if not plan.is_empty():
		check(selected == plan.map(func(step): return step.move) and begun == selected and finished == plan.size(),"entire selected chain completes in requested order")
	else:
		check(not selected.is_empty() and selected.all(func(move): return BulldromeController.MOVE_MENU.has(move)),"seeded fallback produces legal actual actions")
	peaks[scenario].selected = selected
	peaks[scenario].begun = begun
	print("CONTINUITY ",scenario," ",peaks[scenario])

func policy_checks() -> void:
	var policy = Policy.new()
	var menus: Dictionary = {}
	var fresh_laser: int = 0
	var repeated_laser: int = 0
	for sample_id in range(128):
		policy.reset()
		policy.rng.seed = sample_id
		var choice: Dictionary = policy.choose(500,0,"weapon_action",true,lab.monster.LLM_RANGES)
		menus[choice.move] = true
		check(choice.move in ["charge","laser","tusk"],"medium straight-line context never uses near turning/stink")
		policy.selected(choice.move)
		check(policy.recent == [choice.move],"recent choices owned once")
		check(policy.choose(900,22000,"evading",true,lab.monster.LLM_RANGES).move == "charge","far evasive side target uses closing, not laser rotation or long-range turn")
		fresh_laser += 1 if choice.move == "laser" else 0
		policy.reset()
		policy.selected("laser")
		policy.rng.seed = sample_id
		repeated_laser += 1 if policy.choose(500,0,"weapon_action",true,lab.monster.LLM_RANGES).move == "laser" else 0
	check(repeated_laser < fresh_laser,"matched seed sample verifies recent-move repeat weight reduction")
	print("POLICY seeds=128 fresh laser=",fresh_laser," repeated laser=",repeated_laser,"; weighted fallback only, not model inference")
	check(menus.has("charge") and menus.has("laser") and menus.has("tusk"),"finite seeds cover closing, beam and traveling pressure; not fixed sequence")
	for step in [{"tactic":"observe","move":"stink"},{"tactic":"circle_right","move":"laser"}]:
		check(Tactics.parse_plan(JSON.stringify({"plan":[step]})).ok,"one-step plan is legal, not forced laser-stink")
	for move in BulldromeController.MOVE_MENU:
		check(BulldromeController.MOVE_MENU[move].has("use") and BulldromeController.MOVE_MENU[move].has("avoid") and BulldromeController.MOVE_MENU[move].has("telegraph"),"short situational move definitions")

func run() -> void:
	lab = load("res://main.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	lab.set_physics_process(false)
	lab.panel.visible = false
	lab.llm.set_mode(false)
	calibrate()
	policy_checks()
	var plan: Array = [{"tactic":"observe","move":"laser"},{"tactic":"approach","move":"stink"}]
	await chain("selected",Vector3(0,0,600),Vector3.ZERO,plan)
	await chain("distant",Vector3(0,0,900),Vector3.ZERO,plan)
	await chain("collision",Vector3(0,0,125),Vector3.ZERO,plan)
	await chain("wall",Vector3(700,0,0),Vector3(900,0,0),plan)
	await chain("reverse",Vector3(0,0,-190),Vector3.ZERO,[{"tactic":"observe","move":"stink"},{"tactic":"observe","move":"laser"}])
	for seed in [0,7,23]:
		await chain("fallback_"+str(seed),Vector3(0,0,600),Vector3.ZERO,[],seed)
	await chain("fallback_near",Vector3(0,0,-125),Vector3.ZERO,[],23)
	await chain("fallback_wall",Vector3(700,0,0),Vector3(900,0,0),[],7)
	var result: Dictionary = {"checks":checks,"failures":failures,"peaks":peaks,"ticks":rows,"calibration":{"body2_height":vector(Vector3(ground_height.x,ground_height.y,0)),"pose_envelope_m":pose_bound,"skin_tolerance_m":0.00003},"screenshots":screenshots,"adapter":RenderingServer.get_video_adapter_name(),"network":"none; production executor selected plan injected, not real model inference"}
	var file := FileAccess.open(Output.path("user://tactics_continuity/tactics_continuity_results.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	print("TACTICS CONTINUITY: ",checks," checks / ",failures.size()," failed; GPU=",RenderingServer.get_video_adapter_name()," screenshots=",screenshots.size())
	quit(0 if failures.is_empty() else 1)
